import 'package:flutter/material.dart';

import '../components/notes_widget.dart';
import '../models/types.dart';
import 'visit_tabs/accessibility_tab.dart';
import 'visit_tabs/bathroom_tab.dart';
import 'visit_tabs/beneficiary_tab.dart';
import 'visit_tabs/life_context_tab.dart';
import 'visit_tabs/measurements_tab.dart';
import 'visit_tabs/plans_tab.dart';
import 'visit_tabs/recommendations_tab.dart';
import 'visit_tabs/wc_tab.dart';

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
  static const _tabs = [
    'B\u00e9n\u00e9ficiaire',
    'Contexte de vie',
    'Mesures',
    'Accessibilit\u00e9',
    'Salle de bain',
    'WC',
    'Pr\u00e9conisations',
    'Plans',
  ];

  late TabController _tabController;
  late Dossier _dossier;

  @override
  void initState() {
    super.initState();
    _dossier = widget.dossier;
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
    if (!_tabController.indexIsChanging) setState(() {});
  }

  void _onDossierChanged(Dossier updated) {
    setState(() => _dossier = updated);
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = _tabController.index;
    final isPlansTab = currentIndex == 7;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          // ---- Top nav ----
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                color: const Color(0xFF554a63),
                onPressed: widget.onBack,
                tooltip: 'Retour',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    color: const Color(0xFFD8D0DC),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  labelColor: const Color(0xFF554a63),
                  unselectedLabelColor: const Color(0xFF907CA1),
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  labelPadding:
                      const EdgeInsets.symmetric(horizontal: 14),
                  tabs: _tabs.map((t) => Tab(text: t)).toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Content ----
          Expanded(
            child: isPlansTab
                ? PlansTab(
                    dossier: _dossier,
                    tabKey: _tabs[currentIndex],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Form column
                      Expanded(
                        flex: 1,
                        child: _buildFormTab(currentIndex),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        width: 1,
                        color: const Color(0xFFF1F5F9),
                      ),
                      const SizedBox(width: 16),
                      // Notes column
                      Expanded(
                        flex: 2,
                        child: ClipRect(
                          child: NotesWidget(
                            patientId: _dossier.patient.id,
                            tabKey: _tabs[currentIndex],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormTab(int index) {
    switch (index) {
      case 0:
        return BeneficiaryTab(
          dossier: _dossier,
          onDossierChanged: _onDossierChanged,
        );
      case 1:
        return LifeContextTab(
          dossier: _dossier,
          onDossierChanged: _onDossierChanged,
        );
      case 2:
        return MeasurementsTab(dossier: _dossier);
      case 3:
        return AccessibilityTab(
          dossier: _dossier,
          onDossierChanged: _onDossierChanged,
        );
      case 4:
        return BathroomTab(dossier: _dossier);
      case 5:
        return WcTab(dossier: _dossier);
      case 6:
        return RecommendationsTab(dossier: _dossier);
      default:
        return const SizedBox.shrink();
    }
  }
}
