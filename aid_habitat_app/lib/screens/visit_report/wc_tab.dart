import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../services/save_debounce.dart';
import '../../components/brand_colors.dart';
import '../../components/form_widgets.dart';
import '../../components/soft_transitions.dart';
import 'bathroom_tab.dart'
    show
        SanitaryLevelIcon,
        buildSanitaryLevelSelections,
        sanitaryLevelIconIndexFromLabel,
        sanitaryLevelIconLayerCount;

/// WC tab — parité 1:1 avec `WCForm` React.
///
/// UI :
/// - Pills de niveau (WC 1, 2, …) + bouton "+" pour en ajouter
/// - QuickNav 2 tabs : Configuration et équipements / Porte
/// - Configuration : Hauteur de cuvette (Bonne/Trop basse) + dimension cm +
///   Barre de relèvement (Présente/Absente) + Observations (textarea)
/// - Porte : Largeur + Dimension cm + Sens d'ouverture
class WcTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;
  final WcTabController? controller;
  final VoidCallback? onAddRoomRequested;

  /// Incremented by the parent when the housing (Accessibilité > Intérieur)
  /// changes so this tab re-derives its instances from the latest selections.
  final int housingRefreshToken;

  const WcTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.controller,
    this.onAddRoomRequested,
    this.housingRefreshToken = 0,
  });

  @override
  State<WcTab> createState() => _WcTabState();
}

class WcTabController {
  Future<void> Function()? _flushPendingSave;
  void Function(String levelField)? _selectLevelField;
  String? _pendingLevelField;

  Future<void> flushPendingSave() async {
    final flush = _flushPendingSave;
    if (flush == null) return;
    await flush();
  }

  void selectLevelField(String levelField) {
    final select = _selectLevelField;
    if (select == null) {
      _pendingLevelField = levelField;
      return;
    }
    select(levelField);
  }

  void _attach(
    Future<void> Function() flush,
    void Function(String levelField) selectLevelField,
  ) {
    _flushPendingSave = flush;
    _selectLevelField = selectLevelField;
    final pending = _pendingLevelField;
    if (pending != null) {
      _pendingLevelField = null;
      selectLevelField(pending);
    }
  }

  void _detach(Future<void> Function() flush) {
    if (_flushPendingSave == flush) {
      _flushPendingSave = null;
      _selectLevelField = null;
    }
  }
}

