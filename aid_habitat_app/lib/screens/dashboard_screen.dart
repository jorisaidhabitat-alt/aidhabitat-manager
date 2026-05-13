import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/beneficiary_badges.dart'
    show
        formatAccompanimentType,
        accompanimentPaletteFor,
        IncomeCategoryBadge;
import '../components/beneficiary_palettes.dart';
import '../components/soft_transitions.dart';
import '../models/types.dart';
import '../services/references_service.dart';
import '../services/route_service.dart';
import '../services/sync_engine.dart';

/// Dashboard screen aligned with the React web `Dashboard.tsx` layout:
///   - Welcome header with user name + today's date
///   - 3 KPI cards (Dossiers en cours / Visites semaine / Dossiers validés)
///   - Main grid: Recent dossiers list + custom activity bar chart
///
/// Data still comes from Flutter (SQLite + SyncEngine). The top sync banner
/// and [onSyncNow] wiring are kept intact.
///
/// Stateful : un ticker interne rebuild le screen toutes les 60s pour
/// que la « Prochaine visite » se rafraîchisse automatiquement quand
/// une heure passe. Sans ça, le `now` capturé au premier build restait
/// figé et la visite de 9h continuait à s'afficher comme prochaine
/// même à 14h. Demande utilisateur 2026-05-06.
class DashboardScreen extends StatefulWidget {
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

