import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

/// Ordered level catalog — must match accessibility_tab `_kLevelConfigs`.
/// Used to read which levels have the given "target" room (Salle de bain /
/// WC) selected in the housing record, so the SDB and WC tabs can auto-
/// derive their instances from Intérieur instead of letting the user add
/// them manually.
const List<SanitaryLevel> _kSanitaryLevels = [
  SanitaryLevel(field: 'basement', roomsField: 'basement_rooms_json', label: 'Sous-sol'),
  SanitaryLevel(field: 'rdc', roomsField: 'rdc_rooms_json', label: 'RDC'),
  SanitaryLevel(field: 'floor', roomsField: 'floor_rooms_json', label: '1er étage'),
  SanitaryLevel(field: 'second_floor', roomsField: 'second_floor_rooms_json', label: '2e étage'),
  SanitaryLevel(field: 'third_floor', roomsField: 'third_floor_rooms_json', label: '3e étage'),
];

class SanitaryLevel {
  final String field;
  final String roomsField;
  final String label;
  const SanitaryLevel({
    required this.field,
    required this.roomsField,
    required this.label,
  });
}

/// Returns the subset of [_kSanitaryLevels] where [targetRoom] is present in
/// the level's `<prefix>_rooms_json`.
List<SanitaryLevel> buildSanitaryLevelSelections(
  Map<String, dynamic>? housingRow,
  String targetRoom,
) {
  if (housingRow == null) return const [];
  final result = <SanitaryLevel>[];
  for (final lvl in _kSanitaryLevels) {
    final raw = housingRow[lvl.roomsField] as String? ?? '[]';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List &&
          decoded.any((r) => r.toString().toLowerCase() ==
              targetRoom.toLowerCase())) {
        result.add(lvl);
      }
    } catch (_) {
      // Ignore invalid JSON.
    }
  }
  return result;
}

/// Salle de bain tab — parité 1:1 avec `SalleDeBainForm` React.
///
/// UI :
/// - Pills de niveau (salle de bain 1, 2, …) + bouton "+" pour en ajouter
/// - QuickNav 2 tabs : Équipements / Porte
/// - Équipements : toggles Douche/Baignoire, puis 2 cartes :
///   * Zone douche/baignoire (items filtrés selon les zones actives)
///   * Équipements complémentaires (toujours affichés)
///   + bouton "Sol glissant" (amber)
/// - Porte : Largeur (Suffisante/À revoir) + Dimension (cm) + Sens d'ouverture.
class BathroomTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  /// Incremented by the parent each time the housing (Accessibilité >
  /// Intérieur) changes, so the tab can re-derive its instances from the
  /// latest room selections.
  final int housingRefreshToken;

  const BathroomTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.housingRefreshToken = 0,
  });

  @override
  State<BathroomTab> createState() => _BathroomTabState();
}

// =============================================================================
// Equipment catalog (parity with React BATHROOM_MEASURED_EQUIPMENT)
// =============================================================================

enum _EquipRequires { always, bath, shower }

class _EquipDef {
  final String enabledField;
  final String label;
  final _EquipRequires requires;
  const _EquipDef(this.enabledField, this.label, this.requires);
}

const List<_EquipDef> _kEquipment = [
  _EquipDef('sdbBaignoire', 'Baignoire', _EquipRequires.bath),
  _EquipDef('sdbBacDouche', 'Bac à douche', _EquipRequires.shower),
  _EquipDef('sdbParoiDouche', 'Paroi de douche', _EquipRequires.always),
  _EquipDef('sdbVasqueSuspendue', 'Vasque suspendue', _EquipRequires.always),
  _EquipDef('sdbVasqueColonne', 'Vasque sur colonne', _EquipRequires.always),
  _EquipDef('sdbMeubleVasque', 'Meuble vasque', _EquipRequires.always),
  _EquipDef('sdbBidet', 'Bidet', _EquipRequires.always),
  _EquipDef('sdbMachineALaver', 'Machine à laver', _EquipRequires.always),
];

