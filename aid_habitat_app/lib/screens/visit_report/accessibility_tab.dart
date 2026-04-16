import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

class AccessibilityTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  const AccessibilityTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<AccessibilityTab> createState() => _AccessibilityTabState();
}

class _AccessibilityTabState extends State<AccessibilityTab> {
  int _subSection = 0;
  bool _saving = false;
  bool _loaded = false;
  Timer? _saveTimer;

  // -- General --
  String _yearConstruction = '';
  String _yearHabitation = '';
  double? _surface;
  String _levels = '';
  String _typology = 'Maison';

  // -- Interior --
  Set<String> _niveaux = {};
  String _basementDesc = '';
  String _rdcDesc = '';
  String _floorDesc = '';
  Set<String> _heatingTypes = {};

  // -- Exterior --
  String _accessRue = '';
  String _accessObservation = '';
  Set<String> _cheminements = {};
  Set<String> _annexes = {};
  String _motorisationPorteGarage = '';
  String _motorisationPortail = '';

  // -- Volets --
  bool _voletsManEntier = false;
  String _voletsManLoc = '';
  bool _voletsElecEntier = false;
  String _voletsElecLoc = '';
  bool _voletsPersEntier = false;
  String _voletsPersLoc = '';

  static const _subSections = ['Général', 'Intérieur', 'Extérieur', 'Volets'];

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
    'Par l\'arrière',
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
    _loadFromHousing();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  void _loadFromHousing() {
    final h = widget.dossier.housing;

    _yearConstruction = h.yearConstruction;
    _yearHabitation = h.yearHabitation;
    _surface = h.surface;
    _levels = h.levels != null ? h.levels.toString() : '';
    _typology = h.typology.isNotEmpty ? h.typology : 'Maison';

    // Niveaux
    _niveaux = {};
    if (h.basement) _niveaux.add('Sous-sol');
    if (h.rdc) _niveaux.add('RDC');
    if (h.floor) _niveaux.add('Étage');
    _basementDesc = h.basementDescription;
    _rdcDesc = h.rdcDescription;
    _floorDesc = h.floorDescription;

    // Heating
    _heatingTypes = {};
    for (final entry in h.heatingDetails.entries) {
      if (entry.value) _heatingTypes.add(entry.key);
    }

    // Exterior
    _accessRue = h.easyAccess ? 'Facile' : (h.accessObservation.isNotEmpty || !h.easyAccess ? 'À revoir' : '');
    _accessObservation = h.accessObservation;

    _cheminements = {};
    if (h.cheminementPortail) _cheminements.add('Plat');
    if (h.cheminementRampe) _cheminements.add('Pente douce');
    if (h.cheminementMarches) _cheminements.add('Quelques marches');
    // Use Housing fields for cheminements — map from the DB booleans
    // We re-derive from the Housing model fields that exist

    _annexes = {};
    if (h.garage) _annexes.add('Garage');
    if (h.veranda) _annexes.add('Véranda');
    if (h.balcon) _annexes.add('Balcon');
    if (h.terrasse) _annexes.add('Terrasse');
    if (h.jardin) _annexes.add('Jardin');

    _motorisationPorteGarage = h.motorisationPorteGarage;
    _motorisationPortail = h.motorisationPortail;

    // Volets
    _voletsManEntier = h.voletsRoulantsManuelsEntier;
    _voletsManLoc = h.voletsRoulantsManuelsLocalisation;
    _voletsElecEntier = h.voletsRoulantsElectriquesEntier;
    _voletsElecLoc = h.voletsRoulantsElectriquesLocalisation;
    _voletsPersEntier = h.voletsPersiennesEntier;
    _voletsPersLoc = h.voletsPersiennesLocalisation;

    _loaded = true;
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);