  /// Callback déclenché par le bouton « Démarrer le relevé » dans la
  /// bannière prochaine visite — ouvre directement la VAD du
  /// bénéficiaire (visit_report_screen) sans passer par l'écran
  /// dossier. Demande utilisateur 2026-05-12.
  final void Function(Dossier)? onStartReport;

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
    this.onStartReport,
  });

  /// Builds the full postal address `<street> <zip> <CITY>`.
  /// Empty segments are skipped + whitespace collapsed. Static pour
  /// pouvoir être appelé via `DashboardScreen.buildFullAddress(p)`
  /// depuis les widgets enfants (banner, panel) sans contexte d'État.
  static String buildFullAddress(Patient p) {
    final street = p.address.trim();
    final zip = p.zipCode.trim();
    final city = p.city.trim();
    return [street, zip, city.toUpperCase()]
        .where((s) => s.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Adresse format bannière prochaine visite : "<numéro et rue>,
  /// <Ville>" — pas de code postal, ville en Title Case (1ère lettre
  /// majuscule, reste minuscule). Demande utilisateur 2026-05-12.
  static String buildAddressForBanner(Patient p) {
    final street = p.address.trim();
    final cityTitle = _toTitleCase(p.city.trim());
    final parts = [street, cityTitle].where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return '';
    return parts.join(', ').replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Convertit "PLEUMELEUC" / "pleumeleuc" → "Pleumeleuc". Gère les
  /// noms composés ("SAINT-MALO" → "Saint-Malo") et les espaces
  /// ("CHARTRES DE BRETAGNE" → "Chartres De Bretagne"). Si la chaîne
  /// est déjà mixte (un caractère minuscule présent), on la laisse
  /// telle quelle pour respecter une éventuelle saisie soignée.
  static String _toTitleCase(String input) {
    if (input.isEmpty) return input;
    // Si déjà mixte (≠ all upper / all lower) → respecte la saisie.
    if (input != input.toUpperCase() && input != input.toLowerCase()) {
      return input;
    }
    return input
        .toLowerCase()
        .splitMapJoin(
          RegExp(r"[ \-']"),
          onMatch: (m) => m[0]!,
          onNonMatch: (token) => token.isEmpty
              ? token
              : '${token[0].toUpperCase()}${token.substring(1)}',
        );
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

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  /// Ticker qui rafraîchit le `now` du dashboard toutes les 60s. Sans
  /// ça, l'heure courante utilisée par `_findNextVisit` se figeait au
  /// premier build et une visite à 9h restait affichée comme prochaine
  /// jusqu'à un rebuild forcé (changement d'onglet, scroll…). 60s est
  /// suffisamment fin pour que la transition à l'heure pile soit
  /// invisible et assez large pour ne pas empiler des frames.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Refactor 2026-05-12 : suppression de `enterActiveContext` (le mode
    // pull ultra-actif n'existe plus côté SyncEngine). Le Dashboard
    // affiche l'état au moment de l'ouverture ; pour voir les modifs
    // faites sur l'autre device, l'utilisateur passe en background puis
    // revient (foreground return déclenche un pull) ou se reconnecte.
    //
    // Le timer 60 s reste pour rafraîchir l'affichage relatif des dates
    // (« il y a 3 min » → « il y a 4 min ») — purement local, aucun
    // appel réseau.
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // Pass-through getters for backward compat avec le reste du fichier
  // qui référence directement les props (avant la conversion en
  // StatefulWidget). Évite de toucher à 50+ usages.
  List<Visit> get visits => widget.visits;
  List<Dossier> get dossiers => widget.dossiers;
  int get pendingSyncCount => widget.pendingSyncCount;
  bool get isSyncing => widget.isSyncing;
  VoidCallback get onSyncNow => widget.onSyncNow;
  void Function(Dossier) get onSelectDossier => widget.onSelectDossier;
  void Function(Dossier)? get onStartReport => widget.onStartReport;
  String? get userName => widget.userName;
  VoidCallback? get onNavigateToDossiers => widget.onNavigateToDossiers;

  // Short French month labels for the activity chart (Jan..Déc).
  static const List<String> _monthsFr = [
    'Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin',
    'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc',
  ];

  /// Renvoie la prochaine visite à venir — la plus proche dans le
  /// futur en termes de DATETIME (pas seulement de jour). Demande
  /// utilisateur 2026-05-05 : « la plus proche est la prochaine, puis
  /// une fois que l'horaire est passé ça passe à l'autre
  /// automatiquement ». Donc une visite prévue aujourd'hui à 9:00 ne
  /// reste pas affichée à 14:00 — elle laisse la place à la suivante.
  ///
  /// Cas spécial : si la `visit_date` n'a pas d'heure (date pure
  /// sans 'T' et 00:00:00), on considère que la visite court
  /// JUSQU'À la fin de la journée (23:59) — sans heure renseignée,
  /// on ne peut pas décider qu'elle est passée tant que le jour J
  /// n'est pas terminé.
  _NextVisit? _findNextVisit(List<Dossier> dossiers, DateTime now) {
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
      // Deadline = heure réelle si renseignée, sinon fin de la
      // journée comme proxy pour « visite encore valable aujourd'hui ».
      final hasTime =
          raw.contains('T') && !(when.hour == 0 && when.minute == 0);
      final deadline = hasTime
          ? when
          : DateTime(when.year, when.month, when.day, 23, 59, 59);
      if (deadline.isBefore(now)) continue;
      if (best == null || when.isBefore(best.dateTime)) {
        best = _NextVisit(dossier: d, dateTime: when);
      }
    }
    return best;
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
    // Date en uppercase pour le mini-label au-dessus du Bonjour.
    // Format : "MARDI 21 AVRIL" (maquette 2026-05-12).
    final dateLabelUpper =
        DateFormat('EEEE d MMMM', 'fr_FR').format(now).toUpperCase();

    // Next upcoming visit = nearest future `visitDate` across all dossiers.
    final nextVisit = _findNextVisit(dossiers, now);

    // Stats compactes affichées sous le « Bonjour ».
    // - Visites cette semaine = dossiers avec `visitDate` dans la
    //   plage lundi-dimanche en cours.
    // - Dossiers en cours = dossiers dont le statut N'EST PAS « Visité »
    //   (mapping basé sur les statuts existants côté NocoDB, sans
    //   changer le modèle — cf. demande utilisateur 2026-05-12).
    final weekStart = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: (now.weekday - 1)));
    final weekEnd = weekStart.add(const Duration(days: 7));
    int visitsThisWeek = 0;
    int activeDossiers = 0;
    for (final d in dossiers) {
      // Un dossier est « en cours » tant qu'il n'a pas été clôturé /
      // archivé. Les états VISITED / CLOSED / ARCHIVED sortent du
      // compteur ; le reste (TO_VISIT, IN_PROGRESS, WAITING_*, etc.)
      // y est inclus.
      const closedStates = {
        DossierStatus.VISITED,
        DossierStatus.CLOSED,
        DossierStatus.ARCHIVED,
      };
      if (!closedStates.contains(d.status)) {
        activeDossiers += 1;
      }
      final raw = d.visitDate;
      if (raw == null || raw.isEmpty) continue;
      DateTime? when;
      try {
        when = DateTime.parse(raw);
      } catch (_) {
        continue;
      }
      if (!when.isBefore(weekStart) && when.isBefore(weekEnd)) {
        visitsThisWeek += 1;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---------- Welcome header (maquette 2026-05-12) ----------
          // Date en label compact au-dessus, puis « Bonjour, X. », puis
          // stats compactes en sous-titre. Plus de date en gros à droite.
          Text(
            dateLabelUpper,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
              color: Color(0xFF94A3B8), // slate-400
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Bonjour, ${userName ?? 'Ergo'}.",
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
              height: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "$visitsThisWeek visite${visitsThisWeek > 1 ? 's' : ''} cette semaine"
            "  ·  "
            "$activeDossiers dossier${activeDossiers > 1 ? 's' : ''} en cours",
            style: const TextStyle(
              fontSize: 14,
              color: Color(0xFF64748B),
            ),
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
            onStartReport: nextVisit == null
                ? null
                : () => (onStartReport ?? onSelectDossier)(nextVisit.dossier),
          ),
          const SizedBox(height: 24),

          // ---------- 2 panneaux côte à côte ----------
          // À gauche : rapports en cours (dossiers en statut ≠ Visité)
          // À droite : agenda de la semaine (visites planifiées)
          // Demande utilisateur 2026-05-12 : « refais le dashboard en
          // t'inspirant fortement de cette maquette ».
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 800;
              final pending = _PendingReportsPanel(
                dossiers: dossiers,
                onSelect: onSelectDossier,
                onSeeAll: onNavigateToDossiers,
              );
              final agenda = _WeekAgendaPanel(
                dossiers: dossiers,
                now: now,
                weekEnd: weekEnd,
                onSelect: onSelectDossier,
                onSeeAll: onNavigateToDossiers,
              );
              if (isWide) {
                // IntrinsicHeight + stretch garantit que les 2 cards
                // partagent la même hauteur (= max de leurs hauteurs
                // intrinsèques). Demande utilisateur 2026-05-12 : « les
                // deux cadres blancs du bas doivent être à la même
                // hauteur ».
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: pending),
                      const SizedBox(width: 24),
                      Expanded(child: agenda),
                    ],
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  pending,
                  const SizedBox(height: 24),
                  agenda,
                ],
              );
            },
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

  /// Si fourni, affiche une sur-ligne compacte (icône voiture +
  /// durée) en haut de la card pour indiquer le temps de trajet
  /// jusqu'à cette visite. Demande utilisateur 2026-05-05 : pour
  /// « Mes visites du jour » on intègre le temps de route DANS la
  /// bannière de la visite (sans mentionner la visite précédente).
  final _SegmentState? travelState;

  /// Si fourni, le pill « date de visite » par défaut est remplacé
  /// par un pill HEURE mis en évidence (fond violet plein, texte
  /// blanc, icône horloge). Demande utilisateur 2026-05-05 : pour
  /// les visites du jour, pas besoin du jour J — uniquement l'heure
  /// en valeur.
  final String? visitTimeHighlight;

  const _RecentDossierRow({
    required this.dossier,
    required this.onTap,
    this.travelState,
    this.visitTimeHighlight,
  });

  @override
  State<_RecentDossierRow> createState() => _RecentDossierRowState();
}

