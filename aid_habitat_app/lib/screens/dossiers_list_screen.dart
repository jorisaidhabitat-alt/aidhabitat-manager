import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../components/beneficiary_badges.dart';
import '../models/types.dart';
import '../services/references_service.dart';

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
  String _sortOrder = 'asc'; // asc, desc
  String? _selectedEpciId; // null = no filter
  String _selectedEpciLabel = 'Communauté de commune';

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

  List<Dossier> get _filteredDossiers {
    List<Dossier> filtered = widget.dossiers.where((d) {
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

    if (_sortOrder == 'asc') {
      filtered.sort((a, b) => a.patient.lastName.compareTo(b.patient.lastName));
    } else if (_sortOrder == 'desc') {
      filtered.sort((a, b) => b.patient.lastName.compareTo(a.patient.lastName));
    }

    return filtered;
  }

  String get _sortLabel {
    switch (_sortOrder) {
      case 'asc':
        return 'de A à Z';
      case 'desc':
        return 'de Z à A';
      default:
        return 'de A à Z';
    }
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
                    const Text(
                      'Dossiers bénéficiaires',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
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
                _buildSortPill(),
                const SizedBox(width: 12),
                _buildEpciPill(),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ─── Tableau : en-tête de colonnes figé + corps scrollable.
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.02),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  _buildTableHeader(),
                  Expanded(
                    child: _filteredDossiers.isEmpty
                        ? _buildEmptyState()
                        : ListView.separated(
                            padding: EdgeInsets.zero,
                            itemCount: _filteredDossiers.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              thickness: 1,
                              color: Colors.grey.shade100,
                            ),
                            itemBuilder: (context, index) {
                              final dossier = _filteredDossiers[index];
                              return _buildTableRow(dossier);
                            },
                          ),
                  ),
                ],
              ),
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
    return Material(
      color: const Color(0xFF7C6DAA),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onCreateNew,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.plus, size: 18, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'Nouveau dossier',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
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
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
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

  Widget _buildSortPill() {
    return PopupMenuButton<String>(
      tooltip: '',
      onSelected: (value) => setState(() => _sortOrder = value),
      color: Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Text(
              _sortLabel,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            const Icon(LucideIcons.chevronDown, size: 20),
          ],
        ),
      ),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'asc', child: Text('de A à Z')),
        PopupMenuItem(value: 'desc', child: Text('de Z à A')),
      ],
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
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(999),
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
  static const int _flexBeneficiary = 3;
  static const int _flexCommune = 2;
  static const int _flexRevenus = 2;
  static const int _flexEpci = 3;
  static const int _flexDate = 2;

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      color: const Color(0xFFF7F7FA),
      child: Row(
        children: [
          // BÉNÉFICIAIRE inclut l'avatar rond — prévoir la même
          // réserve que dans la rangée (48 + 16 = 64 px).
          SizedBox(width: 64, child: _headerCell('')),
          Expanded(flex: _flexBeneficiary, child: _headerCell('BÉNÉFICIAIRE')),
          Expanded(flex: _flexCommune, child: _headerCell('COMMUNE')),
          Expanded(flex: _flexRevenus, child: _headerCell('REVENUS')),
          Expanded(
            flex: _flexEpci,
            child: _headerCell('COMMUNAUTÉ DE COMMUNE'),
          ),
          Expanded(flex: _flexDate, child: _headerCell('DATE DE VISITE')),
          const SizedBox(width: 32), // espace pour le chevron des rangées
        ],
      ),
    );
  }

  Widget _headerCell(String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
        color: Color(0xFF94A3B8),
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

    return InkWell(
      onTap: () => widget.onSelectDossier(dossier),
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            // Avatar — couleur pastel déterministe (mint/pêche/ciel)
            // dérivée des initiales du bénéficiaire (demande utilisateur :
            // varier les cercles entre #B8DDCC, #F4D5C4, #CFE3F0). Même
            // patient → même couleur à chaque affichage.
            SizedBox(
              width: 64,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _beneficiaryAvatarBgFor(_initials(p)),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  _initials(p),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF554a63),
                    fontSize: 16,
                  ),
                ),
              ),
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
            // REVENUS — palette unifiée via IncomeCategoryBadge
            // (bleu pour Très modeste, jaune/orange pour Modeste,
            // neutre pour les autres).
            Expanded(
              flex: _flexRevenus,
              child: income.isEmpty
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: IncomeCategoryBadge(value: income),
                    ),
            ),
            // COMMUNAUTÉ DE COMMUNE
            Expanded(
              flex: _flexEpci,
              child: epci.isEmpty
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: _EpciBadge(
                        label: epci,
                        palette: _epciPaletteFor(epci),
                      ),
                    ),
            ),
            // DATE DE VISITE
            Expanded(
              flex: _flexDate,
              child: Text(
                visitDate.isEmpty ? '—' : visitDate,
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

/// Palette of soft pill backgrounds + matching foreground, stable per EPCI
/// label. Two dossiers of the same communauté de communes always get the
/// same color; different communities get distinct colors. Good contrast is
/// preserved (WCAG AA on small bold text).
class _EpciPalette {
  final Color bg;
  final Color fg;
  const _EpciPalette({required this.bg, required this.fg});
}

/// Palette "Équilibrée" (charte graphique utilisateur) : 5 fonds pastel
/// doux (mint, pêche, ciel, lavande, sable). Objectif : éviter la
/// sensation de code couleur clinique — le texte reste slate foncé
/// pour la lisibilité. Chaque EPCI garde une couleur stable via hash.
const Color _kPastelEpciFg = Color(0xFF334155);

const List<_EpciPalette> _kEpciPalettes = [
  _EpciPalette(bg: Color(0xFFC8E6D0), fg: _kPastelEpciFg), // mint
  _EpciPalette(bg: Color(0xFFF5D6B8), fg: _kPastelEpciFg), // pêche
  _EpciPalette(bg: Color(0xFFD9EAF3), fg: _kPastelEpciFg), // ciel
  _EpciPalette(bg: Color(0xFFE8E2F0), fg: _kPastelEpciFg), // lavande
  _EpciPalette(bg: Color(0xFFF0E4CC), fg: _kPastelEpciFg), // sable
];

/// Deterministic label → palette assignment (same EPCI = same color every
/// time the list is rendered). Uses a rolling hash of the label to pick a
/// slot in [_kEpciPalettes].
_EpciPalette _epciPaletteFor(String label) {
  if (label.isEmpty) {
    return const _EpciPalette(
      bg: Color(0xFFF1F5F9),
      fg: _kPastelEpciFg,
    );
  }
  int hash = 0;
  for (final rune in label.runes) {
    hash = (hash * 31 + rune) & 0x7FFFFFFF;
  }
  return _kEpciPalettes[hash % _kEpciPalettes.length];
}

/// Palette pastel des cercles d'avatar bénéficiaire (demande utilisateur) :
/// mint / pêche / ciel — varie d'un bénéficiaire à l'autre. Hash stable
/// sur les initiales → même bénéficiaire = même couleur à chaque rendu.
const List<Color> _kBeneficiaryAvatarBgs = [
  Color(0xFFB8DDCC), // mint
  Color(0xFFF4D5C4), // pêche
  Color(0xFFCFE3F0), // ciel
];

Color _beneficiaryAvatarBgFor(String seed) {
  if (seed.isEmpty) return _kBeneficiaryAvatarBgs.first;
  int hash = 0;
  for (final rune in seed.runes) {
    hash = (hash * 31 + rune) & 0x7FFFFFFF;
  }
  return _kBeneficiaryAvatarBgs[hash % _kBeneficiaryAvatarBgs.length];
}

/// Chip showing the communauté de communes with a color-coded background
/// (one stable color per EPCI). Displayed to the left of the visit date.
class _EpciBadge extends StatelessWidget {
  const _EpciBadge({required this.label, required this.palette});

  final String label;
  final _EpciPalette palette;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: palette.bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: palette.fg,
          ),
        ),
      ),
    );
  }
}

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

