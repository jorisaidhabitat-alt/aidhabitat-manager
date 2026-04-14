import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../components/notes_widget.dart';

class VisitReportScreen extends StatefulWidget {
  final Dossier dossier;
  final VoidCallback onBack;

  const VisitReportScreen({
    super.key,
    required this.dossier,
    required this.onBack,
  });

  @override
  State<VisitReportScreen> createState() => _VisitReportScreenState();
}

class _VisitReportScreenState extends State<VisitReportScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final List<String> _tabs = [
    'Bénéficiaire',
    'Contexte de vie',
    'Accessibilité',
    'Salle de bain',
    'WC',
    'Équipements lourds',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(_handleTabChange);
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            // Top Nav
            Row(
              children: [
                InkWell(
                  onTap: widget.onBack,
                  borderRadius: BorderRadius.circular(50),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: const Icon(
                      LucideIcons.arrowLeft,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(50),
                      border: Border.all(color: const Color(0xFF597E8D)),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      indicator: BoxDecoration(
                        color: const Color(0xFFD8D0DC),
                        borderRadius: BorderRadius.circular(50),
                      ),
                      labelColor: const Color(0xFF554a63),
                      unselectedLabelColor: Colors.black87,
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                      tabs: _tabs.map((tab) => Tab(text: tab)).toList(),
                      dividerColor: Colors.transparent,
                      padding: const EdgeInsets.all(4),
                      tabAlignment: TabAlignment.start,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Content Area
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Form Column
                  Expanded(
                    flex: 1,
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _BeneficiaryForm(dossier: widget.dossier),
                          const Center(
                            child: Text("Formulaire Contexte de vie"),
                          ),
                          const Center(child: Text("Formulaire Accessibilité")),
                          const Center(child: Text("Formulaire Salle de bain")),
                          const Center(child: Text("Formulaire WC")),
                          const Center(
                            child: Text("Formulaire Équipements lourds"),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),

                  // Right Column: Canvas Notes
                  Expanded(
                    flex: 2,
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(24),
                              topRight: Radius.circular(24),
                            ),
                            border: Border(
                              bottom: BorderSide(color: Color(0xFFF1F5F9)),
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                "Notes",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade100,
                                  borderRadius: BorderRadius.circular(50),
                                ),
                                child: const Text(
                                  "À jour",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: NotesWidget(
                            patientId: widget.dossier.patient.id,
                            tabKey: _tabs[_tabController.index],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BeneficiaryForm extends StatelessWidget {
  final Dossier dossier;

  const _BeneficiaryForm({required this.dossier});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TextField(
            label: "Nom et prénom",
            initialValue:
                "${dossier.patient.lastName} ${dossier.patient.firstName}",
          ),
          const SizedBox(height: 24),
          _ToggleGroup(
            label: "Situation du bénéficiaire",
            options: const [
              'Marié',
              'Célibataire',
              'Divorcé',
              'Veuf(ve)',
              'Concubinage',
            ],
            selected: dossier.patient.familySituation,
          ),
          const SizedBox(height: 24),
          const _ToggleGroup(
            label: "Statut d'occupation",
            options: ['Propriétaire', 'Locataire', 'Usufruitier'],
            selected: 'Usufruitier',
          ),
          const Divider(height: 48),
          const _ToggleGroup(
            label: "Bénéficiaire APA",
            options: ['Oui', 'Non'],
            selected: 'Non',
          ),
        ],
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  final String label;
  final String initialValue;

  const _TextField({required this.label, required this.initialValue});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: initialValue,
          decoration: const InputDecoration(
            border: UnderlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }
}

class _ToggleGroup extends StatelessWidget {
  final String label;
  final List<String> options;
  final String selected;

  const _ToggleGroup({
    required this.label,
    required this.options,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: options.map((opt) {
            final isSelected = opt == selected;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF907CA1) : Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF907CA1)
                      : Colors.grey.shade400,
                ),
              ),
              child: Text(
                opt,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.black87,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
