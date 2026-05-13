import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, setEquals;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
// Desktop only (macOS/Windows/Linux). Sur web + mobile, un stub vide est
// importé — les appels sont shuntés par un garde `kIsWeb` avant exécution.
import '../services/multi_window_stub.dart'
    if (dart.library.io) 'package:desktop_multi_window/desktop_multi_window.dart';
// Web-only : window.open + BroadcastChannel pour ouvrir une vraie
// fenêtre browser détachée sur Mac (avec les pastilles natives).
import '../services/note_window_web_stub.dart'
    if (dart.library.html) '../services/note_window_web.dart' as note_window_web;
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../models/visit_report_categories.dart';
import '../services/app_config.dart';
import '../services/connectivity_service.dart';
import '../services/dossier_repository.dart';
import '../services/data_service.dart';
import '../services/report_generation_service.dart';
import '../services/sync_engine.dart';
import '../components/beneficiary_badges.dart';
import '../components/notes_widget.dart';
import '../components/soft_transitions.dart';
import 'visit_report/beneficiary_tab.dart';
import 'visit_report/context_tab.dart';
import 'visit_report/mesures_tab.dart';
import 'visit_report/accessibility_tab.dart';
import 'visit_report/bathroom_tab.dart';
import 'visit_report/wc_tab.dart';
import 'visit_report/photos_tab.dart';
import 'visit_report/recommendations_tab.dart';
import 'visit_report/plans_tab.dart';
import 'visit_report/summary_tab.dart';

/// In-memory cache of the last active tab index per dossier, so navigating
/// away from the visit report and back returns the user to the same tab
/// they were on.
class _VisitReportStateCache {
  _VisitReportStateCache._();
  static final Map<String, int> _tabIndex = {};
  static int getTabIndex(String dossierId) => _tabIndex[dossierId] ?? 0;
  static void setTabIndex(String dossierId, int index) =>
      _tabIndex[dossierId] = index;

  /// Last known size of a detached note OS window, reported by the popup
  /// itself every second. Re-used as the initial size when the user opens
  /// another popup, so resizing one popup "sticks" for subsequent ones.
  static Size lastNoteWindowSize = const Size(520, 480);

  /// Dernière position (origine) d'une fenêtre note OS détachée. `null`
  /// tant qu'on n'a pas reçu de frame (premier usage → position par
  /// défaut 200,200). Conservée en même temps que la taille pour que la
  /// fenêtre rouvre exactement là où l'utilisateur l'avait laissée.
  static Offset? lastNoteWindowOrigin;
}

class VisitReportScreen extends StatefulWidget {
  final Dossier dossier;
  final VoidCallback onBack;

  const VisitReportScreen({
    super.key,
    required this.dossier,
    required this.onBack,
  });

  @override
  State<VisitReportScreen> createState() => _VisitReportScreenState();
}

