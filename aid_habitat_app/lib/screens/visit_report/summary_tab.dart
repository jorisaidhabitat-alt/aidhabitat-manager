import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../components/notes_widget.dart';

/// Onglet « Résumé » — créé 2026-05-04 à partir du split de l'ancien
/// onglet Préconisations en deux pages distinctes (demande utilisateur) :
///
///   - **Résumé** (cet onglet) : conserve les 2 cadres « Projet de
///     l'usager » et « Résumé des préconisations » en haut, plus une
///     zone de prise de notes pleine page (toolset advanced, freeform
///     comme l'onglet Mesures), MAIS sans image de fond — c'est juste
///     un canvas blanc pour annoter avec le stylet.
///
///   - **Préconisations** : ne contient plus que la grille de cartes
///     préconisations (cf. recommendations_tab.dart).
///
/// Persistance : les 2 cadres réutilisent les mêmes `tabKey` qu'avant
/// (`Préconisations-Projet`, `Préconisations-Résumé`) → les notes
/// existantes sont préservées sans migration. Le canvas pleine page
/// utilise un nouveau `tabKey = 'Résumé'`.
class SummaryTab extends StatefulWidget {
  final Dossier dossier;
  const SummaryTab({super.key, required this.dossier});

  @override
  State<SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<SummaryTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final patientId = widget.dossier.patient.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header sticky : 2 notes côte-à-côte (compact ~84 px), tabKeys
        // identiques à l'ancien onglet Préconisations pour préserver les
        // données existantes :
        //   - 'Préconisations-Projet'  → page 7 PDF, « Projet ou souhait »
        //   - 'Préconisations-Résumé'  → page 7 PDF, « Résumé des préco »
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: SizedBox(
            height: 84,
            child: Row(
              children: [
                Expanded(
                  child: NotesWidget(
                    key: ValueKey('summary-note-projet-$patientId'),
                    patientId: patientId,
                    tabKey: 'Préconisations-Projet',
                    placeholder: 'Projet de l’usager',
                    showCanvas: false,
                    embedded: true,
                    showSaveButton: false,
                    allowPagination: false,
                    allowTextModal: true,
                    expandModalFullscreen: true,
                    fillParentHeight: true,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: NotesWidget(
                    key: ValueKey('summary-note-resume-$patientId'),
                    patientId: patientId,
                    tabKey: 'Préconisations-Résumé',
                    placeholder: 'Résumé des préconisations',
                    showCanvas: false,
                    embedded: true,
                    showSaveButton: false,
                    allowPagination: false,
                    allowTextModal: true,
                    expandModalFullscreen: true,
                    fillParentHeight: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        // Canvas pleine page — même setup que MesuresTab (toolset
        // advanced, freeform, fillParentHeight) MAIS sans
        // backgroundContent (fond blanc, pas de silhouettes / images).
        // tabKey = 'Résumé' → indépendant des cadres notes du haut.
        Expanded(
          child: NotesWidget(
            key: ValueKey('summary-canvas-$patientId'),
            patientId: patientId,
            tabKey: 'Résumé',
            title: 'Résumé',
            subtitle: 'Notes libres pour préparer les préconisations.',
            toolset: NoteToolset.advanced,
            mode: NoteCanvasMode.freeform,
            allowPagination: false,
            showText: false,
            showSaveButton: false,
            fillParentHeight: true,
            embedded: false,
          ),
        ),
      ],
    );
  }
}
