import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

/// Accessibilité tab — parité 1:1 avec la version React (`AccessForm`).
///
/// Sous-sections : Général • Intérieur (niveaux & pièces + chauffage) •
/// Extérieur (accès rue + cheminement + annexes + motorisations) •
/// Volets (3 types).
///
/// Les niveaux (Sous-sol / RDC / 1er / 2e / 3e étage) sont sélectionnés dans
/// un MultiSelectDropdown. Pour chaque niveau sélectionné, une sous-tab
/// affiche la liste des pièces accessibles (presets + rooms personnalisés
/// ajoutés par l'utilisateur).
class AccessibilityTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  /// Fired after every successful housing save so the parent can ask the
  /// SDB and WC tabs to re-derive their instances from the new level
  /// room selections.
  final VoidCallback? onHousingChanged;

  const AccessibilityTab({
    super.key,
    required this.dossier,
    required this.repository,
    this.onHousingChanged,
  });

  @override
  State<AccessibilityTab> createState() => _AccessibilityTabState();
}

// Niveaux configuration (parité React `ACCESS_LEVEL_OPTIONS`).
class _LevelConfig {
  final String field; // boolean column
  final String descField; // text column (retains free-text if any)
  final String roomsField; // JSON column for selected rooms
  final String label;
  final List<String> presetRooms;
  const _LevelConfig({
    required this.field,
    required this.descField,
    required this.roomsField,
    required this.label,
    required this.presetRooms,
  });
}