    final map = <String, dynamic>{
      'year_construction': _yearConstruction,
      'year_habitation': _yearHabitation,
      'surface': _surface,
      'levels': _levels.isNotEmpty ? int.tryParse(_levels) : null,
      'typology': _typology,
      'basement': _niveaux.contains('Sous-sol') ? 1 : 0,
      'basement_desc': _basementDesc,
      'rdc': _niveaux.contains('RDC') ? 1 : 0,
      'rdc_desc': _rdcDesc,
      'floor': _niveaux.contains('Étage') ? 1 : 0,
      'floor_desc': _floorDesc,
      'heating_details_json': _buildHeatingJson(),
      'easy_access': _accessRue == 'Facile' ? 1 : 0,
      'access_observation': _accessObservation,
      'cheminement_plat': _cheminements.contains('Plat') ? 1 : 0,
      'cheminement_pente_douce': _cheminements.contains('Pente douce') ? 1 : 0,
      'cheminement_quelques_marches': _cheminements.contains('Quelques marches') ? 1 : 0,
      'cheminement_escalier_exterieur': _cheminements.contains('Escalier extérieur') ? 1 : 0,
      'cheminement_escalier_interieur': _cheminements.contains('Escalier intérieur') ? 1 : 0,
      'cheminement_seuil_porte': _cheminements.contains('Seuil de porte') ? 1 : 0,
      'cheminement_par_arriere': _cheminements.contains('Par l\'arrière') ? 1 : 0,
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

    await widget.repository.updateHousing(widget.dossier.id, map);
    if (mounted) setState(() => _saving = false);
  }

  String _buildHeatingJson() {
    final entries = <String, bool>{};
    for (final opt in _heatingOptions) {
      entries[opt] = _heatingTypes.contains(opt);
    }
    // Manual JSON to avoid importing dart:convert just for this
    final pairs = entries.entries.map((e) => '"${e.key}":${e.value}').join(',');
    return '{$pairs}';
  }

