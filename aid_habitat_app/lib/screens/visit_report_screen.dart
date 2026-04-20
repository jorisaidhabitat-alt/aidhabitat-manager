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

  // Refresh token incrémenté après sauvegarde salle de bain/WC pour que
  // l'onglet jumeau recharge ses données housing.
  int _housingRefreshToken = 0;

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

  // Index de l'onglet Plans — plein écran, sans colonne Notes.
  static const int _kPlansIndex = 7;

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

  void _onHousingSaved() {
    setState(() => _housingRefreshToken++);
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = _tabController.index;
    final isPlansTab = currentIndex == _kPlansIndex;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          children: [
            // ── Top Nav ──────────────────────────────────────────────────
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
                const SizedBox(width: 16),
                Expanded(
                  child: Container(
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(50),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      indicator: BoxDecoration(
                        color: const Color(0xFFD8D0DC),
                        borderRadius: BorderRadius.circular(50),
                      ),
                      labelColor: const Color(0xFF554a63),
                      unselectedLabelColor: Colors.black54,
                      labelStyle:
                          const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                      unselectedLabelStyle:
                          const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                      tabs: _tabs.map((tab) => Tab(text: tab)).toList(),
                      dividerColor: Colors.transparent,
                      padding: const EdgeInsets.all(4),
                      tabAlignment: TabAlignment.start,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // ── Content ──────────────────────────────────────────────────
            Expanded(
              child: isPlansTab
                  // Plans : plein écran, pas de colonne Notes
                  ? Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: PlansTab(dossier: widget.dossier),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Formulaire (55 %)
                        Expanded(
                          flex: 55,
                          child: Container(
                            padding: const EdgeInsets.all(24),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: _buildFormTab(currentIndex),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Notes (45 %)
                        Expanded(
                          flex: 45,
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 14,
                                ),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.only(
                                    topLeft: Radius.circular(24),
                                    topRight: Radius.circular(24),
                                  ),
                                  border: Border(
                                    bottom:
                                        BorderSide(color: Color(0xFFF1F5F9)),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Notes',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade100,
                                        borderRadius:
                                            BorderRadius.circular(50),
                                      ),
                                      child: const Text(
                                        'Sauvegarde auto',
                                        style: TextStyle(
                                            fontSize: 11, color: Colors.grey),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.only(
                                    bottomLeft: Radius.circular(24),
                                    bottomRight: Radius.circular(24),
                                  ),
                                  child: NotesWidget(
                                    patientId: widget.dossier.patient.id,
                                    tabKey: _tabs[currentIndex],
                                  ),
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

  Widget _buildFormTab(int index) {
    switch (index) {
      case 0:
        return BeneficiaryTab(
          dossier: widget.dossier,
          repository: _repository,
        );
      case 1:
        return ContextTab(
          dossier: widget.dossier,
          repository: _repository,
        );
      case 2:
        return MesuresTab(
          dossier: widget.dossier,
          repository: _repository,
        );
      case 3:
        return AccessibilityTab(
          dossier: widget.dossier,
          repository: _repository,
        );
      case 4:
        return BathroomTab(
          dossier: widget.dossier,
          repository: _repository,
          housingRefreshToken: _housingRefreshToken,
          onSaved: _onHousingSaved,
        );
      case 5:
        return WcTab(
          dossier: widget.dossier,
          repository: _repository,
          housingRefreshToken: _housingRefreshToken,
          onSaved: _onHousingSaved,
        );
      case 6:
        return RecommendationsTab(
          dossier: widget.dossier,
          repository: _repository,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
