import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/form_widgets.dart';
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

  List<String> _occupantLabels() {
    return List.generate(_occupantCount, (i) {
      final occupants = widget.dossier.patient.occupants;
      if (i < occupants.length) {
        final name = occupants[i].firstName.trim();
        if (name.isNotEmpty) return name.split(' ').first;
      }
      return 'Occ. ${i + 1}';
    });
  }

  /// Occupant 0 → 'Mesures' (rétrocompatibilité). Occupant N → 'Mesures-N'.
  String _tabKeyFor(int index) =>
      index == 0 ? 'Mesures' : 'Mesures-$index';

  int get _safeIndex =>
      _activeOccupantIndex.clamp(0, _occupantCount - 1);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final labels = _occupantLabels();
    final hasMultiple = labels.length > 1;

    return NotesWidget(
      key: ValueKey('mesures-${widget.dossier.patient.id}-${_safeIndex}'),
      patientId: widget.dossier.patient.id,
      tabKey: _tabKeyFor(_safeIndex),
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
      leadingNavWidget: hasMultiple
          ? OccupantSwitcher(
              title: '',
              occupantLabels: labels,
              activeIndex: _safeIndex,
              onChanged: (i) => setState(() => _activeOccupantIndex = i),
            )
          : null,
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
