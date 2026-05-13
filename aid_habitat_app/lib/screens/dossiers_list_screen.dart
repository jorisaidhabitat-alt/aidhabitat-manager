import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../components/beneficiary_badges.dart';
import '../components/beneficiary_palettes.dart';
import '../components/soft_transitions.dart';
import '../models/types.dart';
import '../services/references_service.dart';

/// Catégories pour les 3 menus déroulants de la page « Mes dossiers »
/// (demande utilisateur 2026-05-04). Chaque dossier tombe dans
/// exactement une catégorie selon son `status`.
enum _DossierBucket { visiteAFaire, rapportAFaire, rapportEnvoye }

/// État par section : tri courant + drapeau replié/déroulé. Mutable
/// (les setState côté écran modifient les champs directement).
class _BucketState {
  String sortColumn;
  bool sortAscending;
  bool expanded;
  _BucketState({
    this.sortColumn = 'name',
    this.sortAscending = true,
    this.expanded = true,
  });
}

/// Mapping bucket → libellé affiché en titre de section.
String _bucketTitle(_DossierBucket b) {
  switch (b) {
    case _DossierBucket.visiteAFaire:
      return 'Visite à faire';
    case _DossierBucket.rapportAFaire:
      return 'Rapport à faire';
    case _DossierBucket.rapportEnvoye:
      return 'Rapport envoyé';
  }
}

/// Détermine si le dossier appartient à la section donnée :
///   • TO_VISIT avec date à venir (ou aucune date) → Visite à faire
///   • TO_VISIT avec date PASSÉE                   → Rapport à faire
///     (demande utilisateur 2026-05-04 : si la date de visite est
///     dépassée, la visite a manifestement eu lieu — sinon l'ergo
///     l'aurait reportée — donc on bascule automatiquement en
///     "Rapport à faire" sans attendre que le statut soit changé
///     manuellement à VISITED.)
///   • VISITED                                     → Rapport à faire
///   • IN_PROGRESS et au-delà                      → Rapport envoyé
bool _matchesBucket(Dossier d, _DossierBucket b) {
  final visitInPast = _isVisitInPast(d);
  switch (b) {
    case _DossierBucket.visiteAFaire:
      return d.status == DossierStatus.TO_VISIT && !visitInPast;
    case _DossierBucket.rapportAFaire:
      return d.status == DossierStatus.VISITED ||
          (d.status == DossierStatus.TO_VISIT && visitInPast);
    case _DossierBucket.rapportEnvoye:
      return d.status.index >= DossierStatus.IN_PROGRESS.index;
  }
}

/// Vrai si la date de visite du dossier est strictement antérieure à
/// aujourd'hui (comparaison sur la date civile, pas l'heure — un
/// dossier dont la visite est prévue aujourd'hui reste en "Visite à
/// faire" jusqu'à minuit). Tolère une date absente ou mal formatée
/// (renvoie false dans ces cas — on ne bascule pas par défaut).
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

class DossiersListScreen extends StatefulWidget {
  final List<Dossier> dossiers;
  final Function(Dossier) onSelectDossier;
  final VoidCallback? onCreateNew;

  const DossiersListScreen({
    super.key,
    required this.dossiers,
    required this.onSelectDossier,
    this.onCreateNew,
  });

  @override
  State<DossiersListScreen> createState() => _DossiersListScreenState();
}

class _DossiersListScreenState extends State<DossiersListScreen> {
  final ReferencesService _references = ReferencesService();
  StreamSubscription<ReferencesPayload>? _refsSub;

  String _searchTerm = '';
  String? _selectedEpciId; // null = no filter
  String _selectedEpciLabel = 'Communauté de commune';

  // Trois sections collapsibles avec chacune leur propre tri (colonne +
  // direction) et leur propre état déroulé/replié. Demande utilisateur
  // 2026-05-04 : « 3 menus déroulants avec chacun ces propres titres
  // qui font l'ordre ». Catégorisation par status :
  //   • Visite à faire   = TO_VISIT
  //   • Rapport à faire  = VISITED (visite réalisée, rapport pas encore
  //                        envoyé / pas encore passé en IN_PROGRESS)
  //   • Rapport envoyé   = IN_PROGRESS et au-delà (En cours, Attente
  //                        devis, Subvention validée, Travaux, Clôturé,
  //                        Archivé). Tous les statuts post-rapport.
  final Map<_DossierBucket, _BucketState> _bucketStates = {
    _DossierBucket.visiteAFaire: _BucketState(),
    _DossierBucket.rapportAFaire: _BucketState(),
    _DossierBucket.rapportEnvoye: _BucketState(),
  };

