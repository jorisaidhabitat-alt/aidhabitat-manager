import 'package:flutter/material.dart';
import '../../models/types.dart';
import '../../components/notes_widget.dart';
import '../../components/notes_panel_title_banner.dart';

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

  /// Callback pour les 2 notes texte du haut (« Projet de l'usager »
  /// et « Résumé des préconisations ») — paramètre = tabKey à ouvrir
  /// dans une fenêtre détachée en mode TEXT (vs `onExpandToTab` qui
  /// gère uniquement la note canvas en mode drawing).
  /// Demande utilisateur 2026-05-05 : « projet de l'usager et résumé
  /// des préconisations doivent s'ouvrir dans un nouvel onglet si on
  /// agrandit comme les autres notes de VAD ».
  final void Function(String tabKey)? onExpandTextNote;

  /// Texte courant poussé par la fenêtre détachée pour le cadre
  /// « Projet de l'usager ». Re-rendu à chaque keystroke depuis la
  /// popup pour que le cadre in-app reflète immédiatement la saisie
  /// (demande utilisateur 2026-05-05 : « quand j'écris dans le nouvel
  /// onglet note, il faut également que ça écrive direct dans le
  /// cadre note écrite de l'application »).
  final String? liveTextProjet;

  /// Idem pour le cadre « Résumé des préconisations ».
  final String? liveTextResume;

  /// Callback : quand l'ergo tape dans un cadre note in-app, on
  /// pousse le texte vers la fenêtre détachée si elle est ouverte
  /// (parité avec les autres notes du VAD — cf.
  /// `_pushDraftToOpenWindow` côté visit_report_screen).
  final void Function(String tabKey, String text)? onDraftChange;

  const SummaryTab({
    super.key,
    required this.dossier,
    this.onExpandToTab,
    this.onExpandTextNote,
    this.liveTextProjet,
    this.liveTextResume,
    this.onDraftChange,
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
            // 84 → 138 : libère 50 pt pour la bannière titre (+6 gap)
            // au-dessus de chaque NotesWidget. Demande user 2026-05-15 :
            // les libellés (« Projet de l'usager », « Résumé des
            // préconisations ») passent de hintText en banner permanent
            // fond mauve clair.
            height: 138,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const NotesPanelTitleBanner(
                        title: "Projet de l'usager",
                        attachedToBelow: true,
                      ),
                      Expanded(
                        child: NotesWidget(
                          key: ValueKey('summary-note-projet-$patientId'),
                          patientId: patientId,
                          tabKey: 'Préconisations-Projet',
                          placeholder: '',
                          showCanvas: false,
                          embedded: true,
                          showSaveButton: false,
                          allowPagination: false,
                          allowTextModal: true,
                          // Si le parent a fourni `onExpandTextNote`, le tap
                          // sur agrandir ouvre une fenêtre détachée (parité
                          // avec les notes VAD classiques). Sinon fallback
                          // sur le modal fullscreen in-app.
                          onExpandToTab: widget.onExpandTextNote == null
                              ? null
                              : () => widget.onExpandTextNote!(
                                  'Préconisations-Projet',
                                ),
                          expandModalFullscreen:
                              widget.onExpandTextNote == null,
                          // Sync bi-directionnel avec la fenêtre détachée :
                          // - liveText : reflète chaque keystroke poussé par
                          //   la popup → met à jour le cadre in-app en
                          //   temps réel (fix demande utilisateur 2026-05-05).
                          // - onDraftChange : réciproque — chaque tape dans
                          //   le cadre in-app est poussée vers la popup
                          //   ouverte (`_pushDraftToOpenWindow`).
                          liveText: widget.liveTextProjet,
                          onDraftChange: widget.onDraftChange == null
                              ? null
                              : (draft) => widget.onDraftChange!(
                                  'Préconisations-Projet',
                                  draft.text,
                                ),
                          attachedToTitleBanner: true,
                          fillParentHeight: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const NotesPanelTitleBanner(
                        title: 'Résumé des préconisations',
                        attachedToBelow: true,
                      ),
                      Expanded(
                        child: NotesWidget(
                          key: ValueKey('summary-note-resume-$patientId'),
                          patientId: patientId,
                          tabKey: 'Préconisations-Résumé',
                          placeholder: '',
                          showCanvas: false,
                          embedded: true,
                          showSaveButton: false,
                          allowPagination: false,
                          allowTextModal: true,
                          onExpandToTab: widget.onExpandTextNote == null
                              ? null
                              : () => widget.onExpandTextNote!(
                                  'Préconisations-Résumé',
                                ),
                          expandModalFullscreen:
                              widget.onExpandTextNote == null,
                          liveText: widget.liveTextResume,
                          onDraftChange: widget.onDraftChange == null
                              ? null
                              : (draft) => widget.onDraftChange!(
                                  'Préconisations-Résumé',
                                  draft.text,
                                ),
                          attachedToTitleBanner: true,
                          fillParentHeight: true,
                        ),
                      ),
                    ],
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
