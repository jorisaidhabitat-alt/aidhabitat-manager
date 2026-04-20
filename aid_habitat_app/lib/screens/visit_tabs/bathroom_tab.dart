import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/types.dart';
import '../../services/data_service.dart';
import 'form_widgets.dart';

class BathroomTab extends StatefulWidget {
  final Dossier dossier;

  const BathroomTab({super.key, required this.dossier});

  @override
  State<BathroomTab> createState() => _BathroomTabState();
}

class _BathroomTabState extends State<BathroomTab> {
  final _dataService = DataService();
  Map<String, dynamic> _formData = {};
  int _subSection = 0;
  Timer? _saveTimer;
  bool _loaded = false;

  static const _sections = ['\u00c9quipements', 'Porte'];

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
    final data = await _dataService.fetchFormData(_patientId, 'sdb');
    if (mounted) setState(() { _formData = data; _loaded = true; });
  }

  void _onChanged(String key, dynamic value) {
    setState(() => _formData[key] = value);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _dataService.saveFormData(_patientId, 'sdb', _formData);
    });
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
            child: _subSection == 0 ? _buildEquipment() : _buildDoor(),
          ),
        ),
      ],
    );
  }

  Widget _buildEquipment() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Zone humide'),
        VCheckbox(
          label: 'Baignoire',
          value: _formData['sdbBaignoire'] == true,
          onChanged: (v) => _onChanged('sdbBaignoire', v),
        ),
        if (_formData['sdbBaignoire'] == true)
          VNumberField(
            label: 'Hauteur baignoire',
            initialValue:
                _formData['sdbBaignoireHauteur']?.toString() ?? '',
            suffix: 'cm',
            onChanged: (v) => _onChanged('sdbBaignoireHauteur', v),
          ),
        VCheckbox(
          label: 'Bac \u00e0 douche',
          value: _formData['sdbBacDouche'] == true,
          onChanged: (v) => _onChanged('sdbBacDouche', v),
        ),
        if (_formData['sdbBacDouche'] == true) ...[
          VNumberField(
            label: 'Hauteur bac douche',
            initialValue:
                _formData['sdbBacDoucheHauteur']?.toString() ?? '',
            suffix: 'cm',
            onChanged: (v) => _onChanged('sdbBacDoucheHauteur', v),
          ),
          VCheckbox(
            label: 'Paroi de douche',
            value: _formData['sdbParoiDouche'] == true,
            onChanged: (v) => _onChanged('sdbParoiDouche', v),
          ),
          if (_formData['sdbParoiDouche'] == true)
            VNumberField(
              label: 'Hauteur paroi',
              initialValue:
                  _formData['sdbParoiDoucheHauteur']?.toString() ?? '',
              suffix: 'cm',
              onChanged: (v) => _onChanged('sdbParoiDoucheHauteur', v),
            ),
        ],
        const VSectionHeader('\u00c9quipements compl\u00e9mentaires'),
        _equipmentRow('sdbVasqueSuspendue', 'Vasque suspendue'),
        _equipmentRow('sdbVasqueColonne', 'Vasque colonne'),
        _equipmentRow('sdbMeubleVasque', 'Meuble vasque'),
        _equipmentRow('sdbBidet', 'Bidet'),
        _equipmentRow('sdbMachineALaver', 'Machine \u00e0 laver'),
        const VSectionHeader('S\u00e9curit\u00e9'),
        VCheckbox(
          label: 'Sol glissant',
          value: _formData['sdbSolGlissant'] == true,
          onChanged: (v) => _onChanged('sdbSolGlissant', v),
        ),
      ],
    );
  }

  Widget _equipmentRow(String key, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VCheckbox(
          label: label,
          value: _formData[key] == true,
          onChanged: (v) => _onChanged(key, v),
        ),
        if (_formData[key] == true)
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: VNumberField(
              label: 'Hauteur $label',
              initialValue:
                  _formData['${key}Hauteur']?.toString() ?? '',
              suffix: 'cm',
              onChanged: (v) => _onChanged('${key}Hauteur', v),
            ),
          ),
      ],
    );
  }

  Widget _buildDoor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Porte salle de bain'),
        VToggleGroup(
          label: 'Largeur',
          options: const ['Suffisante', '\u00c0 revoir'],
          selected: _formData['porteSdbLargeurSuffisante']?.toString() ?? '',
          onChanged: (v) => _onChanged('porteSdbLargeurSuffisante', v),
        ),
        VNumberField(
          label: 'Dimension',
          initialValue:
              _formData['porteSdbDimension']?.toString() ?? '',
          suffix: 'cm',
          onChanged: (v) => _onChanged('porteSdbDimension', v),
        ),
        VToggleGroup(
          label: 'Sens d\u2019ouverture',
          options: const ['Int\u00e9rieur', 'Ext\u00e9rieur'],
          selected: _formData['porteSdbSensAdapte']?.toString() ?? '',
          onChanged: (v) => _onChanged('porteSdbSensAdapte', v),
        ),
      ],
    );
  }
}