class _WcTabState extends State<WcTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  DiagnosticSanitaire? _diagnostic;
  bool _loaded = false;
  Timer? _saveTimer;
  Future<void>? _saveFuture;
  int _activeLevelIndex = 0;
  String? _pendingLevelField;
  // (Ancien Set de clés d'édition pour le repli "CollapsedValueRow"
  // retiré : les toggles restent maintenant toujours visibles.)

  // _refreshTimer supprimé 2026-05-12 (refactor sync à la (re)connexion).

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(_flushPendingSave, _selectLevelField);
    _load();
    // Refactor 2026-05-12 : suppression du polling 2 s. L'onglet WC
    // charge ses données au mount + à chaque changement d'onglet
    // (didChangeDependencies/`setState` upstream). Les modifs faites
    // depuis l'autre device apparaîtront au prochain événement de
    // (re)connexion (foreground/reconnexion/login).
  }

  @override
  void dispose() {
    widget.controller?._detach(_flushPendingSave);
    final hadPendingSave = _saveTimer?.isActive ?? false;
    _saveTimer?.cancel();
    if (hadPendingSave) unawaited(_save());
    super.dispose();
  }

  Future<void> _load() async {
    // Phase 1 — rendu immédiat depuis le cache local SQLite.
    await _hydrateFromLocal();
    // Phase 2 — refresh serveur en arrière-plan ; rehydrate si nouvelles
    // données. En offline on reste sur le cache local.
    try {
      await widget.repository.refreshDiagnosticSanitaireFromRemote(
        widget.dossier.id,
      );
    } catch (_) {
      return;
    }
    if (!mounted) return;
    await _hydrateFromLocal();
  }

  Future<void> _hydrateFromLocal() async {
    final result = await widget.repository.fetchDiagnosticSanitaire(
      widget.dossier.id,
    );
    final housingRow = await widget.repository.fetchHousingRaw(
      widget.dossier.id,
    );
    final selectedLevels = buildSanitaryLevelSelections(housingRow, 'WC');
    if (!mounted) return;

    final previous = result?.wcInstances ?? const <WcInstance>[];
    final nextInstances = <WcInstance>[];
    for (final lvl in selectedLevels) {
      final existing = previous
          .where((i) => i.levelField == lvl.field)
          .toList();
      if (existing.isNotEmpty) {
        nextInstances.add(
          WcInstance(
            id: existing.first.id,
            levelField: lvl.field,
            levelLabel: lvl.label,
            wcCuvetteBonneHauteur: existing.first.wcCuvetteBonneHauteur,
            wcCuvetteTropBasse: existing.first.wcCuvetteTropBasse,
            wcCuvetteTropHaute: existing.first.wcCuvetteTropHaute,
            wcCuvetteHauteur: existing.first.wcCuvetteHauteur,
            wcBarreRelevement: existing.first.wcBarreRelevement,
            porteWcLargeurSuffisante: existing.first.porteWcLargeurSuffisante,
            porteWcDimension: existing.first.porteWcDimension,
            porteWcSensAdapte: existing.first.porteWcSensAdapte,
            observationEquipementsUtilisation:
                existing.first.observationEquipementsUtilisation,
          ),
        );
      } else {
        nextInstances.add(
          WcInstance(
            id: 'wc_${lvl.field}',
            levelField: lvl.field,
            levelLabel: lvl.label,
          ),
        );
      }
    }

    final pendingLevelField = _pendingLevelField;
    var nextActiveLevelIndex = _activeLevelIndex;
    if (pendingLevelField != null) {
      final idx = nextInstances.indexWhere(
        (instance) => instance.levelField == pendingLevelField,
      );
      if (idx >= 0) {
        nextActiveLevelIndex = idx;
        _pendingLevelField = null;
      }
    }

    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: result?.sdbInstances ?? const [],
        wcInstances: nextInstances,
      );
      _activeLevelIndex = nextActiveLevelIndex;
      if (_activeLevelIndex >= nextInstances.length) {
        _activeLevelIndex = 0;
      }
      _loaded = true;
    });
  }

  @override
  void didUpdateWidget(covariant WcTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(_flushPendingSave);
      widget.controller?._attach(_flushPendingSave, _selectLevelField);
    }
    if (oldWidget.dossier.id != widget.dossier.id ||
        oldWidget.housingRefreshToken != widget.housingRefreshToken) {
      _load();
    }
  }

  List<WcInstance> get _instances => _diagnostic?.wcInstances ?? [];

  WcInstance? get _active {
    if (_instances.isEmpty) return null;
    final idx = _activeLevelIndex.clamp(0, _instances.length - 1).toInt();
    return _instances[idx];
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(kSaveDebouncePills, _save);
  }

  Future<void> _save() async {
    final diagnostic = _diagnostic;
    if (diagnostic == null) return;
    // Pas de setState(_saving) — voir dossier_screen.dart.
    final saveFuture = _saveMergedDiagnostic(diagnostic);
    _saveFuture = saveFuture;
    try {
      await saveFuture;
    } finally {
      if (_saveFuture == saveFuture) {
        _saveFuture = null;
      }
    }
  }

  Future<void> _saveMergedDiagnostic(DiagnosticSanitaire diagnostic) async {
    final current = await widget.repository.fetchDiagnosticSanitaire(
      widget.dossier.id,
    );
    await widget.repository.upsertDiagnosticSanitaire(
      widget.dossier.id,
      DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: current?.sdbInstances ?? diagnostic.sdbInstances,
        wcInstances: diagnostic.wcInstances,
      ),
    );
  }

  Future<void> _flushPendingSave() async {
    _saveTimer?.cancel();
    final inFlight = _saveFuture;
    if (inFlight != null) await inFlight;
    await _save();
  }

  void _selectLevelField(String levelField) {
    final idx = _instances.indexWhere((i) => i.levelField == levelField);
    if (idx < 0) {
      _pendingLevelField = levelField;
      return;
    }
    if (_activeLevelIndex == idx) return;
    if (!mounted) {
      _activeLevelIndex = idx;
      return;
    }
    setState(() {
      _activeLevelIndex = idx;
    });
  }

  void _updateActive(WcInstance updated) {
    if (_active == null) return;
    final idx = _activeLevelIndex.clamp(0, _instances.length - 1).toInt();
    final next = List<WcInstance>.from(_instances)..[idx] = updated;
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: _diagnostic?.sdbInstances ?? [],
        wcInstances: next,
      );
    });
    _scheduleSave();
  }

  // Instances are auto-derived from Accessibilité > Intérieur > Niveaux &
  // pièces. No manual add/remove.

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildLevelPills(),
        Expanded(
          child: HorizontalSlideSwitcher(
            index: _instances.isEmpty ? -1 : _activeLevelIndex,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_instances.isEmpty)
                    _buildEmptyState()
                  else ...[
                    _buildMain(),
                    const SizedBox(height: 14),
                    _buildDoor(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Center(
        child: SizedBox(
          width: 220,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onAddRoomRequested?.call(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF2ECF5),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFD8D0DC), width: 1.5),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add, size: 16, color: Color(0xFF554265)),
                  SizedBox(width: 8),
                  Text(
                    'Ajouter un wc',
                    style: TextStyle(
                      color: Color(0xFF554265),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLevelPills() {
    final labels = _instances.isEmpty
        ? const ['WC']
        : _instances.map((instance) => instance.levelLabel).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: const Color(0xFFF2ECF5),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: _buildLevelNavItem(
                label: labels[i],
                index: i,
                total: labels.length,
                active: _instances.isEmpty || _activeLevelIndex == i,
                onTap: _instances.isEmpty
                    ? () {}
                    : () => setState(() => _activeLevelIndex = i),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLevelNavItem({
    required String label,
    required int index,
    required int total,
    required bool active,
    required VoidCallback onTap,
  }) {
    const labelColor = Color(0xFF0E1116);
    final iconIndex = sanitaryLevelIconIndexFromLabel(label);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SanitaryLevelIcon(
              activeIndexFromBottom: iconIndex,
              layerCount: sanitaryLevelIconLayerCount(iconIndex),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: labelColor,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              height: 1.5,
              width: 28,
              decoration: BoxDecoration(
                color: active ? kBrandPurple : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sections
  // ---------------------------------------------------------------------------

  Widget _buildMain() {
    final a = _active!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Cuvette : 3 états mutuellement exclusifs sur 2 lignes —
        // demande utilisateur 2026-05-04. Layout :
        //   ligne 1 : [Trop basse] [Trop haute]
        //   ligne 2 : [    Bonne hauteur     ]  (full width)
        // L'option sélectionnée est en violet plein, les deux autres
        // grisées. Tap = mutuellement exclusif (toujours exactement
        // une option active, par défaut « Bonne hauteur »).
        _buildCuvetteToggle(a),
        const SizedBox(height: 14),
        FormNumberField(
          label: 'Hauteur cuvette',
          value: a.wcCuvetteHauteur,
          unit: 'cm',
          onChanged: (v) => _updateActive(
            _copy(a, wcCuvetteHauteur: v, wcCuvetteHauteurNull: v == null),
          ),
        ),
        const SizedBox(height: 14),
        _collapsibleToggle(
          instanceId: a.id,
          fieldName: 'wcBarre',
          label: 'Barre de relèvement',
          options: const ['Présente', 'Absente'],
          selected: a.wcBarreRelevement ? 'Présente' : 'Absente',
          onChanged: (v) =>
              _updateActive(_copy(a, wcBarreRelevement: v == 'Présente')),
        ),
      ],
    );
  }

  Widget _buildDoor() {
    final a = _active!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _collapsibleToggle(
          instanceId: a.id,
          fieldName: 'porteWcLargeur',
          label: 'Largeur de porte',
          options: const ['Suffisante', 'À revoir'],
          // Tri-state : null → '' (pas de pill highlight), true →
          // 'Suffisante', false → 'À revoir'. Permet le décochage par
          // reclic (refonte 2026-05-16, même pattern que bathroom_tab).
          selected: _boolPillValue(
            a.porteWcLargeurSuffisante,
            trueLabel: 'Suffisante',
            falseLabel: 'À revoir',
          ),
          onChanged: (v) => _updateActive(
            _copy(
              a,
              porteWcLargeurSuffisante: v.isEmpty ? null : v == 'Suffisante',
              porteWcLargeurSuffisanteNull: v.isEmpty,
            ),
          ),
        ),
        const SizedBox(height: 14),
        FormNumberField(
          label: 'Dimension de porte',
          value: a.porteWcDimension,
          unit: 'cm',
          onChanged: (v) => _updateActive(
            _copy(a, porteWcDimension: v, porteWcDimensionNull: v == null),
          ),
        ),
        const SizedBox(height: 14),
        _collapsibleToggle(
          instanceId: a.id,
          fieldName: 'porteWcSens',
          label: "Sens d'ouverture",
          options: const ['Intérieur', 'Extérieur'],
          selected: _boolPillValue(
            a.porteWcSensAdapte,
            trueLabel: 'Intérieur',
            falseLabel: 'Extérieur',
          ),
          onChanged: (v) => _updateActive(
            _copy(
              a,
              porteWcSensAdapte: v.isEmpty ? null : v == 'Intérieur',
              porteWcSensAdapteNull: v.isEmpty,
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Toggle toujours visible (ancien « repli en CollapsedValueRow »
  /// retiré à la demande utilisateur — aucun format ne change dans le
  /// relevé de visite, sauf les niveaux Accessibilité).
  Widget _collapsibleToggle({
    required String instanceId,
    required String fieldName,
    required String label,
    required List<String> options,
    required String selected,
    required ValueChanged<String> onChanged,
  }) {
    return FormToggleGroup(
      label: label,
      options: options,
      selected: selected,
      // expand: false → pills dimensionnés au contenu, alignés à
      // GAUCHE via le Wrap interne.
      expand: false,
      onChanged: onChanged,
    );
  }

  /// Toggle 3-états pour la hauteur de cuvette (Trop basse / Trop haute /
  /// Bonne hauteur) — layout demandé par l'utilisateur :
  ///   ligne 1 : 2 chips moitié-largeur côte à côte
  ///   ligne 2 : 1 chip pleine largeur en dessous
  /// Mutuellement exclusif : un tap définit l'état actif et désactive
  /// les deux autres.
  ///
  /// Refonte 2026-05-16 : si l'ergo recliquait la chip déjà active, le
  /// state ne changeait pas (no-op) → pas de décochage possible. Fix :
  /// reclic sur la chip active → toutes les 3 à false (= "non
  /// renseigné", aucune pill highlight). Aligne le comportement sur
  /// l'accessibilité (demande utilisateur).
  Widget _buildCuvetteToggle(WcInstance a) {
    String selected;
    if (a.wcCuvetteTropBasse) {
      selected = 'Trop basse';
    } else if (a.wcCuvetteTropHaute) {
      selected = 'Trop haute';
    } else if (a.wcCuvetteBonneHauteur) {
      selected = 'Bonne hauteur';
    } else {
      // Tous à false → aucune chip highlight. Avant la refonte, cet
      // état était impossible car `wcCuvetteBonneHauteur` était `true`
      // par défaut côté modèle. Désormais on n'assume plus rien.
      selected = '';
    }

    void selectState(String label) {
      // Si on reclique la chip déjà active, on désélectionne tout.
      // Sinon, le label cliqué devient l'unique true (les 2 autres
      // basculent à false comme avant).
      final wasActive = label == selected;
      _updateActive(
        _copy(
          a,
          wcCuvetteTropBasse: !wasActive && label == 'Trop basse',
          wcCuvetteTropHaute: !wasActive && label == 'Trop haute',
          wcCuvetteBonneHauteur: !wasActive && label == 'Bonne hauteur',
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 5.0),
          child: Text(
            'Cuvette',
            // Uniformisé 2026-05-13 : w700 14px ink-900 noir.
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0E1116),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _CuvettePill(
                label: 'Trop basse',
                active: selected == 'Trop basse',
                onTap: () => selectState('Trop basse'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CuvettePill(
                label: 'Trop haute',
                active: selected == 'Trop haute',
                onTap: () => selectState('Trop haute'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: _CuvettePill(
            label: 'Bonne hauteur',
            active: selected == 'Bonne hauteur',
            onTap: () => selectState('Bonne hauteur'),
          ),
        ),
      ],
    );
  }

  /// Lightweight copyWith for WcInstance (which doesn't expose one).
  WcInstance _copy(
    WcInstance i, {
    bool? wcCuvetteBonneHauteur,
    bool? wcCuvetteTropBasse,
    bool? wcCuvetteTropHaute,
    double? wcCuvetteHauteur,
    bool wcCuvetteHauteurNull = false,
    bool? wcBarreRelevement,
    bool? porteWcLargeurSuffisante,
    // Flag `Null` similar à `*HauteurNull` — quand `true`, on set
    // explicitement `null` (refonte 2026-05-16, bool? au modèle).
    bool porteWcLargeurSuffisanteNull = false,
    double? porteWcDimension,
    bool porteWcDimensionNull = false,
    bool? porteWcSensAdapte,
    bool porteWcSensAdapteNull = false,
    String? observationEquipementsUtilisation,
  }) {
    return WcInstance(
      id: i.id,
      levelField: i.levelField,
      levelLabel: i.levelLabel,
      wcCuvetteBonneHauteur: wcCuvetteBonneHauteur ?? i.wcCuvetteBonneHauteur,
      wcCuvetteTropBasse: wcCuvetteTropBasse ?? i.wcCuvetteTropBasse,
      wcCuvetteTropHaute: wcCuvetteTropHaute ?? i.wcCuvetteTropHaute,
      wcCuvetteHauteur: wcCuvetteHauteurNull
          ? null
          : (wcCuvetteHauteur ?? i.wcCuvetteHauteur),
      wcBarreRelevement: wcBarreRelevement ?? i.wcBarreRelevement,
      porteWcLargeurSuffisante: porteWcLargeurSuffisanteNull
          ? null
          : (porteWcLargeurSuffisante ?? i.porteWcLargeurSuffisante),
      porteWcDimension: porteWcDimensionNull
          ? null
          : (porteWcDimension ?? i.porteWcDimension),
      porteWcSensAdapte: porteWcSensAdapteNull
          ? null
          : (porteWcSensAdapte ?? i.porteWcSensAdapte),
      observationEquipementsUtilisation:
          observationEquipementsUtilisation ??
          i.observationEquipementsUtilisation,
    );
  }

  /// Convertit un `bool?` en label de pill pour `FormToggleGroup` :
  /// `null` → '' (aucune pill highlight), `true` → [trueLabel], `false`
  /// → [falseLabel]. Identique à `bathroom_tab._boolPillValue`.
  String _boolPillValue(
    bool? value, {
    required String trueLabel,
    required String falseLabel,
  }) {
    if (value == null) return '';
    return value ? trueLabel : falseLabel;
  }
}

/// Bouton pill réutilisé pour les 3 états de la cuvette. Style
/// cohérent avec les autres pills du relevé (violet plein quand actif,
/// fond gris clair quand inactif).
class _CuvettePill extends StatelessWidget {
  const _CuvettePill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Refonte 2026-05-13 : aligné sur FormToggleGroup.buildPill
    // (Occupation) — AnimatedContainer 220ms ease-out cubic, height
    // 32, padding h:14, bg mauve-50 → mauve-500, border transparent →
    // mauve-500, texte fontSize 14 w400/w500. Demande utilisateur :
    // « conceptionne ... vraiment pareil que les autres boutons, avec
    // fond de couleur de base, animation de remplissage » → Cuvette.
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? kBrandPurple // mauve-500
              : const Color(0xFFFAF7FB), // mauve-50
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? kBrandPurple : Colors.transparent),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            fontWeight: active ? FontWeight.w500 : FontWeight.w400,
            color: active ? Colors.white : const Color(0xFF2B323A), // ink-700
          ),
        ),
      ),
    );
  }
}
