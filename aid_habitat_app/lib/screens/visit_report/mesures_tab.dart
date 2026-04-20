import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../services/dossier_repository.dart';
import '../../components/notes_widget.dart';

/// Mesures tab — parité avec React : deux silhouettes (assise + debout) qui
/// occupent toute la largeur sur fond blanc. L'utilisateur écrit directement
/// les mesures sur les images et le fond blanc avec les outils de dessin
/// (crayon / surligneur / gomme), comme sur une feuille papier.
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
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return NotesWidget(
      patientId: widget.dossier.patient.id,
      tabKey: 'Mesures',
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
  }
}

/// Fond affiché sous le canvas : les deux silhouettes côte à côte sur fond
/// blanc. `IgnorePointer` est appliqué par NotesWidget donc toutes les
/// interactions (pen, eraser…) passent au canvas de dessin.
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