class _VisitReportScreenState extends State<VisitReportScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final DossierRepository _repository = DossierRepository();
  final DataService _dataService = DataService();
  late Dossier _dossier;
  int _housingVersion = 0;
  // Maps (patientId::tabKey) -> secondary OS windowId, so when the user
  // types in the in-app NotesWidget we can forward the change to the
  // detached window via `pushNote`.
  final Map<String, int> _openNoteWindows = {};
  // Live text pushed from popups per tabKey — fed to NotesWidget as
  // `liveText` so UI updates instantly (no DB round-trip).
  final Map<String, String> _liveText = {};
  // Per-tab debounced DB save timers (one sync_operation per burst of
  // typing rather than one per keystroke).
  final Map<String, Timer> _saveDebounce = {};
  // Sous-section active par onglet — mémorisée lors de la navigation.
  final Map<String, int> _activeSubsectionByTab = {};
  // Numéros médicaux actifs (Pathologie=1, Suivi=2, Sensoriel=3) —
  // affichés en badges au-dessus du canvas de la note "Contexte de vie >
  // Médical". Désormais PAR PAGE : ce `Set` représente seulement les
  // flags de la page de note actuellement visible (NotesWidget pousse
  // les flags à chaque changement de page via `onMedicalFlagsChanged`).
  Set<int> _medicalFlagNumbers = <int>{};

  // Page courante de la note "Contexte de vie > Médical" (1-indexed).
  // Demande utilisateur 2026-05-04 : « il doit y avoir simplement les 3
  // pages déjà présentes avec une avec le numéro 1, une avec le 2 et
  // une avec le 3, cela ne change pas en fonction des éléments cochés à
  // gauche et cela ne doit pas être remis à chaque changement de page ».
  // → On affiche désormais UN SEUL badge égal au numéro de page (fixe
  // par page), au lieu d'un badge composite dérivé des flags cochés à
  // gauche. Cf. `_MedicalPageNumberBadge` plus bas.
  int _medicalCurrentPage = 1;

  /// True quand le bouton « Générer le rapport » est en cours d'appel.
  /// Affiche un spinner et bloque les double-taps.
  ///
  /// 2026-05-11 : ce flag est désormais MIRROIR de l'état du singleton
  /// [ReportGenerationService] (filtré sur le `dossierId` courant).
  /// Permet à l'UI du VisitReportScreen de continuer à montrer "Génération
  /// en cours…" même si l'utilisateur quitte et revient sur le dossier
  /// pendant que la génération tourne en arrière-plan. Demande utilisateur
  /// 2026-05-11 : « Quand je quitte le relevé de visite et que je retourne
  /// dessus, je n'ai plus le load qui indique la generation en cours ».
  bool _isGeneratingReport = false;

  /// Subscription au stream du `ReportGenerationService` pour synchroniser
  /// `_isGeneratingReport` quand l'utilisateur re-mount ce dossier alors
  /// qu'une génération en cours était lancée depuis ce même dossier.
  StreamSubscription<ReportGenerationState>? _reportGenSubscription;

  static const List<String> _tabs = [
    'Bénéficiaire',
    'Contexte de vie',
    'Mesures',
    'Accessibilité',
    'Salle de bain',
    'WC',
    // Plans déplacé juste après WC (demande utilisateur 2026-05-04) :
    // l'ergo dessine les plans du logement immédiatement après
    // l'inspection des sanitaires, avant de passer aux photos puis
    // aux préconisations.
    'Plans',
    // Onglet « Photos » : flow d'observation (SDB/WC) → dessin (Plans)
    // → capture (Photos) → analyse (Résumé) → action (Préconisations).
    // Alimente la page 8 du rapport PDF (« Photos du logement »).
    'Photos',
    // « Résumé » créé 2026-05-04 par split de l'ancien onglet
    // Préconisations (demande utilisateur). Contient les 2 cadres
    // « Projet de l'usager » + « Résumé des préconisations » en haut
    // (tabKeys historiques préservés → page 7 PDF) + canvas pleine
    // page de prise de notes au stylet (tabKey 'Résumé').
    'Résumé',
    // « Préconisations » : ne contient plus que la grille de cartes
    // (les 2 cadres notes ont déménagé dans Résumé). Alimente la
    // page 6 du PDF (« Préconisations »).
    'Préconisations',
  ];

  /// Sous-sections de chaque onglet. Le panneau notes à droite affiche
  /// une note indépendante par sous-section (tabKey = '$tab-$section').
  /// Les onglets absents de cette map (Mesures, Photos, Plans,
  /// Préconisations) sont en pleine largeur et n'ont pas de panneau
  /// notes latéral.
  ///
  /// Cas particulier (demande utilisateur 2026-04-29) : « Salle de bain »
  /// et « WC » partagent désormais une note unique stockée sous le
  /// tabKey [_kSharedSanitairesNotesTabKey], peu importe la sous-section
  /// active. Saisir / supprimer dans l'un est immédiatement répliqué
  /// dans l'autre. Voir [_resolveNotesTabKey] pour la logique de
  /// résolution.
  static const Map<String, List<String>> _tabSubsections = {
    'Bénéficiaire': ['Profil', 'Foyer', 'Santé', 'Admin'],
    'Contexte de vie': ['Médical', 'Autonomie'],
    'Accessibilité': ['Général', 'Extérieur'],
    'Salle de bain': ['Équipements'],
    'WC': ['Config. & équipements'],
  };

  /// TabKey unique pour la note partagée entre les onglets « Salle de
  /// bain » et « WC ». Persistée dans `note_pages.tab_key`. Si tu
  /// renommes ce tabKey, les dossiers existants perdront leur note —
  /// pense à une migration côté `note_repository` (lecture des deux
  /// clés possibles, écriture sur la nouvelle).
  static const String _kSharedSanitairesNotesTabKey = 'Sanitaires-Notes';

  /// TabKey unique pour la note partagée entre les sous-sections de
  /// l'onglet « Accessibilité » (Général / Niveaux / Équipements /
  /// Extérieur). Demande utilisateur 2026-04-29 : « la note ecrite
  /// (comme sanitaire avec wc et salle de bain) doit être associé
  /// entre chaque page de accessibilité ». Le contenu de cette note
  /// alimente le champ « Observations sur l'accessibilité »
  /// (`Observations1`) page 5 du PDF (cf. `fetchVadOverlayNotesForReport`
  /// côté serveur).
  static const String _kSharedAccessibiliteNotesTabKey = 'Accessibilité-Notes';

  /// Calcule le tabKey à utiliser pour le panneau notes. Pour la
  /// majorité des onglets c'est `'$tab-$section'`. Cas spéciaux :
  ///   - Sanitaires (Salle de bain / WC) → [_kSharedSanitairesNotesTabKey]
  ///   - Accessibilité (toutes sous-sections) → [_kSharedAccessibiliteNotesTabKey]
  static String _resolveNotesTabKey(String activeTab, String section) {
    if (activeTab == 'Salle de bain' || activeTab == 'WC') {
      return _kSharedSanitairesNotesTabKey;
    }
    if (activeTab == 'Accessibilité') {
      return _kSharedAccessibiliteNotesTabKey;
    }
    return '$activeTab-$section';
  }

  /// Placeholder à afficher dans le `NotesWidget` du panneau de droite,
  /// aligné sur le LIBELLÉ EXACT de la section correspondante dans le
  /// rapport PDF. Demande utilisateur 2026-04-30 : « pour toutes les
  /// notes ecrites qui sont dans le rapport PDF, le placeholder doit
  /// correspondre à l'espace qu'ils concernent dans le PDF ».
  ///
  /// Utile à l'ergo : avant de saisir, il sait à quoi sa note va
  /// servir dans le rapport final, sans avoir à mémoriser le mapping.
  ///
  /// Mapping (cf. `server/templates/visitReport.mapping.json` et
  /// `server/reports/generateVisitReport.mjs`) :
  ///
  ///   tabKey                       → champ PDF
  ///   ──────────────────────────────────────────────────────────
  ///   Contexte de vie-Médical      → Environnement (page 4)
  ///   Contexte de vie-Autonomie    → Habitudes de vie (page 4)
  ///   Accessibilité-Notes          → Observations sur l'accessibilité
  ///                                  (page 5, champ `Observations1`)
  ///   Sanitaires-Notes             → Observations sur les équipements
  ///                                  et utilisation (page 6, champ `obs`)
  ///   autre                        → null (pas de section PDF dédiée)
  static String? _resolvePlaceholderForTabKey(String tabKey) {
    switch (tabKey) {
      case 'Contexte de vie-Médical':
        return 'Environnement';
      case 'Contexte de vie-Autonomie':
        return 'Habitudes de vie';
      case _kSharedAccessibiliteNotesTabKey:
        return "Observations sur l'accessibilité";
      case _kSharedSanitairesNotesTabKey:
        return 'Observations sur les équipements et utilisation';
      default:
        return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _dossier = widget.dossier;
    final initialTabIndex =
        _VisitReportStateCache.getTabIndex(widget.dossier.id)
            .clamp(0, _tabs.length - 1);
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: initialTabIndex,
    );
    _tabController.addListener(_handleTabChange);
    _refreshDossier();

    // Synchronise l'état "génération en cours" avec le singleton global —
    // si l'utilisateur revient sur ce dossier alors qu'une génération
    // lancée précédemment est encore en train de tourner, on RÉACTIVE
    // l'indicateur de loading du bouton. Bug rapporté 2026-05-11 : « quand
    // je quitte le relevé de visite et que je retourne dessus, je n'ai
    // plus le load qui indique la generation en cours ».
    final initialState = ReportGenerationService.instance.currentState;
    _isGeneratingReport = initialState.inProgress
        && initialState.activeDossierId == widget.dossier.id;
    _reportGenSubscription = ReportGenerationService.instance.stateStream
        .listen((state) {
      if (!mounted) return;
      final mineInProgress = state.inProgress
          && state.activeDossierId == widget.dossier.id;
      if (mineInProgress != _isGeneratingReport) {
        setState(() => _isGeneratingReport = mineInProgress);
      }
    });

    // Pull BULK de toutes les notes du patient — 1 seul HTTP request
    // ramène toutes les pages de tous les onglets (Contexte de vie,
    // Sanitaires-Notes, Préconisations, Plans, etc.) directement en
    // SQLite. Démarre IMMÉDIATEMENT à l'ouverture de l'écran (en
    // parallèle du `_refreshDossier`) pour que les NotesWidget
    // affichent la note dès qu'on arrive sur l'onglet, pas 1-2 s
    // plus tard. Demande utilisateur 2026-05-07 : « les notes
    // écrites doivent arriver en même temps que les autres infos
    // du relevé de visite quand je l'ouvre ».
    //
    // Fire-and-forget : on ne bloque PAS le mount initial. Quand le
    // pull se termine on signale via `_lastNotesBulkAt` → les
    // NotesWidget montés re-fetchent leur page courante depuis
    // SQLite (déjà à jour grâce au merge bulk).
    // ignore: discarded_futures
    _kickInitialNotesBulkPull();

    // Refactor 2026-05-12 : suppression de `enterActiveContext` (le mode
    // pull ultra-actif n'existe plus). L'écran VAD reflète l'état au
    // moment de l'ouverture ; les modifs distantes sont récupérées au
    // prochain événement (foreground/reconnexion/login).

    // Auto-refresh quand un pull workspace arrive depuis l'autre
    // device — sinon les modifs faites sur Mac n'apparaissent pas sur
    // iPad (et inversement) tant que l'écran VAD reste ouvert.
    _syncSubscription = SyncEngine().stateStream.listen((state) {
      if (!mounted) return;
      final at = state.lastSyncAt;
      if (at == null) return;
      if (_lastObservedSyncAt != null && at == _lastObservedSyncAt) return;
      _lastObservedSyncAt = at;
      // ignore: discarded_futures
      _refreshDossier();
    });

    // Migration ponctuelle (demande utilisateur 2026-04-29) : on purge
    // les notes saisies sous les anciens tabKeys « Salle de
    // bain-Équipements » et « WC-Config. & équipements ». Désormais
    // SDB et WC partagent une note unique sous `Sanitaires-Notes` (cf.
    // `_resolveNotesTabKey`). Idempotent : DELETE no-op après la 1ère
    // ouverture du dossier post-déploiement. Fire-and-forget, on ne
    // bloque pas le rendu sur ce nettoyage SQLite local.
    _dataService
        .purgeLegacySanitairesNotes(_dossier.patient.id)
        .then((removed) {
      if (removed > 0) {
        // ignore: avoid_print
        print('[visit_report] purge notes SDB/WC legacy : $removed lignes');
      }
    });

    // Register an IPC handler so detached note OS windows can persist
    // their edits through the main window (they cannot touch SQLite
    // themselves because sqflite is not registered in secondary engines).
    //
    // Sur web : on écoute le BroadcastChannel partagé (cf.
    // `note_window_web.dart`) — la 2ème fenêtre browser y poste les
    // mêmes méthodes (`liveNote`, `reportNoteFrame`) que sur natif.
    // Sur natif desktop : on monte le handler via DesktopMultiWindow.
    void handleIpc(String method, Map<String, dynamic> args) {
      switch (method) {
        case 'liveNote':
          final patientId = args['patientId']?.toString() ?? '';
          final tabKey = args['tabKey']?.toString() ?? '';
          final text = args['text']?.toString() ?? '';
          final flush = args['flush'] == true;
          if (mounted) {
            setState(() {
              _liveText['${patientId}::$tabKey'] = text;
            });
          }
          final key = '${patientId}::$tabKey';
          _saveDebounce[key]?.cancel();
          if (flush) {
            _persistNoteText(patientId, tabKey, text);
          } else {
            // Debounce 150 ms (vs 400 ms historique) — demande
            // utilisateur 2026-05-06 : la note écrite doit apparaitre
            // sur l'autre device quasi-instantanément. 150 ms reste
            // assez pour collapser la frappe (≥2 keystrokes typiques).
            _saveDebounce[key] = Timer(
              const Duration(milliseconds: 150),
              () => _persistNoteText(patientId, tabKey, text),
            );
          }
          break;
        case 'reportNoteSize':
          final w = (args['width'] as num?)?.toDouble();
          final h = (args['height'] as num?)?.toDouble();
          if (w != null && h != null && w > 100 && h > 100) {
            _VisitReportStateCache.lastNoteWindowSize = Size(w, h);
          }
          break;
        case 'reportNoteFrame':
          final x = (args['x'] as num?)?.toDouble();
          final y = (args['y'] as num?)?.toDouble();
          final w = (args['width'] as num?)?.toDouble();
          final h = (args['height'] as num?)?.toDouble();
          if (w != null && h != null && w > 100 && h > 100) {
            _VisitReportStateCache.lastNoteWindowSize = Size(w, h);
          }
          if (x != null && y != null) {
            _VisitReportStateCache.lastNoteWindowOrigin = Offset(x, y);
          }
          break;
      }
    }

    if (kIsWeb) {
      _ipcSubscription = note_window_web.listenNoteIpc(handleIpc);
      return;
    }
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      handleIpc(call.method, args);
    });
  }

  /// Subscription au BroadcastChannel web — annulée au dispose pour
  /// éviter de leak un listener si l'écran est navigué hors stack.
  StreamSubscription<dynamic>? _ipcSubscription;

  /// Subscription au `SyncEngine.stateStream` — quand un pull workspace
  /// vient de se terminer (lastSyncAt change), on re-fetch le dossier
  /// depuis SQLite pour propager les modifs faites sur l'autre device
  /// (Mac ↔ iPad). Sans ça, l'écran VAD restait sur le snapshot du
  /// moment de l'ouverture (symptôme reporté 2026-05-06 : date de
  /// naissance + notes BALS Joris non synchronisées).
  StreamSubscription<SyncEngineState>? _syncSubscription;
  DateTime? _lastObservedSyncAt;

  /// Merges the new text into the existing `drawing_json` (preserving
  /// strokes) and persists it via DataService, which also enqueues a
  /// sync_operation so NocoDB receives the change.
  Future<void> _persistNoteText(
      String patientId, String tabKey, String text) async {
    final existingJson = await _dataService.fetchNoteDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: 0,
    );
    List<dynamic> strokes = const [];
    if (existingJson != null && existingJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(existingJson);
        if (decoded is Map<String, dynamic>) {
          // Short-circuit if nothing actually changed — avoids spamming
          // sync_operations while the user pauses typing.
          if (decoded['text']?.toString() == text) return;
          strokes = (decoded['strokes'] as List?) ?? const [];
        }
      } catch (_) {}
    }
    final merged = jsonEncode({
      'version': 1,
      'text': text,
      'strokes': strokes,
    });
    await _dataService.saveNoteDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: 0,
      drawingJson: merged,
    );
  }

  /// Called by ContextTab when the user toggles a numbered medical flag
  /// (Pathologie=1, Suivi médical=2, Sensoriel=3). Met à jour
  /// [_medicalFlagNumbers] — la nouvelle valeur est propagée à NotesWidget
  /// via la prop `medicalFlags` et sauvegardée dans la page courante.
  Future<void> _handleMedicalFlagToggle(int flagNumber, bool checked) async {
    if (!mounted) return;
    final next = Set<int>.from(_medicalFlagNumbers);
    if (checked) {
      next.add(flagNumber);
    } else {
      next.remove(flagNumber);
    }
    setState(() => _medicalFlagNumbers = next);
  }

  /// Appelé par NotesWidget (via `onMedicalFlagsChanged`) lorsqu'il
  /// change de page ou finit de charger. Remplace [_medicalFlagNumbers]
  /// par les flags stockés pour la page désormais visible → les cases à
  /// cocher (ContextTab) et les badges canvas s'ajustent automatiquement.
  void _handleMedicalFlagsFromNotes(Set<int> flagsForPage) {
    if (!mounted) return;
    if (setEquals(flagsForPage, _medicalFlagNumbers)) return;
    setState(() => _medicalFlagNumbers = {...flagsForPage});
  }

  /// Extracts the `text` field from a drawing_json payload. Returns empty
  /// string if the JSON is missing / malformed.
  String _extractTextFromDrawingJson(String? json) {
    if (json == null || json.isEmpty) return '';
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        return decoded['text']?.toString() ?? '';
      }
    } catch (_) {}
    return '';
  }

  /// Web fallback : ouvre un modal plein écran qui édite la même note.
  /// Les changements sont propagés en live dans le `NotesWidget` via le
  /// même mécanisme `liveText`, et persistés toutes les 400 ms via le
  /// pipeline `_persistNoteText`.
  Future<void> _openNoteModalFallback(String sourceTab) async {
    final existingJson = await _dataService.fetchNoteDrawingJson(
      patientId: _dossier.patient.id,
      tabKey: sourceTab,
      pageNumber: 0,
    );
    final initialText = _extractTextFromDrawingJson(existingJson);
    if (!mounted) return;
    await showSoftDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final controller = TextEditingController(text: initialText);
        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            width: 720,
            height: 520,
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Note — $sourceTab',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF2B323A),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: controller,
                      maxLines: null,
                      expands: true,
                      autofocus: true,
                      textAlignVertical: TextAlignVertical.top,
                      style:
                          const TextStyle(fontSize: 14, height: 1.5),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Écrivez votre note…',
                      ),
                      onChanged: (text) {
                        if (!mounted) return;
                        setState(() {
                          _liveText[
                                  '${_dossier.patient.id}::$sourceTab'] =
                              text;
                        });
                        final key = '${_dossier.patient.id}::$sourceTab';
                        _saveDebounce[key]?.cancel();
                        // Debounce 150 ms — cohérent avec le handler
                        // IPC `liveNote` ci-dessus (2026-05-06).
                        _saveDebounce[key] = Timer(
                          const Duration(milliseconds: 150),
                          () => _persistNoteText(
                              _dossier.patient.id, sourceTab, text),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Forwards an in-app note draft to the detached OS window (if open)
  /// so typing in the sidebar is mirrored in real time in the popup.
  ///
  /// Sur web : broadcast à toutes les fenêtres du même origin via le
  /// canal `aidhabitat-note-ipc`. La fenêtre détachée se filtre elle-
  /// même par patientId+tabKey (cf. note_window_screen.dart).
  ///
  /// Sur natif : DesktopMultiWindow.invokeMethod ciblé par windowId.
  void _pushDraftToOpenWindow(String tabKey, String text) {
    final patientId = _dossier.patient.id;
    if (kIsWeb) {
      note_window_web.sendNoteIpc(
        method: 'pushNote',
        args: {'patientId': patientId, 'tabKey': tabKey, 'text': text},
      );
      return;
    }
    final key = '$patientId::$tabKey';
    final windowId = _openNoteWindows[key];
    if (windowId == null) return;
    DesktopMultiWindow.invokeMethod(windowId, 'pushNote', {
      'patientId': patientId,
      'tabKey': tabKey,
      'text': text,
    }).catchError((_) {
      // The user probably closed the window — drop the entry so we stop
      // trying to talk to it.
      _openNoteWindows.remove(key);
    });
  }

  @override
  void dispose() {
    for (final t in _saveDebounce.values) {
      t.cancel();
    }
    _saveDebounce.clear();
    _ipcSubscription?.cancel();
    _ipcSubscription = null;
    _syncSubscription?.cancel();
    _syncSubscription = null;
    _reportGenSubscription?.cancel();
    _reportGenSubscription = null;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (!mounted) return;
    _VisitReportStateCache.setTabIndex(_dossier.id, _tabController.index);
    setState(() {});
  }

  /// Compteur incrémenté à chaque pull bulk de notes terminé. Passé en
  /// prop au `NotesWidget` (`externalRefreshToken`) → le widget
  /// déclenche `_reloadCurrentPageFromStore()` quand il change, ce qui
  /// re-lit SQLite (désormais à jour grâce au merge bulk) et affiche
  /// la note. Le mécanisme `externalRefreshToken` existe déjà — on
  /// l'utilise au lieu d'inventer un nouveau canal.
  int _notesBulkPullToken = 0;

  /// Pull bulk des notes — fire-and-forget depuis `initState`. Quand
  /// la requête se termine, on incrémente [_notesBulkPullToken] →
  /// chaque NotesWidget monté reçoit le nouveau token via build et
  /// se rafraîchit depuis SQLite.
  Future<void> _kickInitialNotesBulkPull() async {
    final patientId = _dossier.patient.id;
    if (patientId.isEmpty) return;
    final merged = await _dataService.refreshAllNotePagesForPatient(patientId);
    if (!mounted) return;
    if (merged > 0) {
      setState(() {
        _notesBulkPullToken += 1;
      });
    }
  }

  /// Re-fetches the dossier from the local database and updates state.
  /// Called after any tab saves, so every other tab sees fresh patient /
  /// housing / dossier fields on the next rebuild.
  Future<void> _refreshDossier() async {
    final fresh = await _repository.fetchDossierById(widget.dossier.id);
    if (!mounted || fresh == null) return;
    // Always setState — the rebuild cost is minimal and it guarantees
    // that per-occupant fields (homeHelp, apa, invalidity, fiscalRevenue
    // inside occupants_json, …) reach the Contexte de vie tab so "Aide
    // humaine" checkboxes appear/disappear the moment the user toggles
    // "Aide à domicile" in the Santé tab.
    setState(() => _dossier = fresh);
    // Note : les flags médicaux sont désormais stockés PAR PAGE dans
    // `drawing_json` (via NotesWidget), et non plus dérivés du dossier.
    // Aucun sync à faire ici — NotesWidget émet les flags de sa page
    // courante via onMedicalFlagsChanged après chargement.
  }

  /// Opens the current tab's note in a SEPARATE OS window that the user
  /// can drag anywhere on their screen (even outside the Flutter app).
  /// Text is persisted to the shared SQLite file so both windows stay in
  /// sync via the 1-second polling in [NoteWindowScreen].
  Future<void> _openNoteInSeparateWindow(String sourceTab) async {
    final patientId = _dossier.patient.id;
    final existingJson = await _dataService.fetchNoteDrawingJson(
      patientId: patientId,
      tabKey: sourceTab,
      pageNumber: 0,
    );
    final initialText = _extractTextFromDrawingJson(existingJson);

    // Sur web : on tente d'ouvrir une VRAIE fenêtre browser détachée
    // (popup window avec les pastilles macOS rouge/jaune/vert). Marche
    // sur Chrome/Safari desktop. Sur iPad PWA, `tryOpenNoteWindow`
    // retourne false (touchscreen détecté) → on retombe sur le modal
    // in-app, plus adapté au format tactile.
    if (kIsWeb) {
      final size = _VisitReportStateCache.lastNoteWindowSize;
      final opened = note_window_web.tryOpenNoteWindow(
        patientId: patientId,
        tabKey: sourceTab,
        title: 'Note — $sourceTab',
        initialText: initialText,
        defaultWidth: size.width,
        defaultHeight: size.height,
        // Bootstrap auth pour la popup — sans ça, mode `drawing`
        // démarrait avec AppConfig vide → 401 sur tous les calls API.
        apiBaseUrl: AppConfig.apiBaseUrl,
        appSessionToken: AppConfig.appSessionToken,
      );
      if (!opened) {
        _openNoteModalFallback(sourceTab);
        return;
      }
      // Seed live text dans le state local pour que la fenêtre
      // principale affiche immédiatement le contenu (mirroir de la
      // fenêtre détachée). L'IPC BroadcastChannel prendra le relais
      // dès que la fenêtre détachée est prête.
      _liveText['${patientId}::$sourceTab'] = initialText;
      return;
    }

    // Native (Flutter desktop) : passe par le plugin
    // `desktop_multi_window` qui spawn un 2ème engine Flutter dans une
    // NSWindow secondaire.
    final payload = jsonEncode({
      'patientId': patientId,
      'tabKey': sourceTab,
      'title': 'Note — $sourceTab',
      'initialText': initialText,
    });
    final window = await DesktopMultiWindow.createWindow(payload);
    _openNoteWindows['${patientId}::$sourceTab'] = window.windowId;
    _liveText['${patientId}::$sourceTab'] = initialText;
    final origin = _VisitReportStateCache.lastNoteWindowOrigin
        ?? const Offset(200, 200);
    window
      ..setFrame(origin & _VisitReportStateCache.lastNoteWindowSize)
      ..setTitle('Note — $sourceTab')
      ..show();
  }

  /// Variante drawing de [_openNoteInSeparateWindow] — utilisée
  /// uniquement pour le canvas pleine page de l'onglet Résumé
  /// (demande utilisateur 2026-05-04 : seule note dessin VAD à pouvoir
  /// s'agrandir dans une fenêtre browser détachée). La 2e fenêtre
  /// rendra un NotesWidget canvas (toolset advanced + freeform +
  /// pagination) au lieu du TextField text-only — cf. branche
  /// `mode == 'drawing'` côté `note_window_screen.dart`.
  ///
  /// Persistance : pas d'IPC pour les strokes (volume trop élevé). La
  /// 2e fenêtre lit/écrit directement dans l'IndexedDB partagé via une
  /// init minimale de databaseFactory + DataService (sans SyncEngine).
  /// La fenêtre principale voit les changements au prochain reload du
  /// dossier (ou au switch d'onglet, qui re-fetch les notes).
  Future<void> _openDrawingNoteInSeparateWindow(String sourceTab) async {
    final patientId = _dossier.patient.id;

    if (kIsWeb) {
      final size = _VisitReportStateCache.lastNoteWindowSize;
      final opened = note_window_web.tryOpenNoteWindow(
        patientId: patientId,
        tabKey: sourceTab,
        title: 'Résumé — dessin',
        // initialText vide : en mode drawing on ne charge pas de texte
        // (la 2e fenêtre lit le drawing JSON directement depuis SQLite).
        initialText: '',
        defaultWidth: size.width,
        defaultHeight: size.height,
        mode: 'drawing',
        // Bootstrap auth — critique en mode drawing car la popup
        // appelle DataService.fetch/saveNoteDrawingJson directement
        // (et donc le backend si SQLite remote sync est nécessaire).
        apiBaseUrl: AppConfig.apiBaseUrl,
        appSessionToken: AppConfig.appSessionToken,
      );
      if (!opened) {
        // Pas de fallback modal pour le moment : le mode drawing en
        // popup browser est la seule cible supportée (Mac desktop).
        // Sur iPad PWA (touchscreen détecté) → on ne fait rien, l'ergo
        // continue d'éditer dans le canvas inline.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Agrandissement disponible uniquement sur navigateur '
              'desktop (Mac/PC). Sur iPad, utilisez le canvas inline.',
            ),
          ),
        );
      }
      return;
    }

    // Native macOS — passe par DesktopMultiWindow comme la version texte.
    final payload = jsonEncode({
      'patientId': patientId,
      'tabKey': sourceTab,
      'title': 'Résumé — dessin',
      'initialText': '',
      'mode': 'drawing',
    });
    final window = await DesktopMultiWindow.createWindow(payload);
    final origin = _VisitReportStateCache.lastNoteWindowOrigin
        ?? const Offset(200, 200);
    window
      ..setFrame(origin & _VisitReportStateCache.lastNoteWindowSize)
      ..setTitle('Résumé — dessin')
      ..show();
  }

  /// Bumps the housing version to trigger a re-derivation of Salle de
  /// bain / WC instances from the fresh Accessibilité selections.
  void _notifyHousingChanged() {
    if (!mounted) return;
    setState(() => _housingVersion++);
  }

  /// Panneau notes à droite : une seule note affichée à la fois, synchronisée
  /// avec la sous-section sélectionnée côté formulaire (gauche) — le
  /// sélecteur de sous-section au-dessus du canvas a été retiré pour
  /// éviter le doublon avec les pills Profil/Foyer/Santé/Admin dans le
  /// formulaire lui-même.
  Widget _buildNotesPanel(String activeTab, List<String> subsections) {
    final activeIdx = _activeSubsectionByTab[activeTab] ?? 0;
    final safeIdx = activeIdx.clamp(0, subsections.length - 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Note de la sous-section active ─────────────────────────────
        // Toutes les notes de l'onglet sont gardées vivantes dans un
        // Stack pour préserver l'état de dessin (un trait en cours n'est
        // pas perdu en switchant Profil ↔ Foyer). Chaque couche est
        // animée en fade + apparition vers le haut quand elle devient
        // active — même grammaire que les sous-sections du formulaire
        // à gauche, pour que l'utilisateur sente que le contenu vient
        // de changer.
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: List.generate(subsections.length, (i) {
              final section = subsections[i];
              final tabKey = _resolveNotesTabKey(activeTab, section);
              final liveKey = '${_dossier.patient.id}::$tabKey';
              final isMedical = tabKey == 'Contexte de vie-Médical';
              final isActive = i == safeIdx;
              final pdfPlaceholder = _resolvePlaceholderForTabKey(tabKey);
              return _NotesPanelLayer(
                isActive: isActive,
                child: NotesWidget(
                  key: ValueKey(liveKey),
                  patientId: _dossier.patient.id,
                  tabKey: tabKey,
                  title: section,
                  // Placeholder = libellé exact de la section PDF (cf.
                  // `_resolvePlaceholderForTabKey`). Si la note ne sert
                  // pas un champ PDF (ex. sous-sections Bénéficiaire),
                  // on retombe sur le label de la sous-section.
                  placeholder: pdfPlaceholder ?? section,
                  liveText: _liveText[liveKey],
                  // Token incrémenté quand le pull bulk des notes
                  // termine — déclenche `_reloadCurrentPageFromStore`
                  // côté NotesWidget pour afficher la note fraîche
                  // depuis SQLite (déjà mergée par le pull bulk).
                  externalRefreshToken: _notesBulkPullToken,
                  onDraftChange: (draft) =>
                      _pushDraftToOpenWindow(tabKey, draft.text),
                  onExpandToTab: () => _openNoteInSeparateWindow(tabKey),
                  showSaveButton: false,
                  embedded: false,
                  fillParentHeight: true,
                  allowPagination: true,
                  stackedCards: true,
                  // Médical : 3 pages fixes, chaque page affiche son
                  // numéro (1/2/3) en background. Plus aucun couplage
                  // avec les checkboxes à gauche (Pathologie / Suivi /
                  // Sensoriel) — celles-ci gardent leur état interne via
                  // `medicalFlags` mais ne pilotent plus l'overlay.
                  // Cf. `_MedicalPageNumberBadge` + `_medicalCurrentPage`
                  // (demande utilisateur 2026-05-04).
                  totalPages: isMedical ? 3 : 1,
                  backgroundContent: isMedical
                      ? _MedicalPageNumberBadge(
                          currentPage: _medicalCurrentPage,
                        )
                      : null,
                  onPageChange: isMedical
                      ? (page) {
                          // `page` est 0-indexé côté NotesWidget, on le
                          // convertit en 1-indexé pour l'affichage.
                          if (!mounted) return;
                          setState(() => _medicalCurrentPage = page + 1);
                        }
                      : null,
                  medicalFlags: isMedical ? _medicalFlagNumbers : null,
                  onMedicalFlagsChanged:
                      isMedical ? _handleMedicalFlagsFromNotes : null,
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 60,
      // Fond blanc retiré (demande utilisateur 2026-04-28 : « pour la
      // barre de navigation dans le relevé de visite, retire le fond
      // blanc »). On garde le borderRadius pour l'indicateur d'onglet
      // actif (qui lui reste en violet pâle) — pas d'effet visuel
      // quand la couleur est transparente.
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(50),
      ),
      // Le pill blanc de la barre de navigation contient désormais à
      // la fois la TabBar (gauche, scrollable) ET le bouton « Générer
      // le rapport » (droite, dernière entrée). On utilise un Row :
      // - `Expanded(TabBar)` prend toute la place restante
      // - `_buildGenerateReportButton()` est posé en bout, séparé par
      //   un padding vertical pour s'aligner avec les onglets.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              // Indicateur d'onglet actif : SIMPLE TRAIT VIOLET FONCÉ en
              // bas, qui s'étend sur TOUTE la largeur cliquable du
              // bouton (label + labelPadding inclus).
              //
              // Demande utilisateur 2026-04-28 :
              //   - « supprime le violet clair des boutons quand ils
              //    sont selectionnés » → plus de pill BoxDecoration
              //    violet pâle (#EDE8F5).
              //   - « agrandis la ligne sous les textes pour qu'il
              //    prenne toute la largeur de la partie cliquable du
              //    bouton » → UnderlineTabIndicator + TabBarIndicatorSize.tab
              //    qui couvre exactement la zone cliquable de chaque
              //    onglet, contrairement à .label qui n'aurait couvert
              //    que la largeur du mot.
              // Refonte 2026-05-13 : indicator mauve-500 du nouveau
              // design system (au lieu du legacy #7C6DAA).
              indicator: const UnderlineTabIndicator(
                borderSide: BorderSide(
                  color: Color(0xFF8B6FA0), // mauve-500
                  width: 1.5,
                ),
                insets: EdgeInsets.zero,
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              indicatorPadding: EdgeInsets.zero,
              // Couleurs labels : mauve-700 pour l'actif, ink-500 pour
              // les inactifs (tokens du nouveau design).
              labelColor: const Color(0xFF554265), // mauve-700
              unselectedLabelColor: const Color(0xFF5C6670), // ink-500
              labelStyle: const TextStyle(fontWeight: FontWeight.w600),
              unselectedLabelStyle:
                  const TextStyle(fontWeight: FontWeight.w500),
              labelPadding: const EdgeInsets.symmetric(horizontal: 16),
              tabs: List.generate(_tabs.length, (i) {
                final label = _tabs[i];
                // Plus de Container underline manuel : le trait est
                // dessiné par UnderlineTabIndicator côté TabBar
                // (mécanique native Flutter), avec la bonne largeur
                // « tab clickable » automatiquement.
                return Tab(
                  child: SoftTapScale.passThrough(
                    child: Text(label),
                  ),
                );
              }),
              dividerColor: Colors.transparent,
              padding: const EdgeInsets.all(4),
              tabAlignment: TabAlignment.start,
              overlayColor: WidgetStateProperty.all(Colors.transparent),
              splashFactory: NoSplash.splashFactory,
            ),
          ),
          // Séparateur visuel discret entre les onglets et l'action
          // « Générer le rapport ». Trait fin slate-200 vertical.
          Container(
            width: 1,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: const Color(0xFFE4E7EB), // ink-200
          ),
          // Bouton d'action en bout de barre — dernière entrée, intégré
          // dans le même pill blanc que les onglets.
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 6),
            child: _buildGenerateReportButton(),
          ),
        ],
      ),
    );
  }

  Widget _buildBackButton() {
    return InkWell(
      onTap: widget.onBack,
      borderRadius: BorderRadius.circular(50),
      child: Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: const Icon(
          LucideIcons.arrowLeft,
          color: Colors.black87,
        ),
      ),
    );
  }

  /// Bouton violet « Générer le rapport » — dernière entrée de la
  /// barre de navigation des onglets (cf. `_buildTabBar`).
  /// Appelle [_generateReport] qui invoque le serveur, récupère le
  /// PDF et le pousse vers le téléchargement local (web) ou la
  /// boîte « Enregistrer sous » / partage natif (iOS/Android/macOS).
  ///
  /// Pas d'icône (demande utilisateur — le label se suffit à
  /// lui-même dans le contexte de la barre de nav). Pendant
  /// l'appel : un spinner blanc remplace le label et le tap est
  /// neutralisé pour éviter les double-clics.
  /// Bouton compact (icône seule) pour générer le rapport. Demande
  /// utilisateur 2026-05-04 : « change le texte génerer dans le
  /// bouton pour un icon téléchargement ». État loading : spinner
  /// blanc à la place de l'icône, le tap est neutralisé.
  Widget _buildGenerateReportButton() {
    return Tooltip(
      message: _isGeneratingReport
          ? 'Génération en cours…'
          : 'Générer le rapport',
      child: InkWell(
        onTap: _isGeneratingReport ? null : _generateReport,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          // Carré ~44×44 (= hauteur de l'ancienne pill) pour rester
          // tactile-friendly sur iPad. Centre l'icône dans la pastille
          // ronde violette.
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _isGeneratingReport
                ? const Color(0xFF9888B5)
                : const Color(0xFF8B6FA0),
            borderRadius: BorderRadius.circular(999),
          ),
          alignment: Alignment.center,
          child: _isGeneratingReport
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Icon(
                  LucideIcons.download,
                  size: 20,
                  color: Colors.white,
                ),
        ),
      ),
    );
  }

  /// Déclenche la génération du PDF côté serveur, puis l'insère
  /// directement dans l'espace **Documents** du dossier (tag
  /// "Rapport") — la sync engine se charge ensuite de pousser le
  /// fichier vers NocoDB. Plus de download local ni de Drive : le
  /// rapport vit désormais comme n'importe quel document du
  /// dossier, accessible depuis l'écran Documents pour preview /
  /// téléchargement / suppression.
  Future<void> _generateReport() async {
    if (_isGeneratingReport) return;
    // Bloque aussi si une autre génération tourne (même autre dossier)
    // pour éviter de saturer Vercel avec 2-3 PDFs en parallèle (~30 s
    // CPU chacun). Le bouton reste cliquable mais le user verra le
    // bandeau global "génération en cours" lui dire d'attendre.
    if (ReportGenerationService.instance.currentState.inProgress) {
      _showReportError(
        'Une autre génération de rapport est déjà en cours, '
        'patientez quelques secondes avant de relancer.',
      );
      return;
    }
    final patientLabel = [
      _dossier.patient.lastName.toUpperCase(),
      _dossier.patient.firstName,
    ].where((s) => s.trim().isNotEmpty).join(' ').trim();

    // Validation amont : vérifie que les champs critiques sont remplis.
    // Si certains manquent, ouvre une popup avec la liste + 2 actions :
    //   - « Valider » → continue la génération malgré tout
    //   - « Remplir les champs » → bascule sur l'onglet du 1er champ
    //     manquant et abort la génération.
    // Demande utilisateur 2026-04-30.
    //
    // IMPORTANT : on rafraîchit `_dossier` AVANT le check, sinon les
    // saves récents (chauffage, volets, typology, surface…) faits dans
    // les onglets ne sont pas visibles via `_dossier.housing` (qui est
    // un snapshot pris à l'ouverture de l'écran). Sans ce refresh, des
    // champs effectivement remplis apparaissent comme manquants dans la
    // popup. Seul l'onglet Bénéficiaire déclenche `onPatientChanged →
    // _refreshDossier` après save ; les autres onglets persistent
    // directement en SQLite via leur propre `_save()`. On force ici un
    // re-fetch pour aligner le modèle in-memory avec le disque.
    await _refreshDossier();
    final missing = await _collectMissingFields();
    if (missing.isNotEmpty) {
      final shouldContinue = await _showMissingFieldsDialog(missing);
      if (shouldContinue != true) {
        // L'utilisateur a choisi « Remplir les champs » (ou fermé la
        // popup) → on a déjà navigué vers le 1er champ manquant.
        return;
      }
    }

    // Notifie le service global → indicateur de loading visible depuis
    // n'importe quel écran (dashboard, autre dossier, documents, etc.)
    // et persistant si l'utilisateur revient sur ce dossier.
    ReportGenerationService.instance.notifyStart(
      dossierId: _dossier.id,
      patientLabel: patientLabel,
    );

    // Détection offline en amont : si la connectivité est perdue, on
    // ne tente même pas la génération online (qui finirait en timeout
    // 60s et frustration). On enqueue directement la génération
    // différée ; le sync engine la drainera dès le retour réseau.
    if (ConnectivityService().isOffline) {
      await _enqueueReportForLater(
        reason:
            'Hors ligne — votre rapport sera généré automatiquement '
            'dès la prochaine connexion.',
      );
      // Marque l'event "différé" comme un échec spécifique pour que
      // l'overlay global affiche le snackbar adapté.
      ReportGenerationService.instance.notifyFailure(
        ReportGenerationFailure(
          dossierId: _dossier.id,
          patientLabel: patientLabel,
          message: 'Hors ligne — rapport ajouté à la file d\'attente.',
          deferred: true,
          occurredAt: DateTime.now(),
        ),
      );
      return;
    }

    try {
      // Note : plus de settle delay ici depuis que `kSaveDebounceText`
      // est à 0 ms. Chaque keystroke a déjà écrit en SQLite + enqueued
      // sa sync_op, donc `runSync()` plus bas verra TOUTES les modifs
      // en attente, même celles tapées la milliseconde précédente.

      // 1. Force-push de la liste de préconisations LOCALE vers
      //    NocoDB. Le PUT côté serveur fait un "wipe and replace"
      //    (cf. /api/visit-recommendations/:dossierId), donc si l'ergo
      //    a supprimé une reco en local sans déclencher de save (ex:
      //    cache local nettoyé, ou bug de debounce), NocoDB peut
      //    encore avoir des recos fantômes — qui finissent dans le
      //    rapport PDF (symptôme reporté : "barre de redressement lit
      //    visible sur le rapport alors qu'il n'y en a aucune sur
      //    l'app"). On force ici un PUT du contenu local courant
      //    (potentiellement vide) pour aligner NocoDB sur la vérité
      //    locale avant que le serveur ne lise les recos.
      try {
        final localRecos =
            await _repository.fetchVisitRecommendations(_dossier.id);
        await _repository.saveVisitRecommendations(_dossier.id, localRecos);
      } catch (_) {
        // Pas bloquant : si la fetch/save échoue, on tombe sur
        // l'ancienne sémantique (NocoDB tel quel).
      }

      // 2. Pousse les changements locaux EN ATTENTE vers NocoDB AVANT
      // d'appeler le serveur de génération PDF — sinon le serveur lit
      // `getDossiersForApp` (NocoDB direct) et reçoit l'ancienne valeur
      // pour les champs récemment modifiés.
      //
      // Si la sync échoue (réseau KO, timeout, 5xx), on bascule sur la
      // génération différée plutôt que d'aborter sec : le sync engine
      // prendra le relais dès la prochaine fenêtre de connectivité
      // stable et pousera D'ABORD les modifs locales en attente, PUIS
      // déclenchera la génération du rapport. Garantit que le rapport
      // contient toujours les dernières données saisies.
      try {
        final syncResult = await _dataService.runSync();
        // ignore: avoid_print
        print('[report] runSync : pushed=${syncResult.pushedOperations} '
            'failed=${syncResult.failedOperations} '
            'conflicts=${syncResult.conflictCount} '
            'msg="${syncResult.message}"');
        if (syncResult.conflictCount > 0) {
          // Conflits = action utilisateur requise (résolution manuelle).
          // Pas un cas pour la queue offline — on remonte l'erreur.
          _showReportError(
            'Synchronisation incomplète : ${syncResult.conflictCount} '
            'conflit(s) à résoudre avant de pouvoir générer le rapport.',
          );
          ReportGenerationService.instance.notifyFailure(
            ReportGenerationFailure(
              dossierId: _dossier.id,
              patientLabel: patientLabel,
              message: 'Conflits à résoudre avant génération.',
              occurredAt: DateTime.now(),
            ),
          );
          return;
        }
        if (syncResult.failedOperations > 0) {
          // Échec transitoire (réseau, 5xx serveur) → queue différée.
          await _enqueueReportForLater(
            reason:
                'Synchronisation interrompue '
                '(${syncResult.failedOperations} échec(s)) — votre '
                'rapport sera généré automatiquement à la prochaine '
                'reprise de la sync.',
          );
          ReportGenerationService.instance.notifyFailure(
            ReportGenerationFailure(
              dossierId: _dossier.id,
              patientLabel: patientLabel,
              message: 'Sync interrompue — rapport en attente.',
              deferred: true,
              occurredAt: DateTime.now(),
            ),
          );
          return;
        }
      } catch (error) {
        // runSync a levé : très probablement perte de connectivité
        // entre le check `isOffline` initial et le push. Queue.
        await _enqueueReportForLater(
          reason:
              'Connexion perdue pendant la synchronisation — votre '
              'rapport sera généré automatiquement dès le retour '
              'réseau.',
        );
        ReportGenerationService.instance.notifyFailure(
          ReportGenerationFailure(
            dossierId: _dossier.id,
            patientLabel: patientLabel,
            message: 'Connexion perdue — rapport en attente.',
            deferred: true,
            occurredAt: DateTime.now(),
          ),
        );
        return;
      }

      // 3. Génération online : on télécharge le PDF synchroneously
      // pour pouvoir l'afficher tout de suite dans Documents.
      final ({
        Uint8List bytes,
        String fileName,
        Map<String, dynamic>? stats,
        String? savedDocUuid,
      }) result;
      try {
        result = await _dataService.downloadVisitReport(
          dossierId: _dossier.id,
        );
      } catch (error) {
        // Échec de l'appel /api/reports/visit/:dossierId (timeout,
        // 5xx, 502 Vercel cold start, etc.) → queue différée. Ne pas
        // abandonner le travail de l'ergo qui voit son clic « Générer »
        // disparaître dans le vide.
        await _enqueueReportForLater(
          reason:
              'Le serveur n\'a pas pu générer le rapport tout de suite '
              ': $error\nIl sera retenté automatiquement.',
        );
        // Message plus parlant pour l'ergo : on précise que le retry
        // est automatique + qu'un rappel apparaîtra quand ce sera prêt.
        // L'erreur technique brute est sauvegardée dans la sync_op
        // (last_error) pour debug, mais on n'inflige pas son contenu à
        // l'utilisateur. Demande utilisateur 2026-05-11 : « j'ai juste
        // 'Serveur indisponible — rapport en attente' et je ne sais
        // pas si ça va se débloquer ».
        ReportGenerationService.instance.notifyFailure(
          ReportGenerationFailure(
            dossierId: _dossier.id,
            patientLabel: patientLabel,
            message: 'Rapport mis en file d\'attente — réessai automatique. '
                'Le bandeau vert s\'affichera dès qu\'il sera prêt.',
            deferred: true,
            occurredAt: DateTime.now(),
          ),
        );
        return;
      }

      // Insertion dans l'espace Documents du dossier.
      //
      // ⚠️ DEUX CHEMINS selon que le serveur a sauvegardé le PDF
      // directement dans NocoDB (header `X-Saved-Doc-Uuid` non vide)
      // ou non :
      //
      //   - SI savedDocUuid présent : on insère localement comme
      //     `synced` (no upload queued). Évite le 413 Vercel sur le
      //     re-upload du PDF (limite ~4.5 MB Hobby) qui faisait que
      //     le rapport restait stuck local-only forever. Le doc est
      //     déjà côté serveur, on partage juste la même vérité.
      //
      //   - SINON (compat) : ancien chemin `importDocumentBytes` qui
      //     queue un upload. Sert si le serveur n'a pas pu sauvegarder
      //     (rare — limite 5 MB interne, erreur réseau NocoDB).
      final patientId = _dossier.patient.id;
      final DocItem inserted;
      if (result.savedDocUuid != null && result.savedDocUuid!.isNotEmpty) {
        // ignore: avoid_print
        print('[report] doc déjà en NocoDB (uuid=${result.savedDocUuid}) '
            '→ insert local-only synced (no upload queue)');
        inserted = await _dataService.importDocumentRemoteOnly(
          patientId: patientId,
          dossierId: _dossier.id,
          bytes: result.bytes,
          fileName: result.fileName,
          title: result.fileName.replaceAll(RegExp(r'\.pdf$'), ''),
          tags: const ['Rapport'],
          remoteUuid: result.savedDocUuid!,
          // CRITICAL : utilise le `clientDocumentId` déterministe
          // pour que `mergeRemoteDocuments` retrouve cette ligne au
          // prochain polling (match `local_id == clientDocumentId`)
          // et n'insère pas un 2e doc. Sans ça, doublon garanti
          // dans Documents (bug reporté 2026-05-05).
          // ID strictement aligné avec celui généré côté serveur
          // dans `app.post('/api/reports/visit/:dossierId')` →
          // `documentLocalId = doc_report_<dossierId>`.
          clientDocumentId: 'doc_report_${_dossier.id}',
        );
      } else {
        // ignore: avoid_print
        print('[report] importDocumentBytes patientId="$patientId" '
            'fileName="${result.fileName}" bytes=${result.bytes.length}');
        // localId déterministe par dossier → 1 seul doc « Rapport »
        // par dossier, regénération = REPLACE (avec préservation des
        // annotations). Sans ça, chaque clic « Générer » créait un
        // nouveau doc → 15 docs dans NocoDB pour 1 click si retries
        // (bug reporté 2026-04-30).
        inserted = await _dataService.importDocumentBytes(
          patientId: patientId,
          dossierId: _dossier.id,
          bytes: result.bytes,
          fileName: result.fileName,
          title: result.fileName.replaceAll(RegExp(r'\.pdf$'), ''),
          tags: const ['Rapport'],
          localId: 'doc_report_${_dossier.id}',
        );
      }
      // ignore: avoid_print
      print('[report] document local_id=${inserted.id} créé '
          '(sync_state=${inserted.syncState.name})');

      // Vérification immédiate : on relit la liste locale et on
      // confirme que le doc est bien retrouvable. Si non, on remonte
      // l'avertissement à l'utilisateur plutôt que de silencieusement
      // afficher un faux succès.
      final docs = await _dataService.fetchDocuments(patientId);
      final found = docs.any((d) => d.id == inserted.id);
      // ignore: avoid_print
      print('[report] vérification : ${docs.length} doc(s) pour '
          'patient="$patientId", trouvé=$found');

      if (!found) {
        _showReportError(
          'Rapport généré mais introuvable dans Documents '
          '(patient="$patientId"). Voir console pour détails.',
        );
        ReportGenerationService.instance.notifyFailure(
          ReportGenerationFailure(
            dossierId: _dossier.id,
            patientLabel: patientLabel,
            message: 'Rapport généré mais introuvable dans Documents.',
            occurredAt: DateTime.now(),
          ),
        );
        return;
      }

      // Compte UNIQUEMENT les docs visibles dans l'espace Documents :
      // on retire les photos visite (tags `Visite - *`) qui vivent
      // dans VAD > Photos. Demande utilisateur 2026-04-30 : la
      // bannière doit refléter ce qui est « disponible dans l'espace
      // document » et non le nombre total de docs en base.
      String norm(String s) => s
          .toLowerCase()
          .replaceAll('é', 'e')
          .replaceAll('è', 'e')
          .replaceAll('ê', 'e')
          .replaceAll('à', 'a')
          .replaceAll('â', 'a')
          .replaceAll('ô', 'o')
          .replaceAll('î', 'i')
          .replaceAll('û', 'u')
          .replaceAll('ç', 'c')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final visitTagsNormalized = kVisitPhotoTags.map(norm).toSet();
      bool isVisitTag(String tag) {
        final n = norm(tag);
        if (visitTagsNormalized.contains(n)) return true;
        return n.startsWith('visite - ') || n.startsWith('visite-');
      }
      final docsInDocumentsSpace =
          docs.where((d) => !d.tags.any(isVisitTag)).length;
      _showReportSuccess(result, totalDocs: docsInDocumentsSpace);

      // Notifie le service global → bandeau vert affichable depuis
      // n'importe quel écran (dashboard, autre dossier, etc.) si
      // l'utilisateur a navigué pendant la génération. Demande
      // utilisateur 2026-05-11 : « le bandeau vert qui indique qu'il
      // a été mis dans l'espace document doit également apparaitre en
      // bas meme si je suis sur une autre page une fois la generation
      // effectuée ».
      ReportGenerationService.instance.notifySuccess(
        ReportGenerationSuccess(
          dossierId: _dossier.id,
          patientLabel: patientLabel,
          fileName: result.fileName,
          byteSize: result.bytes.length,
          savedDocUuid: result.savedDocUuid,
          bytes: result.bytes,
          completedAt: DateTime.now(),
        ),
      );
    } catch (error) {
      // Filet de sécurité : toute autre exception non capturée → queue
      // différée plutôt qu'une erreur sèche.
      await _enqueueReportForLater(
        reason: 'Génération interrompue : $error. Sera retentée plus tard.',
      );
      ReportGenerationService.instance.notifyFailure(
        ReportGenerationFailure(
          dossierId: _dossier.id,
          patientLabel: patientLabel,
          message: 'Génération interrompue — rapport en attente.',
          deferred: true,
          occurredAt: DateTime.now(),
        ),
      );
    }
    // Note : pas de `finally { setState(_isGeneratingReport = false) }`
    // ici — le flag local est désormais piloté par le stream du
    // ReportGenerationService (cf. listener dans initState). Le
    // service signale `inProgress=false` via notifySuccess /
    // notifyFailure ci-dessus, ce qui déclenche le setState
    // synchronisé pour ce widget ET tous les autres écrans abonnés.
  }

  /// True si la note (NotesWidget) sous le `tabKey` donné contient du
  /// texte non-vide. Le texte est encodé dans `drawing_json.text` (cf.
  /// `notes_widget.dart#_currentDrawingJson`). Si le JSON n'a pas de
  /// champ `text`, on retombe sur false (pas de note utilisable).
  Future<bool> _hasNoteText(String tabKey) async {
    try {
      final raw = await _dataService.fetchNoteDrawingJson(
        patientId: _dossier.patient.id,
        tabKey: tabKey,
      );
      if (raw == null || raw.isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['text'] is String) {
        return (decoded['text'] as String).trim().isNotEmpty;
      }
    } catch (_) {
      // JSON invalide ou erreur fetch → considère le champ vide.
    }
    return false;
  }

  /// Vérifie que TOUS les champs critiques pour un PDF complet sont
  /// remplis. Renvoie la liste des champs manquants (vide si tout est OK).
  ///
  /// Spec utilisateur 2026-04-30 :
  ///   - Bénéficiaire (Profil / Foyer / Santé / Admin) : tout rempli
  ///   - Mesures : pas important, on skip
  ///   - Accessibilité Général / Équipements / Extérieur : tout rempli
  ///   - Accessibilité Niveaux : ≥ 1 niveau ajouté avec SDB ET WC
  ///   - SDB : ≥ 1 (douche OU baignoire) + hauteur + porte (largeur,
  ///     dimensions, sens). Équipements complémentaires optionnels.
  ///   - WC : tout rempli (cuvette, hauteur, porte…)
  ///   - Photos : ≥ 1 par catégorie SAUF « Autres »
  ///   - Préconisations : ≥ 1 reco + note Projet + note Résumé
  ///   - Notes écrites : Contexte (Médical/Autonomie), Accessibilité,
  ///     Sanitaires, Préconisations (Projet/Résumé)
  ///   - « Cochée mais pas de précision » : Santé (APA→GIR, MDPH→%,
  ///     aide à domicile→texte) ; Volets roulants Localisé→localisation
  Future<List<_MissingField>> _collectMissingFields() async {
    final missing = <_MissingField>[];
    await _checkBeneficiaryProfil(missing);
    await _checkBeneficiaryFoyer(missing);
    await _checkBeneficiarySante(missing);
    await _checkBeneficiaryAdmin(missing);
    await _checkAccessibilite(missing);
    await _checkSalleDeBain(missing);
    await _checkWc(missing);
    await _checkPhotos(missing);
    await _checkRecommendations(missing);
    await _checkNotesEcrites(missing);
    return missing;
  }

  // -----------------------------------------------------------------
  // Sub-checkers — chacun pousse ses propres `_MissingField` dans la
  // liste passée. Découpés pour rester lisibles à l'inspection.
  // -----------------------------------------------------------------

  Future<void> _checkBeneficiaryProfil(List<_MissingField> missing) async {
    final p = _dossier.patient;
    final tab = _tabs.indexOf('Bénéficiaire');
    if (p.firstName.trim().isEmpty || p.lastName.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Profil — nom et prénom',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }
    if (p.birthDate.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Profil — date de naissance',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }
    if (p.phone.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Profil — téléphone',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }
    if (p.trustedPerson.name.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Profil — personne de confiance',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }
  }

  Future<void> _checkBeneficiaryFoyer(List<_MissingField> missing) async {
    final p = _dossier.patient;
    final tab = _tabs.indexOf('Bénéficiaire');
    if (p.address.trim().isEmpty || p.city.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Foyer — adresse complète',
        tabIndex: tab,
        subSectionIndex: 1,
      ));
    }
    if (p.familySituation.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Foyer — situation familiale',
        tabIndex: tab,
        subSectionIndex: 1,
      ));
    }
    if (p.occupationStatus.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Foyer — statut d\'occupation (Propriétaire/Locataire/Usufruitier)',
        tabIndex: tab,
        subSectionIndex: 1,
      ));
    }
    if ((p.numberPeople ?? 0) <= 0) {
      missing.add(_MissingField(
        label: 'Foyer — nombre de personnes',
        tabIndex: tab,
        subSectionIndex: 1,
      ));
    }
    if (p.fiscalRevenue == null || p.fiscalRevenue! <= 0) {
      missing.add(_MissingField(
        label: 'Foyer — revenu fiscal de référence',
        tabIndex: tab,
        subSectionIndex: 1,
      ));
    }
  }

  Future<void> _checkBeneficiarySante(List<_MissingField> missing) async {
    // Demande utilisateur : « si un élément est coché mais pas de
    // précision, il faut le mentionner ». APA→GIR, MDPH→%, aide à
    // domicile→précision texte.
    final p = _dossier.patient;
    final tab = _tabs.indexOf('Bénéficiaire');
    final occupants = p.occupants;
    final primary = occupants.isNotEmpty ? occupants.first : null;
    final apa = primary?.apa ?? false;
    final apaGir = primary?.apaGir.trim() ?? '';
    if (apa && apaGir.isEmpty) {
      missing.add(_MissingField(
        label: 'Santé — APA cochée mais GIR non renseigné',
        tabIndex: tab,
        subSectionIndex: 2,
      ));
    }
    if (p.invalidity && p.invalidityTxt.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Santé — Reconnaissance MDPH cochée mais % non renseigné',
        tabIndex: tab,
        subSectionIndex: 2,
      ));
    }
    if (p.homeHelp && p.homeHelpTxt.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Santé — Aide à domicile cochée mais détails non renseignés',
        tabIndex: tab,
        subSectionIndex: 2,
      ));
    }
    // Dépendance particulière : skip volontaire (demande utilisateur
    // 2026-04-30). Si l'ergo n'a rien coché, ça vaut implicitement
    // « Aucune » → pas la peine de signaler. Si l'option « Aucune »
    // est explicitement cochée, idem. Donc on ne flag JAMAIS ce
    // champ — il reste optionnel.
  }

  Future<void> _checkBeneficiaryAdmin(List<_MissingField> missing) async {
    final p = _dossier.patient;
    final tab = _tabs.indexOf('Bénéficiaire');
    if (p.caisseRetraitePrincipale.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Admin — caisse de retraite principale',
        tabIndex: tab,
        subSectionIndex: 3,
      ));
    }
    // ANAH (déplacé dans Profil depuis 2026-05-04). Le champ
    // `compte_anah` peut être en JSON ({status, mail, mandat,
    // mandatPar, mandatAutre}) ou en plain string legacy. On flag
    // si le statut est vide (= aucune réponse à « Création compte
    // ANAH »). Les autres sous-questions (mail/mandat) restent
    // optionnelles : pas de flag tant que le statut principal est
    // renseigné.
    String anahStatusForCheck = '';
    final anahRawForCheck = _dossier.compteAnah.trim();
    if (anahRawForCheck.startsWith('{')) {
      try {
        final decoded = jsonDecode(anahRawForCheck);
        if (decoded is Map) {
          anahStatusForCheck = (decoded['status']?.toString() ?? '').trim();
        }
      } catch (_) {/* JSON invalide → considéré vide */}
    } else if (anahRawForCheck != 'Mandat') {
      // Plain string legacy (pas « Mandat » qui n'est plus un statut)
      anahStatusForCheck = anahRawForCheck;
    }
    if (anahStatusForCheck.isEmpty) {
      missing.add(_MissingField(
        label: 'Profil — création compte ANAH (à faire / à vérifier / déjà fait)',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }
    if (_dossier.envoiRapport.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Admin — modalité d\'envoi du rapport',
        tabIndex: tab,
        subSectionIndex: 3,
      ));
    }
    // Type d'accompagnement (Diag ergo / MPA ergo / MPA complet) doit
    // être renseigné — demande utilisateur 2026-05-04 : « tout doit
    // avoir un type d'accompagnement ». Sans ça, la cellule AMO du PDF
    // tombe sur "/" alors que le dossier méritait un montant.
    if (_dossier.natureAccompagnement.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Admin — type d\'accompagnement (Diag ergo / MPA ergo / MPA complet)',
        tabIndex: tab,
        subSectionIndex: 3,
      ));
    }
  }

  Future<void> _checkAccessibilite(List<_MissingField> missing) async {
    final h = _dossier.housing;
    final tab = _tabs.indexOf('Accessibilité');
    // — Général (subSection 0)
    if (h.typology.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Accessibilité Général — type de logement (Maison/Appartement)',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }
    if (h.yearConstruction.trim().isEmpty) {
      missing.add(_MissingField(
        label: 'Accessibilité Général — année de construction',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }
    if (h.surface == null || h.surface! <= 0) {
      missing.add(_MissingField(
        label: 'Accessibilité Général — surface habitable',
        tabIndex: tab,
        subSectionIndex: 0,
      ));
    }

    // — Niveaux et pièces (subSection 1) : ≥ 1 niveau ayant à la fois
    //   « Salle de bain » ET « WC » dans ses pièces.
    final levels = <List<String>>[
      if (h.basement) h.basementRooms,
      if (h.rdc) h.rdcRooms,
      if (h.floor) h.floorRooms,
      if (h.secondFloor) h.secondFloorRooms,
      if (h.thirdFloor) h.thirdFloorRooms,
    ];
    bool hasBoth = levels.any((rooms) {
      final norm = rooms.map((r) => r.toLowerCase().trim()).toSet();
      final hasSdb = norm.any((r) => r.contains('salle de bain'));
      final hasWc = norm.any((r) => r.contains('wc'));
      return hasSdb && hasWc;
    });
    if (!hasBoth) {
      missing.add(_MissingField(
        label: 'Niveaux et pièces — au moins 1 niveau avec « Salle de bain » et « WC »',
        tabIndex: tab,
        subSectionIndex: 1,
      ));
    }

    // — Équipements (subSection 2) : chauffage choisi + volets validés
    final hasHeating = h.heatingDetails.values.any((v) => v == true);
    if (!hasHeating) {
      missing.add(_MissingField(
        label: 'Équipements — chauffage (au moins 1 type sélectionné)',
        tabIndex: tab,
        subSectionIndex: 2,
      ));
    }
    // Volets : 2 cas de manquant
    //   1. Statut = Localisé mais localisation non précisée (texte vide)
    //   2. Statut non renseigné (entier=false ET rawLoc='' SANS marqueur
    //      Aucun) — depuis 2026-04-30, le défaut UI n'est plus « Aucun »
    //      présélectionné. L'ergo doit cliquer explicitement
    //      Aucun/Entier/Localisé.
    //
    // Marqueurs invisibles persistés dans `localisation` (cf.
    // accessibility_tab._serializeVoletsLoc) :
    //   '​' (ZWSP, U+200B) → Localisé sans texte
    //   '‌' (ZWNJ, U+200C) → Aucun explicite
    void checkVolets(String label, bool entier, String rawLoc) {
      if (entier) return; // Entier — pas de check
      const localizedMarker = '​';   // ZWSP
      const aucunMarker = '‌';       // ZWNJ
      if (rawLoc == aucunMarker) return; // Aucun explicite — OK
      // Localisé : extraire le texte (sans le marqueur ZWSP)
      final cleaned = rawLoc.replaceAll(localizedMarker, '').trim();
      if (rawLoc.isNotEmpty && cleaned.isEmpty) {
        // Localisé sans précision (uniquement le marqueur ZWSP)
        missing.add(_MissingField(
          label: 'Équipements — $label : Localisé mais localisation non précisée',
          tabIndex: tab,
          subSectionIndex: 2,
        ));
      } else if (rawLoc.isEmpty) {
        // Aucun marqueur, aucun texte → l'ergo n'a pas répondu
        missing.add(_MissingField(
          label: 'Équipements — $label : statut non renseigné (Aucun/Entier/Localisé)',
          tabIndex: tab,
          subSectionIndex: 2,
        ));
      }
    }
    checkVolets(
      'volets roulants manuels',
      h.voletsRoulantsManuelsEntier,
      h.voletsRoulantsManuelsLocalisation,
    );
    checkVolets(
      'volets roulants électriques',
      h.voletsRoulantsElectriquesEntier,
      h.voletsRoulantsElectriquesLocalisation,
    );
    checkVolets(
      'persiennes',
      h.voletsPersiennesEntier,
      h.voletsPersiennesLocalisation,
    );

    // — Extérieur (subSection 3) : « Accès depuis la rue » doit être
    //   explicitement répondu (Facile / À revoir). On lit la colonne
    //   `easy_access_set` (migration v15→v16) directement plutôt que
    //   `housing.easyAccess`, qui est non-nullable et vaut false par
    //   défaut quand l'ergo n'a jamais cliqué.
    final housingRaw = await _repository.fetchHousingRaw(_dossier.id);
    final easyAccessSet =
        (housingRaw?['easy_access_set'] as int? ?? 0) == 1;
    if (!easyAccessSet) {
      missing.add(_MissingField(
        label: 'Extérieur — accès depuis la rue (Facile / À revoir)',
        tabIndex: tab,
        subSectionIndex: 3,
      ));
    }
    // En plus : au moins une caractéristique d'accès ou d'annexe pour
    // montrer que la section a été visitée. Si l'ergo n'a vraiment rien
    // de spécial à signaler, il peut cocher Valider pour continuer.
    final anyExterieur = h.garage || h.veranda || h.balcon || h.terrasse
        || h.jardin || h.cheminementMarches || h.cheminementRampe;
    if (!anyExterieur) {
      missing.add(_MissingField(
        label: 'Extérieur — au moins une annexe ou caractéristique d\'accès',
        tabIndex: tab,
        subSectionIndex: 3,
      ));
    }
  }

  Future<void> _checkSalleDeBain(List<_MissingField> missing) async {
    final tab = _tabs.indexOf('Salle de bain');
    final diag = await _repository.fetchDiagnosticSanitaire(_dossier.id);
    final sdbInstances = diag?.sdbInstances ?? const [];
    if (sdbInstances.isEmpty) {
      // Cas fréquent : aucun niveau n'a coché « Salle de bain » →
      // déjà signalé par _checkAccessibilite. Pas la peine de
      // doubler ici.
      return;
    }
    for (var i = 0; i < sdbInstances.length; i++) {
      final s = sdbInstances[i];
      final lvl = s.levelLabel.isNotEmpty ? ' (${s.levelLabel})' : '';
      // Au moins douche OU baignoire
      if (!s.sdbBaignoire && !s.sdbBacDouche) {
        missing.add(_MissingField(
          label: 'Salle de bain$lvl — sélectionner douche ou baignoire',
          tabIndex: tab,
        ));
      } else {
        if (s.sdbBaignoire
            && (s.sdbBaignoireHauteur == null || s.sdbBaignoireHauteur! <= 0)) {
          missing.add(_MissingField(
            label: 'Salle de bain$lvl — hauteur baignoire',
            tabIndex: tab,
          ));
        }
        if (s.sdbBacDouche
            && (s.sdbBacDoucheHauteur == null || s.sdbBacDoucheHauteur! <= 0)) {
          missing.add(_MissingField(
            label: 'Salle de bain$lvl — hauteur bac à douche',
            tabIndex: tab,
          ));
        }
      }
      // Porte : dimension chiffrée (les toggles ont des valeurs par
      // défaut, on ne peut pas les valider proprement).
      if (s.porteSdbDimension == null || s.porteSdbDimension! <= 0) {
        missing.add(_MissingField(
          label: 'Salle de bain$lvl — dimension de la porte',
          tabIndex: tab,
        ));
      }
    }
  }

  Future<void> _checkWc(List<_MissingField> missing) async {
    final tab = _tabs.indexOf('WC');
    final diag = await _repository.fetchDiagnosticSanitaire(_dossier.id);
    final wcInstances = diag?.wcInstances ?? const [];
    if (wcInstances.isEmpty) return;
    for (var i = 0; i < wcInstances.length; i++) {
      final w = wcInstances[i];
      final lvl = w.levelLabel.isNotEmpty ? ' (${w.levelLabel})' : '';
      // « Tout remplir » : hauteur cuvette + dimension porte. Toggles
      // (cuvette bonne hauteur/trop basse, barre, sens, largeur)
      // ont des défauts donc on ne peut pas les valider.
      if (w.wcCuvetteHauteur == null || w.wcCuvetteHauteur! <= 0) {
        missing.add(_MissingField(
          label: 'WC$lvl — hauteur de cuvette',
          tabIndex: tab,
        ));
      }
      if (w.porteWcDimension == null || w.porteWcDimension! <= 0) {
        missing.add(_MissingField(
          label: 'WC$lvl — dimension de la porte',
          tabIndex: tab,
        ));
      }
    }
  }

  Future<void> _checkPhotos(List<_MissingField> missing) async {
    final tab = _tabs.indexOf('Photos');
    try {
      final docs = await _dataService.fetchDocuments(_dossier.patient.id);
      bool has(String tag) => docs.any((d) => d.tags.contains(tag));
      // « ≥ 1 photo par partie sauf Autres » → 5 catégories obligatoires.
      const requiredCats = <(String, String)>[
        (kPhotoTagLogement, 'Logement'),
        (kPhotoTagAccessibilite, 'Accessibilité'),
        (kPhotoTagSanitaires, 'Sanitaires'),
        (kPhotoTagPlanAvant, 'Plan avant travaux'),
        (kPhotoTagPlanApres, 'Plan travaux préconisés'),
      ];
      for (final (tag, label) in requiredCats) {
        if (!has(tag)) {
          missing.add(_MissingField(
            label: 'Photos — $label (au moins 1)',
            tabIndex: tab,
          ));
        }
      }
    } catch (_) {
      // Fetch fail → on skip. Pas bloquant.
    }
  }

  Future<void> _checkRecommendations(List<_MissingField> missing) async {
    final tab = _tabs.indexOf('Préconisations');
    final recos =
        await _repository.fetchVisitRecommendations(_dossier.id);
    if (recos.isEmpty) {
      missing.add(_MissingField(
        label: 'Préconisations — au moins 1 préconisation',
        tabIndex: tab,
      ));
    }
  }

  Future<void> _checkNotesEcrites(List<_MissingField> missing) async {
    // 1) Contexte de vie — Médical (subSection 0) → PDF Environnement
    if (!await _hasNoteText('Contexte de vie-Médical')) {
      missing.add(_MissingField(
        label: 'Note Contexte de vie — Médical',
        tabIndex: _tabs.indexOf('Contexte de vie'),
        subSectionIndex: 0,
      ));
    }
    // 2) Contexte de vie — Autonomie (subSection 1) → PDF Habitudes
    if (!await _hasNoteText('Contexte de vie-Autonomie')) {
      missing.add(_MissingField(
        label: 'Note Contexte de vie — Autonomie',
        tabIndex: _tabs.indexOf('Contexte de vie'),
        subSectionIndex: 1,
      ));
    }
    // 3) Accessibilité (note partagée toutes sous-sections)
    if (!await _hasNoteText('Accessibilité-Notes')) {
      missing.add(_MissingField(
        label: 'Note Accessibilité (panneau de droite)',
        tabIndex: _tabs.indexOf('Accessibilité'),
      ));
    }
    // 4) Sanitaires (note partagée SDB+WC) — 1 seule note alimente
    //    le PDF « Observations sur les équipements et utilisation »
    if (!await _hasNoteText('Sanitaires-Notes')) {
      missing.add(_MissingField(
        label: 'Note Sanitaires (panneau de droite SDB ou WC)',
        tabIndex: _tabs.indexOf('Salle de bain'),
      ));
    }
    // 5) Résumé — Projet de l'usager (déménagé de Préconisations vers
    //    le nouvel onglet Résumé en 2026-05-04 ; le tabKey reste
    //    'Préconisations-Projet' pour préserver la donnée historique).
    if (!await _hasNoteText('Préconisations-Projet')) {
      missing.add(_MissingField(
        label: 'Résumé — Projet de l\'usager',
        tabIndex: _tabs.indexOf('Résumé'),
      ));
    }
    // 6) Résumé — Résumé des préconisations (idem)
    if (!await _hasNoteText('Préconisations-Résumé')) {
      missing.add(_MissingField(
        label: 'Résumé — Résumé des préconisations',
        tabIndex: _tabs.indexOf('Résumé'),
      ));
    }
  }

  /// Affiche la popup « Champs manquants ». Renvoie :
  ///   - `true` si l'ergo clique « Valider » → continuer la génération
  ///   - `false` si « Remplir les champs » → on a navigué vers le 1er
  ///     champ manquant, abort la génération
  ///   - `null` si l'ergo ferme la popup (= équivalent annuler, pas
  ///     de génération)
  Future<bool?> _showMissingFieldsDialog(List<_MissingField> missing) async {
    if (!mounted) return null;
    return showSoftDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        // Layout custom pour pouvoir contraindre la largeur (l'AlertDialog
        // par défaut prend ~85 % du viewport sur iPad — trop large pour
        // une simple liste de champs manquants). Demande utilisateur
        // 2026-04-30 : « pop up plus centrée et moins large ».
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        // insetPadding par défaut serait étroit — on lui force une marge
        // confortable + maxWidth pour que sur grand écran (iPad/macOS)
        // la popup reste centrée et compacte plutôt que de s'étirer.
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 40,
          vertical: 24,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Champs manquants',
                  style: GoogleFonts.nunito(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: const Color(0xFF0E1116),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Certaines informations importantes ne sont pas '
                  'remplies. Tu peux générer le rapport quand même '
                  '(les champs vides seront laissés blancs dans le PDF) '
                  'ou compléter d\'abord :',
                  style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
                ),
                const SizedBox(height: 12),
                Flexible(
                  // Scroll si la liste est très longue — sans Flexible
                  // la dialog déborderait verticalement le viewport.
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: missing
                          .map(
                            (m) => Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  const Padding(
                                    padding:
                                        EdgeInsets.only(top: 4, right: 8),
                                    child: Icon(
                                      LucideIcons.alertCircle,
                                      size: 14,
                                      color: Color(0xFFB45309),
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      m.label,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx, false);
                        _navigateToMissingField(missing.first);
                      },
                      child: const Text('Remplir les champs'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF8B6FA0),
                      ),
                      child: const Text('Valider'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Navigue vers l'onglet (et la sous-section quand applicable) du
  /// champ manquant pour permettre à l'ergo de le remplir directement
  /// sans chercher.
  void _navigateToMissingField(_MissingField missing) {
    if (missing.tabIndex < 0 || missing.tabIndex >= _tabs.length) return;
    _tabController.animateTo(missing.tabIndex);
    if (missing.subSectionIndex != null) {
      final tabName = _tabs[missing.tabIndex];
      setState(() {
        _activeSubsectionByTab[tabName] = missing.subSectionIndex!;
      });
    }
  }

  /// Met en file d'attente la génération du rapport pour traitement
  /// par le `SyncEngine` dès la prochaine reprise de connectivité.
  /// Affiche un toast clair pour rassurer l'ergo (« sera généré
  /// automatiquement ») au lieu d'une erreur sèche.
  Future<void> _enqueueReportForLater({required String reason}) async {
    try {
      await _repository.enqueueReportGeneration(
        dossierId: _dossier.id,
        patientId: _dossier.patient.id,
      );
      // ignore: avoid_print
      print('[report] enqueued report_gen pour dossier=${_dossier.id} '
          '(raison: $reason)');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📄 Rapport en attente — $reason'),
          backgroundColor: const Color(0xFF8B6FA0),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (error) {
      // ignore: avoid_print
      print('[report] échec enqueue : $error');
      _showReportError(
        'Impossible de mettre le rapport en attente : $error',
      );
    }
  }

  void _showReportSuccess(
    ({
      Uint8List bytes,
      String fileName,
      Map<String, dynamic>? stats,
      String? savedDocUuid,
    }) result,
    {int? totalDocs}
  ) {
    if (!mounted) return;
    // Demande utilisateur 2026-04-30 : retirer les stats détaillées
    // (« 45 champs remplis, 12 à compléter ») — l'ergo n'en a pas
    // besoin. On garde juste le nom de fichier + le nombre de docs
    // disponibles dans l'espace Documents.
    final docCountSuffix = totalDocs != null
        ? '\n→ $totalDocs document${totalDocs > 1 ? 's' : ''} disponible${totalDocs > 1 ? 's' : ''} dans l\'espace document'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Rapport ajouté dans les Documents : ${result.fileName}'
          '$docCountSuffix',
        ),
        backgroundColor: const Color(0xFF166534),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _showReportError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFB91C1C),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Habille l'onglet [tabName] de sa carte blanche + son panneau de
  /// notes latéral quand l'onglet a des sous-sections (cf.
  /// [_tabSubsections]). Sinon retourne juste la carte (Mesures, Plans,
  /// Préconisations occupent toute la largeur).
  Widget _wrapTabWithNotes(String tabName, Widget formContent) {
    final formCard = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: formContent,
    );
    final subsections = _tabSubsections[tabName];
    if (subsections == null || subsections.isEmpty) {
      return formCard;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 1, child: formCard),
        const SizedBox(width: 24),
        Expanded(
          flex: 2,
          child: _buildNotesPanel(tabName, subsections),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Chaque entrée du TabBarView intègre maintenant son propre panneau
    // de notes (quand l'onglet en a). Conséquence : changer d'onglet
    // (ex. Bénéficiaire → Contexte de vie) fait glisser **simultanément**
    // le formulaire ET les notes par le slide horizontal natif du
    // TabBarView Material. C'est exactement la sensation demandée :
    // toute la page bascule comme un seul bloc.
    final tabView = TabBarView(
      controller: _tabController,
      // Désactive le swipe horizontal entre onglets. Raison : l'onglet
      // Plans a une zone de dessin plein écran — dès qu'un ergo pose le
      // doigt dessus et bouge horizontalement, le TabBarView prenait la
      // gesture et faisait défiler vers l'onglet voisin, arrachant le
      // trait en cours. Les onglets restent accessibles via la barre du
      // haut (TabBar est isScrollable=true).
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _wrapTabWithNotes(
          'Bénéficiaire',
          BeneficiaryTab(
            dossier: _dossier,
            repository: _repository,
            onPatientChanged: _refreshDossier,
            initialSubSection:
                _activeSubsectionByTab['Bénéficiaire'] ?? 0,
            onSubSectionChanged: (i) => setState(
                () => _activeSubsectionByTab['Bénéficiaire'] = i),
          ),
        ),
        _wrapTabWithNotes(
          'Contexte de vie',
          ContextTab(
            dossier: _dossier,
            repository: _repository,
            onMedicalFlagToggled: _handleMedicalFlagToggle,
            // Les cases Pathologie / Suivi / Sensoriel reflètent la PAGE
            // COURANTE de la note Médical — pas le dossier. NotesWidget
            // pousse ces flags via `onMedicalFlagsChanged` à chaque
            // changement/chargement de page.
            currentMedicalFlags: _medicalFlagNumbers,
            // Sync de la sous-section interne (Médical / Autonomie)
            // avec le panneau notes de droite. Sans ça, le panneau
            // restait coincé sur la note Médical même si l'ergo
            // basculait sur Autonomie en interne — et le PDF
            // « Habitudes de vie » paraissait vide alors que la note
            // Autonomie existait. Demande utilisateur 2026-04-30.
            initialSubSection:
                _activeSubsectionByTab['Contexte de vie'] ?? 0,
            onSubSectionChanged: (i) => setState(
                () => _activeSubsectionByTab['Contexte de vie'] = i),
          ),
        ),
        _wrapTabWithNotes(
          'Mesures',
          MesuresTab(dossier: _dossier, repository: _repository),
        ),
        _wrapTabWithNotes(
          'Accessibilité',
          AccessibilityTab(
            dossier: _dossier,
            repository: _repository,
            onHousingChanged: _notifyHousingChanged,
            // Sync de la sous-section interne (Général / Niveaux /
            // Équipements / Extérieur) avec _activeSubsectionByTab —
            // permet à _navigateToMissingField (popup « Remplir les
            // champs ») de pointer directement sur la bonne sous-
            // section (bug rapporté 2026-05-04 : on arrivait sur
            // l'onglet Accessibilité mais pas sur la sous-section
            // contenant le champ vide).
            initialSubSection:
                _activeSubsectionByTab['Accessibilité'] ?? 0,
            onSubSectionChanged: (i) => setState(
                () => _activeSubsectionByTab['Accessibilité'] = i),
          ),
        ),
        _wrapTabWithNotes(
          'Salle de bain',
          BathroomTab(
            dossier: _dossier,
            repository: _repository,
            housingRefreshToken: _housingVersion,
          ),
        ),
        _wrapTabWithNotes(
          'WC',
          WcTab(
            dossier: _dossier,
            repository: _repository,
            housingRefreshToken: _housingVersion,
          ),
        ),
        // Plans déplacé juste après WC (demande utilisateur 2026-05-04) —
        // doit rester aligné avec l'ordre déclaré dans `_tabs`.
        _wrapTabWithNotes(
          'Plans',
          PlansTab(dossier: _dossier),
        ),
        // Onglet Photos — pleine largeur (pas de notes latérales).
        // Voir `lib/screens/visit_report/photos_tab.dart`.
        _wrapTabWithNotes(
          'Photos',
          PhotosTab(dossier: _dossier),
        ),
        // Onglet Résumé — split de l'ancien Préconisations (2026-05-04).
        // Cadres Projet/Résumé en haut + canvas pleine page (style
        // Mesures, sans image de fond) en dessous. Le canvas supporte
        // pagination + agrandissement dans une 2e fenêtre browser
        // (mode drawing — cf. _openDrawingNoteInSeparateWindow).
        _wrapTabWithNotes(
          'Résumé',
          SummaryTab(
            dossier: _dossier,
            onExpandToTab: () =>
                _openDrawingNoteInSeparateWindow('Résumé'),
            // Notes texte du haut (Projet / Résumé des préco) → même
            // mécanisme que les notes VAD classiques : nouvelle
            // fenêtre détachée en mode text. Demande utilisateur
            // 2026-05-05.
            onExpandTextNote: (tabKey) =>
                _openNoteInSeparateWindow(tabKey),
            // Sync bi-directionnel avec la fenêtre détachée — fix
            // demande utilisateur 2026-05-05 : « quand j'écris dans
            // le nouvel onglet note, il faut également que ça écrive
            // direct dans le cadre note écrite de l'application ».
            // L'IPC `liveNote` met à jour `_liveText[...]` côté state
            // → SummaryTab le lit et le passe en `liveText:` à
            // chaque NotesWidget. Réciproque : `onDraftChange` →
            // `_pushDraftToOpenWindow`.
            liveTextProjet: _liveText[
                '${_dossier.patient.id}::Préconisations-Projet'],
            liveTextResume: _liveText[
                '${_dossier.patient.id}::Préconisations-Résumé'],
            onDraftChange: (tabKey, text) =>
                _pushDraftToOpenWindow(tabKey, text),
          ),
        ),
        _wrapTabWithNotes(
          'Préconisations',
          RecommendationsTab(dossier: _dossier, repository: _repository),
        ),
      ],
    );

    // Header bénéficiaire — même pattern que DocumentsScreen : NOM Prénom
    // en gras. On ajoute l'adresse complète en dessous (demande utilisateur :
    // retirer ces champs de la section Identité de l'onglet Bénéficiaire).
    final patient = _dossier.patient;
    final addressLine = [
      patient.address.trim(),
      [patient.zipCode.trim(), patient.city.trim()]
          .where((s) => s.isNotEmpty)
          .join(' '),
    ].where((s) => s.isNotEmpty).join(' · ');
    // Deux badges à afficher entre le nom et l'adresse (parité avec
    // l'écran dossier) : type d'accompagnement + catégorie de revenu.
    final accompanimentLabel =
        formatAccompanimentType(_dossier.natureAccompagnement).trim();
    final incomeLabel = patient.incomeCategory.trim();
    // Statut compte ANAH — extrait du JSON `compte_anah` (cf.
    // beneficiary_tab._parseAnahData). Format historique « plain string »
    // toléré : si la valeur n'est pas du JSON, on l'utilise telle quelle.
    String anahStatus = '';
    final anahRaw = _dossier.compteAnah.trim();
    if (anahRaw.isNotEmpty) {
      if (anahRaw.startsWith('{')) {
        try {
          final decoded = jsonDecode(anahRaw);
          if (decoded is Map) {
            anahStatus = (decoded['status']?.toString() ?? '').trim();
          }
        } catch (_) {/* ignore — laisse vide */}
      } else if (anahRaw == 'Mandat') {
        // Legacy : l'entrée historique « Mandat » n'a plus de statut
        // associé après la migration 2026-05-04 → pas de pastille.
        anahStatus = '';
      } else {
        anahStatus = anahRaw;
      }
    }

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            // Ligne 1 : entête bénéficiaire au-dessus de toute la barre de
            // navigation (NOM Prénom + adresse complète), avec back button
            // à gauche.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildBackButton(),
                const SizedBox(width: 16),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Nom borné par `ConstrainedBox(maxWidth: 380)`
                      // au lieu d'un Flexible — comme ça il prend juste
                      // sa largeur naturelle (typiquement 150-250 pt
                      // pour un NOM Prénom standard) et n'occupe pas
                      // 50 % de l'espace par défaut. Les noms vraiment
                      // longs (composés, doubles…) sont coupés à
                      // 380 pt avec une ellipsis. Ça libère le slot
                      // de l'adresse qui peut désormais se déployer
                      // sur tout l'espace restant via `Expanded`.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 380),
                        child: Text(
                          '${patient.lastName.toUpperCase()} ${patient.firstName}',
                          // Refonte 2026-05-13 : Nunito w700 sur le nom du
                          // bénéficiaire affiché dans le header du relevé.
                          style: GoogleFonts.nunito(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: const Color(0xFF0E1116),
                          ),
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                      ),
                      // Badges insérés ENTRE le nom et l'adresse — parité
                      // avec l'écran dossier (demande utilisateur).
                      //
                      // Fallback "MPA complet" 2026-05-07 : si le champ
                      // `nature_accompagnement` est vide (dossiers legacy
                      // créés avant que la validation rende le champ
                      // obligatoire), on affiche quand même le badge avec
                      // le défaut. Sans ça, le badge disparait sans
                      // explication. La couleur teal pastel "Complet" est
                      // déjà le fallback dans `accompanimentPaletteFor`.
                      const SizedBox(width: 10),
                      AccompanimentBadge(
                        value: accompanimentLabel.isNotEmpty
                            ? accompanimentLabel
                            : 'MPA complet',
                        rawType: _dossier.natureAccompagnement.trim().isNotEmpty
                            ? _dossier.natureAccompagnement
                            : 'complet',
                        large: true,
                      ),
                      if (incomeLabel.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        IncomeCategoryBadge(
                          value: incomeLabel,
                          large: true,
                        ),
                      ],
                      if (addressLine.isNotEmpty) ...[
                        const SizedBox(width: 12),
                        // Icône localisation discrète (même gris que le
                        // texte) juste avant l'adresse.
                        const Icon(
                          LucideIcons.mapPin,
                          size: 18,
                          color: Color(0xFF64748B),
                        ),
                        const SizedBox(width: 6),
                        // `Expanded` (et plus `Flexible`) : l'adresse
                        // prend TOUT l'espace restant après le nom +
                        // badges + icône. Sur iPad paysage cela donne
                        // 700-900 pt qui suffisent largement pour la
                        // plupart des adresses françaises sans
                        // ellipsis. Demande utilisateur : "met sur
                        // toute la longueur car il y a encore de la
                        // place mais elle se termine par ...".
                        Expanded(
                          child: Text(
                            addressLine,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF64748B),
                            ),
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Pastille « État du compte ANAH » épinglée à droite
                // (demande utilisateur 2026-05-04). N'apparaît que si
                // l'ergo a renseigné le statut (sinon vide → caché).
                if (anahStatus.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  AnahStatusBadge(status: anahStatus, large: true),
                ],
                // Le bouton « Générer le rapport » est désormais
                // intégré comme dernière entrée de la barre de
                // navigation des onglets (cf. `_buildTabBar`) — plus
                // de pill flottant à droite de l'entête VAD.
              ],
            ),
            const SizedBox(height: 12),
            // Ligne 2 : barre de navigation des onglets + bouton
            // « Générer le rapport » en dernière position.
            _buildTabBar(),
            const SizedBox(height: 16),
            // Content area — chaque entrée du TabBarView intègre désormais
            // son layout 1 colonne (Mesures/Plans/Préconisations) ou 2
            // colonnes (formulaire + notes), donc le contenu glisse en
            // bloc lors d'un changement d'onglet.
            Expanded(child: tabView),
          ],
        ),
      ),
    );
  }
}