class _RecentDossierRowState extends State<_RecentDossierRow> {
  bool _hover = false;
  // ReferencesService est un singleton — on le lit à chaque build
  // sans s'y abonner ici. L'abonnement vit au NIVEAU DU PARENT
  // (_TodayVisitsPanel) pour ne pas multiplier les listeners par le
  // nombre de visites affichées (audit 2026-05-04 : avant, chaque row
  // s'abonnait → 5+ listeners pour 5 visites + propagation 5 rebuilds
  // au lieu d'1). Le parent appelle setState au moment de l'émission,
  // ce qui rebuild les enfants automatiquement.
  final ReferencesService _refs = ReferencesService();

  @override
  void initState() {
    super.initState();
    // Charge si pas déjà fait (idempotent dans ReferencesService).
    _refs.ensureLoaded();
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

    final travelState = widget.travelState;
    final visitTimeHighlight = widget.visitTimeHighlight;
    final showTravelOverline = travelState != null;
    final showHourPill =
        visitTimeHighlight != null && visitTimeHighlight.isNotEmpty;

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showTravelOverline) ...[
                _TravelOverline(state: travelState),
                const SizedBox(height: 10),
              ],
              Row(
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
              if (showHourPill)
                // Mode « visite du jour » — l'heure prend la place du
                // pill date (le jour est implicite, c'est aujourd'hui).
                // Style pill violet plein, blanc, icône horloge — même
                // hiérarchie visuelle que l'ancien _RouteSegmentRow.
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C6DAA),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        LucideIcons.clock3,
                        size: 12,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        visitTimeHighlight,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: visitLabel.isEmpty
                        ? const Color(0xFFF1F5F9)
                        : const Color(0xFFEDE8F5),
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
  /// Datetime complète (jour + heure) de la visite. Si la
  /// `visit_date` source n'a pas d'heure, l'heure est 00:00:00 — la
  /// bannière affichera alors juste le jour sans l'horaire.
  final DateTime dateTime;
  const _NextVisit({required this.dossier, required this.dateTime});
}

class _NextVisitBanner extends StatefulWidget {
  final _NextVisit? nextVisit;
  /// Tap général sur la bannière (zones gauche + zone info bénéficiaire)
  /// → navigation vers le dossier détail.
  final VoidCallback? onTap;
  /// Tap spécifique sur le bouton « Démarrer le relevé » → navigation
  /// directe vers la VAD (visit_report_screen). Demande utilisateur
  /// 2026-05-12.
  final VoidCallback? onStartReport;