  @override
  void initState() {
    super.initState();
    // Trigger a references load (communes + EPCI mapping). If already
    // loaded, this is a no-op.
    _references.ensureLoaded();
    _refsSub = _references.onLoaded.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refsSub?.cancel();
    super.dispose();
  }

  /// Resolves the EPCI commune-reference for a dossier by joining its
  /// patient.city on the NocoDB communes table. Prefers a match by
  /// cityId (precise), falls back on label then zipCode. Returns null
  /// if no match.
  CommuneRef? _communeFor(Dossier d) {
    if (!_references.isLoaded) return null;
    final cityId = d.patient.cityId.trim();
    final city = d.patient.city.trim().toLowerCase();
    final zip = d.patient.zipCode.trim();

    for (final ref in _references.communes) {
      if (cityId.isNotEmpty && ref.id == cityId) return ref;
    }
    for (final ref in _references.communes) {
      if (ref.label.toLowerCase() == city) return ref;
    }
    if (zip.isNotEmpty) {
      for (final ref in _references.communes) {
        if (ref.zipCode == zip) return ref;
      }
    }
    return null;
  }

  /// Convenience: EPCI label for display.
  String _epciFor(Dossier d) => _communeFor(d)?.epciLabel ?? '';

  /// EPCI id for filter matching.
  String _epciIdFor(Dossier d) => _communeFor(d)?.epciId ?? '';

  /// Filtre + tri pour UNE section. Le filtre (search + EPCI) reste
  /// global (s'applique aux 3 sections). Le tri est par bucket — chaque
  /// section maintient sa colonne + direction indépendamment.
  List<Dossier> _dossiersForBucket(_DossierBucket bucket) {
    List<Dossier> filtered = widget.dossiers.where((d) {
      if (!_matchesBucket(d, bucket)) return false;
      // EPCI filter (only active when user picked a specific one).
      if (_selectedEpciId != null) {
        if (_epciIdFor(d) != _selectedEpciId) return false;
      }
      final term = _searchTerm.toLowerCase();
      if (term.isEmpty) return true;
      final haystack =
          '${d.patient.lastName} ${d.patient.firstName} ${d.patient.city} ${_epciFor(d)}'
              .toLowerCase();
      return haystack.contains(term);
    }).toList();

    final state = _bucketStates[bucket]!;
    int Function(Dossier, Dossier) cmp;
    switch (state.sortColumn) {
      case 'commune':
        cmp = (a, b) =>
            a.patient.city.toLowerCase().compareTo(b.patient.city.toLowerCase());
        break;
      case 'revenus':
        cmp = (a, b) {
          final ar = a.patient.fiscalRevenue ?? 0;
          final br = b.patient.fiscalRevenue ?? 0;
          if (ar != 0 && br != 0) return ar.compareTo(br);
          if (ar != 0) return -1;
          if (br != 0) return 1;
          return a.patient.incomeCategory
              .toLowerCase()
              .compareTo(b.patient.incomeCategory.toLowerCase());
        };
        break;
      case 'epci':
        cmp = (a, b) =>
            _epciFor(a).toLowerCase().compareTo(_epciFor(b).toLowerCase());
        break;
      case 'date':
        cmp = (a, b) {
          final ad = a.visitDate;
          final bd = b.visitDate;
          if (ad == null && bd == null) return 0;
          if (ad == null) return 1;
          if (bd == null) return -1;
          return DateTime.parse(ad).compareTo(DateTime.parse(bd));
        };
        break;
      case 'name':
      default:
        cmp = (a, b) => a.patient.lastName
            .toLowerCase()
            .compareTo(b.patient.lastName.toLowerCase());
    }
    final direction = state.sortAscending ? 1 : -1;
    filtered.sort((a, b) => cmp(a, b) * direction);
    return filtered;
  }

