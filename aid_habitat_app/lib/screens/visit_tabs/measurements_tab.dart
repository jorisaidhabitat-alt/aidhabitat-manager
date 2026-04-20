import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/types.dart';
import '../../services/data_service.dart';
import 'form_widgets.dart';

class MeasurementsTab extends StatefulWidget {
  final Dossier dossier;

  const MeasurementsTab({super.key, required this.dossier});

  @override
  State<MeasurementsTab> createState() => _MeasurementsTabState();
}

class _MeasurementsTabState extends State<MeasurementsTab> {
  final _dataService = DataService();
  Map<String, dynamic> _formData = {};
  Timer? _saveTimer;
  bool _loaded = false;

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
    final data = await _dataService.fetchFormData(_patientId, 'mesures');
    if (mounted) setState(() { _formData = data; _loaded = true; });
  }

  void _onChanged(String key, dynamic value) {
    setState(() => _formData[key] = value);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _dataService.saveFormData(_patientId, 'mesures', _formData);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());

    return SingleChildScrollView(
      padding: const EdgeInsets.only(right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const VSectionHeader('Position assise'),
          VNumberField(
            label: 'Hauteur des coudes',
            initialValue: _formData['assisHauteurCoudes']?.toString() ?? '',
            suffix: 'cm',
            onChanged: (v) => _onChanged('assisHauteurCoudes', v),
          ),
          VNumberField(
            label: 'Profondeur des genoux',
            initialValue: _formData['assisProfondeurGenoux']?.toString() ?? '',
            suffix: 'cm',
            onChanged: (v) => _onChanged('assisProfondeurGenoux', v),
          ),
          VNumberField(
            label: 'Hauteur d\u2019assise',
            initialValue: _formData['assisHauteurAssise']?.toString() ?? '',
            suffix: 'cm',
            onChanged: (v) => _onChanged('assisHauteurAssise', v),
          ),
          const VSectionHeader('Position debout'),
          VNumberField(
            label: 'Hauteur des coudes',
            initialValue: _formData['deboutHauteurCoude']?.toString() ?? '',
            suffix: 'cm',
            onChanged: (v) => _onChanged('deboutHauteurCoude', v),
          ),
          const VSectionHeader('Observations'),
          VTextArea(
            label: 'Observations compl\u00e9mentaires',
            initialValue: _formData['observations']?.toString() ?? '',
            onChanged: (v) => _onChanged('observations', v),
          ),
        ],
      ),
    );
  }
}
