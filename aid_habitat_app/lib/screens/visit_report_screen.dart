import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
// Desktop only (macOS/Windows/Linux). Sur web + mobile, un stub vide est
// importé — les appels sont shuntés par un garde `kIsWeb` avant exécution.
import '../services/multi_window_stub.dart'
    if (dart.library.io) 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../models/types.dart';
import '../services/dossier_repository.dart';
import '../services/data_service.dart';
import '../components/notes_widget.dart';
import 'visit_report/beneficiary_tab.dart';
import 'visit_report/context_tab.dart';
import 'visit_report/mesures_tab.dart';
import 'visit_report/accessibility_tab.dart';
import 'visit_report/bathroom_tab.dart';
import 'visit_report/wc_tab.dart';
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

  static const List<String> _tabs = [
    'Bénéficiaire',
    'Contexte de vie',
    'Mesures',
    'Accessibilité',
    'Salle de bain',
    'WC',
    'Préconisations',
    'Plans',
  ];

  /// Sous-sections de chaque onglet. Le panneau notes à droite affiche
  /// une note indépendante par sous-section (tabKey = '$tab-$section').
  /// Les onglets absents de cette map (Mesures, Plans, Préconisations)
  /// sont en pleine largeur et n'ont pas de panneau notes latéral.
  static const Map<String, List<String>> _tabSubsections = {
    'Bénéficiaire': ['Profil', 'Foyer', 'Santé', 'Admin'],
    'Contexte de vie': ['Médical', 'Autonomie'],
    'Accessibilité': ['Général', 'Intérieur', 'Extérieur', 'Volets'],
    'Salle de bain': ['Équipements', 'Porte'],
    'WC': ['Config. & équipements', 'Porte'],
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
  /// (Pathologie=1, Suivi médical=2, Sensoriel=3). On check, append a
  /// `N - ` marker line to the Contexte de vie note. On uncheck, remove
  /// the line that starts with that marker — along with anything the
  /// visitor may have typed on that same line.
  Future<void> _handleMedicalFlagToggle(int flagNumber, bool checked) async {
    // Les drapeaux médicaux appartiennent à la sous-section "Médical".
    const tabKey = 'Contexte de vie-Médical';
    final patientId = _dossier.patient.id;
    final existingJson = await _dataService.fetchNoteDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: 0,
    );
    final currentText = _extractTextFromDrawingJson(existingJson);
    final nextText = checked
        ? _addMedicalFlagMarker(currentText, flagNumber)
        : _removeMedicalFlagMarker(currentText, flagNumber);
    if (nextText == currentText) return;
    await _persistNoteText(patientId, tabKey, nextText);
    if (!mounted) return;
    setState(() {
      _liveText['${patientId}::$tabKey'] = nextText;
    });
  }

  String _addMedicalFlagMarker(String text, int flagNumber) {
    final marker = '$flagNumber - ';
    final alreadyPresent =
        text.startsWith(marker) || text.contains('\n$marker');
    if (alreadyPresent) return text;
    final separator = text.isEmpty
        ? ''
        : (text.endsWith('\n') ? '' : '\n');
    return '$text$separator$marker';
  }

  String _removeMedicalFlagMarker(String text, int flagNumber) {
    final marker = '$flagNumber - ';
    if (text.startsWith(marker)) {
      final newlineIdx = text.indexOf('\n');
      if (newlineIdx == -1) return '';
      return text.substring(newlineIdx + 1);
    }
    final searchFor = '\n$marker';
    final idx = text.indexOf(searchFor);
    if (idx == -1) return text;
    final endOfLine = text.indexOf('\n', idx + searchFor.length);
    if (endOfLine == -1) return text.substring(0, idx);
    return text.substring(0, idx) + text.substring(endOfLine);
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

  /// Construit le panneau notes à droite : une note indépendante par
  /// sous-section, scrollable verticalement.
  Widget _buildNotesPanel(String activeTab, List<String> subsections) {
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: subsections.length,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (_, i) {
        final section = subsections[i];
        final tabKey = '$activeTab-$section';
        final liveKey = '${_dossier.patient.id}::$tabKey';
        return SizedBox(
          height: 268,
          child: NotesWidget(
            key: ValueKey(liveKey),
            patientId: _dossier.patient.id,
            tabKey: tabKey,
            title: section,
            liveText: _liveText[liveKey],
            onDraftChange: (draft) => _pushDraftToOpenWindow(tabKey, draft.text),
            onExpandToTab: () => _openNoteInSeparateWindow(tabKey),
            showSaveButton: false,
            embedded: false,
            fillParentHeight: false,
            allowPagination: true,
          ),
        );
      },
    );
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
    final activeTab = _tabs[_tabController.index];
    // Sous-sections de l'onglet courant — null pour Mesures/Plans/Préconisations
    final subsections = _tabSubsections[activeTab];

    final tabView = TabBarView(
      controller: _tabController,
      children: [
        BeneficiaryTab(
          dossier: _dossier,
          repository: _repository,
          onPatientChanged: _refreshDossier,
        ),
        ContextTab(
          dossier: _dossier,
          repository: _repository,
          onMedicalFlagToggled: _handleMedicalFlagToggle,
        ),
        MesuresTab(dossier: _dossier, repository: _repository),
        AccessibilityTab(
          dossier: _dossier,
          repository: _repository,
          onHousingChanged: _notifyHousingChanged,
        ),
        BathroomTab(
          dossier: _dossier,
          repository: _repository,
          housingRefreshToken: _housingVersion,
        ),
        WcTab(
          dossier: _dossier,
          repository: _repository,
          housingRefreshToken: _housingVersion,
        ),
        RecommendationsTab(dossier: _dossier, repository: _repository),
        PlansTab(dossier: _dossier),
      ],
    );

    final formPanel = Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: tabView,
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${patient.lastName.toUpperCase()} ${patient.firstName}',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (addressLine.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          addressLine,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF64748B),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Ligne 2 : barre de navigation des onglets sur toute la largeur.
            _buildTabBar(),
            const SizedBox(height: 16),
            // Content area — two columns except on Mesures/Plans where the
            // form takes the full width (no notes panel).
            Expanded(
              child: (subsections == null || subsections.isEmpty)
                  ? formPanel
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 1, child: formPanel),
                        const SizedBox(width: 24),
                        Expanded(
                          flex: 2,
                          child: _buildNotesPanel(activeTab, subsections),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
