import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/types.dart';
import '../../services/data_service.dart';
import 'form_widgets.dart';

class LifeContextTab extends StatefulWidget {
  final Dossier dossier;
  final ValueChanged<Dossier> onDossierChanged;

  const LifeContextTab({
    super.key,
    required this.dossier,
    required this.onDossierChanged,
  });

  @override
  State<LifeContextTab> createState() => _LifeContextTabState();
}

class _LifeContextTabState extends State<LifeContextTab> {
  final _dataService = DataService();
  Map<String, dynamic> _formData = {};
  int _subSection = 0;
  Timer? _saveTimer;
  bool _loaded = false;

  static const _sections = ['M\u00e9dical', 'Autonomie'];

  static const _autonomyItems = [
    'Manger',
    'Boire',
    'Miction',
    'D\u00e9f\u00e9cation',
    'Hygi\u00e8ne',
    'Habillage',
    'Transfert',
    'Verticalisation',
    'D\u00e9placement',
    'Escalier',
    'Sortir',
  ];

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
    final data = await _dataService.fetchFormData(_patientId, 'contexte');
    if (mounted) setState(() { _formData = data; _loaded = true; });
  }

  void _onFormChanged(String key, dynamic value) {
    setState(() => _formData[key] = value);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      _dataService.saveFormData(_patientId, 'contexte', _formData);
    });
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
            child: _subSection == 0 ? _buildMedical() : _buildAutonomy(),
          ),
        ),
      ],
    );
  }

  Widget _buildMedical() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Informations m\u00e9dicales'),
        VCheckbox(
          label: 'Pathologie(s)',
          value: _formData['pathology'] == true,
          onChanged: (v) => _onFormChanged('pathology', v),
        ),
        if (_formData['pathology'] == true)
          VTextField(
            label: 'D\u00e9tail pathologie',
            initialValue: _formData['pathologyTxt']?.toString() ?? '',
            onChanged: (v) => _onFormChanged('pathologyTxt', v),
          ),
        VCheckbox(
          label: 'Suivi m\u00e9dical',
          value: _formData['followUp'] == true,
          onChanged: (v) => _onFormChanged('followUp', v),
        ),
        if (_formData['followUp'] == true)
          VTextField(
            label: 'D\u00e9tail suivi',
            initialValue: _formData['followUpTxt']?.toString() ?? '',
            onChanged: (v) => _onFormChanged('followUpTxt', v),
          ),
        VCheckbox(
          label: 'D\u00e9ficit sensoriel',
          value: _formData['sensory'] == true,
          onChanged: (v) => _onFormChanged('sensory', v),
        ),
        if (_formData['sensory'] == true)
          VTextField(
            label: 'D\u00e9tail d\u00e9ficit sensoriel',
            initialValue: _formData['sensoryTxt']?.toString() ?? '',
            onChanged: (v) => _onFormChanged('sensoryTxt', v),
          ),
        const VSectionHeader('Mensurations'),
        VNumberField(
          label: 'Taille',
          initialValue: _formData['heightCm']?.toString() ?? '',
          suffix: 'cm',
          onChanged: (v) => _onFormChanged('heightCm', v),
        ),
        VNumberField(
          label: 'Poids',
          initialValue: _formData['weightKg']?.toString() ?? '',
          suffix: 'kg',
          onChanged: (v) => _onFormChanged('weightKg', v),
        ),
      ],
    );
  }

  Widget _buildAutonomy() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const VSectionHeader('Autonomie'),
        VCheckbox(
          label: '\u00c9valuation r\u00e9alis\u00e9e',
          value: _formData['autonomyDone'] == true,
          onChanged: (v) => _onFormChanged('autonomyDone', v),
        ),
        const SizedBox(height: 8),
        const Text(
          'Capacit\u00e9s fonctionnelles',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF554a63),
          ),
        ),
        const SizedBox(height: 4),
        ..._autonomyItems.map((item) => VCheckbox(
              label: item,
              value: _getListBool('autonomy', item),
              onChanged: (v) => _toggleListItem('autonomy', item, v),
            )),
        const VSectionHeader('Aide humaine'),
        ..._autonomyItems.map((item) => VCheckbox(
              label: item,
              value: _getListBool('humanHelp', item),
              onChanged: (v) => _toggleListItem('humanHelp', item, v),
            )),
        const SizedBox(height: 8),
        VTextArea(
          label: 'Notes autonomie',
          initialValue: widget.dossier.autonomyNotes,
          onChanged: (v) {
            widget.onDossierChanged(widget.dossier.copyWith(autonomyNotes: v));
            _dataService.updateDossierFields(
              widget.dossier.id,
              {'autonomy_notes': v},
            );
          },
        ),
      ],
    );
  }
}