  /// Tap sur un header : si même colonne, on inverse la direction.
  /// Si nouvelle colonne, on attaque en ascendant pour les colonnes
  /// texte (A→Z, plus pauvre→plus riche) et en DESCENDANT pour la date
  /// (le plus récent en premier — convention visite à domicile).
  /// Scoped au bucket → seule la section touchée se ré-trie.
  void _onHeaderTap(_DossierBucket bucket, String column) {
    final state = _bucketStates[bucket]!;
    setState(() {
      if (state.sortColumn == column) {
        state.sortAscending = !state.sortAscending;
      } else {
        state.sortColumn = column;
        state.sortAscending = column != 'date';
      }
    });
  }

  /// Returns the FULL list of EPCIs ("communautés de commune") from the
  /// NocoDB `epci` reference table — even the ones that no dossier
  /// matches yet. The picker is a pure catalog browser; the empty-state
  /// of the dossiers list itself explains that a chosen EPCI has no
  /// matching dossier.
  List<EpciRef> get _availableEpcis {
    final list = [..._references.epcis];
    list.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return list;
  }

  // Key attached to the EPCI trigger button so we can compute the
  // position where the in-page dropdown should anchor.
  final GlobalKey _epciTriggerKey = GlobalKey();

  Future<void> _openEpciPicker() async {
    final ctx = _epciTriggerKey.currentContext;
    if (ctx == null) return;
    final RenderBox button = ctx.findRenderObject() as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          Offset(0, button.size.height + 6),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + const Offset(0, 6),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final selected = await showMenu<_EpciPickerResult>(
      context: context,
      position: position,
      color: Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: [
        _EpciMenuEntry(
          epcis: _availableEpcis,
          currentEpciId: _selectedEpciId,
        ),
      ],
    );
    if (selected == null) return;
    setState(() {
      _selectedEpciId = selected.id;
      _selectedEpciLabel = selected.label;
    });
  }

  String _initials(Patient patient) {
    final f = patient.firstName.trim();
    final l = patient.lastName.trim();
    if (f.isEmpty && l.isEmpty) return '?';
    if (f.isEmpty) return l.substring(0, 1).toUpperCase();
    if (l.isEmpty) return f.substring(0, 1).toUpperCase();
    return '${f[0]}${l[0]}'.toUpperCase();
  }

  /// Full address: `<street> <zip> <CITY>`. Collapses multiple spaces and
  /// skips empty parts so incomplete dossiers don't render "  35137 ".
  String _fullAddress(Patient p) {
    final street = p.address.trim();
    final zip = p.zipCode.trim();
    final city = p.city.trim();
    return [street, zip, city.toUpperCase()]
        .where((s) => s.isNotEmpty)
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _formatVisitDate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    try {
      return DateFormat('dd/MM/yy').format(DateTime.parse(raw));
    } catch (_) {
      return raw;
    }
  }

  int _ageFromBirth(String rawBirth) {
    if (rawBirth.trim().isEmpty) return -1;
    try {
      final dob = DateTime.parse(rawBirth);
      final now = DateTime.now();
      var age = now.year - dob.year;
      if (now.month < dob.month ||
          (now.month == dob.month && now.day < dob.day)) {
        age -= 1;
      }
      return age < 0 ? -1 : age;
    } catch (_) {
      return -1;
    }
  }

  String _primaryGir(Dossier d) {
    if (d.patient.occupants.isNotEmpty) {
      final g = d.patient.occupants.first.apaGir.trim();
      if (g.isNotEmpty) return g;
    }
    return '';
  }