  const _NextVisitBanner({
    required this.nextVisit,
    required this.onTap,
    this.onStartReport,
  });

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
    // Placeholder quand aucune visite n'est planifiée — on garde le
    // même format 2 colonnes que la version "avec visite" pour ne pas
    // casser la disposition globale du dashboard (demande utilisateur
    // 2026-05-12).
    if (nextVisit == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: const Color(0xFFD8CDE9),
                padding: const EdgeInsets.symmetric(
                    horizontal: 24, vertical: 24),
                constraints: const BoxConstraints(minWidth: 180),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.directions_car,
                        color: Color(0xFF7C6DAA), size: 28),
                    SizedBox(height: 8),
                    Text(
                      'AGENDA',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: Color(0xFF7C6DAA),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  color: const Color(0xFFEDE8F5),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 24),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'PROCHAINE VISITE',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Aucun rendez-vous planifié',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Tout est à jour côté agenda.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF475569),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final nv = nextVisit;
    final patient = nv.dossier.patient;
    final fullAddress = DashboardScreen.buildAddressForBanner(patient);
    final rawDay = DateFormat('EEEE d MMMM', 'fr_FR').format(nv.dateTime);
    final dayLabel = rawDay.isNotEmpty
        ? rawDay.replaceFirst(rawDay[0], rawDay[0].toUpperCase())
        : rawDay;
    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final visitDay = DateTime(
      nv.dateTime.year,
      nv.dateTime.month,
      nv.dateTime.day,
    );
    final daysUntil = visitDay.difference(today).inDays;
    final distanceLabel = daysUntil == 0
        ? "aujourd'hui"
        : daysUntil == 1
            ? 'demain'
            : 'dans $daysUntil jours';

    // Nouveau design 2026-05-12 (maquette) : card violet pastel avec
    // 3 zones — bloc heure/trajet (gauche, fond blanc), info bénéficiaire
    // (centre), bouton « Démarrer le relevé → » (droite).
    final time = _visitTimeLabel(nv);
    final age = _ageFromBirthDate(patient.birthDate);
    final phone = patient.phone.trim();
    final hourLabel = time ?? (daysUntil == 0 ? '—' : 'à venir');
    final dayBadgeLabel = daysUntil == 0
        ? "AUJOURD'HUI"
        : daysUntil == 1
            ? 'DEMAIN'
            : dayLabel.toUpperCase();

