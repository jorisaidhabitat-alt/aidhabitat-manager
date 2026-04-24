import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../models/types.dart';

/// Dashboard screen aligned with the React web `Dashboard.tsx` layout:
///   - Welcome header with user name + today's date
///   - 3 KPI cards (Dossiers en cours / Visites semaine / Dossiers validés)
///   - Main grid: Recent dossiers list + custom activity bar chart
///
/// Data still comes from Flutter (SQLite + SyncEngine). The top sync banner
/// and [onSyncNow] wiring are kept intact.
class DashboardScreen extends StatelessWidget {
  final List<Visit> visits;
  final List<Dossier> dossiers;
  final int pendingSyncCount;
  final bool isSyncing;
  final VoidCallback onSyncNow;
  final void Function(Dossier) onSelectDossier;

  /// Optional: user's display name shown in "Bonjour, …". Falls back to "Ergo".
  final String? userName;

  /// Optional: callback to navigate to the dossiers list. Wired to the KPI
  /// cards and the "Voir tout" button for parity with the React version.
  final VoidCallback? onNavigateToDossiers;

  const DashboardScreen({
    super.key,
    required this.visits,
    required this.dossiers,
    required this.pendingSyncCount,
    required this.isSyncing,
    required this.onSyncNow,
    required this.onSelectDossier,
    this.userName,
    this.onNavigateToDossiers,
  });

  // Short French month labels for the activity chart (Jan..Déc).
  static const List<String> _monthsFr = [
    'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
    'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc',
  ];

  /// Returns the earliest upcoming visit (today or later) across all
  /// dossiers, or null if none is scheduled.
  _NextVisit? _findNextVisit(List<Dossier> dossiers, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    _NextVisit? best;
    for (final d in dossiers) {
      final raw = d.visitDate;
      if (raw == null || raw.isEmpty) continue;
      DateTime? when;
      try {
        when = DateTime.parse(raw);
      } catch (_) {
        continue;
      }
      final day = DateTime(when.year, when.month, when.day);
      if (day.isBefore(today)) continue;
      if (best == null || day.isBefore(best.date)) {
        best = _NextVisit(dossier: d, date: day);
      }
    }
    return best;
  }

  /// Builds the full postal address `<street> <zip> <CITY>`.
  /// Empty segments are skipped + whitespace collapsed.
  static String buildFullAddress(Patient p) {
    final street = p.address.trim();
    final zip = p.zipCode.trim();
    final city = p.city.trim();
    return [street, zip, city.toUpperCase()]
        .where((s) => s.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Builds the last-6-months activity series from the real dossiers list.
  /// Each bar = number of dossiers whose `createdAt` falls in that month.
  List<_ActivityBar> _buildActivitySeries(
    List<Dossier> dossiers,
    DateTime now,
  ) {
    final buckets = <String, int>{}; // key = "YYYY-MM"
    final months = <DateTime>[];
    for (var i = 5; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i, 1);
      months.add(m);
      final key = '${m.year}-${m.month.toString().padLeft(2, '0')}';
      buckets[key] = 0;
    }

    for (final d in dossiers) {
      DateTime? dt;
      try {
        dt = DateTime.parse(d.createdAt);
      } catch (_) {
        continue;
      }
      final key = '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
      if (buckets.containsKey(key)) {
        buckets[key] = buckets[key]! + 1;
      }
    }

    return months.map((m) {
      final key = '${m.year}-${m.month.toString().padLeft(2, '0')}';
      return _ActivityBar(name: _monthsFr[m.month - 1], value: buckets[key]!);
    }).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final recent = dossiers.take(3).toList();
    final now = DateTime.now();
    final rawDate = DateFormat('EEEE d MMMM', 'fr_FR').format(now);
    final dateLabel = rawDate.isEmpty
        ? rawDate
        : rawDate.replaceFirst(rawDate[0], rawDate[0].toUpperCase());

    // Next upcoming visit = nearest future `visitDate` across all dossiers.
    final nextVisit = _findNextVisit(dossiers, now);

    // Real activity chart data (last 6 months).
    final activityData = _buildActivitySeries(dossiers, now);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---------- Welcome header ----------
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Bonjour, ${userName ?? 'Ergo'}",
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A), // slate-900
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Voici le résumé de votre activité aujourd'hui.",
                      style: TextStyle(
                        fontSize: 15,
                        color: Color(0xFF64748B), // slate-500
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                dateLabel,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ---------- Prochaine visite banner (full width) ----------
          _NextVisitBanner(
            nextVisit: nextVisit,
            onTap: nextVisit == null
                ? null
                : () => onSelectDossier(nextVisit.dossier),
          ),
          const SizedBox(height: 24),

          // ---------- Main grid: recent dossiers + activity chart ----------
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Recent dossiers — matches React `minmax(0, 1.6fr)`.
                Expanded(
                  flex: 16,
                  child: _RecentDossiersPanel(
                    recent: recent,
                    onSelect: onSelectDossier,
                    onSeeAll: onNavigateToDossiers,
                  ),
                ),
                const SizedBox(width: 20),
                // Activity chart — matches React `minmax(280px, 0.9fr)`.
                Expanded(
                  flex: 9,
                  child: _PanelCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Activité",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Expanded(
                          child: _ActivityChart(data: activityData),
                        ),
                      ],
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
}

// ---------------------------------------------------------------------------
// KPI card
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// Recent dossiers panel
// ---------------------------------------------------------------------------

class _RecentDossiersPanel extends StatelessWidget {
  final List<Dossier> recent;
  final void Function(Dossier) onSelect;
  final VoidCallback? onSeeAll;

