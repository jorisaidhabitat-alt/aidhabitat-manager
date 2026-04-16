import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';

class DashboardScreen extends StatelessWidget {
  final List<Visit> visits;
  final int dossiersCount;
  final List<Dossier> dossiers;
  final int pendingSyncCount;
  final bool isSyncing;
  final VoidCallback onSyncNow;
  final Function(Dossier) onSelectDossier;

  const DashboardScreen({
    super.key,
    required this.visits,
    required this.dossiersCount,
    required this.dossiers,
    required this.pendingSyncCount,
    required this.isSyncing,
    required this.onSyncNow,
    required this.onSelectDossier,
  });

  @override
  Widget build(BuildContext context) {
    final recentDossiers = dossiers.take(3).toList();
    final now = DateTime.now();
    final dateStr = DateFormat('EEEE d MMMM', 'fr_FR').format(now);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Welcome Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Bonjour, Ergo",
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Voici le résumé de votre activité aujourd'hui.",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
              Text(
                // Capitalize first letter
                dateStr.replaceFirst(dateStr[0], dateStr[0].toUpperCase()),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),

          if (pendingSyncCount > 0 || isSyncing) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFED7AA)),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.upload, color: const Color(0xFFEA580C)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isSyncing
                          ? "Synchronisation NocoDB en cours..."
                          : "$pendingSyncCount élément(s) local(aux) en attente de synchronisation NocoDB.",
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF9A3412),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: isSyncing ? null : onSyncNow,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEA580C),
                      foregroundColor: Colors.white,
                    ),
                    child: Text(isSyncing ? 'Sync...' : 'Synchroniser'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],

          // KPI Cards
          Row(
            children: [
              Expanded(
                child: _KPICard(
                  icon: LucideIcons.users,
                  label: "Dossiers en cours",
                  value: dossiersCount.toString(),
                  color: Colors.blue,
                  trend: "+12%",
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: _KPICard(
                  icon: LucideIcons.calendar,
                  label: "Visites semaine",
                  value: visits.length.toString(),
                  color: Colors.purple,
                  trend: "+5%",
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: _KPICard(
                  icon: LucideIcons.checkCircle,
                  label: "Dossiers validés",
                  value: "12",
                  color: Colors.green,
                  trend: "+8%",
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),

          // Main Content Grid
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Recent Dossiers (2/3 width)
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "Dossiers Récents",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          TextButton(
                            onPressed: () {},
                            child: const Text(
                              "Voir tout",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF907CA1),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      ...recentDossiers.map(
                        (dossier) => _RecentDossierRow(
                          dossier: dossier,
                          onTap: () => onSelectDossier(dossier),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 32),

              // Activity Chart (1/3 width)
              Expanded(
                flex: 1,
                child: Container(
                  height: 400,
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Activité",
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Expanded(
                        child: BarChart(
                          BarChartData(
                            alignment: BarChartAlignment.spaceAround,
                            maxY: 15,
                            barTouchData: BarTouchData(enabled: false),
                            titlesData: FlTitlesData(
                              show: true,
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget: (value, meta) {
                                    const titles = [
                                      'Jan',
                                      'Fév',
                                      'Mar',
                                      'Avr',
                                      'Mai',
                                      'Juin',
                                    ];
                                    if (value.toInt() >= 0 &&
                                        value.toInt() < titles.length) {
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          top: 8.0,
                                        ),
                                        child: Text(
                                          titles[value.toInt()],
                                          style: TextStyle(
                                            color: Colors.grey.shade400,
                                            fontSize: 12,
                                          ),
                                        ),
                                      );
                                    }
                                    return const Text('');
                                  },
                                ),
                              ),
                              leftTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                            ),
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: false,
                              horizontalInterval: 5,
                              getDrawingHorizontalLine: (value) => FlLine(
                                color: Colors.grey.shade100,
                                strokeWidth: 1,
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            barGroups: [
                              _makeGroupData(0, 4),
                              _makeGroupData(1, 7),
                              _makeGroupData(2, 5),
                              _makeGroupData(3, 9),
                              _makeGroupData(4, 12),
                              _makeGroupData(5, 8, isLast: true),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  BarChartGroupData _makeGroupData(int x, double y, {bool isLast = false}) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          color: isLast ? const Color(0xFF907CA1) : Colors.grey.shade200,
          width: 32,
          borderRadius: BorderRadius.circular(6),
        ),
      ],
    );
  }
}

class _KPICard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final String trend;

  const _KPICard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.trend,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.trendingUp,
                      size: 14,
                      color: Colors.green.shade600,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      trend,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.green.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            value,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentDossierRow extends StatelessWidget {
  final Dossier dossier;
  final VoidCallback onTap;

  const _RecentDossierRow({required this.dossier, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  "${dossier.patient.firstName[0]}${dossier.patient.lastName[0]}",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${dossier.patient.lastName} ${dossier.patient.firstName}",
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Row(
                    children: [
                      Icon(
                        LucideIcons.mapPin,
                        size: 12,
                        color: Colors.grey.shade500,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        dossier.patient.city,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _StatusPill(status: dossier.status.label),
                const SizedBox(height: 6),
                Text(
                  dossier.syncState.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _syncColor(dossier.syncState),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 16),
            Icon(LucideIcons.arrowRight, color: Colors.grey.shade300),
          ],
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color text;

    switch (status) {
      case 'Validé':
        bg = Colors.green.shade100;
        text = Colors.green.shade700;
        break;
      case 'À visiter':
        bg = Colors.amber.shade100;
        text = Colors.amber.shade700;
        break;
      default:
        bg = Colors.grey.shade200;
        text = Colors.grey.shade600;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: text,
        ),
      ),
    );
  }
}

Color _syncColor(SyncState syncState) {
  switch (syncState) {
    case SyncState.synced:
      return Colors.green.shade700;
    case SyncState.pendingSync:
    case SyncState.localOnly:
    case SyncState.syncing:
      return Colors.orange.shade700;
    case SyncState.syncError:
    case SyncState.conflict:
      return Colors.red.shade700;
  }
}
