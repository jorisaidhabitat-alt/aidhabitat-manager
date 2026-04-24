import 'dart:async';
import 'dart:convert';

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
        // IndexedStack conserve l'état de dessin de chaque section lors
        // des changements — pas de re-création de NotesWidget quand
        // l'utilisateur alterne entre Profil / Foyer / Santé / Admin.
        Expanded(
          child: IndexedStack(
            index: safeIdx,
            children: List.generate(subsections.length, (i) {
              final section = subsections[i];
              final tabKey = '$activeTab-$section';
              final liveKey = '${_dossier.patient.id}::$tabKey';
              // Sur "Contexte de vie > Médical", les flags cochés dans
              // le formulaire apparaissent en badges numérotés sur la
              // zone de dessin du canvas (plus dans le texte).
              final isMedical =
                  tabKey == 'Contexte de vie-Médical';
              return NotesWidget(
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
                // Nouvelle mise en page "deux cartes empilées" — texte
                // en haut, canvas en bas avec pagination flottante en
                // haut-droite et toolbar en bas-centre.
                stackedCards: true,
                backgroundContent: isMedical
                    ? _MedicalFlagBadges(flags: _medicalFlagNumbers)
                    : null,
                // Sur l'onglet Médical : les flags sont stockés PAR PAGE
                // dans `drawing_json`. La prop `medicalFlags` propage la
                // sélection des cases ContextTab → NotesWidget sauvegarde
                // dans la page courante. Le callback inverse rafraîchit
                // les cases quand l'utilisateur change de page.
                medicalFlags: isMedical ? _medicalFlagNumbers : null,
                onMedicalFlagsChanged:
                    isMedical ? _handleMedicalFlagsFromNotes : null,
              );
            }),
          ),
        ),
      ],
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
        // Fond de l'onglet actif : violet pâle F6EDFB — même teinte
        // que le bandeau sous-menu du relevé (Profil / Foyer / …)
        // pour une cohérence visuelle.
        indicator: BoxDecoration(
          color: const Color(0xFFF6EDFB),
          borderRadius: BorderRadius.circular(50),
        ),
        indicatorSize: TabBarIndicatorSize.label,
        indicatorPadding:
            const EdgeInsets.symmetric(horizontal: -12, vertical: 6),
        // Texte toujours en noir, poids normal (onglet actif +
        // inactifs). Seul le fond violet pâle #F6EDFB distingue
        // l'onglet actif.
        labelColor: Colors.black,
        unselectedLabelColor: Colors.black,
        labelStyle: const TextStyle(fontWeight: FontWeight.normal),
        unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal),
        labelPadding: const EdgeInsets.symmetric(horizontal: 16),
        tabs: _tabs.map((tab) => Tab(text: tab)).toList(),
        dividerColor: Colors.transparent,
        padding: const EdgeInsets.all(4),
        tabAlignment: TabAlignment.start,
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
      // Désactive le swipe horizontal entre onglets. Raison : l'onglet
      // Plans a une zone de dessin plein écran — dès qu'un ergo pose le
      // doigt dessus et bouge horizontalement, le TabBarView prenait la
      // gesture et faisait défiler vers l'onglet voisin, arrachant le
      // trait en cours. Les onglets restent accessibles via la barre du
      // haut (TabBar est isScrollable=true).
      physics: const NeverScrollableScrollPhysics(),
      children: [
        BeneficiaryTab(
          dossier: _dossier,
          repository: _repository,
          onPatientChanged: _refreshDossier,
          initialSubSection:
              _activeSubsectionByTab['Bénéficiaire'] ?? 0,
          onSubSectionChanged: (i) => setState(
              () => _activeSubsectionByTab['Bénéficiaire'] = i),
        ),
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

    // Carte blanche du formulaire — sans padding global pour que les
    // bandeaux internes des tabs (ex: sous-menu Profil/Foyer/Santé/Admin
    // du Bénéficiaire) puissent aller de bord à bord jusqu'en haut,
    // comme le bandeau "Bénéficiaire" de l'écran dossier. Chaque tab
    // gère son propre padding interne pour le contenu.
    final formPanel = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
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
                        AccompanimentBadge(value: accompanimentLabel),
                      ],
                      if (incomeLabel.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        IncomeCategoryBadge(value: incomeLabel),
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
