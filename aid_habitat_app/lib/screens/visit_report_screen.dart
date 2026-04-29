import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, setEquals;
import 'package:flutter/material.dart';
// Desktop only (macOS/Windows/Linux). Sur web + mobile, un stub vide est
// importé — les appels sont shuntés par un garde `kIsWeb` avant exécution.
import '../services/multi_window_stub.dart'
    if (dart.library.io) 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../services/connectivity_service.dart';
import '../services/dossier_repository.dart';
import '../services/data_service.dart';
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

  /// True quand le bouton « Générer le rapport » est en cours d'appel.
  /// Affiche un spinner et bloque les double-taps.
  bool _isGeneratingReport = false;

  static const List<String> _tabs = [
    'Bénéficiaire',
    'Contexte de vie',
    'Mesures',
    'Accessibilité',
    'Salle de bain',
    'WC',
    // Onglet « Photos » inséré entre WC et Préconisations : flow
    // d'observation (SDB/WC) → capture (Photos) → analyse
    // (Préconisations) → dessin (Plans). Alimente la page 8 du
    // rapport PDF (« Photos du logement »).
    'Photos',
    // L'onglet « Préconisations » a fusionné l'ancien onglet
    // « Observations » (cf. demande utilisateur 2026-04-28) : le projet
    // usager + le résumé des préconisations sont maintenant 2 NotesWidget
    // en haut de Préconisations, et l'observation équipements est
    // descendue dans la sous-section Équipements de l'onglet
    // Accessibilité. Alimente toujours les pages 6 et 7 du PDF.
    'Préconisations',
    'Plans',
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
    // Sur web (PWA) le navigateur ne peut pas ouvrir de vraies fenêtres
    // OS secondaires, donc on ne monte pas de handler.
    if (kIsWeb) return;
    DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'liveNote':
          final patientId = args['patientId'] as String;
          final tabKey = args['tabKey'] as String;
          final text = args['text'] as String? ?? '';
          final flush = args['flush'] == true;
          // 1) INSTANT UI mirror — bump `_liveText` + rebuild so the
          //    in-app NotesWidget shows the same text this frame.
          if (mounted) {
            setState(() {
              _liveText['${patientId}::$tabKey'] = text;
            });
          }
          // 2) DEBOUNCED PERSIST — schedule a SQLite write +
          //    sync_operation. A burst of keystrokes collapses into
          //    exactly one NocoDB push. `flush=true` (popup closing /
          //    disposing) writes immediately.
          final key = '${patientId}::$tabKey';
          _saveDebounce[key]?.cancel();
          if (flush) {
            await _persistNoteText(patientId, tabKey, text);
          } else {
            _saveDebounce[key] = Timer(
              const Duration(milliseconds: 400),
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
    });
  }

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
                            color: Color(0xFF334155),
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
                        _saveDebounce[key] = Timer(
                          const Duration(milliseconds: 400),
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
  void _pushDraftToOpenWindow(String tabKey, String text) {
    if (kIsWeb) return; // Pas de fenêtre détachée possible sur web.
    final key = '${_dossier.patient.id}::$tabKey';
    final windowId = _openNoteWindows[key];
    if (windowId == null) return;
    DesktopMultiWindow.invokeMethod(windowId, 'pushNote', {
      'patientId': _dossier.patient.id,
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
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (!mounted) return;
    _VisitReportStateCache.setTabIndex(_dossier.id, _tabController.index);
    setState(() {});
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
    // Sur web : pas de vraie fenêtre OS séparée possible. On ouvre un
    // modal plein écran à la place (le `NotesWidget` reste synchronisé
    // via son propre state — inutile de passer par IPC).
    if (kIsWeb) {
      _openNoteModalFallback(sourceTab);
      return;
    }
    // Pre-fetch the existing note text in the MAIN engine (which has
    // sqflite) and pass it inline in the launch payload so the secondary
    // window can render immediately without a DB call.
    final existingJson = await _dataService.fetchNoteDrawingJson(
      patientId: _dossier.patient.id,
      tabKey: sourceTab,
      pageNumber: 0,
    );
    final initialText = _extractTextFromDrawingJson(existingJson);
    final payload = jsonEncode({
      'patientId': _dossier.patient.id,
      'tabKey': sourceTab,
      'title': 'Note — $sourceTab',
      'initialText': initialText,
    });
    final window = await DesktopMultiWindow.createWindow(payload);
    _openNoteWindows['${_dossier.patient.id}::$sourceTab'] = window.windowId;
    // Seed live text with what's in the DB so the in-app NotesWidget
    // already shows it as "live" (mirrors the popup's initial content).
    _liveText['${_dossier.patient.id}::$sourceTab'] = initialText;
    // Ouvre à la dernière position ET taille connues. La popup reporte
    // sa frame toutes les secondes via IPC (`reportNoteFrame`) donc
    // "position + format" sont conservés entre ouvertures, même si
    // l'utilisateur drague la fenêtre manuellement.
    final origin = _VisitReportStateCache.lastNoteWindowOrigin
        ?? const Offset(200, 200);
    window
      ..setFrame(origin & _VisitReportStateCache.lastNoteWindowSize)
      ..setTitle('Note — $sourceTab')
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
                  onDraftChange: (draft) =>
                      _pushDraftToOpenWindow(tabKey, draft.text),
                  onExpandToTab: () => _openNoteInSeparateWindow(tabKey),
                  showSaveButton: false,
                  embedded: false,
                  fillParentHeight: true,
                  allowPagination: true,
                  stackedCards: true,
                  backgroundContent: isMedical
                      ? _MedicalFlagBadges(flags: _medicalFlagNumbers)
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
              indicator: const UnderlineTabIndicator(
                borderSide: BorderSide(
                  color: Color(0xFF7C6DAA), // violet foncé
                  width: 1.5,
                ),
                insets: EdgeInsets.zero,
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              indicatorPadding: EdgeInsets.zero,
              // Couleur du label : violet foncé pour l'actif, slate
              // gris pour les inactifs (inchangé).
              labelColor: const Color(0xFF554A63),
              unselectedLabelColor: const Color(0xFF334155),
              labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              unselectedLabelStyle:
                  const TextStyle(fontWeight: FontWeight.normal),
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
            color: const Color(0xFFE2E8F0),
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
  Widget _buildGenerateReportButton() {
    return InkWell(
      onTap: _isGeneratingReport ? null : _generateReport,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        // Hauteur 44 px = pill du tab bar (60 px) - 8 px de padding
        // vertical → l'action s'aligne pile avec la zone cliquable
        // des onglets.
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: _isGeneratingReport
              ? const Color(0xFF9888B5)
              : const Color(0xFF7C6DAA),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isGeneratingReport) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 9),
              const Text(
                'Génération…',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ] else
              const Text(
                'Générer',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
          ],
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
    setState(() => _isGeneratingReport = true);

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
      if (mounted) setState(() => _isGeneratingReport = false);
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
        );
      } else {
        // ignore: avoid_print
        print('[report] importDocumentBytes patientId="$patientId" '
            'fileName="${result.fileName}" bytes=${result.bytes.length}');
        inserted = await _dataService.importDocumentBytes(
          patientId: patientId,
          dossierId: _dossier.id,
          bytes: result.bytes,
          fileName: result.fileName,
          title: result.fileName.replaceAll(RegExp(r'\.pdf$'), ''),
          tags: const ['Rapport'],
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
        return;
      }

      _showReportSuccess(result, totalDocs: docs.length);
    } catch (error) {
      // Filet de sécurité : toute autre exception non capturée → queue
      // différée plutôt qu'une erreur sèche.
      await _enqueueReportForLater(
        reason: 'Génération interrompue : $error. Sera retentée plus tard.',
      );
    } finally {
      if (mounted) setState(() => _isGeneratingReport = false);
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
          backgroundColor: const Color(0xFF7C6DAA),
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
    final stats = result.stats;
    final applied = stats?['applied'];
    final missingValue = stats?['missingValue'];
    final extra = (applied != null && missingValue != null)
        ? ' ($applied champs remplis, $missingValue à compléter)'
        : '';
    final docCountSuffix = totalDocs != null
        ? '\n→ $totalDocs document${totalDocs > 1 ? 's' : ''} dans le dossier'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Rapport ajouté dans les Documents : ${result.fileName}$extra'
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
        // Onglet Photos — pleine largeur (pas de notes latérales).
        // Voir `lib/screens/visit_report/photos_tab.dart`.
        _wrapTabWithNotes(
          'Photos',
          PhotosTab(dossier: _dossier),
        ),
        _wrapTabWithNotes(
          'Préconisations',
          RecommendationsTab(dossier: _dossier, repository: _repository),
        ),
        _wrapTabWithNotes(
          'Plans',
          PlansTab(dossier: _dossier),
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
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                      ),
                      // Badges insérés ENTRE le nom et l'adresse — parité
                      // avec l'écran dossier (demande utilisateur).
                      if (accompanimentLabel.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        AccompanimentBadge(
                          value: accompanimentLabel,
                          large: true,
                        ),
                      ],
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

/// Marqueurs numérotés sur le canvas de la note "Contexte de vie >
/// Médical". Format : `N -` en noir gras, taille 28. Positionnés
/// en colonne à gauche — les slots se remplissent de HAUT EN BAS selon
/// l'ordre des flags actifs (pas leur numéro) :
///   • 1 flag actif   → top
///   • 2 flags actifs → top + middle
///   • 3 flags actifs → top + middle + bottom
/// Donc cocher uniquement le 3 l'affiche EN HAUT ; cocher 2 et 3 met
/// le 2 en haut et le 3 au milieu ; cocher les 3 remplit les 3 slots.
class _MedicalFlagBadges extends StatelessWidget {
  const _MedicalFlagBadges({required this.flags});
  final Set<int> flags;

  @override
  Widget build(BuildContext context) {
    if (flags.isEmpty) return const SizedBox.shrink();
    final sorted = flags.toList()..sort();
    return LayoutBuilder(
      builder: (ctx, constraints) {
        const leftPad = 16.0;
        const topPad = 12.0;
        const bottomPad = 12.0;
        return Stack(
          children: [
            for (var i = 0; i < sorted.length; i++)
              Positioned(
                left: leftPad,
                top: _slotTopFor(
                  index: i,
                  total: sorted.length,
                  canvasHeight: constraints.maxHeight,
                  topPad: topPad,
                  bottomPad: bottomPad,
                ),
                child: _FlagMarker(number: sorted[i]),
              ),
          ],
        );
      },
    );
  }

  /// Pour un [total] de flags actifs, retourne le `top:` absolu du slot
  /// d'index [index] (0 = haut, total-1 = bas).
  /// - total == 1 : un seul slot en haut
  /// - total == 2 : haut + milieu
  /// - total == 3 : haut + milieu + bas
  double _slotTopFor({
    required int index,
    required int total,
    required double canvasHeight,
    required double topPad,
    required double bottomPad,
  }) {
    if (total <= 1) return topPad;
    const markerApproxHeight = 30.0; // ~ fontSize 28 + descenders
    final topSlot = topPad;
    final middleSlot = (canvasHeight / 2) - (markerApproxHeight / 2);
    final bottomSlot = canvasHeight - bottomPad - markerApproxHeight;
    if (total == 2) {
      return index == 0 ? topSlot : middleSlot;
    }
    // total == 3
    if (index == 0) return topSlot;
    if (index == 1) return middleSlot;
    return bottomSlot;
  }
}

class _FlagMarker extends StatelessWidget {
  const _FlagMarker({required this.number});
  final int number;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$number -',
      style: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w800,
        color: Colors.black,
        height: 1.0,
      ),
    );
  }
}