/// Couche d'un NotesWidget dans le Stack du panneau de droite. Garde
/// le widget en vie pour préserver l'état (dessin en cours, sélection
/// d'outils…), mais l'anime en fade + apparition vers le haut quand il
/// devient actif/inactif. Mêmes durées et courbes que le `SoftSwitcher`
/// utilisé pour les autres sous-sections du relevé → l'utilisateur
/// retrouve la même grammaire d'animation partout.
class _NotesPanelLayer extends StatelessWidget {
  const _NotesPanelLayer({
    required this.isActive,
    required this.child,
  });

  final bool isActive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      // Position « repos » = (0, 0). Hors-actif : légèrement décalé vers
      // le bas pour que la couche entrante donne l'impression de monter
      // (parité avec `SoftSwitcher`).
      offset: isActive ? Offset.zero : const Offset(0, 0.06),
      duration: kSoftMedium,
      curve: kSoftCurve,
      child: AnimatedOpacity(
        opacity: isActive ? 1.0 : 0.0,
        duration: kSoftMedium,
        curve: kSoftCurve,
        // `IgnorePointer` pour que les couches inactives ne capturent
        // pas les taps (sinon on cliquerait sur un NotesWidget invisible
        // posé par-dessus l'actif).
        child: IgnorePointer(
          ignoring: !isActive,
          child: child,
        ),
      ),
    );
  }
}

