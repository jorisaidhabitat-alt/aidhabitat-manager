import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/types.dart';
import '../../services/data_service.dart';
import 'form_widgets.dart';

class AccessibilityTab extends StatefulWidget {
  final Dossier dossier;
  final ValueChanged<Dossier> onDossierChanged;

  const AccessibilityTab({
    super.key,
    required this.dossier,
    required this.onDossierChanged,
  });

  @override
  State<AccessibilityTab> createState() => _AccessibilityTabState();
}

class _AccessibilityTabState extends State<AccessibilityTab> {
  final _dataService = DataService();
  Map<String, dynamic> _formData = {};
  int _subSection = 0;
  Timer? _saveTimer;
  bool _loaded = false;

  static const _sections = [
    'G\u00e9n\u00e9ral',
    'Int\u00e9rieur',
    'Ext\u00e9rieur',
    'Volets',
  ];

  Housing get _housing => widget.dossier.housing;
  String get _patientId => widget.dossier.patient.id;

  @override
  void initState() {
    super.initState();
    _loadFormData();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFormData() async {
    final data =
        await _dataService.fetchFormData(_patientId, 'accessibilite');
    if (mounted) setState(() { _formData = data; _loaded = true; });
  }

  void _onFormChanged(String key, dynamic value) {
    setState(() => _formData[key] = value);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _dataService.saveFormData(_patientId, 'accessibilite', _formData);
    });
  }

  void _updateHousing(Housing updated) {
    widget.onDossierChanged(widget.dossier.copyWith(housing: updated));
  }

  void _saveHousingField(Map<String, dynamic> fields) {
    _dataService.updateHousingFields(_patientId, fields);
  }

  bool _getListBool(String listKey, String item) {
    final list = _formData[listKey];
    if (list is List) return list.contains(item);
    return false;
  }

  void _toggleListItem(String listKey, String item, bool checked) {
    final list = List<String>.from((_formData[listKey] as List?) ?? []);
    if (checked) {
      if (!list.contains(item)) list.add(item);
    } else {
      list.remove(item);
    }
    _onFormChanged(listKey, list);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VSubSectionBar(
          sections: _sections,
          selected: _subSection,
          onChanged: (i) => setState(() => _subSection = i),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 16),
            child: _buildSubSection(),
          ),
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
        return _buildShutters();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildGeneral() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Informations g\u00e9n\u00e9rales'),
        VToggleGroup(
          label: 'Typologie',
          options: const ['Maison', 'Appartement'],
          selected:
              _housing.type == HousingType.APARTMENT ? 'Appartement' : 'Maison',
          onChanged: (v) {
            final type =
                v == 'Appartement' ? HousingType.APARTMENT : HousingType.HOUSE;
            _updateHousing(_housing.copyWith(type: type));
            _saveHousingField({'type': type.name});
          },
        ),
        VNumberField(
          label: 'Ann\u00e9e de construction',
          initialValue: _housing.year?.toString() ?? '',
          onChanged: (v) {
            final year = int.tryParse(v);
            _updateHousing(_housing.copyWith(year: year));
            _saveHousingField({'year_value': year});
          },
        ),
        VTextField(
          label: 'Ann\u00e9e d\u2019habitation',
          initialValue: _formData['yearHabitation']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('yearHabitation', v),
        ),
        VNumberField(
          label: 'Surface',
          initialValue: _housing.surface?.toString() ?? '',
          suffix: 'm\u00b2',
          onChanged: (v) {
            final surface = double.tryParse(v);
            _updateHousing(_housing.copyWith(surface: surface));
            _saveHousingField({'surface': surface});
          },
        ),
        VDropdown(
          label: 'Nombre de niveaux',
          options: const ['1', '2', '3', '4', '5'],
          selected: _formData['levels']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('levels', v),
        ),
      ],
    );
  }

  Widget _buildInterior() {
    const roomOptions = [
      'Salle de bain',
      'WC',
      'Cuisine',
      'Chambre',
    ];

    Widget levelBlock(String key, String label) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          VCheckbox(
            label: label,
            value: _formData[key] == true,
            onChanged: (v) => _onFormChanged(key, v),
          ),
          if (_formData[key] == true)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Column(
                children: roomOptions
                    .map((room) => VCheckbox(
                          label: room,
                          value: _getListBool('${key}Rooms', room),
                          onChanged: (v) =>
                              _toggleListItem('${key}Rooms', room, v),
                        ))
                    .toList(),
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Niveaux & Pi\u00e8ces'),
        levelBlock('basement', 'Sous-sol'),
        levelBlock('rdc', 'RDC'),
        levelBlock('floor', '1er \u00e9tage'),
        levelBlock('secondFloor', '2\u00e8me \u00e9tage'),
        levelBlock('thirdFloor', '3\u00e8me \u00e9tage'),
        const VSectionHeader('Chauffage'),
        VCheckbox(
          label: '\u00c9lectrique',
          value: _getListBool('heatingDetails', 'electric'),
          onChanged: (v) => _toggleListItem('heatingDetails', 'electric', v),
        ),
        VCheckbox(
          label: 'Gaz',
          value: _getListBool('heatingDetails', 'gas'),
          onChanged: (v) => _toggleListItem('heatingDetails', 'gas', v),
        ),
        VCheckbox(
          label: 'Fioul',
          value: _getListBool('heatingDetails', 'oil'),
          onChanged: (v) => _toggleListItem('heatingDetails', 'oil', v),
        ),
        VCheckbox(
          label: 'Pompe \u00e0 chaleur',
          value: _getListBool('heatingDetails', 'heatPump'),
          onChanged: (v) => _toggleListItem('heatingDetails', 'heatPump', v),
        ),
        VCheckbox(
          label: 'Bois',
          value: _getListBool('heatingDetails', 'wood'),
          onChanged: (v) => _toggleListItem('heatingDetails', 'wood', v),
        ),
        VCheckbox(
          label: 'Granul\u00e9s',
          value: _getListBool('heatingDetails', 'pellet'),
          onChanged: (v) => _toggleListItem('heatingDetails', 'pellet', v),
        ),
        VCheckbox(
          label: 'Collectif',
          value: _getListBool('heatingDetails', 'collective'),
          onChanged: (v) =>
              _toggleListItem('heatingDetails', 'collective', v),
        ),
        VCheckbox(
          label: 'Autre',
          value: _getListBool('heatingDetails', 'other'),
          onChanged: (v) => _toggleListItem('heatingDetails', 'other', v),
        ),
      ],
    );
  }

  Widget _buildExterior() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Acc\u00e8s depuis la rue'),
        VToggleGroup(
          label: 'Acc\u00e8s',
          options: const ['Facile', '\u00c0 revoir'],
          selected: _formData['easyAccess']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('easyAccess', v),
        ),
        VTextArea(
          label: 'Observations acc\u00e8s',
          initialValue: _housing.accessibilityNotes,
          onChanged: (v) {
            _updateHousing(_housing.copyWith(accessibilityNotes: v));
            _saveHousingField({'accessibility_notes': v});
          },
        ),
        const VSectionHeader('Cheminement'),
        VCheckbox(
          label: 'Plat',
          value: _formData['cheminementPlat'] == true,
          onChanged: (v) => _onFormChanged('cheminementPlat', v),
        ),
        VCheckbox(
          label: 'Pente douce',
          value: _formData['cheminementPenteDouce'] == true,
          onChanged: (v) => _onFormChanged('cheminementPenteDouce', v),
        ),
        VCheckbox(
          label: 'Quelques marches',
          value: _formData['cheminementQuelquesMarches'] == true,
          onChanged: (v) => _onFormChanged('cheminementQuelquesMarches', v),
        ),
        VCheckbox(
          label: 'Escalier ext\u00e9rieur',
          value: _formData['cheminementEscalierExterieur'] == true,
          onChanged: (v) =>
              _onFormChanged('cheminementEscalierExterieur', v),
        ),
        VCheckbox(
          label: 'Escalier int\u00e9rieur',
          value: _formData['cheminementEscalierInterieur'] == true,
          onChanged: (v) =>
              _onFormChanged('cheminementEscalierInterieur', v),
        ),
        VCheckbox(
          label: 'Seuil de porte',
          value: _formData['cheminementSeuilPorte'] == true,
          onChanged: (v) => _onFormChanged('cheminementSeuilPorte', v),
        ),
        VCheckbox(
          label: 'Passage par l\u2019arri\u00e8re',
          value: _formData['cheminementParArriere'] == true,
          onChanged: (v) => _onFormChanged('cheminementParArriere', v),
        ),
        const VSectionHeader('Annexes & Motorisations'),
        VCheckbox(
          label: 'Garage',
          value: _formData['garage'] == true,
          onChanged: (v) => _onFormChanged('garage', v),
        ),
        VCheckbox(
          label: 'V\u00e9randa',
          value: _formData['veranda'] == true,
          onChanged: (v) => _onFormChanged('veranda', v),
        ),
        VCheckbox(
          label: 'Balcon',
          value: _formData['balcon'] == true,
          onChanged: (v) => _onFormChanged('balcon', v),
        ),
        VCheckbox(
          label: 'Terrasse',
          value: _formData['terrasse'] == true,
          onChanged: (v) => _onFormChanged('terrasse', v),
        ),
        VCheckbox(
          label: 'Jardin',
          value: _formData['jardin'] == true,
          onChanged: (v) => _onFormChanged('jardin', v),
        ),
        VTextField(
          label: 'Motorisation porte de garage',
          initialValue:
              _formData['motorisationPorteGarage']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('motorisationPorteGarage', v),
        ),
        VTextField(
          label: 'Motorisation portail',
          initialValue: _formData['motorisationPortail']?.toString() ?? '',
          onChanged: (v) => _onFormChanged('motorisationPortail', v),
        ),
      ],
    );
  }

  Widget _buildShutters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Volets'),
        VCheckbox(
          label: 'Volets roulants manuels (entier)',
          value: _formData['voletsRoulantsManuelsEntier'] == true,
          onChanged: (v) =>
              _onFormChanged('voletsRoulantsManuelsEntier', v),
        ),
        VTextField(
          label: 'Localisation volets roulants manuels',
          initialValue:
              _formData['voletsRoulantsManuelsLocalisation']?.toString() ?? '',
          onChanged: (v) =>
              _onFormChanged('voletsRoulantsManuelsLocalisation', v),
        ),
        VCheckbox(
          label: 'Volets roulants \u00e9lectriques (entier)',
          value: _formData['voletsRoulantsElectriquesEntier'] == true,
          onChanged: (v) =>
              _onFormChanged('voletsRoulantsElectriquesEntier', v),
        ),
        VTextField(
          label: 'Localisation volets roulants \u00e9lectriques',
          initialValue:
              _formData['voletsRoulantsElectriquesLocalisation']?.toString() ??
                  '',
          onChanged: (v) =>
              _onFormChanged('voletsRoulantsElectriquesLocalisation', v),
        ),
        VCheckbox(
          label: 'Persiennes (entier)',
          value: _formData['voletsPersiennesEntier'] == true,
          onChanged: (v) => _onFormChanged('voletsPersiennesEntier', v),
        ),
        VTextField(
          label: 'Localisation persiennes',
          initialValue:
              _formData['voletsPersiennesLocalisation']?.toString() ?? '',
          onChanged: (v) =>
              _onFormChanged('voletsPersiennesLocalisation', v),
        ),
      ],
    );
  }
}
