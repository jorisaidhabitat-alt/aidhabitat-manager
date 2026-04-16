import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

class WcTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  const WcTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<WcTab> createState() => _WcTabState();
}

class _WcTabState extends State<WcTab> {
  DiagnosticSanitaire? _diagnostic;
  bool _saving = false;
  Timer? _saveTimer;
  bool _loaded = false;
  final Set<String> _expandedIds = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final result = await widget.repository.fetchDiagnosticSanitaire(widget.dossier.id);
    if (!mounted) return;
    setState(() {
      _diagnostic = result ?? DiagnosticSanitaire(dossierId: widget.dossier.id);
      _loaded = true;
    });
  }

  List<WcInstance> get _instances => _diagnostic?.wcInstances ?? [];

  void _updateInstance(int index, WcInstance updated) {
    final list = List<WcInstance>.from(_instances);
    list[index] = updated;
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: _diagnostic?.sdbInstances ?? [],
        wcInstances: list,
      );
    });
    _scheduleSave();
  }

  void _addInstance() {
    final list = List<WcInstance>.from(_instances);
    final newId = 'wc_${DateTime.now().millisecondsSinceEpoch}';
    final label = 'WC ${list.length + 1}';
    list.add(WcInstance(id: newId, levelLabel: label));
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: _diagnostic?.sdbInstances ?? [],
        wcInstances: list,
      );
      _expandedIds.add(newId);
    });
    _scheduleSave();
  }

  void _removeInstance(int index) {
    final list = List<WcInstance>.from(_instances);
    final removed = list.removeAt(index);
    _expandedIds.remove(removed.id);
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: _diagnostic?.sdbInstances ?? [],
        wcInstances: list,
      );
    });
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (_diagnostic == null) return;
    setState(() => _saving = true);
    await widget.repository.upsertDiagnosticSanitaire(
      widget.dossier.id,
      _diagnostic!,
    );
    if (!mounted) return;
    setState(() => _saving = false);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }

    final instances = _instances;

    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (instances.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: ElevatedButton.icon(
                      onPressed: _addInstance,
                      icon: const Icon(Icons.add),
                      label: const Text('Ajouter WC'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF907CA1),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                )
              else ...[
                for (int i = 0; i < instances.length; i++)
                  _WcCard(
                    instance: instances[i],
                    index: i,
                    expanded: _expandedIds.contains(instances[i].id),
                    onToggleExpand: () {
                      setState(() {
                        if (_expandedIds.contains(instances[i].id)) {
                          _expandedIds.remove(instances[i].id);
                        } else {
                          _expandedIds.add(instances[i].id);
                        }
                      });
                    },
                    onUpdate: (updated) => _updateInstance(i, updated),
                    onDelete: () => _removeInstance(i),
                  ),
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: _addInstance,
                    icon: const Icon(Icons.add),
                    label: const Text('Ajouter WC'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF907CA1),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 80),
            ],
          ),
        ),
        Positioned(
          top: 8,
          right: 16,
          child: SaveStatusIndicator(saving: _saving),
        ),
      ],
    );
  }
}

class _WcCard extends StatelessWidget {
  final WcInstance instance;
  final int index;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final ValueChanged<WcInstance> onUpdate;
  final VoidCallback onDelete;

  const _WcCard({
    required this.instance,
    required this.index,
    required this.expanded,
    required this.onToggleExpand,
    required this.onUpdate,
    required this.onDelete,
  });