  const _RecentDossiersPanel({
    required this.recent,
    required this.onSelect,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    return _PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Mes rapports en cours",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1E293B),
                ),
              ),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
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
          const SizedBox(height: 16),
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  "Aucun dossier pour le moment.",
                  style: TextStyle(color: Colors.grey.shade500),
                ),
              ),
            )
          else
            ...recent.map(
              (d) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _RecentDossierRow(
                  dossier: d,
                  onTap: () => onSelect(d),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RecentDossierRow extends StatefulWidget {
  final Dossier dossier;
  final VoidCallback onTap;

  const _RecentDossierRow({required this.dossier, required this.onTap});

  @override
  State<_RecentDossierRow> createState() => _RecentDossierRowState();
}

class _RecentDossierRowState extends State<_RecentDossierRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final patient = widget.dossier.patient;
    final initials = _initials(patient.firstName, patient.lastName);
    final fullAddress = DashboardScreen.buildFullAddress(patient);
    final visitLabel = _formatVisitDate(widget.dossier.visitDate);

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _hover
                ? const Color(0xFFF1F5F9) // slate-100
                : const Color(0xFFF8FAFC), // slate-50
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    initials,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF334155), // slate-700
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
                      "${patient.lastName} ${patient.firstName}",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: _hover
                            ? const Color(0xFF907CA1)
                            : const Color(0xFF1E293B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(
                          LucideIcons.mapPin,
                          size: 12,
                          color: Color(0xFF94A3B8), // slate-400
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            fullAddress.isEmpty ? '—' : fullAddress,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Remplace l'ancien badge de statut par la date de visite
              // (demande utilisateur — le statut n'apporte pas d'info
              // actionnable sur le tableau de bord).
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: visitLabel.isEmpty
                      ? const Color(0xFFF1F5F9)
                      : const Color(0xFFF6EDFB), // violet clair du thème
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      LucideIcons.calendar,
                      size: 13,
                      color: visitLabel.isEmpty
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFF907CA1),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      visitLabel.isEmpty ? 'À planifier' : visitLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: visitLabel.isEmpty
                            ? const Color(0xFF64748B)
                            : const Color(0xFF907CA1),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Icon(
                LucideIcons.arrowRight,
                size: 18,
                color: _hover
                    ? const Color(0xFF907CA1)
                    : const Color(0xFFCBD5E1), // slate-300
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _initials(String first, String last) {
    final a = first.isNotEmpty ? first[0] : '';
    final b = last.isNotEmpty ? last[0] : '';
    return (a + b).toUpperCase();
  }

  String _formatVisitDate(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    try {
      final d = DateTime.parse(raw);
      return DateFormat('d MMM', 'fr_FR').format(d);
    } catch (_) {
      return '';
    }
  }
}

// ---------------------------------------------------------------------------
// Prochaine visite — banner
// ---------------------------------------------------------------------------

class _NextVisit {
  final Dossier dossier;
  final DateTime date;
  const _NextVisit({required this.dossier, required this.date});
}

class _NextVisitBanner extends StatelessWidget {
  final _NextVisit? nextVisit;
  final VoidCallback? onTap;

  const _NextVisitBanner({required this.nextVisit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Placeholder quand aucune visite n'est planifiée.
    if (nextVisit == null) {
      return _PanelCard(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: Color(0xFFF6EDFB),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(
                  LucideIcons.car,
                  color: Color(0xFF907CA1),
                  size: 26,
                ),
              ),
            ),
            const SizedBox(width: 16),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Titre compact en violet, tout en majuscules — même
                  // hiérarchie que la version "avec visite" ci-dessous.
                  Text(
                    'PROCHAINE VISITE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: Color(0xFF907CA1),
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Aucune visite planifiée pour le moment.',
                    style: TextStyle(
                      fontSize: 15,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final nv = nextVisit!;
    final patient = nv.dossier.patient;
    final fullAddress = DashboardScreen.buildFullAddress(patient);
    final rawDay = DateFormat('EEEE d MMMM', 'fr_FR').format(nv.date);
    final dayLabel = rawDay.isNotEmpty
        ? rawDay.replaceFirst(rawDay[0], rawDay[0].toUpperCase())
        : rawDay;
    final daysUntil = nv.date
        .difference(DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
        ))
        .inDays;
    final distanceLabel = daysUntil == 0
        ? "aujourd'hui"
        : daysUntil == 1
            ? 'demain'
            : 'dans $daysUntil jours';

    return _PanelCard(
      onTap: onTap,
      padding: const EdgeInsets.all(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              color: Color(0xFFF6EDFB),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Icon(
                LucideIcons.car,
                color: Color(0xFF907CA1),
                size: 28,
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Surtitre compact en violet, tout en majuscules — laisse
                // la vedette au nom + prénom du bénéficiaire juste en
                // dessous.
                const Text(
                  'PROCHAINE VISITE',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: Color(0xFF907CA1),
                  ),
                ),
                const SizedBox(height: 6),
                // Nom + prénom du bénéficiaire en noir — vedette de la
                // bannière prochaine visite.
                Text(
                  '${patient.lastName} ${patient.firstName}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                if (fullAddress.isNotEmpty)
                  Row(
                    children: [
                      const Icon(
                        LucideIcons.mapPin,
                        size: 14,
                        color: Color(0xFF64748B),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          fullAddress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFF475569),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          // Bloc date à droite
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                dayLabel,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                distanceLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF907CA1),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Activity chart (custom, matches React `ActivityChart`)
// ---------------------------------------------------------------------------

class _ActivityBar {
  final String name;
  final int value;
  const _ActivityBar({required this.name, required this.value});
}

class _ActivityChart extends StatelessWidget {
  final List<_ActivityBar> data;

  const _ActivityChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final maxValue = data
        .map((e) => e.value)
        .fold<int>(1, (a, b) => a > b ? a : b);

    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF1F5F9)), // slate-100
        ),
      ),
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < data.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: _ActivityBarColumn(
                bar: data[i],
                ratio: data[i].value / maxValue,
                isHighlighted: i == data.length - 1,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActivityBarColumn extends StatelessWidget {
  final _ActivityBar bar;
  final double ratio;
  final bool isHighlighted;

  const _ActivityBarColumn({
    required this.bar,
    required this.ratio,
    required this.isHighlighted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          bar.value.toString(),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF94A3B8), // slate-400
          ),
        ),
        const SizedBox(height: 12),
        // Bar container — matches the slate-50 rounded panel from React.
        SizedBox(
          height: 160,
          width: double.infinity,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC), // slate-50
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            alignment: Alignment.bottomCenter,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final availableHeight = constraints.maxHeight;
                final height = (availableHeight * ratio).clamp(
                  availableHeight * 0.08,
                  availableHeight,
                );
                return Align(
                  alignment: Alignment.bottomCenter,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 32),
                    height: height,
                    decoration: BoxDecoration(
                      color: isHighlighted
                          ? const Color(0xFF907CA1)
                          : const Color(0xFFE2E8F0), // slate-200
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          bar.name,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: Color(0xFF94A3B8),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Panel card — shared container for KPI, recent dossiers, and chart panels
// ---------------------------------------------------------------------------

class _PanelCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  const _PanelCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(24),
  });

  @override
  Widget build(BuildContext context) {
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE2E8F0)), // slate-200
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );

    if (onTap == null) return card;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: card,
    );
  }
}