  void _onChanged() {
    setState(() {});
    _scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: FormSubSectionChips(
            labels: _subSections,
            selectedIndex: _subSection,
            onChanged: (i) => setState(() => _subSection = i),
          ),
        ),
        if (_saving)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: SaveStatusIndicator(saving: true),
          ),
        Expanded(
          child: _buildSubSection(),
        ),
      ],
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
  // Sub-section 1: Général
  // ---------------------------------------------------------------------------
  Widget _buildGeneral() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const FormSectionHeader(title: 'Général', icon: Icons.home_outlined),
        FormTextField(
          label: 'Année construction',
          value: _yearConstruction,
          keyboardType: TextInputType.number,
          onChanged: (v) {
            _yearConstruction = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Année habitation',
          value: _yearHabitation,
          keyboardType: TextInputType.number,
          onChanged: (v) {
            _yearHabitation = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormNumberField(
          label: 'Surface habitable',
          value: _surface,
          unit: 'm²',
          onChanged: (v) {
            _surface = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormToggleGroup(
          label: 'Nombre de niveaux',
          options: const ['1', '2', '3', '4', '5'],
          selected: _levels,
          onChanged: (v) {
            _levels = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormToggleGroup(
          label: 'Type de logement',
          options: const ['Maison', 'Appartement'],
          selected: _typology,
          onChanged: (v) {
            _typology = v;
            _onChanged();
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-section 2: Intérieur
  // ---------------------------------------------------------------------------
  Widget _buildInterior() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const FormSectionHeader(title: 'Intérieur', icon: Icons.door_front_door_outlined),
        FormMultiSelect(
          label: 'Niveaux présents',
          options: const ['Sous-sol', 'RDC', 'Étage'],
          selected: _niveaux,
          onChanged: (v) {
            _niveaux = v;
            _onChanged();
          },
        ),
        if (_niveaux.contains('Sous-sol')) ...[
          const SizedBox(height: 12),
          FormTextField(
            label: 'Description sous-sol',
            value: _basementDesc,
            onChanged: (v) {
              _basementDesc = v;
              _onChanged();
            },
          ),
        ],
        if (_niveaux.contains('RDC')) ...[
          const SizedBox(height: 12),
          FormTextField(
            label: 'Description RDC',
            value: _rdcDesc,
            onChanged: (v) {
              _rdcDesc = v;
              _onChanged();
            },
          ),
        ],
        if (_niveaux.contains('Étage')) ...[
          const SizedBox(height: 12),
          FormTextField(
            label: 'Description étage',
            value: _floorDesc,
            onChanged: (v) {
              _floorDesc = v;
              _onChanged();
            },
          ),
        ],
        const SizedBox(height: 16),
        FormMultiSelect(
          label: 'Types de chauffage',
          options: _heatingOptions,
          selected: _heatingTypes,
          onChanged: (v) {
            _heatingTypes = v;
            _onChanged();
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-section 3: Extérieur
  // ---------------------------------------------------------------------------
  Widget _buildExterior() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const FormSectionHeader(title: 'Extérieur', icon: Icons.landscape_outlined),
        FormToggleGroup(
          label: 'Accès depuis la rue',
          options: const ['Facile', 'À revoir'],
          selected: _accessRue,
          onChanged: (v) {
            _accessRue = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Observation d\'accès',
          value: _accessObservation,
          maxLines: 3,
          onChanged: (v) {
            _accessObservation = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 16),
        FormMultiSelect(
          label: 'Cheminements',
          options: _cheminementOptions,
          selected: _cheminements,
          onChanged: (v) {
            _cheminements = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 16),
        FormMultiSelect(
          label: 'Annexes',
          options: _annexeOptions,
          selected: _annexes,
          onChanged: (v) {
            _annexes = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Motorisation porte garage',
          value: _motorisationPorteGarage,
          onChanged: (v) {
            _motorisationPorteGarage = v;
            _onChanged();
          },
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Motorisation portail',
          value: _motorisationPortail,
          onChanged: (v) {
            _motorisationPortail = v;
            _onChanged();
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Sub-section 4: Volets
  // ---------------------------------------------------------------------------
  Widget _buildVolets() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const FormSectionHeader(title: 'Volets', icon: Icons.blinds_outlined),

        // Volets roulants manuels
        const Text(
          'Volets roulants manuels',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF334155)),
        ),
        const SizedBox(height: 8),
        FormCheckbox(
          label: 'Logement entier',
          value: _voletsManEntier,
          onChanged: (v) {
            _voletsManEntier = v;
            if (v) _voletsManLoc = '';
            _onChanged();
          },
        ),
        if (!_voletsManEntier) ...[
          const SizedBox(height: 8),
          FormTextField(
            label: 'Localisation',
            value: _voletsManLoc,
            onChanged: (v) {
              _voletsManLoc = v;
              _onChanged();
            },
          ),
        ],

        const SizedBox(height: 20),

        // Volets roulants électriques
        const Text(
          'Volets roulants électriques',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF334155)),
        ),
        const SizedBox(height: 8),
        FormCheckbox(
          label: 'Logement entier',
          value: _voletsElecEntier,
          onChanged: (v) {
            _voletsElecEntier = v;
            if (v) _voletsElecLoc = '';
            _onChanged();
          },
        ),
        if (!_voletsElecEntier) ...[
          const SizedBox(height: 8),
          FormTextField(
            label: 'Localisation',
            value: _voletsElecLoc,
            onChanged: (v) {
              _voletsElecLoc = v;
              _onChanged();
            },
          ),
        ],

        const SizedBox(height: 20),

        // Volets persiennes
        const Text(
          'Volets persiennes',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF334155)),
        ),
        const SizedBox(height: 8),
        FormCheckbox(
          label: 'Logement entier',
          value: _voletsPersEntier,
          onChanged: (v) {
            _voletsPersEntier = v;
            if (v) _voletsPersLoc = '';
            _onChanged();
          },
        ),
        if (!_voletsPersEntier) ...[
          const SizedBox(height: 8),
          FormTextField(
            label: 'Localisation',
            value: _voletsPersLoc,
            onChanged: (v) {
              _voletsPersLoc = v;
              _onChanged();
            },
          ),
        ],
      ],
    );
  }
}
