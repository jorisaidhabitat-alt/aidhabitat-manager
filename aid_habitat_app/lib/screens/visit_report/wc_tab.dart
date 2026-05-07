import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/connectivity_service.dart';
import '../../services/dossier_repository.dart';
import '../../services/save_debounce.dart';
import '../../components/form_widgets.dart';
import 'bathroom_tab.dart' show buildSanitaryLevelSelections;

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

  /// Incremented by the parent when the housing (Accessibilité > Intérieur)
  /// changes so this tab re-derives its instances from the latest selections.
  final int housingRefreshToken;

  const WcTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.housingRefreshToken = 0,
  });

  @override
  State<WcTab> createState() => _WcTabState();
}

class _WcTabState extends State<WcTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  DiagnosticSanitaire? _diagnostic;
  bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;
  int _activeLevelIndex = 0;
  // (Ancien Set de clés d'édition pour le repli "CollapsedValueRow"
  // retiré : les toggles restent maintenant toujours visibles.)

  /// Polling cross-device 2s — demande utilisateur 2026-05-06 :
  /// « la synchronisation entre Mac et iPad doit être bien plus
  /// rapide ». Avant, sanitaires n'était fetché qu'à l'init du tab —
  /// si le Mac modifiait la cuvette pendant que l'iPad regardait
  /// l'onglet WC, l'iPad ne voyait rien jusqu'à un changement
  /// d'onglet. Le poll est skippé si l'utilisateur édite localement
  /// (saveTimer actif) — `refreshDiagnosticSanitaireFromRemote` a
  /// déjà sa propre garde `pendingSync`, donc deux niveaux de
  /// protection contre l'écrasement d'une saisie en cours.
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      // Skip offline (2026-05-07) — pas de tentative HTTP qui
      // échouerait silencieusement et gaspillerait CPU/batterie.
      if (ConnectivityService().isOffline) return;
      // Skip si une saisie est en cours côté local (debounce save actif
      // ou save HTTP en flight) → on ne touche pas à _diagnostic pour
      // ne pas écraser la valeur que l'utilisateur tape.
      if (_saveTimer?.isActive == true) return;
      if (_saving) return;
      // ignore: discarded_futures
      _load();
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // Phase 1 — rendu immédiat depuis le cache local SQLite.
    await _hydrateFromLocal();
    // Phase 2 — refresh serveur en arrière-plan ; rehydrate si nouvelles
    // données. En offline on reste sur le cache local.
    try {
      await widget.repository
          .refreshDiagnosticSanitaireFromRemote(widget.dossier.id);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    await _hydrateFromLocal();
  }

  Future<void> _hydrateFromLocal() async {
    final result =
        await widget.repository.fetchDiagnosticSanitaire(widget.dossier.id);
    final housingRow =
        await widget.repository.fetchHousingRaw(widget.dossier.id);
    final selectedLevels =
        buildSanitaryLevelSelections(housingRow, 'WC');
    if (!mounted) return;

    final previous = result?.wcInstances ?? const <WcInstance>[];
    final nextInstances = <WcInstance>[];
    for (final lvl in selectedLevels) {
      final existing =
          previous.where((i) => i.levelField == lvl.field).toList();
      if (existing.isNotEmpty) {
        nextInstances.add(WcInstance(
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
        ));
      } else {
        nextInstances.add(WcInstance(
          id: 'wc_${lvl.field}',
          levelField: lvl.field,
          levelLabel: lvl.label,
        ));
      }
    }

    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: result?.sdbInstances ?? const [],
        wcInstances: nextInstances,
      );
      if (_activeLevelIndex >= nextInstances.length) {
        _activeLevelIndex = 0;
      }
      _loaded = true;
    });
  }

  @override
  void didUpdateWidget(covariant WcTab oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    if (_diagnostic == null) return;
    // Pas de setState(_saving) — voir dossier_screen.dart.
    await widget.repository
        .upsertDiagnosticSanitaire(widget.dossier.id, _diagnostic!);
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
    // Swipe SECTIONS désactivé (demande utilisateur 2026-04-29) :
    // bascule entre les niveaux (WC RDC / étage / …) uniquement via
    // les pills `_buildLevelPills()` (tap). Pas d'occupants dans cet
    // onglet → plus aucun swipe horizontal câblé.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: SaveStatusIndicator(saving: _saving),
          ),
          const SizedBox(height: 4),
          _buildLevelPills(),
          if (_instances.isEmpty)
            _buildEmptyState()
          else ...[
            const SizedBox(height: 16),
            _buildMain(),
            const SizedBox(height: 16),
            _buildDoor(),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      margin: const EdgeInsets.only(top: 24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Column(
        children: [
          Icon(LucideIcons.squareAsterisk,
              size: 38, color: Color(0xFF94A3B8)),
          SizedBox(height: 10),
          Text(
            "Aucun WC renseigné pour ce logement.\n"
            "Cochez « WC » dans Accessibilité › Intérieur › Niveaux & pièces "
            "pour afficher les sections correspondantes ici.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelPills() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < _instances.length; i++)
          GestureDetector(
            onTap: () => setState(() => _activeLevelIndex = i),
            child: Container(
              // Padding bumpé pour rester proportionné au fontSize 12
              // (avant 10 + 12/6 → maintenant 12 + 14/8).
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: _activeLevelIndex == i
                    ? const Color(0xFFEDE8F5)
                    : Colors.white,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _instances[i].levelLabel.toUpperCase(),
                style: TextStyle(
                  // 10 → 12 (demande utilisateur 2026-04-28 : "met les
                  // en taille légèrement plus grande").
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: _activeLevelIndex == i
                      ? const Color(0xFF554A63)
                      : const Color(0xFF94A3B8),
                ),
              ),
            ),
          ),
      ],
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
          onChanged: (v) => _updateActive(_copy(a,
              wcCuvetteHauteur: v, wcCuvetteHauteurNull: v == null)),
        ),
        const SizedBox(height: 14),
        _collapsibleToggle(
          instanceId: a.id,
          fieldName: 'wcBarre',
          label: 'Barre de relèvement',
          options: const ['Présente', 'Absente'],
          selected: a.wcBarreRelevement ? 'Présente' : 'Absente',
          onChanged: (v) => _updateActive(
              _copy(a, wcBarreRelevement: v == 'Présente')),
        ),
        const SizedBox(height: 8),
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
          selected: a.porteWcLargeurSuffisante ? 'Suffisante' : 'À revoir',
          onChanged: (v) => _updateActive(
              _copy(a, porteWcLargeurSuffisante: v == 'Suffisante')),
        ),
        const SizedBox(height: 14),
        FormNumberField(
          label: 'Dimension de porte',
          value: a.porteWcDimension,
          unit: 'cm',
          onChanged: (v) => _updateActive(_copy(a,
              porteWcDimension: v, porteWcDimensionNull: v == null)),
        ),
        const SizedBox(height: 14),
        _collapsibleToggle(
          instanceId: a.id,
          fieldName: 'porteWcSens',
          label: "Sens d'ouverture",
          options: const ['Intérieur', 'Extérieur'],
          selected: a.porteWcSensAdapte ? 'Intérieur' : 'Extérieur',
          onChanged: (v) =>
              _updateActive(_copy(a, porteWcSensAdapte: v == 'Intérieur')),
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
  Widget _buildCuvetteToggle(WcInstance a) {
    String selected;
    if (a.wcCuvetteTropBasse) {
      selected = 'Trop basse';
    } else if (a.wcCuvetteTropHaute) {
      selected = 'Trop haute';
    } else {
      selected = 'Bonne hauteur';
    }

    void selectState(String label) {
      _updateActive(_copy(a,
          wcCuvetteTropBasse: label == 'Trop basse',
          wcCuvetteTropHaute: label == 'Trop haute',
          wcCuvetteBonneHauteur: label == 'Bonne hauteur'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8.0),
          child: Text(
            'Cuvette',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF334155),
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
    double? porteWcDimension,
    bool porteWcDimensionNull = false,
    bool? porteWcSensAdapte,
    String? observationEquipementsUtilisation,
  }) {
    return WcInstance(
      id: i.id,
      levelField: i.levelField,
      levelLabel: i.levelLabel,
      wcCuvetteBonneHauteur:
          wcCuvetteBonneHauteur ?? i.wcCuvetteBonneHauteur,
      wcCuvetteTropBasse: wcCuvetteTropBasse ?? i.wcCuvetteTropBasse,
      wcCuvetteTropHaute: wcCuvetteTropHaute ?? i.wcCuvetteTropHaute,
      wcCuvetteHauteur: wcCuvetteHauteurNull
          ? null
          : (wcCuvetteHauteur ?? i.wcCuvetteHauteur),
      wcBarreRelevement: wcBarreRelevement ?? i.wcBarreRelevement,
      porteWcLargeurSuffisante:
          porteWcLargeurSuffisante ?? i.porteWcLargeurSuffisante,
      porteWcDimension: porteWcDimensionNull
          ? null
          : (porteWcDimension ?? i.porteWcDimension),
      porteWcSensAdapte: porteWcSensAdapte ?? i.porteWcSensAdapte,
      observationEquipementsUtilisation: observationEquipementsUtilisation ??
          i.observationEquipementsUtilisation,
    );
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
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF7C6DAA) : const Color(0xFFF1F1F4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF334155),
          ),
        ),
      ),
    );
  }
}
