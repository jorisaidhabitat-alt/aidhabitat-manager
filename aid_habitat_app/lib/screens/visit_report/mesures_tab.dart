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
    );

    // Mono-occupant → canvas plein écran (rien à ajouter).
    if (!hasMultiple) return notesWidget;

    // Multi-occupants : header avec le nom en haut + canvas au milieu
    // + points de pagination en bas du cadre (parité Bénéficiaire).
    // Pas de swipe horizontal ici : cela entrerait en conflit avec les
    // gestures de dessin. L'utilisateur navigue via les points tappables.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header sticky : fond blanc opaque pour parité avec Bénéficiaire
        // et Contexte de vie (le NotesWidget en dessous ne défile pas
        // mais on garde le même traitement visuel).
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          // Centre la bannière horizontalement — la largeur de la
          // bannière s'adapte au contenu (intrinsic width via
          // `mainAxisSize: MainAxisSize.min` dans le Row interne).
          // Demande utilisateur 2026-05-12 : « ne met pas sur toute
          // la largeur, adapte au contenu et centre ».
          child: Center(child: _buildOccupantHeader(idx)),
        ),
        Expanded(child: notesWidget),
        // Dots déplacés dans la bannière (refonte 2026-05-12 — demande
        // utilisateur « met sur la même ligne que les flèches »).
      ],
    );
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
            // Refonte 2026-05-13 : pill radius 999 uniforme.
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // Refonte 2026-05-13 : pill radius 999 uniforme.
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(icon, size: 16, color: const Color(0xFF2B323A)),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7FB), // mauve-50
        border: Border.all(color: const Color(0xFFF2ECF5)), // mauve-100
        // Radius pill complet (refonte 2026-05-12) — demande utilisateur
        // « met un radius plus fort ». 999 = pill, cohérent avec les
        // chips/inputs et la palette de couleurs de la note.
        borderRadius: BorderRadius.circular(999),
      ),
      // Largeur adaptée au contenu via `mainAxisSize: MainAxisSize.min`
      // — la bannière ne s'étire plus sur toute la largeur du parent.
      // Le nom est protégé par un `ConstrainedBox` (max 300 pt) pour
      // gérer le cas de noms très longs sans déborder.
      //
      // Refonte 2026-05-12 : dots de pagination intégrés à la suite du
      // chevron droit (demande utilisateur « met sur la même ligne que
      // les flèches »). Plus de Padding séparé en bas du canvas — toute
      // la navigation occupant tient dans cette pill unique.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          arrow(LucideIcons.chevronLeft, _occupantPrev),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
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
          const SizedBox(width: 4),
          arrow(LucideIcons.chevronRight, _occupantNext),
          // Séparateur visuel léger entre les chevrons (nav) et les
          // dots (indicateur de position). Espace 12 pour bien
          // distinguer les 2 zones fonctionnelles.
          const SizedBox(width: 12),
          _buildOccupantDots(idx),
          // Petite marge à droite pour que le dernier dot ne colle pas
          // au bord interne du pill.
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  /// Points de pagination — un par occupant. Actif = pill 18×5 mauve-500,
  /// inactif = dot 5×5 ink-200. Parité avec beneficiary_tab pour que les
  /// 2 onglets aient EXACTEMENT le même visuel de navigation occupant.
  Widget _buildOccupantDots(int currentIdx) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_occupantCount, (i) {
        final isActive = i == currentIdx;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _activeOccupantIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: isActive ? 18 : 5,
              height: 5,
              decoration: BoxDecoration(
                color: isActive
                    ? const Color(0xFF8B6FA0) // mauve-500
                    : const Color(0xFFE4E7EB), // ink-200
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        );
      }),
    );
  }
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
