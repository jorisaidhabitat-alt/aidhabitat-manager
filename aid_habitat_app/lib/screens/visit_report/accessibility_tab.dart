import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

/// Accessibilité tab — refonte :
///   Général : type logement · années · surface · chauffage · niveaux
///             (ajout dynamique) · volets (dropdowns)
///   Extérieur : accès rue · annexes + motorisations conditionnelles
class AccessibilityTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;
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

// ---------------------------------------------------------------------------
// Level config
// ---------------------------------------------------------------------------

class _LevelConfig {
  final String field;
  final String roomsField;
  final String label;
  final List<String> presetRooms;
  const _LevelConfig({
    required this.field,
    required this.roomsField,
    required this.label,
    required this.presetRooms,
  });
}

const List<_LevelConfig> _kLevelConfigs = [
  _LevelConfig(
    field: 'basement',
    roomsField: 'basement_rooms_json',
    label: 'Sous-sol',
    presetRooms: ['Salle de bain', 'WC', 'Garage', 'Buanderie'],
  ),
  _LevelConfig(
    field: 'rdc',
    roomsField: 'rdc_rooms_json',
    label: 'RDC',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'floor',
    roomsField: 'floor_rooms_json',
    label: '1er étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'second_floor',
    roomsField: 'second_floor_rooms_json',
    label: '2e étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
  _LevelConfig(
    field: 'third_floor',
    roomsField: 'third_floor_rooms_json',
    label: '3e étage',
    presetRooms: ['Salle de bain', 'WC', 'Cuisine', 'Chambre'],
  ),
];

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class _AccessibilityTabState extends State<AccessibilityTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _subSection = 0;
  bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;

  // Général
  String _yearConstruction = '';
  String _yearHabitation = '';
  double? _surface;
  String _typology = 'Maison';
  Set<String> _heatingTypes = {};

  // Niveaux (ordre d'ajout par l'utilisateur)
  List<String> _orderedLevels = [];
  final Map<String, List<String>> _levelRooms = {};
  final Map<String, TextEditingController> _customRoomCtrls = {};

  // Volets : 'Aucun' | 'Entier' | 'Localisé'
  String _voletsManStatus = 'Aucun';
  String _voletsManLoc = '';
  String _voletsElecStatus = 'Aucun';
  String _voletsElecLoc = '';
  String _voletsPersStatus = 'Aucun';
  String _voletsPersLoc = '';

  // Extérieur
  bool _easyAccess = true;
  final Set<String> _annexes = {};
  bool _portail = false;
  String _motorisationPorteGarage = 'Aucun';
  String _motorisationPortail = 'Aucun';

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

  static const _annexeOptions = [
    'Garage',
    'Véranda',
    'Balcon',
    'Terrasse',
    'Jardin',
  ];

  static const _voletStatuses = ['Aucun', 'Entier', 'Localisé'];
  static const _motorisationOptions = ['Aucun', 'Manuel', 'Électrique'];

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Load
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    final row = await widget.repository.fetchHousingRaw(widget.dossier.id);
    final h = widget.dossier.housing;

    _yearConstruction =
        (row?['year_construction'] ?? h.yearConstruction) as String? ?? '';
    _yearHabitation =
        (row?['year_habitation'] ?? h.yearHabitation) as String? ?? '';
    _surface = (row?['surface'] as num?)?.toDouble() ?? h.surface;
    _typology = (row?['typology'] as String?) ??
        (h.typology.isNotEmpty ? h.typology : 'Maison');

    // Niveaux
    for (final cfg in _kLevelConfigs) {
      _levelRooms[cfg.field] =
          _parseRooms(row?[cfg.roomsField] as String? ?? '[]');
      _customRoomCtrls[cfg.field] = TextEditingController();
    }
    _orderedLevels = _kLevelConfigs
        .where((c) => (row?[c.field] as int? ?? 0) == 1)
        .map((c) => c.field)
        .toList();

    // Chauffage
    _heatingTypes =
        _parseHeatingJson(row?['heating_details_json'] as String? ?? '{}');

    // Volets
    final manEntier =
        ((row?['volets_roulants_manuels_entier'] as int?) ??
                (h.voletsRoulantsManuelsEntier ? 1 : 0)) ==
            1;
    _voletsManLoc = (row?['volets_roulants_manuels_localisation'] as String?) ??
        h.voletsRoulantsManuelsLocalisation;
    _voletsManStatus =
        manEntier ? 'Entier' : (_voletsManLoc.isNotEmpty ? 'Localisé' : 'Aucun');

    final elecEntier =
        ((row?['volets_roulants_electriques_entier'] as int?) ??
                (h.voletsRoulantsElectriquesEntier ? 1 : 0)) ==
            1;
    _voletsElecLoc =
        (row?['volets_roulants_electriques_localisation'] as String?) ??
            h.voletsRoulantsElectriquesLocalisation;
    _voletsElecStatus = elecEntier
        ? 'Entier'
        : (_voletsElecLoc.isNotEmpty ? 'Localisé' : 'Aucun');

    final persEntier =
        ((row?['volets_persiennes_entier'] as int?) ??
                (h.voletsPersiennesEntier ? 1 : 0)) ==
            1;
    _voletsPersLoc = (row?['volets_persiennes_localisation'] as String?) ??
        h.voletsPersiennesLocalisation;
    _voletsPersStatus = persEntier
        ? 'Entier'
        : (_voletsPersLoc.isNotEmpty ? 'Localisé' : 'Aucun');

    // Extérieur
    _easyAccess =
        ((row?['easy_access'] as int?) ?? (h.easyAccess ? 1 : 0)) == 1;
    _annexes.clear();
    if ((row?['garage'] as int? ?? 0) == 1) _annexes.add('Garage');
    if ((row?['veranda'] as int? ?? 0) == 1) _annexes.add('Véranda');
    if ((row?['balcon'] as int? ?? 0) == 1) _annexes.add('Balcon');
    if ((row?['terrasse'] as int? ?? 0) == 1) _annexes.add('Terrasse');
    if ((row?['jardin'] as int? ?? 0) == 1) _annexes.add('Jardin');

    final rawGarage =
        (row?['motorisation_porte_garage'] as String?) ?? h.motorisationPorteGarage;
    _motorisationPorteGarage = rawGarage.isEmpty ? 'Aucun' : rawGarage;

    final rawPortail =
        (row?['motorisation_portail'] as String?) ?? h.motorisationPortail;
    _portail = rawPortail.isNotEmpty;
    _motorisationPortail = rawPortail.isEmpty ? 'Aucun' : rawPortail;

    if (mounted) setState(() => _loaded = true);
  }

  List<String> _parseRooms(String raw) {
    if (raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
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
    return {};
  }

  // ---------------------------------------------------------------------------
  // Save
  // ---------------------------------------------------------------------------

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);

    final heatingJson = <String, bool>{
      for (final opt in _heatingOptions) opt: _heatingTypes.contains(opt),
    };

    final map = <String, dynamic>{
      'year_construction': _yearConstruction,
      'year_habitation': _yearHabitation,
      'surface': _surface,
      'levels': _orderedLevels.length,
      'typology': _typology,
      'heating_details_json': jsonEncode(heatingJson),
      // Volets
      'volets_roulants_manuels_entier': _voletsManStatus == 'Entier' ? 1 : 0,
      'volets_roulants_manuels_localisation':
          _voletsManStatus == 'Localisé' ? _voletsManLoc : '',
      'volets_roulants_electriques_entier':
          _voletsElecStatus == 'Entier' ? 1 : 0,
      'volets_roulants_electriques_localisation':
          _voletsElecStatus == 'Localisé' ? _voletsElecLoc : '',
      'volets_persiennes_entier': _voletsPersStatus == 'Entier' ? 1 : 0,
      'volets_persiennes_localisation':
          _voletsPersStatus == 'Localisé' ? _voletsPersLoc : '',
      // Extérieur
      'easy_access': _easyAccess ? 1 : 0,
      // Champs supprimés de l'UI — on les vide pour effacer les données obsolètes
      'access_observation': '',
      'cheminement_plat': 0,
      'cheminement_pente_douce': 0,
      'cheminement_quelques_marches': 0,
      'cheminement_escalier_exterieur': 0,
      'cheminement_escalier_interieur': 0,
      'cheminement_seuil_porte': 0,
      'cheminement_par_arriere': 0,
      // Annexes
      'garage': _annexes.contains('Garage') ? 1 : 0,
      'veranda': _annexes.contains('Véranda') ? 1 : 0,
      'balcon': _annexes.contains('Balcon') ? 1 : 0,
      'terrasse': _annexes.contains('Terrasse') ? 1 : 0,
      'jardin': _annexes.contains('Jardin') ? 1 : 0,
      'motorisation_porte_garage': _annexes.contains('Garage')
          ? (_motorisationPorteGarage == 'Aucun'
              ? ''
              : _motorisationPorteGarage)
          : '',
      'motorisation_portail': _portail
          ? (_motorisationPortail == 'Aucun' ? 'Aucun' : _motorisationPortail)
          : '',
    };

    for (final cfg in _kLevelConfigs) {
      map[cfg.field] = _orderedLevels.contains(cfg.field) ? 1 : 0;
      map[cfg.roomsField] = jsonEncode(_levelRooms[cfg.field] ?? []);
    }

    try {
      await widget.repository.updateHousing(widget.dossier.id, map);
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
    super.build(context);
    if (!_loaded) return const Center(child: CircularProgressIndicator());

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
          if (_subSection == 0) _buildGeneral() else _buildExterior(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Quick nav (Général / Extérieur)
  // ---------------------------------------------------------------------------

  Widget _buildQuickNav() {
    const items = [
      _QuickNavItem(icon: Icons.home_outlined, label: 'Général'),
      _QuickNavItem(icon: Icons.place_outlined, label: 'Extérieur'),
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
                    Icon(items[i].icon,
                        size: 20,
                        color: active
                            ? const Color(0xFF554A63)
                            : const Color(0xFF64748B)),
                    const SizedBox(height: 2),
                    Text(items[i].label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: active
                              ? const Color(0xFF554A63)
                              : const Color(0xFF64748B),
                        )),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Général
  // ---------------------------------------------------------------------------

  Widget _buildGeneral() {
    final available = _kLevelConfigs
        .where((c) => !_orderedLevels.contains(c.field))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 1. Type de logement (en premier)
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
        const SizedBox(height: 14),
        // 2. Années avec flèche de copie
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
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
            const SizedBox(width: 6),
            Tooltip(
              message: "Copier dans Année d'habitation",
              child: InkWell(
                onTap: () {
                  if (_yearConstruction.isNotEmpty) {
                    setState(() => _yearHabitation = _yearConstruction);
                    _markChanged();
                  }
                },
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF4EFF7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.arrow_forward,
                      size: 16, color: Color(0xFF554A63)),
                ),
              ),
            ),
            const SizedBox(width: 6),
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
        // 3. Surface
        FormNumberField(
          label: 'Surface habitable',
          value: _surface,
          unit: 'm²',
          onChanged: (v) {
            _surface = v;
            _markChanged();
          },
        ),
        const SizedBox(height: 14),
        // 4. Chauffage
        FormMultiSelectDropdown(
          label: 'Chauffage',
          options: _heatingOptions.toList(),
          selected: _heatingTypes,
          placeholder: 'Sélectionner le type de chauffage',
          onChanged: (next) {
            setState(() => _heatingTypes = next);
            _scheduleSave();
          },
        ),
        const SizedBox(height: 14),
        // 5. Niveaux (ajout dynamique)
        ..._orderedLevels.map((field) {
          final cfg = _kLevelConfigs.firstWhere((c) => c.field == field);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildLevelCard(cfg),
          );
        }),
        if (available.isNotEmpty) _buildAddLevelButton(available),
        const SizedBox(height: 14),
        // 6. Volets
        _buildVoletRow(
          'Roulants manuels',
          _voletsManStatus,
          _voletsManLoc,
          (s) => setState(() {
            _voletsManStatus = s;
            if (s != 'Localisé') _voletsManLoc = '';
          }),
          (l) => setState(() => _voletsManLoc = l),
        ),
        const SizedBox(height: 10),
        _buildVoletRow(
          'Roulants électriques',
          _voletsElecStatus,
          _voletsElecLoc,
          (s) => setState(() {
            _voletsElecStatus = s;
            if (s != 'Localisé') _voletsElecLoc = '';
          }),
          (l) => setState(() => _voletsElecLoc = l),
        ),
        const SizedBox(height: 10),
        _buildVoletRow(
          'Persiennes',
          _voletsPersStatus,
          _voletsPersLoc,
          (s) => setState(() {
            _voletsPersStatus = s;
            if (s != 'Localisé') _voletsPersLoc = '';
          }),
          (l) => setState(() => _voletsPersLoc = l),
        ),
      ],
    );
  }

  Widget _buildAddLevelButton(List<_LevelConfig> available) {
    return PopupMenuButton<String>(
      tooltip: '',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      offset: const Offset(0, 44),
      itemBuilder: (_) => available
          .map((cfg) =>
              PopupMenuItem(value: cfg.field, child: Text(cfg.label)))
          .toList(),
      onSelected: (field) {
        setState(() {
          _orderedLevels.add(field);
          _levelRooms[field] ??= [];
          _customRoomCtrls.putIfAbsent(
              field, () => TextEditingController());
        });
        _scheduleSave();
      },
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF4EFF7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFD8D0DC), width: 1.5),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 16, color: Color(0xFF554A63)),
            SizedBox(width: 8),
            Text('Ajouter un niveau',
                style: TextStyle(
                  color: Color(0xFF554A63),
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildLevelCard(_LevelConfig cfg) {
    final rooms = _levelRooms[cfg.field] ?? [];
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
          // En-tête niveau + bouton supprimer
          Row(
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
              const Spacer(),
              InkWell(
                onTap: () {
                  setState(() => _orderedLevels.remove(cfg.field));
                  _scheduleSave();
                },
                borderRadius: BorderRadius.circular(20),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child:
                      Icon(Icons.close, size: 16, color: Color(0xFF94A3B8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Pièces
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
                    final next =
                        List<String>.from(_levelRooms[cfg.field] ?? []);
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
          // Ajout pièce personnalisée
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    hintText: 'Ajouter une pièce',
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
                  decoration: const BoxDecoration(
                      color: Color(0xFFF4EFF7), shape: BoxShape.circle),
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
    final lc = val.toLowerCase();
    if (!current.any((r) => r.toLowerCase() == lc) &&
        !cfg.presetRooms.any((p) => p.toLowerCase() == lc)) {
      current.add(val);
    }
    setState(() {
      _levelRooms[cfg.field] = current;
      ctrl.clear();
    });
    _scheduleSave();
  }

  Widget _buildVoletRow(
    String label,
    String status,
    String loc,
    ValueChanged<String> onStatusChange,
    ValueChanged<String> onLocChange,
  ) {
    return Row(
      children: [
        Expanded(
          child: FormSelectDropdown<String>(
            label: label,
            value: status,
            options: _voletStatuses
                .map((s) => FormSelectOption(value: s, label: s))
                .toList(),
            onChanged: (v) {
              onStatusChange(v ?? 'Aucun');
              _markChanged();
            },
          ),
        ),
        if (status == 'Localisé') ...[
          const SizedBox(width: 10),
          Expanded(
            child: FormTextField(
              label: 'Localisation',
              value: loc,
              onChanged: (v) {
                onLocChange(v);
                _markChanged();
              },
            ),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Extérieur
  // ---------------------------------------------------------------------------

  Widget _buildExterior() {
    final showGarageMoto = _annexes.contains('Garage');
    final showPortailMoto = _portail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Accès depuis la rue (toggle simple, sans observation ni chemin)
        FormSection.text(
          'Accès Depuis la Rue',
          child: FormToggleGroup(
            label: '',
            options: const ['Facile', 'À revoir'],
            selected: _easyAccess ? 'Facile' : 'À revoir',
            expand: true,
            onChanged: (v) {
              setState(() => _easyAccess = v == 'Facile');
              _scheduleSave();
            },
          ),
        ),
        // Annexes + motorisations conditionnelles
        FormSection.text(
          'Annexes',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ..._annexeOptions.map((opt) => _buildAnnexeChip(
                        opt,
                        _annexes.contains(opt),
                        (active) {
                          setState(() {
                            if (active) {
                              _annexes.add(opt);
                            } else {
                              _annexes.remove(opt);
                              if (opt == 'Garage') {
                                _motorisationPorteGarage = 'Aucun';
                              }
                            }
                          });
                          _scheduleSave();
                        },
                      )),
                  // Portail comme annexe
                  _buildAnnexeChip('Portail', _portail, (active) {
                    setState(() {
                      _portail = active;
                      if (!active) _motorisationPortail = 'Aucun';
                    });
                    _scheduleSave();
                  }),
                ],
              ),
              // Motorisations conditionnelles
              if (showGarageMoto || showPortailMoto) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (showGarageMoto)
                      Expanded(
                        child: FormSelectDropdown<String>(
                          label: 'Porte de garage',
                          value: _motorisationPorteGarage,
                          options: _motorisationOptions
                              .map((o) =>
                                  FormSelectOption(value: o, label: o))
                              .toList(),
                          onChanged: (v) {
                            setState(() =>
                                _motorisationPorteGarage = v ?? 'Aucun');
                            _scheduleSave();
                          },
                        ),
                      ),
                    if (showGarageMoto && showPortailMoto)
                      const SizedBox(width: 12),
                    if (showPortailMoto)
                      Expanded(
                        child: FormSelectDropdown<String>(
                          label: 'Portail',
                          value: _motorisationPortail,
                          options: _motorisationOptions
                              .map((o) =>
                                  FormSelectOption(value: o, label: o))
                              .toList(),
                          onChanged: (v) {
                            setState(
                                () => _motorisationPortail = v ?? 'Aucun');
                            _scheduleSave();
                          },
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAnnexeChip(
      String label, bool active, ValueChanged<bool> onTap) {
    return GestureDetector(
      onTap: () => onTap(!active),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color:
              active ? const Color(0xFF907CA1) : Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color:
                active ? Colors.white : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _QuickNavItem {
  final IconData icon;
  final String label;
  const _QuickNavItem({required this.icon, required this.label});
}