    // Bannière en 2 colonnes de fond violet distinctes (demande
    // utilisateur 2026-05-12) : gauche = violet plus saturé pour le
    // bloc horaire/trajet, droite = violet pastel pour les infos
    // bénéficiaire + bouton.
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Bloc gauche : jour + heure + trajet (violet saturé) ---
            Material(
              color: const Color(0xFFD8CDE9),
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                    Text(
                      dayBadgeLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: Color(0xFF7C6DAA),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      hourLabel,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _driveTime != null
                          ? '${RouteService.formatDuration(_driveTime!)} de trajet'
                          : '— de trajet',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    ],
                  ),
                ),
              ),
            ),
            // --- Bloc droit : infos bénéficiaire + bouton (violet clair) ---
            Expanded(
              child: Material(
                color: const Color(0xFFEDE8F5),
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'PROCHAINE VISITE',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.4,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                age != null
                                    ? '${patient.firstName} ${patient.lastName}, $age ans'
                                    : '${patient.firstName} ${patient.lastName}',
                                style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                  height: 1.15,
                                ),
                              ),
                              if (fullAddress.isNotEmpty || phone.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 18,
                                  runSpacing: 6,
                                  children: [
                                    if (fullAddress.isNotEmpty)
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(LucideIcons.mapPin,
                                              size: 14,
                                              color: Color(0xFF64748B)),
                                          const SizedBox(width: 6),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                                maxWidth: 360),
                                            child: Text(
                                              fullAddress,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                color: Color(0xFF475569),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    if (phone.isNotEmpty)
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(LucideIcons.phone,
                                              size: 14,
                                              color: Color(0xFF64748B)),
                                          const SizedBox(width: 6),
                                          Text(
                                            phone,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              color: Color(0xFF475569),
                                            ),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        // --- Bouton « Démarrer le relevé » ---
                        // Navigation directe VAD (visit_report_screen),
                        // pas l'écran dossier (qui est sur le tap général
                        // de la card). Demande utilisateur 2026-05-12.
                        ElevatedButton.icon(
                          onPressed: widget.onStartReport ?? onTap,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7C6DAA),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 0,
                          ),
                          icon: const Text(
                            'Démarrer le relevé',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          label: const Icon(LucideIcons.arrowRight, size: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Calcule l'âge en années depuis une date ISO (ex `1942-06-12`).
  /// null si vide / invalide.
  int? _ageFromBirthDate(String birthDate) {
    final s = birthDate.trim();
    if (s.isEmpty) return null;
    final d = DateTime.tryParse(s);
    if (d == null) return null;
    final now = DateTime.now();
    var age = now.year - d.year;
    if (now.month < d.month ||
        (now.month == d.month && now.day < d.day)) {
      age -= 1;
    }
    return age >= 0 && age < 150 ? age : null;
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
  /// dossier ; valeur = état du segment (loading / failed / done).
  /// Rempli au fur et à mesure des requêtes OSRM.
  ///
  /// Une clé absente = pas encore tenté (équivalent à loading initial).
  /// Distingue explicitement « calcul en cours » et « échec OSRM /
  /// offline » côté UI (audit 2026-05-04).
  final Map<String, _SegmentState> _segmentDurations =
      <String, _SegmentState>{};

  /// Empreinte des visites actuellement résolues — évite de relancer
  /// les requêtes au moindre rebuild si la liste n'a pas changé.
  String _routedKey = '';

  /// Subscription unique à `ReferencesService.onLoaded` au niveau du
  /// PANEL — fait à la place de N subscriptions par row enfant
  /// (audit 2026-05-04). À l'émission, on rebuild le panel entier qui
  /// rebuild ses children, sans avoir N listeners actifs.
  StreamSubscription<ReferencesPayload>? _refsSub;

  @override
  void initState() {
    super.initState();
    final refs = ReferencesService();
    refs.ensureLoaded();
    _refsSub = refs.onLoaded.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refsSub?.cancel();
    super.dispose();
  }

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
  ///
  /// Implémentation 2026-05-04 (fix race condition critique) :
  /// la chaîne est résolue STRICTEMENT en SÉQUENTIEL — `await` chaque
  /// géocodage avant de passer au dossier suivant pour que le
  /// `previous` GeoPoint soit bien à jour. Avant : la boucle for
  /// synchrone lançait `_resolveSegment` avec `previous = kAidHabitatOrigin`
  /// puis tentait de mettre à jour `previous` dans un `.then()` qui
  /// se déclenchait BIEN APRÈS l'iteration suivante → trajets 2 et 3
  /// systématiquement calculés depuis le bureau au lieu de la visite
  /// précédente.
  void _maybeFetchSegments() {
    final visits = _todayVisits;
    final key = visits.map((d) => d.id).join('|');
    if (key == _routedKey) return;
    _routedKey = key;
    // ignore: discarded_futures
    _runFetchChain(visits);
  }

  Future<void> _runFetchChain(List<Dossier> visits) async {
    // Marque tout comme "loading" avant de commencer pour que l'UI
    // affiche un placeholder cohérent (vs "failed" sur les segments
    // pas encore tentés).
    if (mounted) {
      setState(() {
        for (final d in visits) {
          _segmentDurations[d.id] = const _SegmentState.loading();
        }
      });
    }
    GeoPoint previous = kAidHabitatOrigin;
    for (final dossier in visits) {
      if (!mounted) return;
      final addr = DashboardScreen.buildFullAddress(dossier.patient);
      if (addr.isEmpty) {
        setState(() =>
            _segmentDurations[dossier.id] = const _SegmentState.failed());
        continue;
      }
      // 1) Géocode la destination de ce segment.
      final to = await RouteService.instance.geocode(addr);
      if (!mounted) return;
      if (to == null) {
        setState(() =>
            _segmentDurations[dossier.id] = const _SegmentState.failed());
        continue;
      }
      // 2) Calcule le trajet depuis `previous` (séquentiel).
      final d =
          await RouteService.instance.drivingDuration(previous, to);
      if (!mounted) return;
      setState(() => _segmentDurations[dossier.id] = d != null
          ? _SegmentState.done(d)
          : const _SegmentState.failed());
      // 3) Avance le pointeur après calcul.
      previous = to;
    }
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
              // Demande utilisateur 2026-05-05 : le temps de route est
              // intégré DANS la card de visite (sur-ligne en haut),
              // sans mentionner la visite précédente. L'heure de la
              // visite remplace le pill date (« mes visites du jour »
              // = jour J implicite, seule l'heure compte).
              _RecentDossierRow(
                dossier: visits[i],
                onTap: () => widget.onSelect(visits[i]),
                travelState: _segmentDurations[visits[i].id] ??
                    const _SegmentState.loading(),
                visitTimeHighlight: _extractVisitTime(visits[i]),
              ),
              if (i < visits.length - 1) const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

/// Sur-ligne compacte intégrée en haut d'une card de visite du jour
/// pour indiquer le temps de trajet à parcourir. Demande utilisateur
/// 2026-05-05 : intégrer le temps de route DANS la bannière de la
/// visite et masquer le nom de la visite précédente (vs ancien
/// `_RouteSegmentRow` qui affichait « 12 min depuis JEAN DUPONT »
/// entre 2 cards).
///
/// Affiche juste « 🚗 12 min » (ou état loading/failed) — pas de
/// référence au point de départ.
class _TravelOverline extends StatelessWidget {
  final _SegmentState state;

  const _TravelOverline({required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          LucideIcons.car,
          size: 13,
          color: Color(0xFF7C6DAA),
        ),
        const SizedBox(width: 6),
        switch (state) {
          _SegmentLoading() => const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.4,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF7C6DAA),
                    ),
                  ),
                ),
                SizedBox(width: 6),
                Text(
                  'Calcul du trajet…',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF94A3B8),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          _SegmentFailed() => const Text(
              'Trajet indisponible',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF94A3B8),
                fontStyle: FontStyle.italic,
              ),
            ),
          _SegmentDone(duration: final d) => Text(
              RouteService.formatDuration(d),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF7C6DAA),
                letterSpacing: 0.2,
              ),
            ),
        },
      ],
    );
  }
}