  WcInstance _copyWith({
    bool? wcCuvetteBonneHauteur,
    bool? wcCuvetteTropBasse,
    double? wcCuvetteHauteur,
    bool? wcBarreRelevement,
    bool? porteWcLargeurSuffisante,
    double? porteWcDimension,
    bool? porteWcSensAdapte,
    String? observationEquipementsUtilisation,
  }) {
    return WcInstance(
      id: instance.id,
      levelField: instance.levelField,
      levelLabel: instance.levelLabel,
      wcCuvetteBonneHauteur: wcCuvetteBonneHauteur ?? instance.wcCuvetteBonneHauteur,
      wcCuvetteTropBasse: wcCuvetteTropBasse ?? instance.wcCuvetteTropBasse,
      wcCuvetteHauteur: wcCuvetteHauteur ?? instance.wcCuvetteHauteur,
      wcBarreRelevement: wcBarreRelevement ?? instance.wcBarreRelevement,
      porteWcLargeurSuffisante: porteWcLargeurSuffisante ?? instance.porteWcLargeurSuffisante,
      porteWcDimension: porteWcDimension ?? instance.porteWcDimension,
      porteWcSensAdapte: porteWcSensAdapte ?? instance.porteWcSensAdapte,
      observationEquipementsUtilisation: observationEquipementsUtilisation ?? instance.observationEquipementsUtilisation,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          InkWell(
            onTap: onToggleExpand,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.wc_outlined, size: 20, color: Color(0xFF907CA1)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      instance.levelLabel.isNotEmpty
                          ? instance.levelLabel
                          : 'WC ${index + 1}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  // --- Equipements ---
                  const FormSectionHeader(title: 'Equipements', icon: Icons.plumbing),
                  const SizedBox(height: 8),

                  FormToggleGroup(
                    label: 'Hauteur cuvette',
                    options: const ['Bonne hauteur', 'Trop basse'],
                    selected: instance.wcCuvetteBonneHauteur ? 'Bonne hauteur' : 'Trop basse',
                    onChanged: (v) {
                      final bonneHauteur = v == 'Bonne hauteur';
                      onUpdate(_copyWith(
                        wcCuvetteBonneHauteur: bonneHauteur,
                        wcCuvetteTropBasse: !bonneHauteur,
                      ));
                    },
                  ),
                  const SizedBox(height: 12),

                  FormNumberField(
                    label: 'Hauteur cuvette',
                    value: instance.wcCuvetteHauteur,
                    unit: 'cm',
                    onChanged: (v) => onUpdate(_copyWith(wcCuvetteHauteur: v)),
                  ),
                  const SizedBox(height: 12),

                  FormToggleGroup(
                    label: 'Barre de relevement',
                    options: const ['Presente', 'Absente'],
                    selected: instance.wcBarreRelevement ? 'Presente' : 'Absente',
                    onChanged: (v) => onUpdate(_copyWith(wcBarreRelevement: v == 'Presente')),
                  ),
                  const SizedBox(height: 12),

                  FormTextField(
                    label: 'Observations',
                    value: instance.observationEquipementsUtilisation,
                    maxLines: 3,
                    onChanged: (v) => onUpdate(_copyWith(observationEquipementsUtilisation: v)),
                  ),

                  const SizedBox(height: 20),
                  // --- Porte ---
                  const FormSectionHeader(title: 'Porte', icon: Icons.door_front_door_outlined),
                  const SizedBox(height: 8),

                  FormToggleGroup(
                    label: 'Largeur suffisante',
                    options: const ['Suffisante', 'A revoir'],
                    selected: instance.porteWcLargeurSuffisante ? 'Suffisante' : 'A revoir',
                    onChanged: (v) => onUpdate(_copyWith(porteWcLargeurSuffisante: v == 'Suffisante')),
                  ),
                  const SizedBox(height: 12),

                  FormNumberField(
                    label: 'Dimension',
                    value: instance.porteWcDimension,
                    unit: 'cm',
                    onChanged: (v) => onUpdate(_copyWith(porteWcDimension: v)),
                  ),
                  const SizedBox(height: 12),

                  FormToggleGroup(
                    label: "Sens d'ouverture adapte",
                    options: const ['Adapte', 'A revoir'],
                    selected: instance.porteWcSensAdapte ? 'Adapte' : 'A revoir',
                    onChanged: (v) => onUpdate(_copyWith(porteWcSensAdapte: v == 'Adapte')),
                  ),

                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Supprimer'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red.shade400),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
