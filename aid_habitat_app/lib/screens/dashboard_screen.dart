import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/beneficiary_palettes.dart';
import '../components/soft_transitions.dart';
import '../models/types.dart';
import '../services/references_service.dart';
import '../services/route_service.dart';

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

  /// Adresse courte (CP + ville UPPER) pour les listes du dashboard où
  /// la rue + numéro pollue la ligne sans apporter de valeur — l'ergo
  /// veut juste savoir où se trouve géographiquement le bénéficiaire.
  /// Demande utilisateur 2026-04-28 : « la petite ligne doit simplement
  /// mettre le code postal et la ville mais pas le numéro et la rue ».
  static String buildShortAddress(Patient p) {
    final zip = p.zipCode.trim();
    final city = p.city.trim();
    return [zip, city.toUpperCase()]
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
    final now = DateTime.now();
    final rawDate = DateFormat('EEEE d MMMM', 'fr_FR').format(now);
    final dateLabel = rawDate.isEmpty
        ? rawDate
        : rawDate.replaceFirst(rawDate[0], rawDate[0].toUpperCase());

    // Next upcoming visit = nearest future `visitDate` across all dossiers.
    final nextVisit = _findNextVisit(dossiers, now);
    // (_buildActivitySeries / _RecentDossiersPanel / _ActivityChart sont
    // conservés dans le fichier mais plus utilisés depuis la refonte
    // 2026-05-04 — voir `_TodayVisitsPanel` ci-dessous qui remplace
    // les deux panneaux côte à côte par un bloc plein largeur.)

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
          // Avec temps de route depuis Aid'Habitat (16 rue Léo Lagrange,
          // Chartres-de-Bretagne) — calculé async via OSRM.
          _NextVisitBanner(
            nextVisit: nextVisit,
            onTap: nextVisit == null
                ? null
                : () => onSelectDossier(nextVisit.dossier),
          ),
          const SizedBox(height: 24),

          // ---------- Mes visites du jour (full width) ----------
          // Demande utilisateur 2026-05-04 : remplace « Mes rapports en
          // cours » + « Activité » par une seule section pleine largeur
          // listant les visites prévues aujourd'hui, avec temps de
          // trajet entre chaque adresse (1ère = depuis Aid'Habitat).
          _TodayVisitsPanel(
            dossiers: dossiers,
            now: now,
            onSelect: onSelectDossier,
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
                      color: Color(0xFF7C6DAA),
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
  final ReferencesService _refs = ReferencesService();
  StreamSubscription<ReferencesPayload>? _refsSub;

  @override
  void initState() {
    super.initState();
    _refs.ensureLoaded();
    _refsSub = _refs.onLoaded.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refsSub?.cancel();
    super.dispose();
  }

  /// Resolves the EPCI label for the current dossier via the commune
  /// reference (id → label → zip fallbacks). Empty string if no match.
  String _epciLabel() {
    if (!_refs.isLoaded) return '';
    final p = widget.dossier.patient;
    final cityId = p.cityId.trim();
    final city = p.city.trim().toLowerCase();
    final zip = p.zipCode.trim();
    for (final ref in _refs.communes) {
      if (cityId.isNotEmpty && ref.id == cityId) return ref.epciLabel;
    }
    for (final ref in _refs.communes) {
      if (ref.label.toLowerCase() == city) return ref.epciLabel;
    }
    if (zip.isNotEmpty) {
      for (final ref in _refs.communes) {
        if (ref.zipCode == zip) return ref.epciLabel;
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final patient = widget.dossier.patient;
    final initials = _initials(patient.firstName, patient.lastName);
    // Ligne secondaire des tuiles « Mes rapports en cours » : uniquement
    // CP + ville, pas la rue (cf. `buildShortAddress`).
    final shortAddress = DashboardScreen.buildShortAddress(patient);
    final visitLabel = _formatVisitDate(widget.dossier.visitDate);
    final epci = _epciLabel();

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SoftTapScale(
        onTap: widget.onTap,
        child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _hover
                ? const Color(0xFFF1F5F9) // slate-100
                : const Color(0xFFF7F7FA), // slate-50
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  // Pastel stable par bénéficiaire — même palette et
                  // même couleur que sur l'écran "Mes dossiers" (hash
                  // des initiales, cf. `beneficiaryAvatarBgFor`).
                  color: beneficiaryAvatarBgFor(initials),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    initials,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: kBeneficiaryAvatarFg,
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
                            ? const Color(0xFF7C6DAA)
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
                            shortAddress.isEmpty ? '—' : shortAddress,
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
              // Badge EPCI + pill date de visite côte à côte.
              if (epci.isNotEmpty) ...[
                EpciBadge(label: epci, maxWidth: 180),
                const SizedBox(width: 8),
              ],
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: visitLabel.isEmpty
                      ? const Color(0xFFF1F5F9)
                      : const Color(0xFFEDE8F5), // violet clair du thème
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
                          : const Color(0xFF7C6DAA),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      visitLabel.isEmpty ? 'À planifier' : visitLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: visitLabel.isEmpty
                            ? const Color(0xFF64748B)
                            : const Color(0xFF7C6DAA),
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
                    ? const Color(0xFF7C6DAA)
                    : const Color(0xFFCBD5E1), // slate-300
              ),
            ],
          ),
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

class _NextVisitBanner extends StatefulWidget {
  final _NextVisit? nextVisit;
  final VoidCallback? onTap;

  const _NextVisitBanner({required this.nextVisit, required this.onTap});

  @override
  State<_NextVisitBanner> createState() => _NextVisitBannerState();
}

class _NextVisitBannerState extends State<_NextVisitBanner> {
  Duration? _driveTime;
  String? _routedAddressKey;

  @override
  void initState() {
    super.initState();
    _maybeFetchRoute();
  }

  @override
  void didUpdateWidget(covariant _NextVisitBanner old) {
    super.didUpdateWidget(old);
    _maybeFetchRoute();
  }

  void _maybeFetchRoute() {
    final nv = widget.nextVisit;
    if (nv == null) return;
    final addr = DashboardScreen.buildFullAddress(nv.dossier.patient);
    if (addr.isEmpty) return;
    if (_routedAddressKey == addr) return;
    _routedAddressKey = addr;
    // ignore: discarded_futures
    RouteService.instance
        .drivingDurationByAddress(
          from: kAidHabitatOrigin,
          toAddress: addr,
        )
        .then((d) {
      if (!mounted) return;
      setState(() => _driveTime = d);
    });
  }

  /// Extrait l'heure (HH:mm) si la `visit_date` ISO contient une partie
  /// horaire non-triviale. Renvoie null sinon — le pill heure est
  /// alors caché dans le banner.
  static String? _visitTimeLabel(_NextVisit nv) {
    final raw = nv.dossier.visitDate;
    if (raw == null || raw.isEmpty) return null;
    try {
      final dt = DateTime.parse(raw);
      if (dt.hour == 0 && dt.minute == 0 && !raw.contains('T')) return null;
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nextVisit = widget.nextVisit;
    final onTap = widget.onTap;
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
                color: Color(0xFFEDE8F5),
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Icon(
                  // Icône Material `directions_car` — style « filled »
                  // visuellement plus dense que le Lucide outline qu'on
                  // utilisait avant. Demande utilisateur 2026-04-28
                  // (« change l'icon voiture pour un autre icon
                  // voiture »).
                  Icons.directions_car,
                  color: Color(0xFF7C6DAA),
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
                      color: Color(0xFF7C6DAA),
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

    final nv = nextVisit;
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
              color: Color(0xFFEDE8F5),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Icon(
                // Variante « visite planifiée » du même Material
                // `directions_car` (cf. ci-dessus), un cran plus
                // grand pour la card hero du dashboard.
                Icons.directions_car,
                color: Color(0xFF7C6DAA),
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
                    color: Color(0xFF7C6DAA),
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
                // Temps de route depuis Aid'Habitat (16 rue Léo Lagrange,
                // Chartres-de-Bretagne) — demande utilisateur 2026-05-04.
                if (_driveTime != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(
                        LucideIcons.car,
                        size: 14,
                        color: Color(0xFF7C6DAA),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${RouteService.formatDuration(_driveTime!)} '
                        "depuis Aid'Habitat",
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF7C6DAA),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          // Bloc date à droite — l'horaire est désormais intégré dans
          // le libellé de la date (« Lundi 4 mai à 14:30 ») au lieu
          // d'un pill violette séparé en dessous (demande utilisateur
          // 2026-05-04 : « l'horaire doit être intégré dans la date de
          // visite pas deux bundles différents »). Si la visit_date
          // n'a pas d'heure non-triviale, on affiche juste la date.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Builder(
                builder: (_) {
                  final time = _visitTimeLabel(nv);
                  final label =
                      time != null ? '$dayLabel à $time' : dayLabel;
                  return Text(
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  );
                },
              ),
              const SizedBox(height: 4),
              Text(
                distanceLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF7C6DAA),
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
              color: const Color(0xFFF7F7FA), // slate-50
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
                          ? const Color(0xFF7C6DAA)
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
        borderRadius: BorderRadius.circular(16),
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
    // Ajoute un léger scale-down au tap pour l'effet "soft" partagé avec
    // le reste de l'app (cf. `components/soft_transitions.dart`).
    return SoftTapScale(
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: card,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mes visites du jour (full width)
// ---------------------------------------------------------------------------

/// Panneau pleine largeur listant les visites prévues AUJOURD'HUI, avec
/// le temps de trajet entre chaque adresse (1ère = depuis Aid'Habitat,
/// 16 rue Léo Lagrange, Chartres-de-Bretagne).
///
/// Demande utilisateur 2026-05-04 : remplace « Mes rapports en cours »
/// + « Activité » (deux panneaux côte à côte) par un seul bloc plein
/// largeur centré sur la journée en cours. Tri alphabétique par défaut
/// (le modèle `Dossier.visitDate` n'a pas d'heure — pas d'ordre
/// chronologique pertinent à l'intérieur d'une journée).
class _TodayVisitsPanel extends StatefulWidget {
  final List<Dossier> dossiers;
  final DateTime now;
  final void Function(Dossier) onSelect;

  const _TodayVisitsPanel({
    required this.dossiers,
    required this.now,
    required this.onSelect,
  });

  @override
  State<_TodayVisitsPanel> createState() => _TodayVisitsPanelState();
}

class _TodayVisitsPanelState extends State<_TodayVisitsPanel> {
  /// Temps de trajet calculés pour chaque visite affichée. Clé = id du
  /// dossier ; valeur = durée jusqu'à cette visite depuis la PRÉCÉDENTE
  /// (ou Aid'Habitat pour la 1ère). Rempli au fur et à mesure des
  /// requêtes OSRM.
  final Map<String, Duration?> _segmentDurations = <String, Duration?>{};

  /// Empreinte des visites actuellement résolues — évite de relancer
  /// les requêtes au moindre rebuild si la liste n'a pas changé.
  String _routedKey = '';

  /// Tri chronologique sur l'heure (visit_date stocké en ISO complet :
  /// `2026-05-04T14:30:00`). Si plusieurs visites partagent la même
  /// heure (ou n'ont pas d'heure renseignée), on retombe sur le
  /// nom de famille pour stabilité.
  ///
  /// Cap à 3 visites (demande utilisateur 2026-05-04 : « affiche que
  /// les 3 visites du jour car dans tout les cas il y'aura 3 visites
  /// max par jour »).
  List<Dossier> get _todayVisits {
    final today = DateTime(widget.now.year, widget.now.month, widget.now.day);
    final out = <Dossier>[];
    for (final d in widget.dossiers) {
      final raw = d.visitDate;
      if (raw == null || raw.isEmpty) continue;
      DateTime? when;
      try {
        when = DateTime.parse(raw);
      } catch (_) {
        continue;
      }
      final day = DateTime(when.year, when.month, when.day);
      if (day == today) out.add(d);
    }
    out.sort((a, b) {
      final da = DateTime.tryParse(a.visitDate ?? '');
      final db = DateTime.tryParse(b.visitDate ?? '');
      if (da != null && db != null) {
        final cmp = da.compareTo(db);
        if (cmp != 0) return cmp;
      }
      return a.patient.lastName
          .toLowerCase()
          .compareTo(b.patient.lastName.toLowerCase());
    });
    // Cap à 3 visites max par jour.
    return out.length > 3 ? out.sublist(0, 3) : out;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeFetchSegments();
  }

  @override
  void didUpdateWidget(covariant _TodayVisitsPanel old) {
    super.didUpdateWidget(old);
    _maybeFetchSegments();
  }

  /// Lance les requêtes de géocodage + routing pour chaque segment du
  /// jour. Re-déclenché uniquement quand la liste des visites change
  /// (clé d'empreinte = liste d'IDs).
  void _maybeFetchSegments() {
    final visits = _todayVisits;
    final key = visits.map((d) => d.id).join('|');
    if (key == _routedKey) return;
    _routedKey = key;
    GeoPoint previous = kAidHabitatOrigin;
    for (final dossier in visits) {
      final addr = DashboardScreen.buildFullAddress(dossier.patient);
      if (addr.isEmpty) {
        _segmentDurations[dossier.id] = null;
        continue;
      }
      // Capture `previous` dans le scope async — on attend chaque
      // géocodage avant de passer au suivant pour calculer chaque
      // segment depuis le point précédent.
      _resolveSegment(
        dossierId: dossier.id,
        from: previous,
        toAddress: addr,
      );
      // Pour estimer le `previous` du segment suivant, on peut
      // pré-géocoder l'adresse courante en parallèle. Le résultat sera
      // mis en cache par `RouteService.geocode` donc le `_resolveSegment`
      // suivant le retrouvera sans coût.
      // ignore: discarded_futures
      RouteService.instance.geocode(addr).then((g) {
        if (g != null) {
          previous = g;
        }
      });
    }
  }

  Future<void> _resolveSegment({
    required String dossierId,
    required GeoPoint from,
    required String toAddress,
  }) async {
    final to = await RouteService.instance.geocode(toAddress);
    if (!mounted || to == null) {
      if (mounted) setState(() => _segmentDurations[dossierId] = null);
      return;
    }
    final d = await RouteService.instance.drivingDuration(from, to);
    if (!mounted) return;
    setState(() => _segmentDurations[dossierId] = d);
  }

  /// Extrait l'heure (HH:mm) d'une visit_date ISO 8601 si renseignée.
  /// Renvoie null si la chaîne ne contient qu'une date sans heure (cas
  /// legacy avant la généralisation de l'heure de visite).
  static String? _extractVisitTime(Dossier d) {
    final raw = d.visitDate;
    if (raw == null || raw.isEmpty) return null;
    try {
      final dt = DateTime.parse(raw);
      // Si l'heure est 00:00:00 ET la chaîne d'origine ne contient pas
      // de séparateur 'T', c'est une date pure → on ne montre rien.
      if (dt.hour == 0 && dt.minute == 0 && !raw.contains('T')) {
        return null;
      }
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$hh:$mm';
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final visits = _todayVisits;
    return _PanelCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mes visites du jour',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 16),
          if (visits.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text(
                  "Aucune visite prévue aujourd'hui.",
                  style: TextStyle(color: Color(0xFF94A3B8)),
                ),
              ),
            )
          else
            for (var i = 0; i < visits.length; i++) ...[
              _RouteSegmentRow(
                duration: _segmentDurations[visits[i].id],
                fromLabel: i == 0
                    ? "Aid'Habitat"
                    : '${visits[i - 1].patient.firstName} '
                        '${visits[i - 1].patient.lastName.toUpperCase()}',
                visitTime: _extractVisitTime(visits[i]),
              ),
              _RecentDossierRow(
                dossier: visits[i],
                onTap: () => widget.onSelect(visits[i]),
              ),
              if (i < visits.length - 1) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

/// Petite ligne discrète entre deux cartes de visite : icône voiture +
/// libellé « 12 min depuis X ». Affichée AVANT chaque visite (pour
/// indiquer le trajet à effectuer pour s'y rendre).
class _RouteSegmentRow extends StatelessWidget {
  final Duration? duration;
  final String fromLabel;

  /// Heure de la visite à laquelle ce segment mène (format `HH:mm`).
  /// Affichée à droite en pill violette compacte. `null` = pas
  /// d'heure renseignée (cas legacy, avant généralisation côté
  /// NocoDB).
  final String? visitTime;

  const _RouteSegmentRow({
    required this.duration,
    required this.fromLabel,
    this.visitTime,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFFEDE8F5),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: const Icon(
              LucideIcons.car,
              size: 14,
              color: Color(0xFF7C6DAA),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF64748B),
                ),
                children: [
                  TextSpan(
                    text: duration == null
                        ? '— min'
                        : RouteService.formatDuration(duration!),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF7C6DAA),
                    ),
                  ),
                  const TextSpan(text: ' depuis '),
                  TextSpan(
                    text: fromLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          if (visitTime != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF7C6DAA),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    LucideIcons.clock3,
                    size: 11,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    visitTime!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