class _BathroomTabState extends State<BathroomTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  DiagnosticSanitaire? _diagnostic;
  bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;
  int _activeLevelIndex = 0;
  // (Anciens Sets d'édition/repli retirés : les toggles et listes
  // d'équipements restent maintenant toujours visibles.)

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // Phase 1 — rendu immédiat à partir des données locales (SQLite).
    // La partie réseau (NocoDB) tournera en arrière-plan dans la
    // phase 2 ci-dessous. Permet d'afficher les pills de niveaux et
    // d'éditer les équipements sans attendre l'aller-retour serveur,
    // surtout sur la PWA iPad via Vercel où la latence est visible.
    await _hydrateFromLocal();
    // Phase 2 — refresh depuis le serveur en arrière-plan. Si des
    // données plus récentes arrivent, on rehydrate silencieusement.
    try {
      await widget.repository
          .refreshDiagnosticSanitaireFromRemote(widget.dossier.id);
    } catch (_) {
      return; // offline : le cache local suffit
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
        buildSanitaryLevelSelections(housingRow, 'Salle de bain');
    if (!mounted) return;

    final previous = result?.sdbInstances ?? const <BathroomInstance>[];
    // One instance per level with "Salle de bain" selected. Preserve any
    // existing saved instance for that level; create an empty one otherwise.
    final nextInstances = <BathroomInstance>[];
    for (final lvl in selectedLevels) {
      final existing =
          previous.where((i) => i.levelField == lvl.field).toList();
      if (existing.isNotEmpty) {
        nextInstances.add(BathroomInstance(
          id: existing.first.id,
          levelField: lvl.field,
          levelLabel: lvl.label,
          sdbBaignoire: existing.first.sdbBaignoire,
          sdbBaignoireHauteur: existing.first.sdbBaignoireHauteur,
          sdbBacDouche: existing.first.sdbBacDouche,
          sdbBacDoucheHauteur: existing.first.sdbBacDoucheHauteur,
          sdbVasqueSuspendue: existing.first.sdbVasqueSuspendue,
          sdbVasqueSuspendueHauteur: existing.first.sdbVasqueSuspendueHauteur,
          sdbVasqueColonne: existing.first.sdbVasqueColonne,
          sdbVasqueColonneHauteur: existing.first.sdbVasqueColonneHauteur,
          sdbMeubleVasque: existing.first.sdbMeubleVasque,
          sdbMeubleVasqueHauteur: existing.first.sdbMeubleVasqueHauteur,
          sdbBidet: existing.first.sdbBidet,
          sdbBidetHauteur: existing.first.sdbBidetHauteur,
          sdbParoiDouche: existing.first.sdbParoiDouche,
          sdbParoiDoucheHauteur: existing.first.sdbParoiDoucheHauteur,
          sdbSolGlissant: existing.first.sdbSolGlissant,
          sdbMachineALaver: existing.first.sdbMachineALaver,
          sdbMachineALaverHauteur: existing.first.sdbMachineALaverHauteur,
          porteSdbLargeurSuffisante: existing.first.porteSdbLargeurSuffisante,
          porteSdbDimension: existing.first.porteSdbDimension,
          porteSdbSensAdapte: existing.first.porteSdbSensAdapte,
        ));
      } else {
        nextInstances.add(BathroomInstance(
          id: 'sdb_${lvl.field}',
          levelField: lvl.field,
          levelLabel: lvl.label,
        ));
      }
    }

    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: nextInstances,
        wcInstances: result?.wcInstances ?? const [],
      );
      // Keep activeLevelIndex in range.
      if (_activeLevelIndex >= nextInstances.length) {
        _activeLevelIndex = 0;
      }
      _loaded = true;
    });
  }

  /// Called when the parent pushes a refreshed dossier (e.g. after the user
  /// toggled a bathroom in Accessibilité > Intérieur). Re-derives instances.
  @override
  void didUpdateWidget(covariant BathroomTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dossier.id != widget.dossier.id ||
        oldWidget.housingRefreshToken != widget.housingRefreshToken) {
      _load();
    }
  }

  List<BathroomInstance> get _instances => _diagnostic?.sdbInstances ?? [];

  BathroomInstance? get _active {
    if (_instances.isEmpty) return null;
    final idx = _activeLevelIndex.clamp(0, _instances.length - 1).toInt();
    return _instances[idx];
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (_diagnostic == null) return;
    setState(() => _saving = true);
    try {
      await widget.repository.upsertDiagnosticSanitaire(
        widget.dossier.id,
        _diagnostic!,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _updateActive(BathroomInstance updated) {
    if (_active == null) return;
    final idx = _activeLevelIndex.clamp(0, _instances.length - 1).toInt();
    final next = List<BathroomInstance>.from(_instances)..[idx] = updated;
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: next,
        wcInstances: _diagnostic?.wcInstances ?? [],
      );
    });
    _scheduleSave();
  }

  // Note: instances are auto-derived from Accessibilité > Intérieur >
  // Niveaux & pièces (see `_load`). Manual +/- add/remove was removed to
  // enforce the single source of truth.

  // ---------------------------------------------------------------------------
  // Mutations on the active instance
  // ---------------------------------------------------------------------------

  void _toggleShower() {
    final a = _active;
    if (a == null) return;
    final next = !a.sdbBacDouche;
    _updateActive(_copy(a,
        sdbBacDouche: next,
        sdbBacDoucheHauteur: next ? a.sdbBacDoucheHauteur : null,
        sdbParoiDouche: next ? a.sdbParoiDouche : false,
        sdbParoiDoucheHauteur: next ? a.sdbParoiDoucheHauteur : null));
  }

  void _toggleBath() {
    final a = _active;
    if (a == null) return;
    final next = !a.sdbBaignoire;
    _updateActive(_copy(a,
        sdbBaignoire: next,
        sdbBaignoireHauteur: next ? a.sdbBaignoireHauteur : null));
  }

  void _setEquipmentEnabled(_EquipDef def, bool checked) {
    final a = _active;
    if (a == null) return;
    _updateActive(_setEquipmentOnInstance(a, def.enabledField,
        enabled: checked, clearHeight: !checked));
  }

  void _setEquipmentHeight(_EquipDef def, double? v) {
    final a = _active;
    if (a == null) return;
    _updateActive(_setEquipmentOnInstance(a, def.enabledField, height: v));
  }

  /// Applies a multi-select delta for the complementary-equipment dropdown:
  /// enables every field whose label is in [nextLabels] and disables the
  /// rest (clearing any stored height, since height isn't asked for the
  /// complementary items).
  void _applyCommonSelection(
      List<_EquipDef> items, Set<String> nextLabels) {
    final start = _active;
    if (start == null) return;
    var a = start;
    for (final def in items) {
      final shouldBeOn = nextLabels.contains(def.label);
      final isOn = _getEquipmentEnabled(a, def.enabledField);
      if (shouldBeOn == isOn) continue;
      a = _setEquipmentOnInstance(a, def.enabledField,
          enabled: shouldBeOn, clearHeight: !shouldBeOn);
    }
    _updateActive(a);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
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
            _buildEquipment(),
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
          Icon(Icons.bathtub_outlined,
              size: 40, color: Color(0xFF94A3B8)),
          SizedBox(height: 10),
          Text(
            "Aucune salle de bain renseignée pour ce logement.\n"
            "Cochez « Salle de bain » dans Accessibilité › Intérieur › Niveaux & pièces "
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _activeLevelIndex == i
                    ? const Color(0xFFEDE8F5)
                    : Colors.white,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _instances[i].levelLabel.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
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
  // Equipment sub-section
  // ---------------------------------------------------------------------------

  Widget _buildEquipment() {
    final a = _active!;
    final hasShower = a.sdbBacDouche;
    final hasBath = a.sdbBaignoire;
    final commonItems = _kEquipment
        .where((e) => e.requires == _EquipRequires.always)
        .toList();
    final selectedCommon = <String>{
      for (final it in commonItems)
        if (_getEquipmentEnabled(a, it.enabledField)) it.label,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Titre "Équipements Salle de Bain — …" retiré.
          // Wet zone toggles
          Row(
            children: [
              Expanded(
                child: _WetZoneButton(
                  label: 'Douche',
                  active: hasShower,
                  onTap: _toggleShower,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _WetZoneButton(
                  label: 'Baignoire',
                  active: hasBath,
                  onTap: _toggleBath,
                ),
              ),
            ],
          ),
          // Hauteur douche / baignoire : sur UNE MÊME ligne quand les
          // deux sont cochées (une colonne chacune), sinon l'unique
          // champ visible occupe toute la largeur.
          if (hasShower || hasBath) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasShower)
                  Expanded(
                    child: FormNumberField(
                      label: 'Hauteur douche',
                      value: a.sdbBacDoucheHauteur,
                      unit: 'cm',
                      onChanged: (v) => _updateActive(
                        _setEquipmentOnInstance(
                          a,
                          'sdbBacDouche',
                          height: v,
                          clearHeight: v == null,
                        ),
                      ),
                    ),
                  ),
                if (hasShower && hasBath) const SizedBox(width: 10),
                if (hasBath)
                  Expanded(
                    child: FormNumberField(
                      label: 'Hauteur baignoire',
                      value: a.sdbBaignoireHauteur,
                      unit: 'cm',
                      onChanged: (v) => _updateActive(
                        _setEquipmentOnInstance(
                          a,
                          'sdbBaignoire',
                          height: v,
                          clearHeight: v == null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          _buildEquipmentChecklistOrCollapsed(
            instance: a,
            commonItems: commonItems,
            selectedCommon: selectedCommon,
          ),
          const SizedBox(height: 24),
        ],
      );
  }

  // ---------------------------------------------------------------------------
  // Door sub-section
  // ---------------------------------------------------------------------------

  Widget _buildDoor() {
    final a = _active!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _collapsibleToggle(
          instanceId: a.id,
          fieldName: 'porteSdbLargeur',
          label: 'Largeur de porte',
          options: const ['Suffisante', 'À revoir'],
          selected: a.porteSdbLargeurSuffisante ? 'Suffisante' : 'À revoir',
          onChanged: (v) => _updateActive(
              _copy(a, porteSdbLargeurSuffisante: v == 'Suffisante')),
        ),
        const SizedBox(height: 14),
        FormNumberField(
          label: 'Dimension de porte',
          value: a.porteSdbDimension,
          unit: 'cm',
          onChanged: (v) => _updateActive(
              _copy(a, porteSdbDimension: v, porteSdbDimensionNull: v == null)),
        ),
        const SizedBox(height: 14),
        _collapsibleToggle(
          instanceId: a.id,
          fieldName: 'porteSdbSens',
          label: "Sens d'ouverture",
          options: const ['Intérieur', 'Extérieur'],
          selected: a.porteSdbSensAdapte ? 'Intérieur' : 'Extérieur',
          onChanged: (v) =>
              _updateActive(_copy(a, porteSdbSensAdapte: v == 'Intérieur')),
        ),
        const SizedBox(height: 18),
        // Sol glissant — déplacé tout en bas de l'onglet Salle de bain à
        // la demande de l'utilisateur (après la section Porte).
        GestureDetector(
          onTap: () =>
              _updateActive(_copy(a, sdbSolGlissant: !a.sdbSolGlissant)),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Violet #907CA1 pour aligner ce pill toggle « Sol
              // glissant » avec tous les autres boutons du relevé.
              color: a.sdbSolGlissant
                  ? const Color(0xFF7C6DAA)
                  : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: a.sdbSolGlissant
                    ? const Color(0xFF7C6DAA)
                    : Colors.grey.shade300,
                width: 1.2,
              ),
            ),
            child: Text(
              'Sol glissant',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: a.sdbSolGlissant
                    ? Colors.white
                    : Colors.black87,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Liste 2 colonnes de pills pour les équipements complémentaires,
  /// toujours visibles (plus de repli "Équipements (…) + crayon").
  Widget _buildEquipmentChecklistOrCollapsed({
    required BathroomInstance instance,
    required List<_EquipDef> commonItems,
    required Set<String> selectedCommon,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Équipements complémentaires',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 8),
        _EquipPillGrid(
          items: commonItems,
          selected: selectedCommon,
          columns: 2,
          onToggle: (label) {
            final next = Set<String>.from(selectedCommon);
            if (next.contains(label)) {
              next.remove(label);
            } else {
              next.add(label);
            }
            _applyCommonSelection(commonItems, next);
          },
        ),
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

  // ---------------------------------------------------------------------------
  // Helpers — read/write per-equipment fields on a BathroomInstance.
  // ---------------------------------------------------------------------------

  bool _getEquipmentEnabled(BathroomInstance i, String field) {
    switch (field) {
      case 'sdbBaignoire':
        return i.sdbBaignoire;
      case 'sdbBacDouche':
        return i.sdbBacDouche;
      case 'sdbParoiDouche':
        return i.sdbParoiDouche;
      case 'sdbVasqueSuspendue':
        return i.sdbVasqueSuspendue;
      case 'sdbVasqueColonne':
        return i.sdbVasqueColonne;
      case 'sdbMeubleVasque':
        return i.sdbMeubleVasque;
      case 'sdbBidet':
        return i.sdbBidet;
      case 'sdbMachineALaver':
        return i.sdbMachineALaver;
    }
    return false;
  }

  double? _getEquipmentHeight(BathroomInstance i, String field) {
    switch (field) {
      case 'sdbBaignoire':
        return i.sdbBaignoireHauteur;
      case 'sdbBacDouche':
        return i.sdbBacDoucheHauteur;
      case 'sdbParoiDouche':
        return i.sdbParoiDoucheHauteur;
      case 'sdbVasqueSuspendue':
        return i.sdbVasqueSuspendueHauteur;
      case 'sdbVasqueColonne':
        return i.sdbVasqueColonneHauteur;
      case 'sdbMeubleVasque':
        return i.sdbMeubleVasqueHauteur;
      case 'sdbBidet':
        return i.sdbBidetHauteur;
      case 'sdbMachineALaver':
        return i.sdbMachineALaverHauteur;
    }
    return null;
  }

  BathroomInstance _setEquipmentOnInstance(
    BathroomInstance i,
    String field, {
    bool? enabled,
    double? height,
    bool clearHeight = false,
  }) {
    switch (field) {
      case 'sdbBaignoire':
        return _copy(i,
            sdbBaignoire: enabled ?? i.sdbBaignoire,
            sdbBaignoireHauteur: clearHeight ? null : (height ?? i.sdbBaignoireHauteur),
            sdbBaignoireHauteurNull: clearHeight);
      case 'sdbBacDouche':
        return _copy(i,
            sdbBacDouche: enabled ?? i.sdbBacDouche,
            sdbBacDoucheHauteur: clearHeight ? null : (height ?? i.sdbBacDoucheHauteur),
            sdbBacDoucheHauteurNull: clearHeight);
      case 'sdbParoiDouche':
        return _copy(i,
            sdbParoiDouche: enabled ?? i.sdbParoiDouche,
            sdbParoiDoucheHauteur: clearHeight ? null : (height ?? i.sdbParoiDoucheHauteur),
            sdbParoiDoucheHauteurNull: clearHeight);
      case 'sdbVasqueSuspendue':
        return _copy(i,
            sdbVasqueSuspendue: enabled ?? i.sdbVasqueSuspendue,
            sdbVasqueSuspendueHauteur: clearHeight ? null : (height ?? i.sdbVasqueSuspendueHauteur),
            sdbVasqueSuspendueHauteurNull: clearHeight);
      case 'sdbVasqueColonne':
        return _copy(i,
            sdbVasqueColonne: enabled ?? i.sdbVasqueColonne,
            sdbVasqueColonneHauteur: clearHeight ? null : (height ?? i.sdbVasqueColonneHauteur),
            sdbVasqueColonneHauteurNull: clearHeight);
      case 'sdbMeubleVasque':
        return _copy(i,
            sdbMeubleVasque: enabled ?? i.sdbMeubleVasque,
            sdbMeubleVasqueHauteur: clearHeight ? null : (height ?? i.sdbMeubleVasqueHauteur),
            sdbMeubleVasqueHauteurNull: clearHeight);
      case 'sdbBidet':
        return _copy(i,
            sdbBidet: enabled ?? i.sdbBidet,
            sdbBidetHauteur: clearHeight ? null : (height ?? i.sdbBidetHauteur),
            sdbBidetHauteurNull: clearHeight);
      case 'sdbMachineALaver':
        return _copy(i,
            sdbMachineALaver: enabled ?? i.sdbMachineALaver,
            sdbMachineALaverHauteur: clearHeight ? null : (height ?? i.sdbMachineALaverHauteur),
            sdbMachineALaverHauteurNull: clearHeight);
    }
    return i;
  }

  /// Lightweight "copyWith" replacement for BathroomInstance (which doesn't
  /// expose one). Nullable height fields use explicit `<field>Null` booleans
  /// to distinguish "unchanged" from "set to null".
  BathroomInstance _copy(
    BathroomInstance i, {
    bool? sdbBaignoire,
    double? sdbBaignoireHauteur,
    bool sdbBaignoireHauteurNull = false,
    bool? sdbBacDouche,
    double? sdbBacDoucheHauteur,
    bool sdbBacDoucheHauteurNull = false,
    bool? sdbVasqueSuspendue,
    double? sdbVasqueSuspendueHauteur,
    bool sdbVasqueSuspendueHauteurNull = false,
    bool? sdbVasqueColonne,
    double? sdbVasqueColonneHauteur,
    bool sdbVasqueColonneHauteurNull = false,
    bool? sdbMeubleVasque,
    double? sdbMeubleVasqueHauteur,
    bool sdbMeubleVasqueHauteurNull = false,
    bool? sdbBidet,
    double? sdbBidetHauteur,
    bool sdbBidetHauteurNull = false,
    bool? sdbParoiDouche,
    double? sdbParoiDoucheHauteur,
    bool sdbParoiDoucheHauteurNull = false,
    bool? sdbSolGlissant,
    bool? sdbMachineALaver,
    double? sdbMachineALaverHauteur,
    bool sdbMachineALaverHauteurNull = false,
    bool? porteSdbLargeurSuffisante,
    double? porteSdbDimension,
    bool porteSdbDimensionNull = false,
    bool? porteSdbSensAdapte,
  }) {
    return BathroomInstance(
      id: i.id,
      levelField: i.levelField,
      levelLabel: i.levelLabel,
      sdbBaignoire: sdbBaignoire ?? i.sdbBaignoire,
      sdbBaignoireHauteur: sdbBaignoireHauteurNull
          ? null
          : (sdbBaignoireHauteur ?? i.sdbBaignoireHauteur),
      sdbBacDouche: sdbBacDouche ?? i.sdbBacDouche,
      sdbBacDoucheHauteur: sdbBacDoucheHauteurNull
          ? null
          : (sdbBacDoucheHauteur ?? i.sdbBacDoucheHauteur),
      sdbVasqueSuspendue: sdbVasqueSuspendue ?? i.sdbVasqueSuspendue,
      sdbVasqueSuspendueHauteur: sdbVasqueSuspendueHauteurNull
          ? null
          : (sdbVasqueSuspendueHauteur ?? i.sdbVasqueSuspendueHauteur),
      sdbVasqueColonne: sdbVasqueColonne ?? i.sdbVasqueColonne,
      sdbVasqueColonneHauteur: sdbVasqueColonneHauteurNull
          ? null
          : (sdbVasqueColonneHauteur ?? i.sdbVasqueColonneHauteur),
      sdbMeubleVasque: sdbMeubleVasque ?? i.sdbMeubleVasque,
      sdbMeubleVasqueHauteur: sdbMeubleVasqueHauteurNull
          ? null
          : (sdbMeubleVasqueHauteur ?? i.sdbMeubleVasqueHauteur),
      sdbBidet: sdbBidet ?? i.sdbBidet,
      sdbBidetHauteur: sdbBidetHauteurNull
          ? null
          : (sdbBidetHauteur ?? i.sdbBidetHauteur),
      sdbParoiDouche: sdbParoiDouche ?? i.sdbParoiDouche,
      sdbParoiDoucheHauteur: sdbParoiDoucheHauteurNull
          ? null
          : (sdbParoiDoucheHauteur ?? i.sdbParoiDoucheHauteur),
      sdbSolGlissant: sdbSolGlissant ?? i.sdbSolGlissant,
      sdbMachineALaver: sdbMachineALaver ?? i.sdbMachineALaver,
      sdbMachineALaverHauteur: sdbMachineALaverHauteurNull
          ? null
          : (sdbMachineALaverHauteur ?? i.sdbMachineALaverHauteur),
      porteSdbLargeurSuffisante:
          porteSdbLargeurSuffisante ?? i.porteSdbLargeurSuffisante,
      porteSdbDimension: porteSdbDimensionNull
          ? null
          : (porteSdbDimension ?? i.porteSdbDimension),
      porteSdbSensAdapte: porteSdbSensAdapte ?? i.porteSdbSensAdapte,
    );
  }
}

// =============================================================================
// Sub-widgets
// =============================================================================

class _WetZoneButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _WetZoneButton(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF7C6DAA) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active
                ? const Color(0xFF7C6DAA)
                : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : Colors.black87,
          ),
        ),
      ),
    );
  }
}

class _MeasuredOptionCard extends StatelessWidget {
  final String label;
  final bool checked;
  final double? value;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double?> onValueChange;

  const _MeasuredOptionCard({
    required this.label,
    required this.checked,
    required this.value,
    required this.onToggle,
    required this.onValueChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: checked ? const Color(0xFFEDE8F5) : Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => onToggle(!checked),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: checked
                        ? const Color(0xFF7C6DAA)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.check,
                    size: 13,
                    color: checked ? Colors.white : Colors.transparent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: checked
                          ? const Color(0xFF554A63)
                          : const Color(0xFF334155),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (checked) ...[
            const SizedBox(height: 10),
            FormNumberField(
              label: 'Hauteur',
              value: value,
              unit: 'cm',
              onChanged: onValueChange,
            ),
          ],
        ],
      ),
    );
  }
}

