import 'dart:async';
import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';

class BathroomTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  const BathroomTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<BathroomTab> createState() => _BathroomTabState();
}

class _BathroomTabState extends State<BathroomTab> {
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

  List<BathroomInstance> get _instances => _diagnostic?.sdbInstances ?? [];

  void _updateInstance(int index, BathroomInstance updated) {
    final list = List<BathroomInstance>.from(_instances);
    list[index] = updated;
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: list,
        wcInstances: _diagnostic?.wcInstances ?? [],
      );
    });
    _scheduleSave();
  }

  void _addInstance() {
    final list = List<BathroomInstance>.from(_instances);
    final newId = 'sdb_${DateTime.now().millisecondsSinceEpoch}';
    final label = 'Salle de bain ${list.length + 1}';
    list.add(BathroomInstance(id: newId, levelLabel: label));
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: list,
        wcInstances: _diagnostic?.wcInstances ?? [],
      );
      _expandedIds.add(newId);
    });
    _scheduleSave();
  }

  void _removeInstance(int index) {
    final list = List<BathroomInstance>.from(_instances);
    final removed = list.removeAt(index);
    _expandedIds.remove(removed.id);
    setState(() {
      _diagnostic = DiagnosticSanitaire(
        dossierId: widget.dossier.id,
        sdbInstances: list,
        wcInstances: _diagnostic?.wcInstances ?? [],
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
                      label: const Text('Ajouter une salle de bain'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF907CA1),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                )
              else ...[
                for (int i = 0; i < instances.length; i++)
                  _BathroomCard(
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
                    label: const Text('Ajouter salle de bain'),
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

class _BathroomCard extends StatelessWidget {
  final BathroomInstance instance;
  final int index;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final ValueChanged<BathroomInstance> onUpdate;
  final VoidCallback onDelete;

  const _BathroomCard({
    required this.instance,
    required this.index,
    required this.expanded,
    required this.onToggleExpand,
    required this.onUpdate,
    required this.onDelete,
  });

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
                  const Icon(Icons.bathtub_outlined, size: 20, color: Color(0xFF907CA1)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      instance.levelLabel.isNotEmpty
                          ? instance.levelLabel
                          : 'Salle de bain ${index + 1}',
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

                  FormCheckbox(
                    label: 'Baignoire',
                    value: instance.sdbBaignoire,
                    onChanged: (v) => onUpdate(BathroomInstance(
                      id: instance.id, levelField: instance.levelField, levelLabel: instance.levelLabel,
                      sdbBaignoire: v, sdbBaignoireHauteur: instance.sdbBaignoireHauteur,
                      sdbBacDouche: instance.sdbBacDouche, sdbBacDoucheHauteur: instance.sdbBacDoucheHauteur,
                      sdbVasqueSuspendue: instance.sdbVasqueSuspendue, sdbVasqueSuspendueHauteur: instance.sdbVasqueSuspendueHauteur,
                      sdbVasqueColonne: instance.sdbVasqueColonne, sdbVasqueColonneHauteur: instance.sdbVasqueColonneHauteur,
                      sdbMeubleVasque: instance.sdbMeubleVasque, sdbMeubleVasqueHauteur: instance.sdbMeubleVasqueHauteur,
                      sdbBidet: instance.sdbBidet, sdbBidetHauteur: instance.sdbBidetHauteur,
                      sdbParoiDouche: instance.sdbParoiDouche, sdbParoiDoucheHauteur: instance.sdbParoiDoucheHauteur,
                      sdbSolGlissant: instance.sdbSolGlissant,
                      sdbMachineALaver: instance.sdbMachineALaver, sdbMachineALaverHauteur: instance.sdbMachineALaverHauteur,
                      porteSdbLargeurSuffisante: instance.porteSdbLargeurSuffisante, porteSdbDimension: instance.porteSdbDimension,
                      porteSdbSensAdapte: instance.porteSdbSensAdapte,
                    )),
                  ),
                  if (instance.sdbBaignoire) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur baignoire',
                        value: instance.sdbBaignoireHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(BathroomInstance(
                          id: instance.id, levelField: instance.levelField, levelLabel: instance.levelLabel,
                          sdbBaignoire: instance.sdbBaignoire, sdbBaignoireHauteur: v,
                          sdbBacDouche: instance.sdbBacDouche, sdbBacDoucheHauteur: instance.sdbBacDoucheHauteur,
                          sdbVasqueSuspendue: instance.sdbVasqueSuspendue, sdbVasqueSuspendueHauteur: instance.sdbVasqueSuspendueHauteur,
                          sdbVasqueColonne: instance.sdbVasqueColonne, sdbVasqueColonneHauteur: instance.sdbVasqueColonneHauteur,
                          sdbMeubleVasque: instance.sdbMeubleVasque, sdbMeubleVasqueHauteur: instance.sdbMeubleVasqueHauteur,
                          sdbBidet: instance.sdbBidet, sdbBidetHauteur: instance.sdbBidetHauteur,
                          sdbParoiDouche: instance.sdbParoiDouche, sdbParoiDoucheHauteur: instance.sdbParoiDoucheHauteur,
                          sdbSolGlissant: instance.sdbSolGlissant,
                          sdbMachineALaver: instance.sdbMachineALaver, sdbMachineALaverHauteur: instance.sdbMachineALaverHauteur,
                          porteSdbLargeurSuffisante: instance.porteSdbLargeurSuffisante, porteSdbDimension: instance.porteSdbDimension,
                          porteSdbSensAdapte: instance.porteSdbSensAdapte,
                        )),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Bac a douche',
                    value: instance.sdbBacDouche,
                    onChanged: (v) => onUpdate(_copyWith(sdbBacDouche: v)),
                  ),
                  if (instance.sdbBacDouche) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur bac',
                        value: instance.sdbBacDoucheHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(_copyWith(sdbBacDoucheHauteur: v)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Vasque suspendue',
                    value: instance.sdbVasqueSuspendue,
                    onChanged: (v) => onUpdate(_copyWith(sdbVasqueSuspendue: v)),
                  ),
                  if (instance.sdbVasqueSuspendue) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur',
                        value: instance.sdbVasqueSuspendueHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(_copyWith(sdbVasqueSuspendueHauteur: v)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Vasque sur colonne',
                    value: instance.sdbVasqueColonne,
                    onChanged: (v) => onUpdate(_copyWith(sdbVasqueColonne: v)),
                  ),
                  if (instance.sdbVasqueColonne) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur',
                        value: instance.sdbVasqueColonneHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(_copyWith(sdbVasqueColonneHauteur: v)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Meuble vasque',
                    value: instance.sdbMeubleVasque,
                    onChanged: (v) => onUpdate(_copyWith(sdbMeubleVasque: v)),
                  ),
                  if (instance.sdbMeubleVasque) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur',
                        value: instance.sdbMeubleVasqueHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(_copyWith(sdbMeubleVasqueHauteur: v)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Bidet',
                    value: instance.sdbBidet,
                    onChanged: (v) => onUpdate(_copyWith(sdbBidet: v)),
                  ),
                  if (instance.sdbBidet) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur',
                        value: instance.sdbBidetHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(_copyWith(sdbBidetHauteur: v)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Paroi de douche',
                    value: instance.sdbParoiDouche,
                    onChanged: (v) => onUpdate(_copyWith(sdbParoiDouche: v)),
                  ),
                  if (instance.sdbParoiDouche) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur',
                        value: instance.sdbParoiDoucheHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(_copyWith(sdbParoiDoucheHauteur: v)),
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Sol glissant',
                    value: instance.sdbSolGlissant,
                    onChanged: (v) => onUpdate(_copyWith(sdbSolGlissant: v)),
                  ),
                  const SizedBox(height: 4),

                  FormCheckbox(
                    label: 'Machine a laver',
                    value: instance.sdbMachineALaver,
                    onChanged: (v) => onUpdate(_copyWith(sdbMachineALaver: v)),
                  ),
                  if (instance.sdbMachineALaver) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: FormNumberField(
                        label: 'Hauteur',
                        value: instance.sdbMachineALaverHauteur,
                        unit: 'cm',
                        onChanged: (v) => onUpdate(_copyWith(sdbMachineALaverHauteur: v)),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),
                  // --- Porte ---
                  const FormSectionHeader(title: 'Porte', icon: Icons.door_front_door_outlined),
                  const SizedBox(height: 8),

                  FormToggleGroup(
                    label: 'Largeur suffisante',
                    options: const ['Suffisante', 'A revoir'],
                    selected: instance.porteSdbLargeurSuffisante ? 'Suffisante' : 'A revoir',
                    onChanged: (v) => onUpdate(_copyWith(porteSdbLargeurSuffisante: v == 'Suffisante')),
                  ),
                  const SizedBox(height: 12),

                  FormNumberField(
                    label: 'Dimension',
                    value: instance.porteSdbDimension,
                    unit: 'cm',
                    onChanged: (v) => onUpdate(_copyWith(porteSdbDimension: v)),
                  ),
                  const SizedBox(height: 12),

                  FormToggleGroup(
                    label: "Sens d'ouverture adapte",
                    options: const ['Adapte', 'A revoir'],
                    selected: instance.porteSdbSensAdapte ? 'Adapte' : 'A revoir',
                    onChanged: (v) => onUpdate(_copyWith(porteSdbSensAdapte: v == 'Adapte')),
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

  BathroomInstance _copyWith({
    bool? sdbBaignoire,
    double? sdbBaignoireHauteur,
    bool? sdbBacDouche,
    double? sdbBacDoucheHauteur,
    bool? sdbVasqueSuspendue,
    double? sdbVasqueSuspendueHauteur,
    bool? sdbVasqueColonne,
    double? sdbVasqueColonneHauteur,
    bool? sdbMeubleVasque,
    double? sdbMeubleVasqueHauteur,
    bool? sdbBidet,
    double? sdbBidetHauteur,
    bool? sdbParoiDouche,
    double? sdbParoiDoucheHauteur,
    bool? sdbSolGlissant,
    bool? sdbMachineALaver,
    double? sdbMachineALaverHauteur,
    bool? porteSdbLargeurSuffisante,
    double? porteSdbDimension,
    bool? porteSdbSensAdapte,
  }) {
    return BathroomInstance(
      id: instance.id,
      levelField: instance.levelField,
      levelLabel: instance.levelLabel,
      sdbBaignoire: sdbBaignoire ?? instance.sdbBaignoire,
      sdbBaignoireHauteur: sdbBaignoireHauteur ?? instance.sdbBaignoireHauteur,
      sdbBacDouche: sdbBacDouche ?? instance.sdbBacDouche,
      sdbBacDoucheHauteur: sdbBacDoucheHauteur ?? instance.sdbBacDoucheHauteur,
      sdbVasqueSuspendue: sdbVasqueSuspendue ?? instance.sdbVasqueSuspendue,
      sdbVasqueSuspendueHauteur: sdbVasqueSuspendueHauteur ?? instance.sdbVasqueSuspendueHauteur,
      sdbVasqueColonne: sdbVasqueColonne ?? instance.sdbVasqueColonne,
      sdbVasqueColonneHauteur: sdbVasqueColonneHauteur ?? instance.sdbVasqueColonneHauteur,
      sdbMeubleVasque: sdbMeubleVasque ?? instance.sdbMeubleVasque,
      sdbMeubleVasqueHauteur: sdbMeubleVasqueHauteur ?? instance.sdbMeubleVasqueHauteur,
      sdbBidet: sdbBidet ?? instance.sdbBidet,
      sdbBidetHauteur: sdbBidetHauteur ?? instance.sdbBidetHauteur,
      sdbParoiDouche: sdbParoiDouche ?? instance.sdbParoiDouche,
      sdbParoiDoucheHauteur: sdbParoiDoucheHauteur ?? instance.sdbParoiDoucheHauteur,
      sdbSolGlissant: sdbSolGlissant ?? instance.sdbSolGlissant,
      sdbMachineALaver: sdbMachineALaver ?? instance.sdbMachineALaver,
      sdbMachineALaverHauteur: sdbMachineALaverHauteur ?? instance.sdbMachineALaverHauteur,
      porteSdbLargeurSuffisante: porteSdbLargeurSuffisante ?? instance.porteSdbLargeurSuffisante,
      porteSdbDimension: porteSdbDimension ?? instance.porteSdbDimension,
      porteSdbSensAdapte: porteSdbSensAdapte ?? instance.porteSdbSensAdapte,
    );
  }
}
