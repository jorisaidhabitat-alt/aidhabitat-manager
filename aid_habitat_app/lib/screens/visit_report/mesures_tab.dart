import 'package:flutter/material.dart';
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
          child: _buildOccupantHeader(idx),
        ),
        Expanded(child: notesWidget),
        Padding(
          padding: const EdgeInsets.only(bottom: 14, top: 6),
          child: Center(child: _buildOccupantDots(idx)),
        ),
      ],
    );
  }

  /// Nom + NOM de l'occupant courant — change quand l'utilisateur tape
  /// un point de pagination (pas de swipe ici, conflit avec le dessin).
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
    return Text(
      display,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: Color(0xFF0E1116),
        letterSpacing: -0.2,
      ),
    );
  }

  /// Rangée de points centrée — un par occupant, le courant violet plein.
  /// Tap direct pour sauter à un occupant (pas de swipe sur cet onglet).
  Widget _buildOccupantDots(int currentIdx) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_occupantCount, (i) {
        final isActive = i == currentIdx;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _activeOccupantIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: isActive ? 10 : 8,
              height: isActive ? 10 : 8,
              decoration: BoxDecoration(
                color: isActive
                    ? const Color(0xFF8B6FA0)
                    : const Color(0xFFD8CFE0),
                shape: BoxShape.circle,
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
