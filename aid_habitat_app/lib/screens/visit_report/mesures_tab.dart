import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/notes_widget.dart';

/// Mesures tab — deux silhouettes (assise + debout) sur fond blanc.
/// Si le foyer compte plusieurs occupants, un sélecteur "Occupant 1 /
/// Occupant 2" apparaît à gauche sur la même ligne que les flèches undo/redo,
/// exactement comme dans les autres onglets.
class MesuresTab extends StatefulWidget {
  final Dossier dossier;
  final DossierRepository repository;

  const MesuresTab({
    super.key,
    required this.dossier,
    required this.repository,
  });

  @override
  State<MesuresTab> createState() => _MesuresTabState();
}

class _MesuresTabState extends State<MesuresTab>
    with AutomaticKeepAliveClientMixin {
  int _activeOccupantIndex = 0;

  @override
  bool get wantKeepAlive => true;

  int get _occupantCount {
    final n = widget.dossier.patient.numberPeople;
    if (n != null && n > 1) return n;
    return widget.dossier.patient.occupants.length > 1
        ? widget.dossier.patient.occupants.length
        : 1;
  }

  // _occupantLabels() retiré : l'en-tête affiche maintenant le nom
  // complet (Prénom NOM) de l'occupant courant via `_buildOccupantHeader`.

  /// Occupant 0 → 'Mesures' (rétrocompatibilité). Occupant N → 'Mesures-N'.
  String _tabKeyFor(int index) =>
      index == 0 ? 'Mesures' : 'Mesures-$index';

  int get _safeIndex =>
      _activeOccupantIndex.clamp(0, _occupantCount - 1);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final hasMultiple = _occupantCount > 1;
    final idx = _safeIndex;

    // Refonte 2026-05-12 : la bannière occupant est désormais injectée
    // dans le NotesWidget via `leadingNavWidget` — elle apparaît sur
    // LA MÊME LIGNE que les flèches undo/redo internes du widget.
    // Demande utilisateur : « met cette bannière sur la même ligne que
    // les flèches ». Plus de header séparé au-dessus du canvas.
    final notesWidget = NotesWidget(
      key: ValueKey('mesures-${widget.dossier.patient.id}-$idx'),
      patientId: widget.dossier.patient.id,
      tabKey: _tabKeyFor(idx),
      title: 'Mesures anthropométriques',
      subtitle: 'Écrivez directement les mesures sur les silhouettes.',
      toolset: NoteToolset.advanced,
      mode: NoteCanvasMode.freeform,
      allowPagination: false,
      showText: false,
      showSaveButton: false,
      fillParentHeight: true,
      embedded: false,
      backgroundContent: const _MesuresBackground(),
      // Bannière occupant uniquement quand il y en a plusieurs —
      // sinon on évite d'encombrer la barre de navigation pour rien.
      leadingNavWidget: hasMultiple ? _buildOccupantHeader(idx) : null,
    );

    // Plus de Column wrapper — le NotesWidget gère lui-même le layout
    // header (avec leadingNavWidget) + canvas. Mono ou multi-occupant,
    // c'est le même retour direct.
    return notesWidget;
  }

  void _occupantPrev() {
    if (_occupantCount <= 1) return;
    setState(() {
      _activeOccupantIndex = (_safeIndex - 1 + _occupantCount) % _occupantCount;
    });
  }

  void _occupantNext() {
    if (_occupantCount <= 1) return;
    setState(() {
      _activeOccupantIndex = (_safeIndex + 1) % _occupantCount;
    });
  }

  /// Bannière occupant — parité avec beneficiary_tab._buildOccupantHeader
  /// (refonte 2026-05-13). Container fond mauve-50 + chevrons gauche/droite
  /// + nom centré (Nunito w600). Demande utilisateur 2026-05-12 :
  /// « dans mesures tu dois egalement mettre la banniere de chaque
  /// occupant avec le nombre de pages dessin qui correspond au nombre
  /// d'occupant » → on aligne l'onglet Mesures sur le même pattern banner
  /// que Bénéficiaire et Contexte de vie.
  Widget _buildOccupantHeader(int idx) {
    final p = widget.dossier.patient;
    String first = '';
    String last = '';
    if (idx == 0) {
      first = p.firstName.trim();
      last = p.lastName.trim();
    } else if (idx < p.occupants.length) {
      first = p.occupants[idx].firstName.trim();
      last = p.occupants[idx].lastName.trim();
    }
    final display = (first.isEmpty && last.isEmpty)
        ? 'Occupant ${idx + 1}'
        : [first, last.toUpperCase()]
            .where((s) => s.isNotEmpty)
            .join(' ');
    final hasNav = _occupantCount > 1;

    Widget arrow(IconData icon, VoidCallback action) {
      return Opacity(
        opacity: hasNav ? 1 : 0.35,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: hasNav ? action : null,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(icon, size: 16, color: const Color(0xFF2B323A)),
            ),
          ),
        ),
      );
    }

    // Largeur fixe légèrement plus large que le contenu, contenu centré
    // (demande utilisateur 2026-05-13). La bannière ne s'adapte plus au
    // contenu : elle a une largeur constante quelle que soit la longueur
    // du nom de l'occupant, ce qui évite les sauts visuels en naviguant
    // entre occupants. Le centrage dans la barre de nav est assuré par
    // le NotesWidget côté parent (Expanded + Center autour du
    // leadingNavWidget quand `allowPagination` est false).
    return Container(
      width: 280,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7FB), // mauve-50
        border: Border.all(color: const Color(0xFFF2ECF5)), // mauve-100
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          arrow(LucideIcons.chevronLeft, _occupantPrev),
          Expanded(
            child: Text(
              display,
              style: GoogleFonts.nunito(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.25,
                height: 1.15,
                color: const Color(0xFF0E1116),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          arrow(LucideIcons.chevronRight, _occupantNext),
        ],
      ),
    );
  }

  // `_buildOccupantDots` retiré (refonte 2026-05-12). Les dots étaient
  // d'abord déplacés dans la bannière, puis retirés sur demande
  // utilisateur (« ils sont déjà en bas de la page »). La navigation
  // entre occupants se fait désormais uniquement via les chevrons
  // gauche/droite de la bannière. Si un autre dots-style indicateur
  // est nécessaire plus tard, le NotesWidget intégré le fournit déjà.
}

class _MesuresBackground extends StatelessWidget {
  const _MesuresBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Row(
        children: [
          Expanded(
            child: Image.asset(
              'assets/measurements/seated-figure.png',
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Image.asset(
              'assets/measurements/standing-figure.png',
              fit: BoxFit.contain,
            ),
          ),
        ],
      ),
    );
  }
}
