import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/types.dart';
import '../../services/data_service.dart';
import 'form_widgets.dart';

class WcTab extends StatefulWidget {
  final Dossier dossier;

  const WcTab({super.key, required this.dossier});

  @override
  State<WcTab> createState() => _WcTabState();
}

class _WcTabState extends State<WcTab> {
  final _dataService = DataService();
  Map<String, dynamic> _formData = {};
  int _subSection = 0;
  Timer? _saveTimer;
  bool _loaded = false;

  static const _sections = ['Configuration', 'Porte'];

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
    final data = await _dataService.fetchFormData(_patientId, 'wc');
    if (mounted) setState(() { _formData = data; _loaded = true; });
  }

  void _onChanged(String key, dynamic value) {
    setState(() => _formData[key] = value);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _dataService.saveFormData(_patientId, 'wc', _formData);
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
            child: _subSection == 0 ? _buildMain() : _buildDoor(),
          ),
        ),
      ],
    );
  }

  Widget _buildMain() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Configuration et \u00e9quipements'),
        VCheckbox(
          label: 'Cuvette bonne hauteur',
          value: _formData['wcCuvetteBonneHauteur'] == true,
          onChanged: (v) => _onChanged('wcCuvetteBonneHauteur', v),
        ),
        VCheckbox(
          label: 'Cuvette trop basse',
          value: _formData['wcCuvetteTropBasse'] == true,
          onChanged: (v) => _onChanged('wcCuvetteTropBasse', v),
        ),
        VNumberField(
          label: 'Hauteur cuvette',
          initialValue: _formData['wcCuvetteHauteur']?.toString() ?? '',
          suffix: 'cm',
          onChanged: (v) => _onChanged('wcCuvetteHauteur', v),
        ),
        VCheckbox(
          label: 'Barre de rel\u00e8vement',
          value: _formData['wcBarreRelevement'] == true,
          onChanged: (v) => _onChanged('wcBarreRelevement', v),
        ),
        const VSectionHeader('Observations'),
        VTextArea(
          label: 'Observations \u00e9quipements / utilisation',
          initialValue:
              _formData['observationEquipementsUtilisation']?.toString() ?? '',
          onChanged: (v) =>
              _onChanged('observationEquipementsUtilisation', v),
        ),
      ],
    );
  }

  Widget _buildDoor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Porte WC'),
        VToggleGroup(
          label: 'Largeur',
          options: const ['Suffisante', '\u00c0 revoir'],
          selected: _formData['porteWcLargeurSuffisante']?.toString() ?? '',
          onChanged: (v) => _onChanged('porteWcLargeurSuffisante', v),
        ),
        VNumberField(
          label: 'Dimension',
          initialValue: _formData['porteWcDimension']?.toString() ?? '',
          suffix: 'cm',
          onChanged: (v) => _onChanged('porteWcDimension', v),
        ),
        VToggleGroup(
          label: 'Sens d\u2019ouverture',
          options: const ['Int\u00e9rieur', 'Ext\u00e9rieur'],
          selected: _formData['porteWcSensAdapte']?.toString() ?? '',
          onChanged: (v) => _onChanged('porteWcSensAdapte', v),
        ),
      ],
    );
  }
}