const List<_LevelConfig> _kLevelConfigs = [
  _LevelConfig(
    field: 'basement',
    descField: 'basement_desc',
    roomsField: 'basement_rooms_json',
    label: 'Sous-sol',
    presetRooms: ['Salle de bain', 'WC'],
  ),
  _LevelConfig(
    field: 'rdc',
    descField: 'rdc_desc',
    roomsField: 'rdc_rooms_json',
    label: 'RDC',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'floor',
    descField: 'floor_desc',
    roomsField: 'floor_rooms_json',
    label: '1er étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'second_floor',
    descField: 'second_floor_desc',
    roomsField: 'second_floor_rooms_json',
    label: '2e étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'third_floor',
    descField: 'third_floor_desc',
    roomsField: 'third_floor_rooms_json',
    label: '3e étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
];

class _AccessibilityTabState extends State<AccessibilityTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _subSection = 0;
  bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;

  // -- Général --
  String _yearConstruction = '';
  String _yearHabitation = '';
  double? _surface;
  String _levels = '';
  String _typology = 'Maison';

  // -- Intérieur --
  // Per-level: is the level selected? + which rooms are selected?
  final Map<String, bool> _levelSelected = {};
  final Map<String, List<String>> _levelRooms = {};
  final Map<String, TextEditingController> _customRoomCtrls = {};
  String _activeLevelField = '';
  Set<String> _heatingTypes = {};
  String? _levelsError;

  // -- Extérieur --
  bool _easyAccess = true;
  String _accessObservation = '';
  final Set<String> _cheminements = {};
  final Set<String> _annexes = {};
  String _motorisationPorteGarage = '';
  String _motorisationPortail = '';

  // -- Volets --
  bool _voletsManEntier = false;
  String _voletsManLoc = '';
  bool _voletsElecEntier = false;
  String _voletsElecLoc = '';
  bool _voletsPersEntier = false;
  String _voletsPersLoc = '';

  static const _heatingOptions = [
    'Électrique',
    'Gaz',
    'Fioul',
    'Pompe à chaleur',
    'Bois',
    'Granulés',
    'Collectif',
    'Autre',
  ];

  static const _cheminementOptions = [
    'Plat',
    'Pente douce',
    'Quelques marches',
    'Escalier extérieur',
    'Escalier intérieur',
    'Seuil de porte',
    "Par l'arrière",
  ];

  static const _annexeOptions = [
    'Garage',
    'Véranda',
    'Balcon',
    'Terrasse',
    'Jardin',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final c in _customRoomCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final row = await widget.repository.fetchHousingRaw(widget.dossier.id);

    // Fallback: use the dossier.housing object (minimal fields) if the row
    // isn't available for some reason.
    final h = widget.dossier.housing;

    _yearConstruction = (row?['year_construction'] ?? h.yearConstruction) as String? ?? '';
    _yearHabitation = (row?['year_habitation'] ?? h.yearHabitation) as String? ?? '';
    _surface = (row?['surface'] as num?)?.toDouble() ?? h.surface;
    final lvlFromRow = row?['levels'];
    _levels = lvlFromRow != null
        ? lvlFromRow.toString()
        : (h.levels != null ? h.levels.toString() : '');
    _typology = (row?['typology'] as String?) ?? (h.typology.isNotEmpty ? h.typology : 'Maison');

    // Levels
    for (final cfg in _kLevelConfigs) {
      final selected = (row?[cfg.field] as int? ?? 0) == 1;
      _levelSelected[cfg.field] = selected;
      _levelRooms[cfg.field] = _parseRooms(row?[cfg.roomsField] as String? ?? '[]');
      _customRoomCtrls[cfg.field] = TextEditingController();
    }
    _activeLevelField = _kLevelConfigs
        .firstWhere(
          (c) => _levelSelected[c.field] == true,
          orElse: () => _kLevelConfigs[1], // default RDC
        )
        .field;

    // Heating
    final rawHeating = row?['heating_details_json'] as String? ?? '{}';
    _heatingTypes = _parseHeatingJson(rawHeating);

    // Exterior
    _easyAccess = ((row?['easy_access'] as int?) ?? (h.easyAccess ? 1 : 0)) == 1;
    _accessObservation = (row?['access_observation'] as String?) ?? h.accessObservation;
    _cheminements.clear();
    if ((row?['cheminement_plat'] as int? ?? 0) == 1) _cheminements.add('Plat');
    if ((row?['cheminement_pente_douce'] as int? ?? 0) == 1) {
      _cheminements.add('Pente douce');
    }
    if ((row?['cheminement_quelques_marches'] as int? ?? 0) == 1) {
      _cheminements.add('Quelques marches');
    }
    if ((row?['cheminement_escalier_exterieur'] as int? ?? 0) == 1) {
      _cheminements.add('Escalier extérieur');
    }
    if ((row?['cheminement_escalier_interieur'] as int? ?? 0) == 1) {
      _cheminements.add('Escalier intérieur');
    }
    if ((row?['cheminement_seuil_porte'] as int? ?? 0) == 1) {
      _cheminements.add('Seuil de porte');
    }
    if ((row?['cheminement_par_arriere'] as int? ?? 0) == 1) {
      _cheminements.add("Par l'arrière");
    }

    _annexes.clear();
    if ((row?['garage'] as int? ?? 0) == 1) _annexes.add('Garage');
    if ((row?['veranda'] as int? ?? 0) == 1) _annexes.add('Véranda');
    if ((row?['balcon'] as int? ?? 0) == 1) _annexes.add('Balcon');
    if ((row?['terrasse'] as int? ?? 0) == 1) _annexes.add('Terrasse');
    if ((row?['jardin'] as int? ?? 0) == 1) _annexes.add('Jardin');

    _motorisationPorteGarage =
        (row?['motorisation_porte_garage'] as String?) ?? h.motorisationPorteGarage;
    _motorisationPortail =
        (row?['motorisation_portail'] as String?) ?? h.motorisationPortail;

    // Volets
    _voletsManEntier =
        ((row?['volets_roulants_manuels_entier'] as int?) ?? (h.voletsRoulantsManuelsEntier ? 1 : 0)) == 1;
    _voletsManLoc = (row?['volets_roulants_manuels_localisation'] as String?) ??
        h.voletsRoulantsManuelsLocalisation;
    _voletsElecEntier =
        ((row?['volets_roulants_electriques_entier'] as int?) ?? (h.voletsRoulantsElectriquesEntier ? 1 : 0)) == 1;
    _voletsElecLoc = (row?['volets_roulants_electriques_localisation'] as String?) ??
        h.voletsRoulantsElectriquesLocalisation;
    _voletsPersEntier =
        ((row?['volets_persiennes_entier'] as int?) ?? (h.voletsPersiennesEntier ? 1 : 0)) == 1;
    _voletsPersLoc = (row?['volets_persiennes_localisation'] as String?) ??
        h.voletsPersiennesLocalisation;

    if (mounted) setState(() => _loaded = true);
  }

  List<String> _parseRooms(String raw) {
    if (raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {}
    return [];
  }

  Set<String> _parseHeatingJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.entries
            .where((e) => e.value == true)
            .map((e) => e.key.toString())
            .toSet();
      }
    } catch (_) {}
    return <String>{};
  }

  // ---------------------------------------------------------------------------
  // Save (debounced)
  // ---------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);

    final heatingJson = <String, bool>{};
    for (final opt in _heatingOptions) {
      heatingJson[opt] = _heatingTypes.contains(opt);
    }

    final map = <String, dynamic>{
      'year_construction': _yearConstruction,
      'year_habitation': _yearHabitation,
      'surface': _surface,
      'levels': _levels.isNotEmpty ? int.tryParse(_levels) : null,
      'typology': _typology,
      'heating_details_json': jsonEncode(heatingJson),
      'easy_access': _easyAccess ? 1 : 0,
      'access_observation': _accessObservation,
      'cheminement_plat': _cheminements.contains('Plat') ? 1 : 0,
      'cheminement_pente_douce': _cheminements.contains('Pente douce') ? 1 : 0,
      'cheminement_quelques_marches':
          _cheminements.contains('Quelques marches') ? 1 : 0,
      'cheminement_escalier_exterieur':
          _cheminements.contains('Escalier extérieur') ? 1 : 0,
      'cheminement_escalier_interieur':
          _cheminements.contains('Escalier intérieur') ? 1 : 0,
      'cheminement_seuil_porte':
          _cheminements.contains('Seuil de porte') ? 1 : 0,
      'cheminement_par_arriere':
          _cheminements.contains("Par l'arrière") ? 1 : 0,
      'garage': _annexes.contains('Garage') ? 1 : 0,
      'veranda': _annexes.contains('Véranda') ? 1 : 0,
      'balcon': _annexes.contains('Balcon') ? 1 : 0,
      'terrasse': _annexes.contains('Terrasse') ? 1 : 0,
      'jardin': _annexes.contains('Jardin') ? 1 : 0,
      'motorisation_porte_garage': _motorisationPorteGarage,
      'motorisation_portail': _motorisationPortail,
      'volets_roulants_manuels_entier': _voletsManEntier ? 1 : 0,
      'volets_roulants_manuels_localisation': _voletsManLoc,
      'volets_roulants_electriques_entier': _voletsElecEntier ? 1 : 0,
      'volets_roulants_electriques_localisation': _voletsElecLoc,
      'volets_persiennes_entier': _voletsPersEntier ? 1 : 0,
      'volets_persiennes_localisation': _voletsPersLoc,
    };
    for (final cfg in _kLevelConfigs) {
      map[cfg.field] = (_levelSelected[cfg.field] ?? false) ? 1 : 0;
      map[cfg.roomsField] = jsonEncode(_levelRooms[cfg.field] ?? []);
    }

    try {
      await widget.repository.updateHousing(widget.dossier.id, map);
      // Notify the parent so dependent tabs (Salle de bain, WC) re-derive
      // their instances from the new "Salle de bain" / "WC" selections.
      widget.onHousingChanged?.call();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _markChanged() {
    setState(() {});
    _scheduleSave();
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
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: SaveStatusIndicator(saving: _saving),
          ),
          const SizedBox(height: 4),
          _buildQuickNav(),
          const SizedBox(height: 16),
          _buildSubSection(),
        ],
      ),
    );
  }

  Widget _buildQuickNav() {
    final items = const <_QuickNavItem>[
      _QuickNavItem(icon: Icons.home_outlined, label: 'Général'),
      _QuickNavItem(icon: Icons.grid_view_outlined, label: 'Intérieur'),
      _QuickNavItem(icon: Icons.place_outlined, label: 'Extérieur'),
      _QuickNavItem(icon: LucideIcons.blinds, label: 'Volets'),
    ];
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: List.generate(items.length, (i) {
          final active = i == _subSection;
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _subSection = i),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                margin: EdgeInsets.only(left: i == 0 ? 0 : 4),
                decoration: BoxDecoration(
                  color:
                      active ? const Color(0xFFD8D0DC) : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Icon(
                      items[i].icon,
                      size: 20,
                      color: active
                          ? const Color(0xFF554A63)
                          : const Color(0xFF64748B),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      items[i].label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: active
                            ? const Color(0xFF554A63)
                            : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildSubSection() {
    switch (_subSection) {
      case 0:
        return _buildGeneral();
      case 1:
        return _buildInterior();
      case 2:
        return _buildExterior();
      case 3:
        return _buildVolets();
      default:
        return const SizedBox.shrink();
    }
  }

  // ---------------------------------------------------------------------------
  // Général
  // ---------------------------------------------------------------------------

  Widget _buildGeneral() {
    return FormSection.text(
      'Informations Générales',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: FormTextField(
                  label: 'Année construction',
                  value: _yearConstruction,
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    _yearConstruction = v;
                    _markChanged();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FormTextField(
                  label: "Année d'habitation",
                  value: _yearHabitation,
                  keyboardType: TextInputType.number,
                  onChanged: (v) {
                    _yearHabitation = v;
                    _markChanged();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FormNumberField(
                  label: 'Surface habitable',
                  value: _surface,
                  unit: 'm²',
                  onChanged: (v) {
                    _surface = v;
                    _markChanged();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FormSelectDropdown<String>(
                  label: 'Nombre de niveaux',
                  value: _levels.isEmpty ? null : _levels,
                  options: const [
                    FormSelectOption(value: '1', label: '1'),
                    FormSelectOption(value: '2', label: '2'),
                    FormSelectOption(value: '3', label: '3'),
                    FormSelectOption(value: '4', label: '4'),
                    FormSelectOption(value: '5', label: '5'),
                  ],
                  onChanged: (v) {
                    _levels = v ?? '';
                    // Clear the error and auto-trim the selection if the new
                    // cap is lower than the current number of selected levels.
                    final cap = int.tryParse(_levels) ?? 0;
                    final picked = _kLevelConfigs
                        .where((c) => _levelSelected[c.field] == true)
                        .toList();
                    if (cap > 0 && picked.length > cap) {
                      for (var i = cap; i < picked.length; i++) {
                        _levelSelected[picked[i].field] = false;
                      }
                    }
                    _levelsError = null;
                    _markChanged();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FormToggleGroup(
            label: 'Type de logement',
            options: const ['Maison', 'Appartement'],
            selected: _typology,
            expand: true,
            onChanged: (v) {
              _typology = v;
              _markChanged();
            },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Intérieur
  // ---------------------------------------------------------------------------

  Widget _buildInterior() {
    final selectedConfigs =
        _kLevelConfigs.where((c) => _levelSelected[c.field] == true).toList();
    final selectedLabels =
        selectedConfigs.map((c) => c.label).toSet();
    final activeConfig = selectedConfigs.firstWhere(
      (c) => c.field == _activeLevelField,
      orElse: () =>
          selectedConfigs.isNotEmpty ? selectedConfigs.first : _kLevelConfigs[0],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormSection.text(
          'Niveaux & Pièces',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FormMultiSelectDropdown(
                label: 'Niveaux présents',
                options: _kLevelConfigs.map((c) => c.label).toList(),
                selected: selectedLabels,
                placeholder: 'Sélectionner un ou plusieurs niveaux',
                onChanged: (nextLabels) {
                  // Parité React : respecter le "Nombre de niveaux" choisi
                  // dans Général. Si l'utilisateur dépasse le cap, on bloque
                  // et on affiche un message d'erreur.
                  final maxLevels = int.tryParse(_levels);
                  if (maxLevels == null || maxLevels <= 0) {
                    setState(() {
                      _levelsError =
                          "Veuillez d'abord renseigner le nombre de niveaux "
                          "dans Général.";
                    });
                    return;
                  }
                  if (nextLabels.length > maxLevels) {
                    setState(() {
                      _levelsError =
                          "Vous ne pouvez sélectionner que $maxLevels "
                          "niveau${maxLevels > 1 ? 'x' : ''} "
                          "(défini dans Général).";
                    });
                    return;
                  }
                  setState(() {
                    _levelsError = null;
                    for (final cfg in _kLevelConfigs) {
                      _levelSelected[cfg.field] =
                          nextLabels.contains(cfg.label);
                    }
                    if (_levelSelected[_activeLevelField] != true) {
                      final firstActive = _kLevelConfigs
                          .where((c) => _levelSelected[c.field] == true)
                          .toList();
                      _activeLevelField = firstActive.isNotEmpty
                          ? firstActive.first.field
                          : '';
                    }
                  });
                  _scheduleSave();
                },
              ),
              if (_levelsError != null) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 16, color: Color(0xFFB91C1C)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _levelsError!,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFB91C1C)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (selectedConfigs.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: selectedConfigs.map((cfg) {
                    final active = cfg.field == _activeLevelField;
                    return GestureDetector(
                      onTap: () =>
                          setState(() => _activeLevelField = cfg.field),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: active
                              ? const Color(0xFFF4EFF7)
                              : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          cfg.label.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: active
                                ? const Color(0xFF554A63)
                                : const Color(0xFF94A3B8),
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                _buildLevelRoomsCard(activeConfig),
              ],
            ],
          ),
        ),
        FormSection.text(
          'Chauffage',
          child: GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 3.2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: _heatingOptions.map((opt) {
              final active = _heatingTypes.contains(opt);
              return GestureDetector(
                onTap: () {
                  setState(() {
                    if (active) {
                      _heatingTypes.remove(opt);
                    } else {
                      _heatingTypes.add(opt);
                    }
                  });
                  _scheduleSave();
                },
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active
                        ? const Color(0xFF907CA1)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    opt,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active
                          ? Colors.white
                          : const Color(0xFF334155),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildLevelRoomsCard(_LevelConfig cfg) {
    final rooms = _levelRooms[cfg.field] ?? const [];
    final allItems = <String>[
      ...cfg.presetRooms,
      ...rooms.where((r) =>
          !cfg.presetRooms.any((p) => p.toLowerCase() == r.toLowerCase())),
    ];
    final ctrl = _customRoomCtrls[cfg.field]!;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cfg.label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: Color(0xFF94A3B8),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 5.5,
            mainAxisSpacing: 4,
            crossAxisSpacing: 8,
            children: allItems.map((room) {
              final checked = rooms.contains(room);
              return FormCheckbox(
                label: room,
                value: checked,
                onChanged: (v) {
                  setState(() {
                    final next = List<String>.from(_levelRooms[cfg.field] ?? []);
                    if (v) {
                      if (!next.contains(room)) next.add(room);
                    } else {
                      next.remove(room);
                    }
                    _levelRooms[cfg.field] = next;
                  });
                  _scheduleSave();
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    hintText: 'Ajouter un champ',
                    hintStyle: const TextStyle(
                        color: Color(0xFF94A3B8), fontSize: 13),
                    border: InputBorder.none,
                    filled: true,
                    fillColor: Colors.white,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _addCustomRoom(cfg),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _addCustomRoom(cfg),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4EFF7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add,
                      color: Color(0xFF554A63), size: 18),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _addCustomRoom(_LevelConfig cfg) {
    final ctrl = _customRoomCtrls[cfg.field]!;
    final val = ctrl.text.trim();
    if (val.isEmpty) return;
    final current = List<String>.from(_levelRooms[cfg.field] ?? []);
    final lowercase = val.toLowerCase();
    if (!current.any((r) => r.toLowerCase() == lowercase) &&
        !cfg.presetRooms
            .any((p) => p.toLowerCase() == lowercase)) {
      current.add(val);
    } else if (!current.any((r) => r.toLowerCase() == lowercase)) {
      current.add(val);
    }
    setState(() {
      _levelRooms[cfg.field] = current;
      ctrl.clear();
    });
    _scheduleSave();
  }

  // ---------------------------------------------------------------------------
  // Extérieur
  // ---------------------------------------------------------------------------

  Widget _buildExterior() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormSection.text(
          'Accès Depuis la Rue',
          child: Column(
            children: [
              FormToggleGroup(
                label: '',
                options: const ['Facile', 'À revoir'],
                selected: _easyAccess ? 'Facile' : 'À revoir',
                expand: true,
                onChanged: (v) {
                  setState(() => _easyAccess = v == 'Facile');
                  _scheduleSave();
                },
              ),
              const SizedBox(height: 12),
              FormTextField(
                label: "Observation d'accès",
                value: _accessObservation,
                maxLines: 2,
                onChanged: (v) {
                  _accessObservation = v;
                  _markChanged();
                },
              ),
            ],
          ),
        ),
        FormSection.text(
          "Chemin d'Accès",
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _cheminementOptions.map((opt) {
              final active = _cheminements.contains(opt);
              return GestureDetector(
                onTap: () {
                  setState(() {
                    if (active) {
                      _cheminements.remove(opt);
                    } else {
                      _cheminements.add(opt);
                    }
                  });
                  _scheduleSave();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color:
                        active ? const Color(0xFF907CA1) : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    opt,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? Colors.white
                          : const Color(0xFF475569),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        FormSection.text(
          'Annexes & Motorisations',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _annexeOptions.map((opt) {
                  final active = _annexes.contains(opt);
                  return GestureDetector(
                    onTap: () {
                      setState(() {
                        if (active) {
                          _annexes.remove(opt);
                        } else {
                          _annexes.add(opt);
                        }
                      });
                      _scheduleSave();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF907CA1)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        opt,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: active
                              ? Colors.white
                              : const Color(0xFF475569),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _IconToggleRow(
                      label: 'Porte garage',
                      selected: _motorisationPorteGarage,
                      options: const [
                        'Manuel',
                        'Électrique',
                        'Pas de porte',
                      ],
                      onSelect: (v) {
                        setState(() => _motorisationPorteGarage = v);
                        _scheduleSave();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _IconToggleRow(
                      label: 'Portail',
                      selected: _motorisationPortail,
                      options: const [
                        'Manuel',
                        'Électrique',
                        'Pas de portail',
                      ],
                      onSelect: (v) {
                        setState(() => _motorisationPortail = v);
                        _scheduleSave();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Volets
  // ---------------------------------------------------------------------------

  Widget _buildVolets() {
    Widget buildShutter({
      required String title,
      required bool entier,
      required String localisation,
      required ValueChanged<bool> onEntierChange,
      required ValueChanged<String> onLocChange,
    }) {
      return FormSection.text(
        title,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FormCheckbox(
              label: 'Logement entier',
              value: entier,
              onChanged: (v) {
                onEntierChange(v);
                if (v) onLocChange('');
                _markChanged();
              },
            ),
            if (!entier) ...[
              const SizedBox(width: 16),
              Expanded(
                child: FormTextField(
                  label: 'Localisation',
                  value: localisation,
                  onChanged: (v) {
                    onLocChange(v);
                    _markChanged();
                  },
                ),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        buildShutter(
          title: 'Volets roulants manuels',
          entier: _voletsManEntier,
          localisation: _voletsManLoc,
          onEntierChange: (v) => setState(() => _voletsManEntier = v),
          onLocChange: (v) => setState(() => _voletsManLoc = v),
        ),
        buildShutter(
          title: 'Volets roulants électriques',
          entier: _voletsElecEntier,
          localisation: _voletsElecLoc,
          onEntierChange: (v) => setState(() => _voletsElecEntier = v),
          onLocChange: (v) => setState(() => _voletsElecLoc = v),
        ),
        buildShutter(
          title: 'Volets persiennes',
          entier: _voletsPersEntier,
          localisation: _voletsPersLoc,
          onEntierChange: (v) => setState(() => _voletsPersEntier = v),
          onLocChange: (v) => setState(() => _voletsPersLoc = v),
        ),
      ],
    );
  }
}

class _QuickNavItem {
  final IconData icon;
  final String label;
  const _QuickNavItem({required this.icon, required this.label});
}

class _IconToggleRow extends StatelessWidget {
  const _IconToggleRow({
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final String label;
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelect;

  static IconData _iconFor(String value) {
    final lower = value.toLowerCase();
    if (lower.contains('manuel')) return LucideIcons.hand;
    if (lower.contains('électrique') || lower.contains('electrique')) {
      return LucideIcons.zap;
    }
    return LucideIcons.ban;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: Color(0xFF64748B),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final option in options) ...[
              Tooltip(
                message: option,
                child: InkWell(
                  onTap: () => onSelect(selected == option ? '' : option),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected == option
                          ? const Color(0xFF907CA1)
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _iconFor(option),
                      size: 20,
                      color: selected == option
                          ? Colors.white
                          : const Color(0xFF64748B),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ],
    );
  }
}
