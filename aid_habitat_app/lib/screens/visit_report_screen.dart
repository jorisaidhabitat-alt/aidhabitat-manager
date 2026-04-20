import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../components/notes_widget.dart';
import '../models/types.dart';
import 'visit_tabs/accessibility_tab.dart';
import 'visit_tabs/bathroom_tab.dart';
import 'visit_tabs/beneficiary_tab.dart';
import 'visit_tabs/life_context_tab.dart';
import 'visit_tabs/measurements_tab.dart';
import 'visit_tabs/plans_tab.dart';
import 'visit_tabs/recommendations_tab.dart';
import 'visit_tabs/wc_tab.dart';

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
  static const _tabs = [
    'B\u00e9n\u00e9ficiaire',
    'Contexte de vie',
    'Mesures',
    'Accessibilit\u00e9',
    'Salle de bain',
    'WC',
    'Pr\u00e9conisations',
    'Plans',
  ];

  late TabController _tabController;
  late Dossier _dossier;

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
    await showDialog<void>(
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
    if (!_tabController.indexIsChanging) setState(() {});
  }

  void _onDossierChanged(Dossier updated) {
    setState(() => _dossier = updated);
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
    // Open at whatever size the user last resized a note popup to. The
    // popup itself reports its size every second via IPC so "format" is
    // retained across sessions of the visit report screen.
    window
      ..setFrame(
          const Offset(200, 200) & _VisitReportStateCache.lastNoteWindowSize)
      ..setTitle('Note — $sourceTab')
      ..show();
  }

  /// Bumps the housing version to trigger a re-derivation of Salle de
  /// bain / WC instances from the fresh Accessibilité selections.
  void _notifyHousingChanged() {
    if (!mounted) return;
    setState(() => _housingVersion++);
  }

  Widget _buildTabBar() {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(50),
      ),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        indicator: BoxDecoration(
          color: const Color(0xFFD8D0DC),
          borderRadius: BorderRadius.circular(50),
        ),
        indicatorSize: TabBarIndicatorSize.label,
        indicatorPadding:
            const EdgeInsets.symmetric(horizontal: -12, vertical: 6),
        labelColor: const Color(0xFF554a63),
        unselectedLabelColor: Colors.black87,
        labelStyle: const TextStyle(fontWeight: FontWeight.bold),
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        tabs: _tabs.map((tab) => Tab(text: tab)).toList(),
        dividerColor: Colors.transparent,
        padding: const EdgeInsets.all(4),
        tabAlignment: TabAlignment.start,
        // Disable hover / splash / pressed overlay on tabs so hovering
        // "Bénéficiaire" (and any other tab) does NOT show a gray fill.
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
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

  @override
  Widget build(BuildContext context) {
    final currentIndex = _tabController.index;
    final isPlansTab = currentIndex == 7;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          // ---- Top nav ----
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                color: const Color(0xFF554a63),
                onPressed: widget.onBack,
                tooltip: 'Retour',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    color: const Color(0xFFD8D0DC),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  labelColor: const Color(0xFF554a63),
                  unselectedLabelColor: const Color(0xFF907CA1),
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  labelPadding:
                      const EdgeInsets.symmetric(horizontal: 14),
                  tabs: _tabs.map((t) => Tab(text: t)).toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Content ----
          Expanded(
            child: isPlansTab
                ? PlansTab(
                    dossier: _dossier,
                    tabKey: _tabs[currentIndex],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Form column
                      Expanded(
                        flex: 1,
                        child: _buildFormTab(currentIndex),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        width: 1,
                        color: const Color(0xFFF1F5F9),
                      ),
                      const SizedBox(width: 16),
                      // Notes column
                      Expanded(
                        flex: 2,
                        child: ClipRect(
                          child: NotesWidget(
                            patientId: _dossier.patient.id,
                            tabKey: _tabs[currentIndex],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormTab(int index) {
    switch (index) {
      case 0:
        return BeneficiaryTab(
          dossier: _dossier,
          onDossierChanged: _onDossierChanged,
        );
      case 1:
        return LifeContextTab(
          dossier: _dossier,
          onDossierChanged: _onDossierChanged,
        );
      case 2:
        return MeasurementsTab(dossier: _dossier);
      case 3:
        return AccessibilityTab(
          dossier: _dossier,
          onDossierChanged: _onDossierChanged,
        );
      case 4:
        return BathroomTab(dossier: _dossier);
      case 5:
        return WcTab(dossier: _dossier);
      case 6:
        return RecommendationsTab(dossier: _dossier);
      default:
        return const SizedBox.shrink();
    }
  }
}