/// État du calcul de trajet pour un segment du dashboard.
/// `loading` = requête OSRM en cours.
/// `failed`  = géocodage / routing échoué (offline, BAN/OSRM down, adresse invalide).
/// `done`    = trajet calculé, durée disponible.
sealed class _SegmentState {
  const _SegmentState();
  const factory _SegmentState.loading() = _SegmentLoading;
  const factory _SegmentState.failed() = _SegmentFailed;
  const factory _SegmentState.done(Duration duration) = _SegmentDone;
}

class _SegmentLoading extends _SegmentState {
  const _SegmentLoading();
}

class _SegmentFailed extends _SegmentState {
  const _SegmentFailed();
}

class _SegmentDone extends _SegmentState {
  final Duration duration;
  const _SegmentDone(this.duration);
}

// ---------------------------------------------------------------------------
// Pending reports panel — « Mes rapports en cours / à relancer »
// ---------------------------------------------------------------------------
//
// Liste compacte (max 3) des dossiers dont le statut n'est pas
// « Visité ». Reprend les statuts existants côté NocoDB sans en
// ajouter — demande utilisateur 2026-05-12 (Q1 « ne change pas les
// statuts qu'on a actuellement »). Le badge coloré est dérivé du
// statut texte tel quel.

/// Helper local pour reproduire la logique de bascule auto « visite
/// passée → rapport à faire » de DossiersListScreen sans dépendre
/// d'un export privé. Vrai si la `visitDate` est strictement
/// antérieure à aujourd'hui (date civile, pas l'heure).
bool _isVisitInPast(Dossier d) {
  final raw = d.visitDate;
  if (raw == null || raw.trim().isEmpty) return false;
  try {
    final dt = DateTime.parse(raw);
    final today = DateTime.now();
    final dtDay = DateTime(dt.year, dt.month, dt.day);
    final todayDay = DateTime(today.year, today.month, today.day);
    return dtDay.isBefore(todayDay);
  } catch (_) {
    return false;
  }
}

class _PendingReportsPanel extends StatelessWidget {
  final List<Dossier> dossiers;
  final void Function(Dossier) onSelect;
  final VoidCallback? onSeeAll;

  const _PendingReportsPanel({
    required this.dossiers,
    required this.onSelect,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    // Filtre identique au bucket « Rapport à faire » de
    // DossiersListScreen (cf. _matchesBucket) — demande utilisateur
    // 2026-05-12 : « Les bénéficiaires qu'on voit dans rapports en
    // cours doivent être ceux qu'on retrouve dans rapport à faire
    // dans mes dossiers ». Critère :
    //   • status == VISITED (visite réalisée, rapport pas envoyé)
    //   • OU status == TO_VISIT && date de visite passée (bascule
    //     auto quand l'ergo a oublié de marquer la visite).
    final pending = dossiers
        .where((d) => d.status == DossierStatus.VISITED
            || (d.status == DossierStatus.TO_VISIT && _isVisitInPast(d)))
        .toList(growable: false)
      ..sort((a, b) {
        // Plus récents d'abord (createdAt desc).
        final aDt = DateTime.tryParse(a.createdAt) ?? DateTime(2000);
        final bDt = DateTime.tryParse(b.createdAt) ?? DateTime(2000);
        return bDt.compareTo(aDt);
      });
    final items = pending.take(3).toList(growable: false);

    return _PanelCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'À RÉALISER',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Mes rapports en cours',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF475569),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                      side: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                  ),
                  child: const Text('Voir tout'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            // Pas d'Expanded : `IntrinsicHeight` (parent du panel) ne
            // sait pas calculer la hauteur intrinsèque d'un widget Flex.
            // Le placeholder s'auto-centre via Center + Column(min) — il
            // garde la même apparence ; le panel s'aligne ensuite sur la
            // hauteur du panel non-vide grâce à IntrinsicHeight.
            const _EmptyStatePlaceholder(
              icon: LucideIcons.check,
              text: 'Tout est à jour',
              subText: 'Aucun rapport à réaliser pour le moment.',
            )
          else
            ...items.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PendingReportRow(
                    dossier: d,
                    onTap: () => onSelect(d),
                  ),
                )),
        ],
      ),
    );
  }
}

class _PendingReportRow extends StatelessWidget {
  final Dossier dossier;
  final VoidCallback onTap;