// `_MedicalFlagBadges` retiré le 2026-05-04 — remplacé par
// `_MedicalPageNumberBadge` (badge unique = numéro de page courant).
// L'ancienne logique « slots haut/milieu/bas selon les flags cochés à
// gauche » créait une re-disposition à chaque changement de page que
// l'utilisateur ressentait comme une « remise à zéro ».

class _FlagMarker extends StatelessWidget {
  const _FlagMarker({required this.number});
  final int number;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$number -',
      style: GoogleFonts.nunito(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: Colors.black,
        height: 1.0,
      ),
    );
  }
}

/// Badge unique « N - » affiché en arrière-plan du canvas de la note
/// "Contexte de vie > Médical". `N` est égal au numéro de page courant
/// (1, 2 ou 3) — fixe par page, indépendant des cases cochées à gauche
/// (Pathologie / Suivi / Sensoriel).
///
/// Demande utilisateur 2026-05-04 : « il doit y avoir simplement les 3
/// pages déjà présentes avec une avec le numéro 1, une avec le 2 et
/// une avec le 3, cela ne change pas en fonction des éléments cochés à
/// gauche et cela ne doit pas être remis à chaque changement de page ».
///
/// Avant : `_MedicalFlagBadges` empilait jusqu'à 3 badges (haut/milieu/bas)
/// dérivés du Set de flags cochés. À chaque changement de page, le Set
/// était relu depuis `drawing_json` → l'overlay se reconfigurait — d'où
/// la sensation de « remise à zéro » signalée. Désormais : un seul badge
/// posé en haut-gauche, qui suit purement le `currentPage`.
class _MedicalPageNumberBadge extends StatelessWidget {
  const _MedicalPageNumberBadge({required this.currentPage});

  /// Numéro de page 1-indexé (1, 2 ou 3).
  final int currentPage;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 16,
          // top descendu de 12 → 56 (demande utilisateur 2026-05-04 :
          // « redescend légèrement le numéro pour ne pas être en face
          // de l'outil navigation entre page »). 56 pt = sous la zone
          // top-right occupée par le contrôle pagination.
          top: 56,
          child: _FlagMarker(number: currentPage),
        ),
      ],
    );
  }
}

/// Décrit un champ critique non rempli. Utilisé par
/// `_collectMissingFields` + `_showMissingFieldsDialog` (popup
/// pré-génération qui propose à l'ergo de naviguer directement vers
/// le champ pour le remplir).
class _MissingField {
  /// Libellé affiché à l'ergo dans la liste de la popup.
  final String label;

  /// Index dans `_tabs` (0 = Bénéficiaire, 1 = Contexte de vie, …).
  final int tabIndex;

  /// Index de sous-section dans `_activeSubsectionByTab` (optionnel —
  /// pas toutes les tabs ont des sous-sections, ex. Photos).
  final int? subSectionIndex;

  const _MissingField({
    required this.label,
    required this.tabIndex,
    this.subSectionIndex,
  });
}
