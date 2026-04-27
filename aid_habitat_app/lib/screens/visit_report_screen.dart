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
    'Préconisations',
    'Plans',
  ];

  /// Sous-sections de chaque onglet. Le panneau notes à droite affiche
  /// une note indépendante par sous-section (tabKey = '$tab-$section').
  /// Les onglets absents de cette map (Mesures, Photos, Plans,
  /// Préconisations) sont en pleine largeur et n'ont pas de panneau
  /// notes latéral.
  static const Map<String, List<String>> _tabSubsections = {
    'Bénéficiaire': ['Profil', 'Foyer', 'Santé', 'Admin'],
    'Contexte de vie': ['Médical', 'Autonomie'],
    'Accessibilité': ['Général', 'Extérieur'],
    'Salle de bain': ['Équipements'],
    'WC': ['Config. & équipements'],
  };

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
              final tabKey = '$activeTab-$section';
              final liveKey = '${_dossier.patient.id}::$tabKey';
              final isMedical = tabKey == 'Contexte de vie-Médical';
              final isActive = i == safeIdx;
              return _NotesPanelLayer(
                isActive: isActive,
                child: NotesWidget(
                  key: ValueKey(liveKey),
                  patientId: _dossier.patient.id,
                  tabKey: tabKey,
                  title: section,
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
      decoration: BoxDecoration(
        color: Colors.white,
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
              // Fond de l'onglet actif : violet pâle F6EDFB — même teinte
              // que le bandeau sous-menu du relevé (Profil / Foyer / …)
              // pour une cohérence visuelle.
              indicator: BoxDecoration(
                color: const Color(0xFFEDE8F5),
                borderRadius: BorderRadius.circular(50),
              ),
              indicatorSize: TabBarIndicatorSize.label,
              indicatorPadding:
                  const EdgeInsets.symmetric(horizontal: -12, vertical: 6),
              // Onglet actif : fond violet pâle + texte + trait dark violet
              // (#7C6DAA). Onglet inactif : texte slate gris foncé.
              labelColor: const Color(0xFF554A63),
              unselectedLabelColor: const Color(0xFF334155),
              labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              unselectedLabelStyle:
                  const TextStyle(fontWeight: FontWeight.normal),
              labelPadding: const EdgeInsets.symmetric(horizontal: 16),
              tabs: List.generate(_tabs.length, (i) {
                final label = _tabs[i];
                return Tab(
                  // `SoftTapScale.passThrough` observe le pointer event sans
                  // réclamer le tap → le TabBar reste fonctionnel et on ajoute
                  // l'effet zoom/dezoom au-dessus, comme demandé (mêmes
                  // sensations que les boutons de la sidebar).
                  child: SoftTapScale.passThrough(
                    child: AnimatedBuilder(
                      animation: _tabController,
                      builder: (context, _) {
                        final isActive = _tabController.index == i;
                        // Underline strictly smaller than the text and centered
                        // (CrossAxisAlignment.center — défaut). Ratio ~50 % de
                        // la largeur estimée du texte (au lieu de ~100 %).
                        final underlineWidth =
                            (label.length * 3.2).clamp(18.0, 60.0);
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(label),
                            const SizedBox(height: 3),
                            Container(
                              height: 1.5,
                              width: underlineWidth,
                              decoration: BoxDecoration(
                                color: isActive
                                    ? const Color(0xFF7C6DAA) // violet foncé
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
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
    try {
      // Pousse les changements locaux EN ATTENTE vers NocoDB AVANT
      // d'appeler le serveur de génération PDF — sinon le serveur lit
      // `getDossiersForApp` (NocoDB direct) et reçoit l'ancienne valeur
      // pour les champs récemment modifiés. `runSync` flush la queue
      // d'opérations locales (debounced 200 ms côté `SyncEngine`). Si
      // offline ou si la sync échoue, on génère quand même — le serveur
      // retombera sur ce qu'il connaît.
      try {
        await _dataService.runSync();
      } catch (_) {
        // Pas bloquant — on continue avec ce qui est déjà sur NocoDB.
      }

      final result = await _dataService.downloadVisitReport(
        dossierId: _dossier.id,
      );

      // Insertion dans l'espace Documents du dossier. L'op
      // `upload_file` queued par `importDocumentBytes` est ensuite
      // poussée à NocoDB par la sync engine (debounced 200 ms) —
      // pas besoin d'attendre ici, le doc apparaît déjà localement.
      // Le tag « Rapport » est filtré par DocumentsScreen pour
      // organiser le dossier (cf. `_kAvailableTags`).
      await _dataService.importDocumentBytes(
        patientId: _dossier.patient.id,
        bytes: result.bytes,
        fileName: result.fileName,
        title: result.fileName.replaceAll(RegExp(r'\.pdf$'), ''),
        tags: const ['Rapport'],
      );

      _showReportSuccess(result);
    } catch (error) {
      _showReportError('Génération impossible : $error');
    } finally {
      if (mounted) setState(() => _isGeneratingReport = false);
    }
  }

  void _showReportSuccess(
    ({Uint8List bytes, String fileName, Map<String, dynamic>? stats}) result,
  ) {
    if (!mounted) return;
    final stats = result.stats;
    final applied = stats?['applied'];
    final missingValue = stats?['missingValue'];
    final extra = (applied != null && missingValue != null)
        ? ' ($applied champs remplis, $missingValue à compléter)'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Rapport ajouté dans les Documents : ${result.fileName}$extra',
        ),
        backgroundColor: const Color(0xFF166534),
        duration: const Duration(seconds: 4),
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
                      Flexible(
                        child: Text(
                          '${patient.lastName.toUpperCase()} ${patient.firstName}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                          overflow: TextOverflow.ellipsis,
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
                        Flexible(
                          child: Text(
                            addressLine,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF64748B),
                            ),
                            overflow: TextOverflow.ellipsis,
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