  const _PendingReportRow({required this.dossier, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = dossier.patient;
    final initials = _twoInitials(p.firstName, p.lastName);
    final age = _ageFromBirthDate(p.birthDate);
    final city = p.city.trim();
    final subtitle = [
      if (age != null) '$age ans',
      if (city.isNotEmpty) city,
    ].join(' · ');
    // Remplace le badge statut par le badge catégorie de revenu en
    // monochrome (parité visuelle avec la liste « Mes dossiers »).
    // Demande utilisateur 2026-05-12.
    final income = p.incomeCategory.trim();

    // Palette d'avatar identique à `DossiersListScreen` (basée sur la
    // nature d'accompagnement Diag/MPA) + contour vert/jaune selon le
    // flag `beneficiaryPrepared` — parité totale avec Mes dossiers.
    // Demande utilisateur 2026-05-12.
    final avatarPalette =
        accompanimentPaletteFor(dossier.natureAccompagnement);
    final borderColor = dossier.beneficiaryPrepared
        ? const Color(0xFF86EFAC) // green-300, bénéficiaire prêt
        : const Color(0xFFFDE047); // yellow-300, en attente
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: Row(
          children: [
            // Initiales sur fond coloré (palette d'accompagnement) +
            // bordure vert/jaune comme dans Mes dossiers.
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: avatarPalette.bg,
                shape: BoxShape.circle,
                border: Border.all(color: borderColor, width: 1.8),
              ),
              alignment: Alignment.center,
              child: Text(
                initials,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: avatarPalette.fg,
                ),
              ),
            ),
            const SizedBox(width: 16),
            // Nom + sous-titre
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${p.firstName} ${p.lastName}'.trim(),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF94A3B8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Badge catégorie de revenu (variante monochrome — fond
            // gris neutre, pas de teinte selon le palier ANAH).
            if (income.isNotEmpty)
              IncomeCategoryBadge(
                value: income,
                monochrome: true,
              ),
            const SizedBox(width: 10),
            const Icon(LucideIcons.arrowRight,
                size: 18, color: Color(0xFFCBD5E1)),
          ],
        ),
      ),
    );
  }

  String _twoInitials(String first, String last) {
    final f = first.trim();
    final l = last.trim();
    if (f.isEmpty && l.isEmpty) return '??';
    final c1 = f.isNotEmpty ? f.substring(0, 1) : '';
    final c2 = l.isNotEmpty ? l.substring(0, 1) : '';
    return (c1 + c2).toUpperCase();
  }

  int? _ageFromBirthDate(String birthDate) {
    final s = birthDate.trim();
    if (s.isEmpty) return null;
    final d = DateTime.tryParse(s);
    if (d == null) return null;
    final now = DateTime.now();
    var age = now.year - d.year;
    if (now.month < d.month ||
        (now.month == d.month && now.day < d.day)) {
      age -= 1;
    }
    return age >= 0 && age < 150 ? age : null;
  }

  _StatusPalette _statusPalette(DossierStatus status) {
    // Palette compacte alignée sur l'esprit de la maquette : ton
    // pastel + point vif. Mapping sur les enum existants (cf.
    // DossierStatus + DossierStatusLabel). Demande utilisateur
    // 2026-05-12 : ne pas changer les statuts, juste mieux les
    // visualiser.
    switch (status) {
      case DossierStatus.TO_VISIT:
        return const _StatusPalette(
          bg: Color(0xFFFCE7F3),
          fg: Color(0xFFBE185D),
          dot: Color(0xFFDB2777),
        );
      case DossierStatus.IN_PROGRESS:
        return const _StatusPalette(
          bg: Color(0xFFFFEDD5),
          fg: Color(0xFFB45309),
          dot: Color(0xFFD97706),
        );
      case DossierStatus.WAITING_QUOTES:
      case DossierStatus.QUOTES_RECEIVED:
      case DossierStatus.WAITING_GRANT:
        return const _StatusPalette(
          bg: Color(0xFFFEE2E2),
          fg: Color(0xFFB91C1C),
          dot: Color(0xFFDC2626),
        );
      case DossierStatus.GRANT_VALIDATED:
      case DossierStatus.WORKS_STARTED:
      case DossierStatus.WORKS_COMPLETED:
        return const _StatusPalette(
          bg: Color(0xFFDCFCE7),
          fg: Color(0xFF15803D),
          dot: Color(0xFF16A34A),
        );
      case DossierStatus.VISITED:
      case DossierStatus.CLOSED:
      case DossierStatus.ARCHIVED:
        return const _StatusPalette(
          bg: Color(0xFFF1F5F9),
          fg: Color(0xFF475569),
          dot: Color(0xFF94A3B8),
        );
    }
  }
}

class _StatusPalette {
  final Color bg;
  final Color fg;
  final Color dot;
  const _StatusPalette({
    required this.bg,
    required this.fg,
    required this.dot,
  });
}

