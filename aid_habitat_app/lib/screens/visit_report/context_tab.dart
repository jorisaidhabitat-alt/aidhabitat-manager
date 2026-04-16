import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

class ContextTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  const ContextTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<ContextTab> createState() => _ContextTabState();
}

class _ContextTabState extends State<ContextTab> {
  MedicalContext _medical = const MedicalContext();
  AutonomyData _autonomy = _defaultAutonomy();
  int _subSection = 0;
  bool _saving = false;
  Timer? _saveTimer;
  bool _loaded = false;

  static AutonomyData _defaultAutonomy() {
    return AutonomyData(
      checklist: kAutonomyItemNames
          .map((name) => AutonomyItem(name: name))
          .toList(),
    );
  }

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
    final data =
        await widget.repository.fetchContexteDeVie(widget.dossier.id);
    if (data != null) {
      _medical = data['medicalContext'] != null
          ? MedicalContext.fromJson(
              data['medicalContext'] as Map<String, dynamic>)
          : const MedicalContext();
      _autonomy = data['autonomy'] != null
          ? AutonomyData.fromJson(data['autonomy'] as Map<String, dynamic>)
          : _defaultAutonomy();
    }
    if (mounted) setState(() => _loaded = true);
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _saving = true);
    await widget.repository.upsertContexteDeVie(
      widget.dossier.id,
      widget.dossier.patient.id,
      medicalContext: _medical,
      autonomy: _autonomy,
    );
    if (mounted) setState(() => _saving = false);
  }

  void _updateMedical(MedicalContext updated) {
    setState(() => _medical = updated);
    _scheduleSave();
  }

  void _updateChecklistItem(int index, bool checked) {
    final items = List<AutonomyItem>.from(_autonomy.checklist);
    items[index] = items[index].copyWith(checked: checked);
    setState(() {
      _autonomy = AutonomyData(
        done: _autonomy.done,
        checklist: items,
        occupants: _autonomy.occupants,
      );
    });
    _scheduleSave();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        _buildSubSectionToggle(),
        if (_saving)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: LinearProgressIndicator(),
          ),
        Expanded(
          child: _subSection == 0 ? _buildMedical() : _buildAutonomy(),
        ),
      ],
    );
  }

  Widget _buildSubSectionToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ToggleButtons(
        isSelected: [_subSection == 0, _subSection == 1],
        onPressed: (index) => setState(() => _subSection = index),
        borderRadius: BorderRadius.circular(8),
        children: const [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Médical'),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Autonomie'),
          ),
        ],
      ),
    );
  }

  Widget _buildMedical() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FormTextField(
          label: 'Pathologie',
          value: _medical.pathology,
          maxLines: 3,
          onChanged: (v) => _updateMedical(MedicalContext(
            pathology: v,
            followUp: _medical.followUp,
            sensory: _medical.sensory,
            heightCm: _medical.heightCm,
            weightKg: _medical.weightKg,
          )),
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Suivi médical',
          value: _medical.followUp,
          maxLines: 3,
          onChanged: (v) => _updateMedical(MedicalContext(
            pathology: _medical.pathology,
            followUp: v,
            sensory: _medical.sensory,
            heightCm: _medical.heightCm,
            weightKg: _medical.weightKg,
          )),
        ),
        const SizedBox(height: 12),
        FormTextField(
          label: 'Déficience sensorielle',
          value: _medical.sensory,
          maxLines: 3,
          onChanged: (v) => _updateMedical(MedicalContext(
            pathology: _medical.pathology,
            followUp: _medical.followUp,
            sensory: v,
            heightCm: _medical.heightCm,
            weightKg: _medical.weightKg,
          )),
        ),
        const SizedBox(height: 12),
        FormNumberField(
          label: 'Taille',
          value: double.tryParse(_medical.heightCm),
          unit: 'cm',
          onChanged: (v) => _updateMedical(MedicalContext(
            pathology: _medical.pathology,
            followUp: _medical.followUp,
            sensory: _medical.sensory,
            heightCm: v?.toStringAsFixed(0) ?? '',
            weightKg: _medical.weightKg,
          )),
        ),
        const SizedBox(height: 12),
        FormNumberField(
          label: 'Poids',
          value: double.tryParse(_medical.weightKg),
          unit: 'kg',
          onChanged: (v) => _updateMedical(MedicalContext(
            pathology: _medical.pathology,
            followUp: _medical.followUp,
            sensory: _medical.sensory,
            heightCm: _medical.heightCm,
            weightKg: v?.toStringAsFixed(1) ?? '',
          )),
        ),
      ],
    );
  }

  Widget _buildAutonomy() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          "Grille d'autonomie",
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < _autonomy.checklist.length; i++)
          FormCheckbox(
            label: _autonomy.checklist[i].name,
            value: _autonomy.checklist[i].checked,
            onChanged: (checked) => _updateChecklistItem(i, checked),
          ),
      ],
    );
  }
}