/// Grille de pills multi-toggle pour les équipements complémentaires de
/// la salle de bain. Même visuel que les pills "Niveaux" de l'onglet
/// Accessibilité : bordure grise quand non sélectionné, fond violet
/// plein quand sélectionné, texte blanc.
class _EquipPillGrid extends StatelessWidget {
  const _EquipPillGrid({
    required this.items,
    required this.selected,
    required this.onToggle,
    this.columns = 2,
  });

  final List<_EquipDef> items;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var r = 0; r < items.length; r += columns) {
      final rowChildren = <Widget>[];
      for (var c = 0; c < columns; c++) {
        if (c > 0) rowChildren.add(const SizedBox(width: 8));
        final idx = r + c;
        rowChildren.add(
          Expanded(
            child: idx < items.length
                ? _Pill(
                    label: items[idx].label,
                    isSelected: selected.contains(items[idx].label),
                    onTap: () => onToggle(items[idx].label),
                  )
                : const SizedBox.shrink(),
          ),
        );
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(Row(children: rowChildren));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // Même violet que FormToggleGroup (#907CA1) pour unifier tous
          // les pills multi-select avec les autres boutons du relevé.
          color: isSelected ? const Color(0xFF7C6DAA) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF7C6DAA)
                : Colors.grey.shade300,
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.black87,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