/// Placeholder « empty state » réutilisé par les 2 panneaux du
/// dashboard (rapports en cours / agenda). On garde la disposition
/// globale (cards à la même hauteur côte à côte) — demande
/// utilisateur 2026-05-12 : « s'il n'y a pas de prochaine visite, ou
/// de visite de la semaine ou de rapport en cours, garde tout de
/// même cette disposition et indique simplement un texte de
/// remplacement ».
class _EmptyStatePlaceholder extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? subText;

  const _EmptyStatePlaceholder({
    required this.icon,
    required this.text,
    this.subText,
  });

  @override
  Widget build(BuildContext context) {
    // Center pour centrer dans n'importe quel parent (vs Expanded qui
    // ne marche que dans un Flex et casse IntrinsicHeight). Demande
    // utilisateur 2026-05-12 : « centre les dans leur container ».
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: Color(0xFFF1F5F9),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 26, color: const Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF475569),
              ),
              textAlign: TextAlign.center,
            ),
            if (subText != null) ...[
              const SizedBox(height: 4),
              Text(
                subText!,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF94A3B8),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Week agenda panel — « Cette semaine / Agenda »
// ---------------------------------------------------------------------------
//
// Liste compacte (max 3) des prochaines visites planifiées DANS la
// semaine en cours. Trié par date croissante. Affiche jour (DD/MOIS
// court) + nom + ville · sujet + heure à droite.

class _WeekAgendaPanel extends StatelessWidget {
  final List<Dossier> dossiers;
  final DateTime now;
  final DateTime weekEnd;
  final void Function(Dossier) onSelect;
  final VoidCallback? onSeeAll;

  const _WeekAgendaPanel({
    required this.dossiers,
    required this.now,
    required this.weekEnd,
    required this.onSelect,
    this.onSeeAll,
  });

  @override
  Widget build(BuildContext context) {
    // Sélection : visites à faire DE LA SEMAINE — demande utilisateur
    // 2026-05-12 : « ceux qu'on voit dans agenda sont les visites à
    // faire de la semaine ». Critère identique au bucket « Visite à
    // faire » de DossiersListScreen :
    //   • status == TO_VISIT
    //   • date de visite >= aujourd'hui (pas dans le passé, sinon
    //     bascule auto vers "Rapport à faire")
    //   • date de visite dans la semaine en cours
    final upcoming = <_AgendaItem>[];
    for (final d in dossiers) {
      if (d.status != DossierStatus.TO_VISIT) continue;
      if (_isVisitInPast(d)) continue;
      final raw = d.visitDate;
      if (raw == null || raw.isEmpty) continue;
      final when = DateTime.tryParse(raw);
      if (when == null) continue;
      if (when.isBefore(DateTime(now.year, now.month, now.day))) continue;
      if (!when.isBefore(weekEnd)) continue;
      upcoming.add(_AgendaItem(dossier: d, dateTime: when));
    }
    upcoming.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    final items = upcoming.take(3).toList(growable: false);

    return _PanelCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CETTE SEMAINE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Agenda',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              if (onSeeAll != null)
                TextButton(
                  onPressed: onSeeAll,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF475569),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                      side: const BorderSide(color: Color(0xFFE2E8F0)),
                    ),
                  ),
                  child: const Text('Voir tout'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            // Pas d'Expanded — cf. note dans `_PendingReportsPanel`.
            // IntrinsicHeight ne peut pas mesurer un Flex enfant.
            const _EmptyStatePlaceholder(
              icon: LucideIcons.calendar,
              text: 'Aucune visite cette semaine',
              subText: 'Profite d\'une semaine plus calme.',
            )
          else
            ...items.map((it) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _AgendaRow(
                    item: it,
                    isHighlighted: _isSameDay(it.dateTime, now),
                    onTap: () => onSelect(it.dossier),
                  ),
                )),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _AgendaItem {
  final Dossier dossier;
  final DateTime dateTime;
  const _AgendaItem({required this.dossier, required this.dateTime});
}

class _AgendaRow extends StatelessWidget {
  final _AgendaItem item;
  final bool isHighlighted;
  final VoidCallback onTap;

  const _AgendaRow({
    required this.item,
    required this.isHighlighted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = item.dossier.patient;
    final dt = item.dateTime;
    final dayLabel = dt.day.toString().padLeft(2, '0');
    final monthLabel =
        DateFormat('MMM', 'fr_FR').format(dt).toUpperCase().replaceAll('.', '');
    final hasTime = !(dt.hour == 0 && dt.minute == 0);
    final timeLabel = hasTime
        ? '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
        : '—';
    final city = p.city.trim();
    final subtitle = city.isNotEmpty
        ? '$city · ${item.dossier.natureAccompagnement.isNotEmpty
            ? formatAccompanimentType(item.dossier.natureAccompagnement)
            : 'Relevé visite'}'
        : (item.dossier.natureAccompagnement.isNotEmpty
            ? formatAccompanimentType(item.dossier.natureAccompagnement)
            : 'Relevé visite');

    return Material(
      color: isHighlighted ? const Color(0xFFEDE8F5) : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: [
              // Bloc date (agrandi pour cohérence avec _PendingReportRow
              // côté gauche dont l'avatar fait 48 — demande utilisateur
              // 2026-05-12).
              SizedBox(
                width: 48,
                child: Column(
                  children: [
                    Text(
                      dayLabel,
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        height: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      monthLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Nom + sous-titre
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${p.firstName} ${p.lastName}'.trim(),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF94A3B8),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                timeLabel,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

