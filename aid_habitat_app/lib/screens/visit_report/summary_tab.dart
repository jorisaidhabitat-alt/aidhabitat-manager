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
///
/// Spécificité 2026-05-04 (demande utilisateur) : c'est la SEULE note
/// au format dessin du VAD qui peut être agrandie dans une nouvelle
/// fenêtre browser (comme les notes textuelles). Le callback
/// [onExpandToTab] est fourni par le parent visit_report_screen et
/// déclenche `tryOpenNoteWindow(mode: 'drawing')`.
class SummaryTab extends StatefulWidget {
  final Dossier dossier;

  /// Optionnel — appelé quand l'ergo tape sur le bouton « agrandir »
  /// du NotesWidget canvas. Le parent (visit_report_screen) ouvre alors
  /// la fenêtre détachée en mode drawing. Si null → bouton agrandir
  /// caché.
  final VoidCallback? onExpandToTab;

  const SummaryTab({
    super.key,
    required this.dossier,
    this.onExpandToTab,
  });

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
        //
        // - allowPagination: true → l'ergo peut ajouter / naviguer /
        //   supprimer des pages (jusqu'à `maxPages = 20` par défaut).
        // - onExpandToTab: pris du parent → ouvre la fenêtre browser
        //   détachée en mode drawing (cf. note_window_screen.dart
        //   branche `mode == 'drawing'`).
        // - allowTextModal: true → expose le bouton « agrandir » même
        //   en mode dessin pur (showText=false). Le tap déclenche
        //   onExpandToTab si fourni, sinon ouvre la modale fallback.
        Expanded(
          child: NotesWidget(
            key: ValueKey('summary-canvas-$patientId'),
            patientId: patientId,
            tabKey: 'Résumé',
            title: 'Résumé',
            subtitle: 'Notes libres pour préparer les préconisations.',
            toolset: NoteToolset.advanced,
            mode: NoteCanvasMode.freeform,
            allowPagination: true,
            showText: false,
            allowTextModal: true,
            onExpandToTab: widget.onExpandToTab,
            showSaveButton: false,
            fillParentHeight: true,
            embedded: false,
          ),
        ),
      ],
    );
  }
}