  /// Count of dossiers created in the current calendar month.
  int get _createdThisMonth {
    final now = DateTime.now();
    var count = 0;
    for (final d in widget.dossiers) {
      try {
        final dt = DateTime.parse(d.createdAt);
        if (dt.year == now.year && dt.month == now.month) count++;
      } catch (_) {}
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.dossiers.length;
    final thisMonth = _createdThisMonth;
    return Padding(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─── En-tête : sous-titre + titre à gauche, bouton "Nouveau
          // dossier" à droite. Parité maquette.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "$total dossier${total > 1 ? 's' : ''} · $thisMonth ce mois-ci",
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Mes dossiers',
                      // Refonte 2026-05-13 : Nunito w600 — style
                      // uniforme avec les autres titres de page.
                      style: GoogleFonts.nunito(
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.onCreateNew != null) _buildNewDossierButton(),
            ],
          ),
          const SizedBox(height: 24),

          // ─── Contrôles : recherche (icône à gauche) + tri + EPCI.
          Theme(
            data: Theme.of(context).copyWith(
              hoverColor: Colors.transparent,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              focusColor: Colors.transparent,
            ),
            child: Row(
              children: [
                Expanded(child: _buildSearchField()),
                const SizedBox(width: 12),
                _buildEpciPill(),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ─── 3 sections collapsibles, chacune avec son propre tri.
          // Demande utilisateur 2026-05-04 : « 3 menus déroulants avec
          // chacun ces propres titres qui font l'ordre ». Le pill global
          // « Tri » a été retiré — les en-têtes de colonnes par section
          // remplissent désormais ce rôle individuellement.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildBucketSection(_DossierBucket.visiteAFaire),
                  const SizedBox(height: 12),
                  _buildBucketSection(_DossierBucket.rapportAFaire),
                  const SizedBox(height: 12),
                  _buildBucketSection(_DossierBucket.rapportEnvoye),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section collapsible (3 buckets : Visite à faire / Rapport à faire /
  // Rapport envoyé). Chaque section a son propre tri + son propre état
  // déroulé/replié, animés via AnimatedSize + AnimatedRotation.
  // ---------------------------------------------------------------------------

  Widget _buildBucketSection(_DossierBucket bucket) {
    final state = _bucketStates[bucket]!;
    final dossiers = _dossiersForBucket(bucket);
    final title = _bucketTitle(bucket);
    // Refonte 2026-05-13 : border ink-200 1px autour de chaque section
    // (Visite à faire / Rapport à faire / Rapport envoyé) — au lieu
    // d'une simple shadow. Donne un look plus card / contour propre.
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE4E7EB)), // ink-200
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Titre de section + chevron animé. Tap = toggle expanded.
          // Pas d'effet ripple gris (Material default) qui débordait en
          // rectangle sans radius par-dessus le coin arrondi de la
          // section au survol — demande utilisateur 2026-05-04.
          // `GestureDetector` à la place d'`InkWell` : le tap reste
          // détecté, mais Flutter ne dessine plus de feedback visuel.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => state.expanded = !state.expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Badge compteur (style discret slate-100).
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${dossiers.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF334155),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: state.expanded ? 0.5 : 0,
                    duration: kSoftMedium,
                    curve: kSoftCurve,
                    child: const Icon(
                      Icons.expand_more,
                      color: Color(0xFF64748B),
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Contenu animé : `AnimatedSize` collapse la hauteur quand
          // replié, `SoftSwitcher` rejoue le fade+slide 8 px à chaque
          // changement de tri (parité avec les transitions de pages).
          AnimatedSize(
            duration: kSoftMedium,
            curve: kSoftCurve,
            alignment: Alignment.topCenter,
            child: state.expanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 1,
                        color: const Color(0xFFEEEEF2),
                      ),
                      _buildTableHeader(bucket),
                      SoftSwitcher(
                        fillParent: false,
                        child: KeyedSubtree(
                          key: ValueKey<String>(
                            '${bucket.name}:${state.sortColumn}:${state.sortAscending ? 'a' : 'd'}',
                          ),
                          child: dossiers.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 24),
                                  child: Text(
                                    'Aucun dossier dans cette catégorie.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                )
                              : ListView.separated(
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  physics:
                                      const NeverScrollableScrollPhysics(),
                                  itemCount: dossiers.length,
                                  separatorBuilder: (_, __) => Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: Colors.grey.shade100,
                                  ),
                                  itemBuilder: (context, index) =>
                                      _buildTableRow(dossiers[index]),
                                ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox(
                    width: double.infinity,
                    height: 0,
                  ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header bits
  // ---------------------------------------------------------------------------

  Widget _buildNewDossierButton() {
    // Refonte 2026-05-13 : radius pill complet (999) au lieu de 16.
    return Material(
      color: const Color(0xFF8B6FA0),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: widget.onCreateNew,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.plus, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Text(
                'Nouveau dossier',
                style: GoogleFonts.nunito(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.search, size: 18, color: Color(0xFF64748B)),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              onChanged: (v) => setState(() => _searchTerm = v),
              decoration: const InputDecoration(
                hintText: 'Rechercher un nom, une ville…',
                hintStyle: TextStyle(color: Color(0xFF94A3B8)),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpciPill() {
    return InkWell(
      key: _epciTriggerKey,
      onTap: _openEpciPicker,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: [
            const Icon(LucideIcons.mapPin,
                size: 16, color: Color(0xFF64748B)),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                _selectedEpciLabel,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(LucideIcons.chevronDown, size: 20),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Table
  // ---------------------------------------------------------------------------

  /// Largeurs proportionnelles des colonnes (flex-based) utilisées par
  /// l'en-tête ET chaque rangée pour garder l'alignement vertical.
  /// `_flexEpci` est élargi pour décaler la colonne DATE DE VISITE
  /// plus à droite (demande utilisateur : laisser respirer la date).
  /// `_flexCommune` est élargi (2 → 4) pour que les noms de villes
  /// longs ("Châteauneuf-d'Ille-et-Vilaine", "Saint-Méen-le-Grand"…)
  /// ne soient plus tronqués — ce qui pousse mécaniquement REVENUS et
  /// COMMUNAUTÉ DE COMMUNE vers la droite.
  static const int _flexBeneficiary = 3;
  static const int _flexCommune = 4;
  static const int _flexRevenus = 2;
  static const int _flexEpci = 4;
  static const int _flexDate = 2;

  /// En-tête de colonnes pour UNE section. Le tap sur une colonne sort
  /// uniquement les dossiers de cette section (pas les autres) — chaque
  /// bucket conserve son propre tri.
  Widget _buildTableHeader(_DossierBucket bucket) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      // Fond plus clair que le scaffold global (#F7F7FA) pour que la
      // barre de titres de colonnes se distingue visuellement du fond
      // de la page.
      color: const Color(0xFFFAFAFC),
      child: Row(
        children: [
          // BÉNÉFICIAIRE inclut l'avatar rond — prévoir la même
          // réserve que dans la rangée (48 + 16 = 64 px). Cellule sans
          // tri (juste l'avatar).
          SizedBox(
              width: 64, child: _headerCell(bucket, '', column: null)),
          Expanded(
              flex: _flexBeneficiary,
              child: _headerCell(bucket, 'BÉNÉFICIAIRE', column: 'name')),
          Expanded(
              flex: _flexCommune,
              child: _headerCell(bucket, 'COMMUNE', column: 'commune')),
          Expanded(
              flex: _flexRevenus,
              child: _headerCell(bucket, 'REVENUS', column: 'revenus')),
          Expanded(
            flex: _flexEpci,
            child: _headerCell(bucket, 'COMMUNAUTÉ DE COMMUNE',
                column: 'epci'),
          ),
          Expanded(
            flex: _flexDate,
            child: _headerCell(bucket, 'DATE DE VISITE',
                column: 'date', alignRight: true),
          ),
          const SizedBox(width: 32), // espace pour le chevron des rangées
        ],
      ),
    );
  }

  /// Cellule d'en-tête de colonne pour le bucket donné. Si [column] est
  /// non-null, le tap déclenche `_onHeaderTap(bucket, column)` — 1er
  /// clic = ascendant, 2e clic = inverse. Une flèche ▲ / ▼ apparaît
  /// à côté du titre actif, lue depuis l'état du bucket.
  Widget _headerCell(_DossierBucket bucket, String text,
      {String? column, bool alignRight = false}) {
    final state = _bucketStates[bucket]!;
    final isActive = column != null && state.sortColumn == column;
    final indicator = isActive
        ? Icon(
            state.sortAscending
                ? Icons.arrow_drop_up
                : Icons.arrow_drop_down,
            size: 18,
            color: const Color(0xFF8B6FA0),
          )
        : null;

    final textWidget = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: alignRight ? TextAlign.right : TextAlign.left,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: isActive ? const Color(0xFF8B6FA0) : const Color(0xFF94A3B8),
      ),
    );

    if (column == null) return textWidget;

    final content = Row(
      mainAxisAlignment:
          alignRight ? MainAxisAlignment.end : MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (alignRight && indicator != null) indicator,
        Flexible(child: textWidget),
        if (!alignRight && indicator != null) indicator,
      ],
    );

    return InkWell(
      onTap: () => _onHeaderTap(bucket, column),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: content,
      ),
    );
  }

  Widget _buildTableRow(Dossier dossier) {
    final p = dossier.patient;
    final age = _ageFromBirth(p.birthDate);
    final gir = _primaryGir(dossier);
    final meta = <String>[];
    if (age >= 0) meta.add('$age ans');
    if (gir.isNotEmpty) meta.add('GIR $gir');

    final epci = _epciFor(dossier);
    final visitDate = _formatVisitDate(dossier.visitDate);
    final income = p.incomeCategory.trim();

    return SoftTapScale(
      onTap: () => widget.onSelectDossier(dossier),
      child: InkWell(
      onTap: () => widget.onSelectDossier(dossier),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            // Avatar — couleur dérivée du TYPE D'ACCOMPAGNEMENT du
            // dossier (rose pour Diag ergo, vert pour MPA ergo, violet
            // pour MPA complet, gris pour vide). Demande utilisateur
            // 2026-05-04 : "la même couleur sur la photo de profil que
            // le type d'accompagnement". Permet à l'ergo de reconnaître
            // la nature d'un dossier d'un seul coup d'œil dans la liste,
            // sans avoir à le scanner colonne par colonne.
            //
            // Si l'avatar a une vraie photo de profil un jour, ce
            // Container sert de bordure/halo coloré autour de la photo
            // (à câbler quand le champ photo de bénéficiaire existera —
            // pour l'instant, fallback initiales).
            //
            // Avant : couleur dérivée des initiales (mint/pêche/ciel)
            // qui ne portait aucune info métier, juste de la variété
            // visuelle.
            SizedBox(
              width: 64,
              child: Builder(builder: (_) {
                final palette =
                    accompanimentPaletteFor(dossier.natureAccompagnement);
                // Bordure jaune (non préparé) / verte (préparé) autour
                // de l'avatar — demande utilisateur 2026-05-05. Reflète
                // le flag `beneficiary_prepared` togglé dans le bandeau
                // bénéficiaire de l'écran dossier.
                final borderColor = dossier.beneficiaryPrepared
                    ? const Color(0xFF86EFAC) // green-300, vert léger
                    : const Color(0xFFFDE047); // yellow-300, jaune léger
                return Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: palette.bg,
                    shape: BoxShape.circle,
                    border: Border.all(color: borderColor, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initials(p),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: palette.fg,
                      fontSize: 16,
                    ),
                  ),
                );
              }),
            ),
            // BÉNÉFICIAIRE (nom + âge/GIR)
            Expanded(
              flex: _flexBeneficiary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${p.lastName.toUpperCase()} ${p.firstName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      meta.join(' · '),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // COMMUNE (ville + code postal)
            Expanded(
              flex: _flexCommune,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    p.city,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  if (p.zipCode.trim().isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      p.zipCode,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // REVENUS — variante monochrome (sans couleur) demandée
            // par l'utilisateur sur la liste « Mes dossiers » : fond
            // gris neutre, texte gris foncé. Les couleurs (bleu Très
            // modeste, jaune/orange Modeste…) restent utilisées dans
            // les autres écrans (header de dossier, relevé de visite).
            Expanded(
              flex: _flexRevenus,
              child: income.isEmpty
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: IncomeCategoryBadge(
                        value: income,
                        monochrome: true,
                      ),
                    ),
            ),
            // COMMUNAUTÉ DE COMMUNE
            Expanded(
              flex: _flexEpci,
              child: epci.isEmpty
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: EpciBadge(label: epci),
                    ),
            ),
            // DATE DE VISITE — alignée à droite pour la pousser au
            // maximum vers le chevron (demande utilisateur : "décaler
            // la date plus à droite").
            Expanded(
              flex: _flexDate,
              child: Text(
                visitDate.isEmpty ? '—' : visitDate,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: visitDate.isEmpty
                      ? const Color(0xFF94A3B8)
                      : const Color(0xFF0F172A),
                ),
              ),
            ),
            // Chevron
            const SizedBox(
              width: 32,
              child: Icon(
                LucideIcons.chevronRight,
                size: 18,
                color: Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            LucideIcons.search,
            size: 48,
            color: Colors.grey.shade300,
          ),
          const SizedBox(height: 16),
          Text(
            'Aucun résultat',
            style: TextStyle(color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }
}

// (Ancien _IncomeBadge local retiré — remplacé par IncomeCategoryBadge
// du module components/beneficiary_badges.dart, pour garder la même
// palette dans tout l'app.)

// Palettes EPCI + avatar bénéficiaire désormais dans
// `components/beneficiary_palettes.dart` — partagées entre
// DossiersListScreen et DashboardScreen pour que même bénéficiaire /
// même EPCI garde la même couleur partout dans l'app.

/// Visit date badge shown on the right of each dossier row, right before
/// the chevron. Larger font than the address line. Falls back to the
/// soft placeholder "À planifier" when no date is set.
class _VisitDateBadge extends StatelessWidget {
  const _VisitDateBadge({required this.dateLabel});

  final String dateLabel;

  @override
  Widget build(BuildContext context) {
    final hasDate = dateLabel.isNotEmpty;
    final displayDate = hasDate ? dateLabel : 'À planifier';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.calendar,
            size: 16,
            color: hasDate
                ? const Color(0xFF0F172A)
                : const Color(0xFF94A3B8),
          ),
          const SizedBox(width: 6),
          Text(
            displayDate,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: hasDate
                  ? const Color(0xFF0F172A)
                  : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}

/// Payload returned by the EPCI picker. `id` null = reset filter.
class _EpciPickerResult {
  const _EpciPickerResult({this.id, required this.label});
  final String? id;
  final String label;
}

/// Custom PopupMenuEntry that renders the full EPCI picker UI — search
/// field on top + scrollable list. Plugged directly into `showMenu()`
/// so the dropdown opens inline below the trigger button (no modal
/// dialog, no blocking overlay).
class _EpciMenuEntry extends PopupMenuEntry<_EpciPickerResult> {
  const _EpciMenuEntry({
    required this.epcis,
    required this.currentEpciId,
  });

  final List<EpciRef> epcis;
  final String? currentEpciId;

  @override
  double get height => 420;

  @override
  bool represents(_EpciPickerResult? value) => false;

  @override
  State<_EpciMenuEntry> createState() => _EpciMenuEntryState();
}

class _EpciMenuEntryState extends State<_EpciMenuEntry> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<EpciRef> get _visible {
    if (_query.isEmpty) return widget.epcis;
    return widget.epcis
        .where((e) => e.label.toLowerCase().contains(_query))
        .toList();
  }

  void _pick(EpciRef e) {
    // Reclicking the active EPCI clears the filter (toggle).
    if (widget.currentEpciId == e.id) {
      Navigator.of(context).pop(
        const _EpciPickerResult(id: null, label: 'Communauté de commune'),
      );
      return;
    }
    Navigator.of(context)
        .pop(_EpciPickerResult(id: e.id, label: e.label));
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return SizedBox(
      width: 340,
      child: Theme(
        data: Theme.of(context).copyWith(
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(999),
                ),
                // Row defaults to CrossAxisAlignment.center → the loupe
                // and the TextField share the same vertical middle.
                child: Row(
                  children: [
                    const Icon(
                      LucideIcons.search,
                      size: 16,
                      color: Color(0xFF64748B),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        // height: 1.0 on the style + isCollapsed + zero
                        // contentPadding force the TextField to stop
                        // inserting its own vertical padding, so the hint
                        // baseline aligns with the icon center.
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.0,
                          color: Color(0xFF0F172A),
                        ),
                        // Slight negative y nudges the text/hint upward so
                        // the optical center of "Rechercher…" matches the
                        // loupe icon instead of sitting just below it.
                        textAlignVertical: const TextAlignVertical(y: -0.25),
                        decoration: const InputDecoration(
                          hintText: 'Rechercher…',
                          hintStyle: TextStyle(
                            color: Color(0xFF94A3B8),
                            height: 1.0,
                          ),
                          isCollapsed: true,
                          contentPadding: EdgeInsets.only(bottom: 2),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Results
            SizedBox(
              height: 320,
              child: visible.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          'Aucun résultat',
                          style: TextStyle(color: Color(0xFF94A3B8)),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final epci = visible[index];
                        return _EpciMenuTile(
                          label: epci.label,
                          selected: widget.currentEpciId == epci.id,
                          onTap: () => _pick(epci),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpciMenuTile extends StatelessWidget {
  const _EpciMenuTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF1F5F9) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: const Color(0xFF1E293B),
                ),
              ),
            ),
            if (selected)
              const Icon(LucideIcons.check,
                  size: 18, color: Color(0xFF334155)),
          ],
        ),
      ),
    );
  }
}

