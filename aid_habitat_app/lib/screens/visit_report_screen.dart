import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../services/dossier_repository.dart';
import '../components/notes_widget.dart';
import 'visit_report/beneficiary_tab.dart';
import 'visit_report/context_tab.dart';
import 'visit_report/mesures_tab.dart';
import 'visit_report/accessibility_tab.dart';
import 'visit_report/bathroom_tab.dart';
import 'visit_report/wc_tab.dart';
import 'visit_report/recommendations_tab.dart';
import 'visit_report/plans_tab.dart';

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
  final DossierRepository _repository = DossierRepository();

  static const List<String> _tabs = [
    'Bénéficiaire',
    'Contexte de vie',
    'Mesures',
    'Accessibilité',
    'Salle de bain',
    'WC',
    'Préconisations',
    'Plans',
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
    if (mounted) setState(() {});
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
                          BeneficiaryTab(dossier: widget.dossier, repository: _repository),
                          ContextTab(dossier: widget.dossier, repository: _repository),
                          MesuresTab(dossier: widget.dossier, repository: _repository),
                          AccessibilityTab(dossier: widget.dossier, repository: _repository),
                          BathroomTab(dossier: widget.dossier, repository: _repository),
                          WcTab(dossier: widget.dossier, repository: _repository),
                          RecommendationsTab(dossier: widget.dossier, repository: _repository),
                          PlansTab(dossier: widget.dossier),
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
