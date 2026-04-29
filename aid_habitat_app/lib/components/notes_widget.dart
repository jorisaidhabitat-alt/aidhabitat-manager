import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../services/data_service.dart';
import '../services/save_debounce.dart';

// =============================================================================
// Enums & constantes — équivalents directs du composant React NotesCanvas.tsx
// =============================================================================

/// Outils de dessin disponibles (identiques à la version React).
enum NoteTool { pen, highlighter, eraser, line, rect }

/// Toolsets qui contrôlent les outils disponibles — voir React prop `toolset`.
enum NoteToolset { quick, advanced, structured }

/// Mode de fond du canvas — équivalent de la prop `mode`.
enum NoteCanvasMode { freeform, grid }

/// Emplacement de la toolbar — équivalent de la prop `toolbarPlacement`.
enum NoteToolbarPlacement { bottomCenter, topRight }

/// États du bouton Save (label + animation).
enum _SaveLabel { idle, saved, error }

/// Payload émis par `onSave` (équivalent de `{ text, drawingJson, previewDataUrl }`).
class NoteSavePayload {
  final String text;
  final String drawingJson;

  /// En React ce champ est le dataURL PNG. Dans la version Flutter on expose
  /// également un dataURL (via `RepaintBoundary.toImage`) pour la parité.
  final String? previewDataUrl;

  const NoteSavePayload({
    required this.text,
    required this.drawingJson,
    this.previewDataUrl,
  });
}

/// Payload émis par `onDraftChange`.
class NoteDraftPayload {
  final String text;
  final String drawingJson;
  final bool isDirty;

  const NoteDraftPayload({
    required this.text,
    required this.drawingJson,
    required this.isDirty,
  });
}

// =============================================================================
// Modèle de stroke persisté (format JSON identique à celui de React)
// =============================================================================

class _Stroke {
  final NoteTool tool;
  final int color; // ARGB int
  final double size;
  final List<Offset> points; // normalisés 0..1

  _Stroke({
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
  });

  Map<String, dynamic> toJson() => {
    'tool': _toolToString(tool),
    'color': _colorToHex(color),
    'size': size,
    'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
  };

  static _Stroke? fromJson(Map<String, dynamic> json) {
    final tool = _toolFromString(json['tool']?.toString() ?? 'pen');
    if (tool == null) return null;
    final color = _colorFromHex(json['color']?.toString() ?? '#111827');
    final size = (json['size'] as num?)?.toDouble() ?? 2.0;
    final rawPoints = json['points'] as List?;
    if (rawPoints == null) return null;
    final points = rawPoints
        .whereType<Map>()
        .map((raw) {
          final x = (raw['x'] as num?)?.toDouble() ?? 0;
          final y = (raw['y'] as num?)?.toDouble() ?? 0;
          return Offset(x, y);
        })
        .toList();
    if (points.isEmpty) return null;
    // Plafonne à 2000 points par stroke (parité React — ligne 857).
    if (points.length > 2000) {
      return _Stroke(
        tool: tool,
        color: color,
        size: size,
        points: points.sublist(0, 2000),
      );
    }
    return _Stroke(tool: tool, color: color, size: size, points: points);
  }
}

String _toolToString(NoteTool tool) {
  switch (tool) {
    case NoteTool.pen:
      return 'pen';
    case NoteTool.highlighter:
      return 'highlighter';
    case NoteTool.eraser:
      return 'eraser';
    case NoteTool.line:
      return 'line';
    case NoteTool.rect:
      return 'rect';
  }
}

NoteTool? _toolFromString(String value) {
  switch (value) {
    case 'pen':
      return NoteTool.pen;
    case 'highlighter':
      return NoteTool.highlighter;
    case 'eraser':
      return NoteTool.eraser;
    case 'line':
      return NoteTool.line;
    case 'rect':
      return NoteTool.rect;
  }
  return null;
}

String _colorToHex(int argb) {
  final rgb = argb & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}

int _colorFromHex(String hex) {
  var value = hex.replaceFirst('#', '');
  if (value.length == 6) {
    value = 'ff$value';
  } else if (value.length != 8) {
    return 0xff111827;
  }
  return int.tryParse(value, radix: 16) ?? 0xff111827;
}

// =============================================================================
// Presets (1:1 avec React)
// =============================================================================

/// Palette 8 couleurs identique à la version React.
const List<int> _kColorPresets = [
  0xff111827, // noir / dark gray
  0xffdc2626, // rouge
  0xffea580c, // orange
  0xffca8a04, // jaune foncé (gold)
  0xff16a34a, // vert
  0xff2563eb, // bleu
  0xff7c3aed, // violet
  0xffec4899, // rose
];

const int _kDefaultPenColor = 0xff111827;
const int _kDefaultHighlighterColor = 0xffFDE047; // yellow-300
const double _kDefaultPenSize = 2.0;
const double _kDefaultHighlighterSize = 10.0;
const double _kDefaultEraserSize = 18.0;
const Color _kAccentColor = Color(0xFF7C6DAA);
const Color _kActiveText = Color(0xFF554A63);
const double _kGridCell = 24.0;

// Constantes de la mise en page "deux cartes empilées" (parité maquette).
const Color _kStackedBorder = Color(0xFFEDE9EF);
// Fond splitter = même violet clair que les icônes Documents / VAD sur
// l'écran dossier (cohérence visuelle — demande utilisateur).
const Color _kStackedSplitterBg = Color(0xFFEDE8F5);
const Color _kStackedViolet = Color(0xFF7C6DAA);
const Color _kStackedVioletSoft = Color(0xFFEDE8F5);
const Color _kStackedPinkSoft = Color(0xFFE8A4B0);

List<NoteTool> _availableToolsFor(NoteToolset toolset) {
  switch (toolset) {
    case NoteToolset.quick:
      return const [NoteTool.pen, NoteTool.eraser];
    case NoteToolset.advanced:
      return const [NoteTool.pen, NoteTool.highlighter, NoteTool.eraser];
    case NoteToolset.structured:
      return const [NoteTool.pen, NoteTool.line, NoteTool.rect, NoteTool.eraser];
  }
}

// =============================================================================
// NotesWidget — point d'entrée public (toutes les props du React)
// =============================================================================

class NotesWidget extends StatefulWidget {
  const NotesWidget({
    super.key,
    required this.patientId,
    required this.tabKey,
    this.initialText = '',
    this.placeholder = 'Saisir une note...',
    this.currentPage = 0,
    this.totalPages = 1,
    this.onPageChange,
    this.onSave,
    this.onAddPage,
    this.onDeletePage,
    this.canDeletePage = false,
    this.mode = NoteCanvasMode.freeform,
    this.showText = true,
    this.toolset = NoteToolset.advanced,
    this.allowPagination = true,
    this.sharedText = false,
    this.allowTextModal = true,
    this.showSaveButton = true,
    this.showCanvas = true,
    this.expandModalFullscreen = false,
    this.onDraftChange,
    this.embedded = false,
    this.toolbarPlacement = NoteToolbarPlacement.bottomCenter,
    this.toolbarDockedToBorder = false,
    this.toolbarInFooter = false,
    this.fillParentHeight = false,
    this.activeTool,
    this.onToolChange,
    this.backgroundContent,
    this.title = 'Notes',
    this.subtitle,
    this.autoSaveToService = true,
    this.maxPages = 20,
    this.onExpandToTab,
    this.externalRefreshToken = 0,
    this.liveText,
    this.leadingNavWidget,
    this.medicalFlags,
    this.onMedicalFlagsChanged,
    this.stackedCards = false,
  });

  // Identifiants / titre
  final String patientId;
  final String tabKey;
  final String title;
  final String? subtitle;
  final int maxPages;

  /// Bumped by the parent whenever the underlying note was modified from
  /// outside (e.g. a detached OS note window wrote to SQLite). When it
  /// changes AND the local widget isn't dirty, the current page is
  /// re-fetched and the text area is re-hydrated. When the field is
  /// focused (user actively typing) the refresh is ignored to avoid
  /// clobbering in-flight edits.
  final int externalRefreshToken;

  /// Live text pushed from an external source (detached OS note window)
  /// — applied immediately if the local TextField isn't focused. This is
  /// the fast path that keeps the popup and the in-app widget in sync
  /// without waiting for a DB round-trip.
  final String? liveText;

  /// Called when the user taps the "Agrandir" button. If provided, the
  /// notes widget does NOT show its floating text modal — it delegates to
  /// the parent, which can e.g. open a real new tab in a TabBar.
  final VoidCallback? onExpandToTab;

  /// Widget optionnel affiché à gauche dans la ligne de navigation
  /// (même ligne que les flèches undo/redo). Utilisé par ex. par
  /// MesuresTab pour injecter le sélecteur d'occupant.
  final Widget? leadingNavWidget;

  // Contenu initial
  final String initialText;
  final String placeholder;

  // Pagination
  final int currentPage;
  final int totalPages;
  final void Function(int page)? onPageChange;
  final FutureOr<void> Function()? onAddPage;
  final FutureOr<void> Function()? onDeletePage;
  final bool canDeletePage;
  final bool allowPagination;

  /// When true, the written note is shared across all drawing pages —
  /// switching pages only swaps the strokes, not the text. Typing mirrors
  /// the same text into every page's stored record so persistence stays
  /// coherent even as pages are added or removed.
  final bool sharedText;

  /// When false, the "expand" handle that opens a floating text modal
  /// (or forwards to `onExpandToTab`) is hidden and the in-widget modal
  /// is never rendered. Used by the dossier quick-notes card where the
  /// note is meant to stay inline only.
  final bool allowTextModal;

  // Sauvegarde
  final FutureOr<void> Function(NoteSavePayload payload)? onSave;
  final void Function(NoteDraftPayload draft)? onDraftChange;

  /// Si true (défaut), écrit automatiquement dans DataService().saveNoteDrawingJson
  /// avec un debounce de 500ms. Passer à false pour laisser le parent gérer.
  final bool autoSaveToService;

  // Configuration d'affichage
  final NoteCanvasMode mode;
  final bool showText;
  final NoteToolset toolset;
  final bool showSaveButton;

  /// Si false, masque entièrement la zone canvas (dessin + toolbar +
  /// page-nav). Le widget devient un simple bloc-note texte. Garde
  /// l'expand button et le sync via drawing_json (avec strokes vides).
  /// Utilisé pour les notes VAD textuelles (Préconisations-Projet,
  /// Préconisations-Résumé, etc.) où le dessin n'apporte rien.
  final bool showCanvas;

  /// Si true, le modal d'expansion s'ouvre en pleine largeur d'écran
  /// dès le départ (au lieu du floating window 420×340 par défaut).
  /// Pratique pour les notes textuelles compactes où l'utilisateur
  /// veut écrire confortablement quand il agrandit. Le bouton de
  /// bascule fullscreen ↔ fenêtré reste accessible dans le modal.
  final bool expandModalFullscreen;

  final bool embedded;
  final NoteToolbarPlacement toolbarPlacement;
  final bool toolbarDockedToBorder;
  final bool toolbarInFooter;
  final bool fillParentHeight;

  // Contrôle externe de l'outil
  final NoteTool? activeTool;
  final void Function(NoteTool tool)? onToolChange;

  // Contenu décoratif derrière le canvas
  final Widget? backgroundContent;

  /// Flags médicaux actifs POUR LA PAGE COURANTE (ex. {1, 2}). Sérialisés
  /// dans `drawing_json` sous la clé `medicalFlags`. Utilisé uniquement
  /// par l'onglet "Contexte de vie > Médical" pour afficher des badges
  /// numérotés en overlay sur la zone de dessin. `null` = feature désactivée.
  ///
  /// Flux bidirectionnel :
  /// - En ENTRÉE : quand le parent pousse une nouvelle valeur (ex. après
  ///   toggle d'une case dans ContextTab), NotesWidget met à jour la
  ///   map interne `_pageMedicalFlags[currentPage]` et persiste la page.
  /// - En SORTIE : [onMedicalFlagsChanged] est émis lors d'un changement
  ///   de page (`_switchPage`, `_addPage`) et après chargement initial
  ///   (`_loadPages`), pour que le parent synchronise ses checkboxes /
  ///   badges sur les flags de la nouvelle page.
  final Set<int>? medicalFlags;

  /// Callback émis lorsque la page active change ou après chargement
  /// initial — transmet les flags médicaux stockés pour cette page.
  /// Le parent l'utilise pour rafraîchir l'état des cases à cocher
  /// (ContextTab > Médical) et des badges numérotés (overlay canvas).
  final ValueChanged<Set<int>>? onMedicalFlagsChanged;

  /// Nouvelle mise en page "deux cartes empilées" (demande utilisateur) :
  /// - Zone texte en CARTE arrondie indépendante en haut.
  /// - Petite poignée-pastille avec chevron au centre.
  /// - Canvas en CARTE arrondie indépendante en bas.
  /// - Navigation de pages (1/N, +, 🗑) flottante en haut-droite du canvas.
  /// - Toolbar outils flottante en bas-centre du canvas (incluant
  ///   annuler/rétablir — auparavant dans la barre d'en-tête).
  ///
  /// Par défaut `false` → conserve la mise en page historique
  /// (une seule carte + barre d'en-tête page-nav + toolbar séparée).
  /// Utilisé par les notes du relevé de visite et la note rapide du
  /// dossier pour converger vers le nouveau design.
  final bool stackedCards;

  @override
  State<NotesWidget> createState() => _NotesWidgetState();
}

class _NotesWidgetState extends State<NotesWidget> {
  final DataService _dataService = DataService();

  // Texte + contrôleur
  late final TextEditingController _textController;
  final FocusNode _textFocusNode = FocusNode();

  // Pages
  late int _currentPage;
  late int _totalPages;
  final Map<int, List<_Stroke>> _pageStrokes = <int, List<_Stroke>>{};
  final Map<int, String> _pageTexts = <int, String>{};
  // Flags médicaux par page (1 = Pathologie, 2 = Suivi, 3 = Sensoriel).
  // Sérialisés dans `drawing_json['medicalFlags']`. Utilisé uniquement
  // quand [widget.medicalFlags] / [widget.onMedicalFlagsChanged] sont
  // fournis par le parent (onglet "Contexte de vie > Médical").
  final Map<int, Set<int>> _pageMedicalFlags = <int, Set<int>>{};

  // Outil actif
  late NoteTool _activeTool;
  int _penColor = _kDefaultPenColor;
  int _highlighterColor = _kDefaultHighlighterColor;
  double _penSize = _kDefaultPenSize;
  double _highlighterSize = _kDefaultHighlighterSize;
  double _eraserSize = _kDefaultEraserSize;

  // Stroke en cours
  _Stroke? _activeStroke;

  // Dernière position de la gomme (pour interpoler les trous entre deux events)
  Offset? _lastEraserPos;

  // Undo / redo (bonus par rapport à React)
  final List<List<_Stroke>> _undoStack = <List<_Stroke>>[];
  final List<List<_Stroke>> _redoStack = <List<_Stroke>>[];

  // État sauvegarde
  bool _isLoaded = false;
  bool _isDirty = false;
  bool _isSaving = false;
  _SaveLabel _saveLabel = _SaveLabel.idle;
  Timer? _autoSaveDebounce;

  // Canvas
  Size _canvasSize = Size.zero;

  // Outer container size (used to clamp the splitter).
  final GlobalKey _outerKey = GlobalKey();

  // UI pop-ups
  bool _showColorPalette = false;

  // Text area height (splitter) — équivalent de `textAreaHeight` (default 92px).
  double _textAreaHeight = 92.0;

  // Modal flottant — inséré dans l'Overlay global (root) plutôt que
  // dans le Stack local pour qu'il puisse couvrir TOUTE la fenêtre, y
  // compris quand le NotesWidget est dans un SizedBox borné (ex. note
  // sticky 64 px en haut de Préconisations). Sans Overlay, le pop-up
  // restait clippé aux dimensions de la note source.
  OverlayEntry? _textModalEntry;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.currentPage;
    _totalPages = math.max(1, widget.totalPages);
    _textController = TextEditingController(text: widget.initialText);
    _pageTexts[_currentPage] = widget.initialText;
    _activeTool = widget.activeTool ?? _availableToolsFor(widget.toolset).first;
    _textController.addListener(_onTextChanged);
    _loadPages();
  }

  @override
  void didUpdateWidget(covariant NotesWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedDoc = oldWidget.patientId != widget.patientId ||
        oldWidget.tabKey != widget.tabKey;
    if (changedDoc) {
      _pageStrokes.clear();
      _pageTexts.clear();
      _pageMedicalFlags.clear();
      _undoStack.clear();
      _redoStack.clear();
      _currentPage = widget.currentPage;
      _totalPages = math.max(1, widget.totalPages);
      _loadPages();
      return;
    }

    if (oldWidget.currentPage != widget.currentPage && !_isDirty) {
      _switchPage(widget.currentPage);
    }
    // Le parent a poussé une nouvelle sélection de flags médicaux (ex.
    // case à cocher togglée dans ContextTab) → on applique aux flags de
    // la page courante et on persiste. On ne ré-émet PAS onMedicalFlagsChanged
    // ici, pour éviter une boucle aller-retour avec le parent.
    if (widget.medicalFlags != null &&
        !_setIntEquals(
          widget.medicalFlags!,
          _pageMedicalFlags[_currentPage] ?? const <int>{},
        )) {
      setState(() {
        _pageMedicalFlags[_currentPage] = {...widget.medicalFlags!};
      });
      // Persiste immédiatement la nouvelle sélection sur la page courante.
      unawaited(_persistPage(_currentPage));
    }
    if (oldWidget.totalPages != widget.totalPages) {
      setState(() => _totalPages = math.max(1, widget.totalPages));
    }
    if (oldWidget.activeTool != widget.activeTool && widget.activeTool != null) {
      setState(() => _activeTool = widget.activeTool!);
    }
    if (oldWidget.toolset != widget.toolset) {
      final available = _availableToolsFor(widget.toolset);
      if (!available.contains(_activeTool)) {
        setState(() => _activeTool = available.first);
      }
    }
    if (oldWidget.externalRefreshToken != widget.externalRefreshToken &&
        !_isDirty) {
      _reloadCurrentPageFromStore();
    }
    if (oldWidget.liveText != widget.liveText && widget.liveText != null) {
      final incoming = widget.liveText!;
      if (_textController.text != incoming && !_textFocusNode.hasFocus) {
        // Detach the listener briefly so the mirrored write doesn't mark
        // the widget dirty / trigger an autosave loop.
        _textController.removeListener(_onTextChanged);
        _textController.value = TextEditingValue(
          text: incoming,
          selection: TextSelection.collapsed(offset: incoming.length),
        );
        _textController.addListener(_onTextChanged);
        _pageTexts[_currentPage] = incoming;
      }
    }
  }

  /// Re-fetches the drawing_json of the current page and re-applies it,
  /// including the embedded text. Used when an external writer (detached
  /// OS note window) edited the same row and we need to mirror the change
  /// into this in-app widget.
  Future<void> _reloadCurrentPageFromStore() async {
    final json = await _dataService.fetchNoteDrawingJson(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
      pageNumber: _currentPage,
    );
    if (!mounted || _isDirty) return;
    setState(() => _applyJson(_currentPage, json, hydrateController: true));
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    _textFocusNode.dispose();
    // Sécurité : si le pop-up est encore visible quand le NotesWidget
    // est démonté (ex. navigation arrière), on retire l'OverlayEntry
    // pour éviter de garder un orphelin sur l'écran.
    _textModalEntry?.remove();
    _textModalEntry = null;
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Accesseurs internes
  // ---------------------------------------------------------------------------

  List<_Stroke> get _strokes =>
      _pageStrokes.putIfAbsent(_currentPage, () => <_Stroke>[]);

  List<NoteTool> get _availableTools => _availableToolsFor(widget.toolset);

  int get _activeColor {
    switch (_activeTool) {
      case NoteTool.pen:
      case NoteTool.line:
      case NoteTool.rect:
        return _penColor;
      case NoteTool.highlighter:
        return _highlighterColor;
      case NoteTool.eraser:
        return 0x00000000;
    }
  }

  double get _activeSize {
    switch (_activeTool) {
      case NoteTool.pen:
      case NoteTool.line:
      case NoteTool.rect:
        return _penSize;
      case NoteTool.highlighter:
        return _highlighterSize;
      case NoteTool.eraser:
        return _eraserSize;
    }
  }

  String _currentDrawingJson() {
    final flags = _pageMedicalFlags[_currentPage];
    return jsonEncode({
      'version': 1,
      'text': _textController.text,
      'strokes': _strokes.map((s) => s.toJson()).toList(),
      // Champ facultatif — omis quand il n'y a pas de flags pour éviter de
      // polluer les notes non-médicales. Trié pour un JSON stable.
      if (flags != null && flags.isNotEmpty)
        'medicalFlags': (flags.toList()..sort()),
    });
  }

  // ---------------------------------------------------------------------------
  // Hydration (chargement initial des pages depuis DataService)
  // ---------------------------------------------------------------------------

  Future<void> _loadPages() async {
    setState(() => _isLoaded = false);

    // 1. Première page : on lit en SQLite et on l'affiche IMMÉDIATEMENT.
    //    Le spinner disparaît dès qu'on a la page courante — les autres
    //    pages sont sondées en arrière-plan pour ne pas bloquer le rendu.
    //    Avant ce changement, sur iPad PWA après clear cache, NotesWidget
    //    sondait jusqu'à 20 pages séquentiellement dans SQLite WASM avant
    //    d'afficher quoi que ce soit, ce qui prenait plusieurs secondes
    //    pour la note rapide du dossier.
    final firstJson = await _dataService.fetchNoteDrawingJson(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
      pageNumber: _currentPage,
    );
    if (!mounted) return;
    setState(() {
      _applyJson(_currentPage, firstJson, hydrateController: true);
      _isLoaded = true;
    });
    _emitMedicalFlagsForCurrentPage();

    // 2. Refresh réseau de la page courante (non-bloquant).
    unawaited(
      _dataService
          .refreshNotePageFromRemote(
            patientId: widget.patientId,
            tabKey: widget.tabKey,
            pageNumber: _currentPage,
          )
          .then((_) async {
            if (_isDirty || !mounted) return;
            final refreshed = await _dataService.fetchNoteDrawingJson(
              patientId: widget.patientId,
              tabKey: widget.tabKey,
              pageNumber: _currentPage,
            );
            if (!mounted || _isDirty) return;
            setState(() => _applyJson(_currentPage, refreshed,
                hydrateController: true));
          }),
    );

    // 3. Sondage des pages suivantes en arrière-plan (non-bloquant).
    //    On ne ré-affiche un setState qu'à la fin pour éviter les
    //    repaints intermédiaires.
    unawaited(_probeAdditionalPages(startFrom: _currentPage + 1));
  }

  /// Sonde les pages > [startFrom] en lecture locale uniquement.
  /// Appelée en `unawaited` après le rendu initial pour ne pas bloquer
  /// l'affichage de la première page.
  Future<void> _probeAdditionalPages({required int startFrom}) async {
    var probe = startFrom;
    while (probe < widget.maxPages) {
      final json = await _dataService.fetchNoteDrawingJson(
        patientId: widget.patientId,
        tabKey: widget.tabKey,
        pageNumber: probe,
      );
      if (!mounted) return;
      if (json == null || json.isEmpty) break;
      _applyJson(probe, json, hydrateController: false);
      probe += 1;
    }
    if (!mounted) return;

    var changed = false;
    if (probe > _totalPages) {
      _totalPages = probe;
      changed = true;
    }

    if (widget.sharedText) {
      // Normalize: take the first non-empty text found across pages
      // (pre-existing records may have diverged per page) and propagate
      // it to every page so the shared-text invariant holds.
      String? firstText;
      for (var i = 0; i < _totalPages; i++) {
        final t = _pageTexts[i] ?? '';
        if (t.isNotEmpty) {
          firstText = t;
          break;
        }
      }
      final txt = firstText ?? '';
      for (var i = 0; i < _totalPages; i++) {
        _pageTexts[i] = txt;
      }
      // Ne ré-hydrate le controller que si la valeur courante diffère
      // (sinon on perd la sélection / position du curseur si l'user a
      // commencé à taper pendant le sondage).
      if (_textController.text != txt && !_textFocusNode.hasFocus) {
        _textController.removeListener(_onTextChanged);
        _textController.value = TextEditingValue(
          text: txt,
          selection: TextSelection.collapsed(offset: txt.length),
        );
        _textController.addListener(_onTextChanged);
        changed = true;
      }
    }

    if (changed) setState(() {});
  }

  void _applyJson(int page, String? json, {required bool hydrateController}) {
    if (json == null || json.isEmpty) {
      _pageStrokes[page] = <_Stroke>[];
      _pageTexts[page] = '';
      _pageMedicalFlags[page] = <int>{};
      if (hydrateController) _textController.text = '';
      return;
    }
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) {
        _pageStrokes[page] = <_Stroke>[];
        _pageTexts[page] = '';
        _pageMedicalFlags[page] = <int>{};
        if (hydrateController) _textController.text = '';
        return;
      }
      final text = decoded['text']?.toString() ?? '';
      final rawStrokes = decoded['strokes'] as List?;
      final strokes = rawStrokes == null
          ? <_Stroke>[]
          : rawStrokes
              .whereType<Map>()
              .map((raw) => _Stroke.fromJson(raw.cast<String, dynamic>()))
              .whereType<_Stroke>()
              .toList();
      // `medicalFlags` est optionnel (ajouté pour l'onglet Médical).
      // Les notes préexistantes sans ce champ → ensemble vide. Rétrocompatible.
      final rawFlags = decoded['medicalFlags'];
      final flags = <int>{};
      if (rawFlags is List) {
        for (final v in rawFlags) {
          if (v is int) {
            flags.add(v);
          } else if (v is num) {
            flags.add(v.toInt());
          }
        }
      }
      _pageStrokes[page] = strokes;
      _pageTexts[page] = text;
      _pageMedicalFlags[page] = flags;
      if (hydrateController) _textController.text = text;
    } catch (_) {
      _pageStrokes[page] = <_Stroke>[];
      _pageTexts[page] = '';
      _pageMedicalFlags[page] = <int>{};
      if (hydrateController) _textController.text = '';
    }
  }

  // ---------------------------------------------------------------------------
  // Sauvegarde
  // ---------------------------------------------------------------------------

  void _markDirty() {
    if (!_isDirty) setState(() => _isDirty = true);
    if (_saveLabel != _SaveLabel.idle) {
      setState(() => _saveLabel = _SaveLabel.idle);
    }
    _emitDraft();
    if (widget.autoSaveToService) _scheduleAutoSave();
  }

  void _emitDraft() {
    widget.onDraftChange?.call(NoteDraftPayload(
      text: _textController.text,
      drawingJson: _currentDrawingJson(),
      isDirty: _isDirty,
    ));
  }

  void _scheduleAutoSave() {
    _autoSaveDebounce?.cancel();
    // Debounce 0 ms (kSaveDebounceText) — chaque keystroke déclenche
    // immédiatement l'écriture SQLite + enqueue sync_op. Avant : 500 ms,
    // qui pouvait laisser un trou si l'ergo cliquait « Générer le
    // rapport » dans la milliseconde après avoir tapé → la note n'était
    // pas encore en SQLite, donc pas vue par runSync(). Demande
    // utilisateur 2026-04-29 : « il faut que ce soit instantané comme
    // les autres notes pas de délais ».
    _autoSaveDebounce = Timer(kSaveDebounceText, _autoSavePersist);
  }

  Future<void> _autoSavePersist() async {
    if (!mounted) return;
    try {
      await _dataService.saveNoteDrawingJson(
        patientId: widget.patientId,
        tabKey: widget.tabKey,
        pageNumber: _currentPage,
        drawingJson: _currentDrawingJson(),
      );
    } catch (_) {
      // silencieux : l'utilisateur peut quand même déclencher manuellement Save.
    }
  }

  Future<void> _handleSavePressed() async {
    if (!_isDirty || _isSaving) return;
    setState(() {
      _isSaving = true;
    });
    try {
      final payload = NoteSavePayload(
        text: _textController.text,
        drawingJson: _currentDrawingJson(),
      );
      if (widget.onSave != null) {
        await widget.onSave!(payload);
      } else if (widget.autoSaveToService) {
        await _dataService.saveNoteDrawingJson(
          patientId: widget.patientId,
          tabKey: widget.tabKey,
          pageNumber: _currentPage,
          drawingJson: payload.drawingJson,
        );
      }
      if (!mounted) return;
      setState(() {
        _isDirty = false;
        _saveLabel = _SaveLabel.saved;
      });
      _emitDraft();
    } catch (_) {
      if (!mounted) return;
      setState(() => _saveLabel = _SaveLabel.error);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Texte
  // ---------------------------------------------------------------------------

  void _onTextChanged() {
    if (widget.sharedText) {
      final txt = _textController.text;
      for (var i = 0; i < _totalPages; i++) {
        _pageTexts[i] = txt;
      }
    } else {
      _pageTexts[_currentPage] = _textController.text;
    }
    _markDirty();
  }

  // ---------------------------------------------------------------------------
  // Undo / redo / clear
  // ---------------------------------------------------------------------------

  void _pushUndo() {
    _undoStack.add(List<_Stroke>.from(_strokes));
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _redoStack.add(List<_Stroke>.from(_strokes));
      _pageStrokes[_currentPage] = _undoStack.removeLast();
    });
    _markDirty();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      _undoStack.add(List<_Stroke>.from(_strokes));
      _pageStrokes[_currentPage] = _redoStack.removeLast();
    });
    _markDirty();
  }

  void _clearStrokes() {
    if (_strokes.isEmpty) return;
    _pushUndo();
    setState(() => _pageStrokes[_currentPage] = <_Stroke>[]);
    _markDirty();
  }

  // ---------------------------------------------------------------------------
  // Dessin
  // ---------------------------------------------------------------------------

  Offset _normalize(Offset local) {
    if (_canvasSize.isEmpty) return Offset.zero;
    return Offset(
      (local.dx / _canvasSize.width).clamp(0.0, 1.0),
      (local.dy / _canvasSize.height).clamp(0.0, 1.0),
    );
  }

  /// Retourne true si la position locale est dans le cadre de dessin.
  /// Utilisé pour bloquer les tracés (y compris l'effacement) quand le
  /// curseur sort du cadre — évite les points sur la bordure et les
  /// payloads hors limites envoyés au serveur.
  bool _isInsideCanvas(Offset local) {
    if (_canvasSize.isEmpty) return false;
    return local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx <= _canvasSize.width &&
        local.dy <= _canvasSize.height;
  }

  void _onDrawStart(DragStartDetails details) {
    if (_canvasSize.isEmpty) return;
    if (!_isInsideCanvas(details.localPosition)) return;
    _pushUndo();
    setState(() {
      _activeStroke = _Stroke(
        tool: _activeTool,
        color: _activeColor,
        size: _activeSize,
        points: <Offset>[_normalize(details.localPosition)],
      );
    });
  }

  void _onDrawUpdate(DragUpdateDetails details) {
    if (_canvasSize.isEmpty) return;
    final stroke = _activeStroke;
    if (stroke == null) return;
    // Ignorer les positions hors cadre : sinon le clamp de `_normalize`
    // ajoute un point fixé sur la bordure (ligne parasite) et peut
    // déclencher un payload rejeté par le serveur (erreur 500).
    if (!_isInsideCanvas(details.localPosition)) return;
    setState(() {
      if (stroke.tool == NoteTool.line || stroke.tool == NoteTool.rect) {
        if (stroke.points.length == 1) {
          stroke.points.add(_normalize(details.localPosition));
        } else {
          stroke.points[1] = _normalize(details.localPosition);
        }
      } else if (stroke.points.length < 2000) {
        stroke.points.add(_normalize(details.localPosition));
      }
    });
  }

  void _onDrawEnd(DragEndDetails details) {
    final stroke = _activeStroke;
    if (stroke == null) return;
    setState(() {
      _strokes.add(stroke);
      _activeStroke = null;
    });
    _markDirty();
  }

  // Distance entre un point [p] et le segment [a, b] — projection
  // orthogonale clampée aux extrémités.
  double _distPointSegment(Offset p, Offset a, Offset b) {
    final abx = b.dx - a.dx;
    final aby = b.dy - a.dy;
    final lenSq = abx * abx + aby * aby;
    if (lenSq < 1e-12) {
      final dx = p.dx - a.dx;
      final dy = p.dy - a.dy;
      return math.sqrt(dx * dx + dy * dy);
    }
    final apx = p.dx - a.dx;
    final apy = p.dy - a.dy;
    var t = (apx * abx + apy * aby) / lenSq;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    final projx = a.dx + abx * t;
    final projy = a.dy + aby * t;
    final dx = p.dx - projx;
    final dy = p.dy - projy;
    return math.sqrt(dx * dx + dy * dy);
  }

  // Distance minimale entre deux segments [a1,a2] et [b1,b2]. Zéro si
  // intersection. Sinon, min des 4 distances point-vers-l'autre-segment.
  // Cruciale pour que la gomme efface les traits même quand elle passe
  // ENTRE deux points consécutifs d'un stroke dessiné rapidement (les
  // points peuvent être espacés de plusieurs px).
  double _distSegmentSegment(Offset a1, Offset a2, Offset b1, Offset b2) {
    // Test rapide d'intersection : si les segments se croisent, dist = 0.
    if (_segmentsIntersect(a1, a2, b1, b2)) return 0.0;
    final d1 = _distPointSegment(a1, b1, b2);
    final d2 = _distPointSegment(a2, b1, b2);
    final d3 = _distPointSegment(b1, a1, a2);
    final d4 = _distPointSegment(b2, a1, a2);
    return math.min(math.min(d1, d2), math.min(d3, d4));
  }

  bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
    double ccw(Offset a, Offset b, Offset c) =>
        (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
    final d1 = ccw(p3, p4, p1);
    final d2 = ccw(p3, p4, p2);
    final d3 = ccw(p1, p2, p3);
    final d4 = ccw(p1, p2, p4);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
      return true;
    }
    return false;
  }

  // Calcule la liste de strokes résultant du passage de la gomme entre
  // [from] et [to] (bande circulaire de rayon [hitDistance]). Teste
  // chaque SEGMENT (paire de points consécutifs) du stroke vs le
  // segment de gomme — pas juste les points isolés — pour un effaçage
  // pixel-précis même quand le stroke a des points très espacés.
  List<_Stroke>? _computeEraseSegment(List<_Stroke> input,
      Offset from, Offset to, double hitDistance) {
    final next = <_Stroke>[];
    var changed = false;
    for (final stroke in input) {
      if (stroke.tool == NoteTool.line || stroke.tool == NoteTool.rect) {
        // Line/rect : 2 points, un seul segment à tester.
        if (stroke.points.length < 2) {
          next.add(stroke);
          continue;
        }
        final hit = _distSegmentSegment(
              stroke.points[0], stroke.points[1], from, to,
            ) <
            hitDistance;
        if (hit) {
          changed = true;
        } else {
          next.add(stroke);
        }
        continue;
      }
      // Pen/highlighter : liste de points. Pour chaque segment du stroke,
      // on teste la distance au segment de gomme. Si < hitDistance, les
      // DEUX points aux extrémités sont marqués "effacés" → le stroke
      // se coupe proprement.
      final pts = stroke.points;
      final n = pts.length;
      if (n == 0) {
        next.add(stroke);
        continue;
      }
      final erased = List<bool>.filled(n, false);
      var anyHit = false;
      if (n == 1) {
        // Stroke-point unique : distance point-segment.
        if (_distPointSegment(pts[0], from, to) < hitDistance) {
          erased[0] = true;
          anyHit = true;
        }
      } else {
        for (var i = 0; i < n - 1; i++) {
          if (_distSegmentSegment(pts[i], pts[i + 1], from, to) <
              hitDistance) {
            erased[i] = true;
            erased[i + 1] = true;
            anyHit = true;
          }
        }
      }
      if (!anyHit) {
        next.add(stroke);
        continue;
      }
      changed = true;
      // Segmente le stroke autour des points effacés.
      var current = <Offset>[];
      for (var i = 0; i < n; i++) {
        if (erased[i]) {
          if (current.length >= 2) {
            next.add(_Stroke(
              tool: stroke.tool,
              color: stroke.color,
              size: stroke.size,
              points: current,
            ));
          }
          current = <Offset>[];
        } else {
          current.add(pts[i]);
        }
      }
      if (current.length >= 2) {
        next.add(_Stroke(
          tool: stroke.tool,
          color: stroke.color,
          size: stroke.size,
          points: current,
        ));
      }
    }
    return changed ? next : null;
  }

  // Efface un point unique (utilisé au début du tracé, avant qu'on ait
  // un segment).
  void _eraseAt(Offset point) {
    final hitDistance =
        _eraserSize / math.max(1.0, _canvasSize.shortestSide);
    final next = _computeEraseSegment(_strokes, point, point, hitDistance);
    if (next == null) return;
    setState(() => _pageStrokes[_currentPage] = next);
    _markDirty();
  }

  // Efface la bande balayée entre [from] et [to] en une seule passe.
  // Précédemment : boucle de jusqu'à 64 itérations, chacune scannant tous
  // les strokes → saccades visibles quand on efface vite ou avec beaucoup
  // de traits. Maintenant : un seul `_computeEraseSegment` qui teste la
  // distance point-segment → O(n) au lieu de O(n×64).
  void _eraseAlongPath(Offset? from, Offset to) {
    final hitDistance =
        _eraserSize / math.max(1.0, _canvasSize.shortestSide);
    if (from == null) {
      _eraseAt(to);
      return;
    }
    final next = _computeEraseSegment(_strokes, from, to, hitDistance);
    if (next == null) return;
    setState(() => _pageStrokes[_currentPage] = next);
    _markDirty();
  }

  // ---------------------------------------------------------------------------
  // Pagination
  // ---------------------------------------------------------------------------

  void _switchPage(int page) {
    if (page < 0 || page >= _totalPages || page == _currentPage) return;
    setState(() {
      _currentPage = page;
      if (!widget.sharedText) {
        _textController.text = _pageTexts[page] ?? '';
      }
      _activeStroke = null;
      _isDirty = false;
      _undoStack.clear();
      _redoStack.clear();
    });
    widget.onPageChange?.call(page);
    // Informe le parent des flags médicaux stockés pour cette page — le
    // parent met alors à jour les cases à cocher (ContextTab) et les
    // badges numérotés (overlay canvas) en fonction de la nouvelle page.
    _emitMedicalFlagsForCurrentPage();
  }

  /// Pousse `_pageMedicalFlags[_currentPage]` (ou {}) vers le parent via
  /// [NotesWidget.onMedicalFlagsChanged]. No-op si le callback est null.
  void _emitMedicalFlagsForCurrentPage() {
    final cb = widget.onMedicalFlagsChanged;
    if (cb == null) return;
    final flags = _pageMedicalFlags[_currentPage] ?? <int>{};
    cb({...flags});
  }

  /// Égalité ensembliste entre deux `Set<int>` — évite d'importer
  /// `collection.dart` juste pour ce cas.
  static bool _setIntEquals(Set<int> a, Set<int> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }

  Future<void> _addPage() async {
    if (widget.onAddPage != null) {
      await widget.onAddPage!();
      return;
    }
    if (_totalPages >= widget.maxPages) return;
    final newPageIndex = _totalPages;
    setState(() {
      _totalPages += 1;
      _pageStrokes[newPageIndex] = <_Stroke>[];
      _pageTexts[newPageIndex] =
          widget.sharedText ? _textController.text : '';
      // Nouvelle page : flags médicaux vides — l'utilisateur re-sélectionne
      // les numéros souhaités via les cases Pathologie / Suivi / Sensoriel
      // (demande utilisateur : les numéros ne doivent pas rester les mêmes
      // d'une page à l'autre).
      _pageMedicalFlags[newPageIndex] = <int>{};
    });
    // Persiste la nouvelle page côté serveur (JSON vide) — SyncEngine déclenche
    // la sync remote si le réseau est disponible.
    await _persistPage(newPageIndex);
    _switchPage(newPageIndex);
  }

  Future<void> _deletePage() async {
    if (widget.onDeletePage != null) {
      if (widget.canDeletePage) await widget.onDeletePage!();
      return;
    }
    if (_totalPages <= 1) return;

    final deletedIndex = _currentPage;
    final oldLastIndex = _totalPages - 1;

    setState(() {
      _pageStrokes.remove(deletedIndex);
      _pageTexts.remove(deletedIndex);
      _pageMedicalFlags.remove(deletedIndex);
      final nextStrokes = <int, List<_Stroke>>{};
      final nextTexts = <int, String>{};
      final nextFlags = <int, Set<int>>{};
      _pageStrokes.forEach((index, strokes) {
        nextStrokes[index > deletedIndex ? index - 1 : index] = strokes;
      });
      _pageTexts.forEach((index, text) {
        nextTexts[index > deletedIndex ? index - 1 : index] = text;
      });
      _pageMedicalFlags.forEach((index, flags) {
        nextFlags[index > deletedIndex ? index - 1 : index] = flags;
      });
      _pageStrokes
        ..clear()
        ..addAll(nextStrokes);
      _pageTexts
        ..clear()
        ..addAll(nextTexts);
      _pageMedicalFlags
        ..clear()
        ..addAll(nextFlags);
      _totalPages -= 1;
      if (_currentPage >= _totalPages) _currentPage = _totalPages - 1;
      _textController.text = _pageTexts[_currentPage] ?? '';
      _undoStack.clear();
      _redoStack.clear();
      _isDirty = false;
    });
    // Les flags médicaux de la page courante ont peut-être changé (on a
    // sauté sur la page précédente) → informe le parent.
    _emitMedicalFlagsForCurrentPage();

    // Persiste l'état des pages déplacées (decalées d'un cran vers le bas)
    // pour que le serveur voie les bonnes valeurs sous leur nouvel index.
    for (var i = deletedIndex; i < _totalPages; i++) {
      await _persistPage(i);
    }
    // Remet la dernière page (ancienne) à vide sur le serveur pour qu'elle ne
    // réapparaisse pas au prochain chargement (détection de pages par scan).
    await _persistEmptyAt(oldLastIndex);
  }

  Future<void> _persistPage(int pageIndex) async {
    final strokes =
        _pageStrokes.putIfAbsent(pageIndex, () => <_Stroke>[]);
    final text = _pageTexts[pageIndex] ?? '';
    final flags = _pageMedicalFlags[pageIndex];
    final json = jsonEncode({
      'version': 1,
      'text': text,
      'strokes': strokes.map((s) => s.toJson()).toList(),
      if (flags != null && flags.isNotEmpty)
        'medicalFlags': (flags.toList()..sort()),
    });
    try {
      await _dataService.saveNoteDrawingJson(
        patientId: widget.patientId,
        tabKey: widget.tabKey,
        pageNumber: pageIndex,
        drawingJson: json,
      );
    } catch (_) {
      // ignore : sera repris au prochain sync
    }
  }

  Future<void> _persistEmptyAt(int pageIndex) async {
    try {
      await _dataService.saveNoteDrawingJson(
        patientId: widget.patientId,
        tabKey: widget.tabKey,
        pageNumber: pageIndex,
        drawingJson: jsonEncode({
          'version': 1,
          'text': '',
          'strokes': const [],
        }),
      );
    } catch (_) {
      // ignore
    }
  }

  // ---------------------------------------------------------------------------
  // Modal flottant / plein écran
  // ---------------------------------------------------------------------------

  void _openTextModal() {
    // Parent opted into "real tab" mode → delegate without showing any
    // floating modal. The parent will open a new entry in its TabBar.
    if (widget.onExpandToTab != null) {
      widget.onExpandToTab!();
      return;
    }
    if (!widget.allowTextModal) return;
    if (_textModalEntry != null) return;

    // On insère dans l'Overlay racine (pas le local) pour que le pop-up
    // couvre toute la fenêtre indépendamment des contraintes de la note
    // source (ex. SizedBox(64) du header sticky Préconisations).
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => _FloatingTextModal(
        initialText: _textController.text,
        placeholder: widget.placeholder,
        title: widget.title,
        startFullscreen: widget.expandModalFullscreen,
        onChanged: (value) {
          if (_textController.text == value) return;
          _textController.value = TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length),
          );
        },
        onClose: _closeTextModal,
      ),
    );
    _textModalEntry = entry;
    overlay.insert(entry);
    setState(() {}); // pour rafraîchir un éventuel indicateur visuel
  }

  void _closeTextModal() {
    final entry = _textModalEntry;
    if (entry == null) return;
    entry.remove();
    _textModalEntry = null;
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Le _FloatingTextModal n'est PAS dans ce Stack — il est inséré
    // dans l'Overlay racine via _openTextModal pour pouvoir couvrir
    // toute la fenêtre indépendamment des contraintes de ce widget.
    return _buildMainBody();
  }

  Widget _buildMainBody() {
    if (widget.stackedCards) return _buildStackedCardsBody();

    final decoration = widget.embedded
        ? const BoxDecoration(color: Colors.white)
        : BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          );

    // Mode "texte seul" (showCanvas: false) — bloc-note allégé sans
    // canvas/toolbar/pagination. Garde l'expand button du _buildTextEditor.
    //
    // Hauteur par défaut **60 px** (≈ 1-2 lignes visibles) : très
    // compact pour libérer l'espace autour (ex. liste préconisations
    // dessous). L'expand button (haut-gauche) ouvre le modal pour les
    // saisies longues. Override possible en wrappant dans un SizedBox
    // côté caller.
    if (!widget.showCanvas) {
      final editor = _buildTextEditor(fillHeight: true);
      final textOnly = widget.fillParentHeight
          ? SizedBox.expand(child: editor)
          : SizedBox(height: 60, child: editor);
      return Container(
        key: _outerKey,
        decoration: decoration,
        child: textOnly,
      );
    }

    final content = Column(
      children: [
        if (widget.showText) _buildTextEditor(),
        if (widget.showText) _buildSplitter(),
        if (widget.allowPagination || !widget.embedded) _buildPageNavRow(),
        if (!widget.embedded) const Divider(height: 1),
        // Parité React : réserver au moins ~88px au canvas quand le texte est
        // visible (espace nécessaire pour que la toolbar reste en place).
        Expanded(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.showText ? 88.0 : 340.0,
            ),
            child: _buildCanvasArea(),
          ),
        ),
        if (widget.toolbarInFooter) _buildFooterToolbar(),
      ],
    );

    final wrapped = widget.fillParentHeight
        ? SizedBox.expand(child: content)
        : Container(constraints: const BoxConstraints(minHeight: 460), child: content);

    return Container(key: _outerKey, decoration: decoration, child: wrapped);
  }


  /// Nouvelle mise en page "deux cartes empilées" (demande utilisateur) :
  /// - carte texte en haut AVEC poignée rose intégrée en bas (full-width,
  ///   icône double-chevron violet) pour redimensionner la zone texte ;
  /// - carte canvas en bas avec pagination centrée en violet (chevrons +
  ///   "N/total") et boutons "+" (fond violet clair) + corbeille (rose
  ///   clair) sans conteneur en haut-droite ;
  /// - contours fins arrondis sur les deux cartes (parité maquette).
  Widget _buildStackedCardsBody() {
    final showText = widget.showText;
    final content = Column(
      children: [
        // La carte texte inclut désormais le splitter en bas (même carte)
        if (showText) _buildStackedTextCard(),
        Expanded(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: showText ? 120.0 : 340.0,
            ),
            child: _buildStackedCanvasCard(),
          ),
        ),
      ],
    );

    final wrapped = widget.fillParentHeight
        ? SizedBox.expand(child: content)
        : Container(constraints: const BoxConstraints(minHeight: 460), child: content);

    // Pas de décoration externe : chaque sous-carte porte son propre
    // fond blanc arrondi (séparation visuelle nette entre texte et canvas).
    return Container(key: _outerKey, color: Colors.transparent, child: wrapped);
  }

  /// Carte arrondie contenant le champ texte ET la poignée rose intégrée
  /// en bas (full-width, double-chevron violet). Contour fin + coins
  /// arrondis pour matcher la maquette utilisateur.
  Widget _buildStackedTextCard() {
    const double kSplitterHeight = 22.0;
    return Container(
      height: _textAreaHeight + kSplitterHeight,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        // Charte "Équilibrée" — 16 px (juste milieu densité / respiration).
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kStackedBorder, width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Column(
              children: [
                // Zone de saisie texte (occupe toute la hauteur au-dessus du
                // splitter rose).
                Expanded(
                  child: Padding(
                    // En mode stackedCards on réserve 38 px à gauche quand le
                    // bouton « ouvrir dans un onglet » est disponible, comme
                    // dans `_buildTextEditor`, pour que le texte ne passe pas
                    // sous l'icône maximize2.
                    padding: EdgeInsets.fromLTRB(
                      widget.allowTextModal ? 38 : 16,
                      12,
                      16,
                      6,
                    ),
                    child: TextField(
                      controller: _textController,
                      focusNode: _textFocusNode,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontSize: 14),
                      // Scribble (Apple Pencil) — écriture directe sur iPad.
                      stylusHandwritingEnabled: true,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: widget.placeholder,
                        hintStyle: TextStyle(color: Colors.grey.shade500),
                        isCollapsed: true,
                      ),
                    ),
                  ),
                ),
                // Poignée rose intégrée en bas de la carte — full-width, icône
                // double-chevron violet centrée. Draggable verticalement pour
                // redimensionner la zone texte.
                _buildStackedIntegratedSplitter(kSplitterHeight),
              ],
            ),
            // Poignée d'agrandissement — ouvre la note dans un nouvel onglet
            // (via `onExpandToTab`) ou une modale plein écran en fallback.
            // Confinée en haut-gauche pour ne pas intercepter les taps du
            // TextField.
            if (widget.allowTextModal)
              Positioned(
                left: 6,
                top: 6,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _openTextModal,
                    customBorder: const CircleBorder(),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        LucideIcons.maximize2,
                        size: 14,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Poignée de redimensionnement intégrée au bas de la carte texte —
  /// bande rose full-width avec double-chevron violet centré. Drag
  /// vertical pour ajuster la hauteur de la zone texte.
  Widget _buildStackedIntegratedSplitter(double height) {
    const double kToolbarReserved = 88.0;
    const double kSplitterMargin = 40.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        setState(() {
          final outerSize =
              (_outerKey.currentContext?.findRenderObject() as RenderBox?)
                  ?.size;
          final totalHeight = outerSize?.height ?? 600;
          final maxH = math.max(
              40.0, totalHeight - kToolbarReserved - kSplitterMargin);
          final next = _textAreaHeight + details.delta.dy;
          _textAreaHeight = next.clamp(40.0, maxH);
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: height,
          width: double.infinity,
          color: _kStackedSplitterBg,
          alignment: Alignment.center,
          child: const Icon(
            LucideIcons.chevronsDown,
            size: 16,
            color: _kStackedViolet,
          ),
        ),
      ),
    );
  }

  /// Carte arrondie contenant le canvas + pagination centrée + boutons
  /// + / 🗑 en haut-droite + toolbar flottante. Contour fin pour matcher
  /// la maquette. Le canvas interne se clip déjà aux limites
  /// rectangulaires (ClipRect sur le stroke painter) — on évite un
  /// ClipRRect externe pour ne pas tronquer l'ombre de la toolbar.
  Widget _buildStackedCanvasCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        // Charte "Équilibrée" — 16 px (idem carte texte).
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _kStackedBorder, width: 1),
      ),
      // Clip.antiAlias sur le conteneur externe → le contenu (fond du
      // canvas, strokes, overlays) est rogné au rayon 16 px pour que
      // les coins arrondis soient aussi visibles que ceux de la carte
      // texte (demande utilisateur : radius identiques entre les deux
      // cartes). Remarque : la petite ombre de la toolbar flottante
      // dépasse légèrement en bas et sera clippée — compromis
      // acceptable pour garder un visuel cohérent.
      clipBehavior: Clip.antiAlias,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: _buildCanvasArea()),
          // Pagination centrée (en haut) : `< N/total >` en violet.
          if (widget.allowPagination)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Center(child: _buildCenteredPageNav()),
            ),
          // Boutons + et 🗑 en haut-droite, SANS conteneur visible.
          if (widget.allowPagination)
            Positioned(
              top: 10,
              right: 12,
              child: _buildTopRightPageActions(),
            ),
        ],
      ),
    );
  }

  /// Pagination centrée en haut du canvas : `<  N/total  >` (typo violette).
  /// Le chevron gauche est MASQUÉ visuellement quand on est sur la
  /// première page (demande utilisateur), mais sa zone de 44×44 est
  /// réservée par un SizedBox équivalent pour que le numéro "N/total"
  /// reste à la MÊME position horizontale quelle que soit la page
  /// courante (demande utilisateur : pagination toujours centrée).
  Widget _buildCenteredPageNav() {
    final canGoPrev = _currentPage > 0;
    final canGoNext = _currentPage < _totalPages - 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canGoPrev)
          _StackedChevronButton(
            icon: LucideIcons.chevronLeft,
            enabled: true,
            tooltip: 'Page précédente',
            onTap: () => _switchPage(_currentPage - 1),
          )
        else
          const SizedBox(width: 44, height: 44),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            '${_currentPage + 1}/${math.max(_totalPages, 1)}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _kStackedViolet,
              letterSpacing: 0.2,
            ),
          ),
        ),
        _StackedChevronButton(
          icon: LucideIcons.chevronRight,
          enabled: canGoNext,
          tooltip: 'Page suivante',
          onTap: () => _switchPage(_currentPage + 1),
        ),
      ],
    );
  }

  /// Actions flottantes en haut-droite du canvas : bouton `+` (cercle
  /// violet **clair** avec `+` violet **foncé`) + corbeille (icône rose,
  /// aucun fond). Sans conteneur englobant, sans ombre — parité maquette.
  /// Taille 44×44 pour respecter les guidelines tactiles tablette.
  Widget _buildTopRightPageActions() {
    final canAdd = _totalPages < widget.maxPages;
    final canDelete = widget.onDeletePage != null
        ? widget.canDeletePage
        : _totalPages > 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // "+" : cercle violet **clair** (#EDE8F5) de 26px avec un `+`
        // violet **foncé** (#7C6DAA) de 16px à l'intérieur — même
        // grammaire pastel que la sub-nav du relevé de visite.
        // GestureDetector pour éviter le halo Material (même traitement
        // que la corbeille).
        Tooltip(
          message: 'Nouvelle page',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: canAdd ? _addPage : null,
            child: Padding(
              padding: const EdgeInsets.all(9), // tap area ≈ 44×44
              child: Opacity(
                opacity: canAdd ? 1 : 0.4,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(
                    color: _kStackedSplitterBg, // violet clair #EDE8F5
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    LucideIcons.plus,
                    size: 16,
                    color: _kStackedViolet, // violet foncé #7C6DAA
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Corbeille : même empreinte 26×26 que le cercle violet du
        // bouton + à gauche, pour que les deux aient la même taille
        // visuelle. GestureDetector (pas d'InkWell) → pas de halo.
        Tooltip(
          message: 'Supprimer la page',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: canDelete ? () => _deletePage() : null,
            child: Padding(
              padding: const EdgeInsets.all(9), // tap area ≈ 44×44
              child: Opacity(
                opacity: canDelete ? 1 : 0.4,
                child: const SizedBox(
                  width: 26,
                  height: 26,
                  child: Center(
                    child: Icon(
                      LucideIcons.trash2,
                      size: 26,
                      color: _kStackedPinkSoft,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPageNavRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          if (widget.leadingNavWidget != null) ...[
            widget.leadingNavWidget!,
            const SizedBox(width: 8),
          ],
          if (widget.allowPagination) ...[
            _HeaderIconButton(
              icon: LucideIcons.chevronLeft,
              onTap: _currentPage > 0
                  ? () => _switchPage(_currentPage - 1)
                  : null,
              tooltip: 'Page précédente',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '${_currentPage + 1}/${math.max(_totalPages, 1)}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            _HeaderIconButton(
              icon: LucideIcons.chevronRight,
              onTap: _currentPage < _totalPages - 1
                  ? () => _switchPage(_currentPage + 1)
                  : null,
              tooltip: 'Page suivante',
            ),
            // Bouton "+" à côté de la pagination — fond violet pour
            // signaler l'action primaire "ajouter une page de dessin".
            _VioletHeaderIconButton(
              icon: LucideIcons.plus,
              onTap: _totalPages < widget.maxPages ? _addPage : null,
              tooltip: 'Nouvelle page (dessin)',
            ),
            _HeaderIconButton(
              icon: LucideIcons.trash2,
              onTap: (_totalPages > 1 &&
                      (widget.onDeletePage == null || widget.canDeletePage))
                  ? () => _deletePage()
                  : null,
              tooltip: 'Supprimer la page',
            ),
          ],
          const Spacer(),
          _HeaderIconButton(
            icon: LucideIcons.undo2,
            onTap: _undoStack.isEmpty ? null : _undo,
            tooltip: 'Annuler',
          ),
          _HeaderIconButton(
            icon: LucideIcons.redo2,
            onTap: _redoStack.isEmpty ? null : _redo,
            tooltip: 'Rétablir',
          ),
        ],
      ),
    );
  }

  Widget _buildTextEditor({bool fillHeight = false}) {
    // En mode texte-seul (showCanvas: false → fillHeight: true), la
    // zone texte remplit toute la hauteur disponible. Sinon hauteur
    // fixe pilotée par le splitter (mode classique).
    final stack = Stack(
      children: [
        // Zone texte — remplit toute la zone, avec une petite marge à
        // gauche pour la poignée d'agrandissement.
        Padding(
          padding: EdgeInsets.fromLTRB(
            widget.allowTextModal ? 38 : 14,
            10,
            14,
            10,
          ),
          child: TextField(
            controller: _textController,
            focusNode: _textFocusNode,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: widget.placeholder,
              hintStyle: TextStyle(color: Colors.grey.shade500),
              isCollapsed: true,
            ),
          ),
        ),
        // Poignée d'agrandissement — petite zone de tap confinée en haut-gauche
        // pour ne pas intercepter les taps destinés au TextField.
        if (widget.allowTextModal)
          Positioned(
            left: 6,
            top: 6,
            child: InkWell(
              onTap: _openTextModal,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  LucideIcons.maximize2,
                  size: 14,
                  color: Colors.grey.shade500,
                ),
              ),
            ),
          ),
      ],
    );

    final boxedContainer = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(16),
      ),
      // En mode texte-seul (fillHeight: true), pas de hauteur intrinsèque
      // : le parent (SizedBox.expand dans la branche showCanvas: false)
      // contraint la zone. En mode classique, hauteur pilotée par le
      // splitter via _textAreaHeight.
      child: fillHeight ? stack : SizedBox(height: _textAreaHeight, child: stack),
    );

    // En mode texte-seul (fillHeight) on resserre le padding externe
    // pour que la carte prenne le minimum d'espace autour.
    final outerPadding = fillHeight
        ? const EdgeInsets.fromLTRB(4, 4, 4, 4)
        : const EdgeInsets.fromLTRB(16, 12, 16, 8);
    return Padding(
      padding: outerPadding,
      child: boxedContainer,
    );
  }

  Widget _buildSplitter() {
    // Parité React : on réserve ~88px pour la toolbar en bas + ~40px de marge
    // afin que la zone texte puisse s'agrandir jusqu'à juste au-dessus de la
    // toolbar sans la pousser.
    const double kToolbarReserved = 88.0;
    const double kSplitterMargin = 40.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (details) {
        setState(() {
          final outerSize =
              (_outerKey.currentContext?.findRenderObject() as RenderBox?)
                  ?.size;
          final totalHeight = outerSize?.height ?? 600;
          final maxH = math.max(
              40.0, totalHeight - kToolbarReserved - kSplitterMargin);
          final next = _textAreaHeight + details.delta.dy;
          _textAreaHeight = next.clamp(40.0, maxH);
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: 10,
          alignment: Alignment.center,
          color: Colors.grey.shade100,
          child: Container(
            width: 60,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvasArea() {
    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                if (_canvasSize != size) setState(() => _canvasSize = size);
              });
              // ClipRRect EXTERNE qui englobe TOUS les layers du canvas
              // (fond grid, backgroundContent, strokes). Sans ce clip
              // global, le _BackgroundPainter (lignes grille, fond) n'est
              // pas rogné au border radius et les coins apparaissent
              // "effacés" / carrés. Maintenant le fond ET les strokes
              // sont clippés au même rayon que la carte parente.
              return ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    // Fond : freeform (blanc) ou grille.
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _BackgroundPainter(mode: widget.mode),
                      ),
                    ),
                    // Contenu décoratif optionnel derrière le canvas.
                    if (widget.backgroundContent != null)
                      Positioned.fill(
                        child: IgnorePointer(child: widget.backgroundContent!),
                      ),
                    if (!_isLoaded)
                      const Positioned.fill(
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: _onDrawStart,
                          onPanUpdate: _onDrawUpdate,
                          onPanEnd: _onDrawEnd,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.precise,
                            child: CustomPaint(
                              size: size,
                              painter: _StrokePainter(
                                strokes: _strokes,
                                activeStroke: _activeStroke,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        // Toolbar principale.
        if (!widget.toolbarInFooter) _positionedToolbar(),
        // Popover palette couleur (positionnée au-dessus/en-dessous de la toolbar).
        if (!widget.toolbarInFooter && _showColorPalette) _positionedPalette(),
        // Le "+" pour ajouter une page est désormais dans le header à
        // côté de la pagination (cf. _buildPageNavRow) — plus de FAB.
      ],
    );
  }

  Widget _buildPageManagement() {
    // Toujours visible quand la pagination est active.
    // Ajout : autorisé jusqu'à `maxPages`.
    // Suppression : autorisée dès qu'il reste ≥ 2 pages, sauf si un callback
    // externe pilote la logique (alors on respecte `canDeletePage`).
    final canAdd = _totalPages < widget.maxPages;
    final canDelete = widget.onDeletePage != null
        ? widget.canDeletePage
        : _totalPages > 1;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        border: Border.all(color: _kAccentColor),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PillIconButton(
            icon: LucideIcons.plus,
            onTap: canAdd ? () => _addPage() : null,
            tooltip: 'Nouvelle page',
          ),
          _PillIconButton(
            icon: LucideIcons.trash2,
            onTap: canDelete ? () => _deletePage() : null,
            tooltip: 'Supprimer la page',
          ),
        ],
      ),
    );
  }

  Widget _buildPageNav() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PillIconButton(
            icon: LucideIcons.chevronLeft,
            onTap: _currentPage > 0 ? () => _switchPage(_currentPage - 1) : null,
            tooltip: 'Page précédente',
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 42),
            alignment: Alignment.center,
            child: Text(
              '${_currentPage + 1}/${math.max(_totalPages, 1)}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
          _PillIconButton(
            icon: LucideIcons.chevronRight,
            onTap: _currentPage < _totalPages - 1
                ? () => _switchPage(_currentPage + 1)
                : null,
            tooltip: 'Page suivante',
          ),
        ],
      ),
    );
  }

  Widget _positionedToolbar() {
    final toolbar = _buildToolbar();
    switch (widget.toolbarPlacement) {
      case NoteToolbarPlacement.topRight:
        return Positioned(top: 12, right: 12, child: toolbar);
      case NoteToolbarPlacement.bottomCenter:
        final bottomOffset = widget.toolbarDockedToBorder ? -20.0 : 16.0;
        return Positioned(
          left: 0,
          right: 0,
          bottom: bottomOffset,
          child: Center(child: toolbar),
        );
    }
  }

  Widget _positionedPalette() {
    final palette = _buildColorPalettePopover();
    const margin = 12.0;
    switch (widget.toolbarPlacement) {
      case NoteToolbarPlacement.topRight:
        return Positioned(top: 74, right: 12, child: palette);
      case NoteToolbarPlacement.bottomCenter:
        final bottomOffset =
            widget.toolbarDockedToBorder ? 40.0 : 80.0 + margin;
        return Positioned(
          left: 0,
          right: 0,
          bottom: bottomOffset,
          child: Center(child: palette),
        );
    }
  }

  Widget _buildFooterToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [_buildToolbar()],
      ),
    );
  }

  Widget _buildToolbar() {
    final buttons = <Widget>[];
    for (final tool in _availableTools) {
      buttons.add(_toolButtonFor(tool));
    }
    // Palette — toujours visible en mode advanced. Désactivée (grisée)
    // quand la gomme est active, mais le bouton reste dans la toolbar.
    if (widget.toolset == NoteToolset.advanced) {
      buttons.add(_paletteButton());
    }
    // Clear
    buttons.add(_circularToolButton(
      icon: LucideIcons.trash2,
      tooltip: 'Tout effacer',
      onTap: _clearStrokes,
      disabled: _strokes.isEmpty,
    ));
    // Undo / Redo — inclus uniquement dans la nouvelle mise en page
    // "deux cartes" (la mise en page historique les affiche dans la
    // barre d'en-tête `_buildPageNavRow`).
    if (widget.stackedCards) {
      buttons.add(_circularToolButton(
        icon: LucideIcons.undo2,
        tooltip: 'Annuler',
        onTap: _undo,
        disabled: _undoStack.isEmpty,
      ));
      buttons.add(_circularToolButton(
        icon: LucideIcons.redo2,
        tooltip: 'Rétablir',
        onTap: _redo,
        disabled: _redoStack.isEmpty,
      ));
    }
    // Save
    if (widget.showSaveButton) buttons.add(_saveButton());

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      // Fallback horizontal scroll if the toolbar is too wide for its
      // container (evite l'overflow RenderFlex en écrans étroits).
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              buttons[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _toolButtonFor(NoteTool tool) {
    final icon = _iconForTool(tool);
    final isActive = _activeTool == tool;
    return _circularToolButton(
      icon: icon,
      tooltip: _labelForTool(tool),
      isActive: isActive,
      onTap: () => _setActiveTool(tool),
    );
  }

  void _setActiveTool(NoteTool tool) {
    setState(() {
      _activeTool = tool;
      if (tool == NoteTool.eraser) _showColorPalette = false;
    });
    widget.onToolChange?.call(tool);
  }

  Widget _paletteButton() {
    // La palette n'a pas de sens avec la gomme : on grise le bouton et on
    // empêche l'ouverture de la palette, sans le retirer de la toolbar.
    final disabled = _activeTool == NoteTool.eraser;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _circularToolButton(
          icon: LucideIcons.palette,
          tooltip: 'Couleur',
          isActive: !disabled && _showColorPalette,
          disabled: disabled,
          onTap: () => setState(() => _showColorPalette = !_showColorPalette),
        ),
        Positioned(
          top: -2,
          right: -2,
          child: Opacity(
            opacity: disabled ? 0.35 : 1,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: disabled ? Colors.grey.shade400 : Color(_activeColor),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _saveButton() {
    final label = _isSaving
        ? 'Sauvegarde'
        : (_saveLabel == _SaveLabel.saved ? 'Enregistré' : 'Sauvegarder');
    final disabled = _isSaving || !_isDirty;
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: disabled ? null : () => _handleSavePressed(),
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: _saveLabel == _SaveLabel.saved
                  ? const Color(0xFFDCFCE7)
                  : (_saveLabel == _SaveLabel.error
                      ? const Color(0xFFFEE2E2)
                      : Colors.grey.shade100),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _PulseIcon(
                  icon: LucideIcons.save,
                  animate: _isSaving,
                  size: 16,
                  color: disabled
                      ? Colors.grey.shade400
                      : Colors.grey.shade800,
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: disabled
                        ? Colors.grey.shade400
                        : Colors.grey.shade800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _circularToolButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool isActive = false,
    bool disabled = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: disabled ? null : onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              // Fond actif = violet clair canonique de l'app
              // (`_kStackedVioletSoft = 0xFFEDE8F5`), même teinte que
              // les conteneurs « ajouter un niveau » / icônes Documents
              // & VAD du dossier. Demande utilisateur 2026-04-28 :
              // « la couleur de fond des outils de note quand je les
              // selectionne doit être le meme violet clair que celui
              // qui est présent dans toute l'application ». L'ancien
              // `_kAccentSoft = 0xFFD8D0DC` (lavande terne) n'était
              // utilisé qu'ici — supprimé pour éviter toute dérive.
              color: isActive ? _kStackedVioletSoft : Colors.grey.shade100,
              shape: BoxShape.circle,
            ),
            child: Opacity(
              opacity: disabled ? 0.4 : 1,
              child: Icon(
                icon,
                size: 18,
                color: isActive ? _kActiveText : Colors.grey.shade700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildColorPalettePopover() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final preset in _kColorPresets)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    if (_activeTool == NoteTool.highlighter) {
                      _highlighterColor = preset;
                    } else {
                      _penColor = preset;
                    }
                    _showColorPalette = false;
                  });
                  _markDirty();
                },
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: Color(preset),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Icônes & labels
  // ---------------------------------------------------------------------------

  IconData _iconForTool(NoteTool tool) {
    switch (tool) {
      case NoteTool.pen:
        return LucideIcons.pencil;
      case NoteTool.highlighter:
        return LucideIcons.highlighter;
      case NoteTool.eraser:
        return LucideIcons.eraser;
      case NoteTool.line:
        return LucideIcons.minus;
      case NoteTool.rect:
        return LucideIcons.rectangleHorizontal;
    }
  }

  String _labelForTool(NoteTool tool) {
    switch (tool) {
      case NoteTool.pen:
        return 'Crayon';
      case NoteTool.highlighter:
        return 'Surligneur';
      case NoteTool.eraser:
        return 'Gomme';
      case NoteTool.line:
        return 'Ligne';
      case NoteTool.rect:
        return 'Rectangle';
    }
  }
}

// =============================================================================
// Painter du fond (freeform ou grid)
// =============================================================================

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter({required this.mode});

  final NoteCanvasMode mode;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (mode == NoteCanvasMode.grid) {
      final paint = Paint()
        ..color = const Color(0xFF94A3B8).withValues(alpha: 0.22)
        ..strokeWidth = 1;
      for (double x = _kGridCell; x < size.width; x += _kGridCell) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
      for (double y = _kGridCell; y < size.height; y += _kGridCell) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BackgroundPainter oldDelegate) =>
      oldDelegate.mode != mode;
}

// =============================================================================
// Painter des traits
// =============================================================================

class _StrokePainter extends CustomPainter {
  _StrokePainter({required this.strokes, required this.activeStroke});

  final List<_Stroke> strokes;
  final _Stroke? activeStroke;

  @override
  void paint(Canvas canvas, Size size) {
    // saveLayer isole les traits dans une couche transparente — la
    // gomme peut alors utiliser BlendMode.clear pour trouer seulement
    // les pixels de strokes, sans toucher le fond (silhouettes Mesures,
    // plans…). Sans cette couche, la gomme peindrait en blanc par-dessus
    // et masquerait les images de fond.
    final bounds = Offset.zero & size;
    canvas.saveLayer(bounds, Paint());
    for (final stroke in strokes) {
      _drawStroke(canvas, size, stroke);
    }
    final pending = activeStroke;
    if (pending != null) _drawStroke(canvas, size, pending);
    canvas.restore();
  }

  void _drawStroke(Canvas canvas, Size size, _Stroke stroke) {
    if (stroke.points.isEmpty) return;
    final realPoints = stroke.points
        .map((p) => Offset(p.dx * size.width, p.dy * size.height))
        .toList();

    switch (stroke.tool) {
      case NoteTool.pen:
      case NoteTool.eraser:
      case NoteTool.highlighter:
        // Gomme = BlendMode.clear sur la couche de strokes → efface
        // uniquement les pixels de traits, laisse le fond intact.
        // Plume/surligneur = srcOver normal.
        final isEraser = stroke.tool == NoteTool.eraser;
        final paint = Paint()
          ..color = isEraser
              ? Colors.black // couleur ignorée avec BlendMode.clear
              : Color(stroke.color).withValues(
                  alpha: stroke.tool == NoteTool.highlighter ? 0.4 : 1.0,
                )
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = stroke.size
          ..style = PaintingStyle.stroke
          ..blendMode = isEraser ? BlendMode.clear : BlendMode.srcOver;
        if (realPoints.length == 1) {
          canvas.drawCircle(
            realPoints.first,
            stroke.size / 2,
            Paint()
              ..color = paint.color
              ..blendMode = paint.blendMode,
          );
          return;
        }
        // Courbe quadratique midpoint (comme plan_canvas) pour un tracé
        // fluide sans saccades.
        final path = Path()..moveTo(realPoints.first.dx, realPoints.first.dy);
        for (var i = 1; i < realPoints.length; i++) {
          final p0 = realPoints[i - 1];
          final p1 = realPoints[i];
          final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
          path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
        }
        path.lineTo(realPoints.last.dx, realPoints.last.dy);
        canvas.drawPath(path, paint);
        break;
      case NoteTool.line:
        if (realPoints.length < 2) return;
        final paint = Paint()
          ..color = Color(stroke.color)
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke.size
          ..style = PaintingStyle.stroke;
        canvas.drawLine(realPoints.first, realPoints.last, paint);
        break;
      case NoteTool.rect:
        if (realPoints.length < 2) return;
        final paint = Paint()
          ..color = Color(stroke.color)
          ..strokeWidth = stroke.size
          ..style = PaintingStyle.stroke;
        canvas.drawRect(Rect.fromPoints(realPoints.first, realPoints.last),
            paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}

// =============================================================================
// Modal flottant draggable + resizable + plein écran
// =============================================================================

class _FloatingTextModal extends StatefulWidget {
  const _FloatingTextModal({
    required this.initialText,
    required this.placeholder,
    required this.title,
    required this.onChanged,
    required this.onClose,
    this.startFullscreen = false,
  });

  final String initialText;
  final String placeholder;
  final String title;
  final ValueChanged<String> onChanged;
  final VoidCallback onClose;

  /// Si true, le modal s'ouvre directement en pleine largeur (rect
  /// `(12, 12, screen.width - 24, screen.height - 24)`). Le bouton
  /// de bascule reste actif pour revenir en fenêtré si besoin.
  final bool startFullscreen;

  @override
  State<_FloatingTextModal> createState() => _FloatingTextModalState();
}

class _FloatingTextModalState extends State<_FloatingTextModal>
    with SingleTickerProviderStateMixin {
  static Offset _sharedPos = const Offset(60, 40);
  static Size _sharedSize = const Size(420, 340);

  late Offset _pos;
  late Size _size;
  late final TextEditingController _controller;
  late bool _fullscreen;

  /// Animation d'ouverture/fermeture — match `softDialogRouteBuilder`
  /// (cf. components/soft_transitions.dart) : fade 0→1 + scale 0.94→1.0
  /// sur 220 ms (kSoftMedium), easeOutCubic. Cohérent avec les autres
  /// pop-ups de l'app (showSoftDialog).
  late final AnimationController _entryController;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _pos = _sharedPos;
    _size = _sharedSize;
    _fullscreen = widget.startFullscreen;
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(() => widget.onChanged(_controller.text));
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..forward();
  }

  @override
  void dispose() {
    _sharedPos = _pos;
    _sharedSize = _size;
    _controller.dispose();
    _entryController.dispose();
    super.dispose();
  }

  /// Ferme le pop-up en jouant l'animation à l'envers (fade-out + scale
  /// down) avant d'appeler `widget.onClose` qui retire l'OverlayEntry.
  /// Évite le pop "abrupt" quand on tape sur le backdrop ou la croix.
  void _animateClose() {
    if (_closing) return;
    _closing = true;
    _entryController.reverse().whenComplete(() {
      if (mounted) widget.onClose();
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;

    // Mode "fullscreen" (qui est en réalité un grand pop-up centré sur
    // l'écran, pas un fullscreen total) :
    //   - Largeur ~ 90% de l'écran, capée à 1100 px (lisibilité sur
    //     iPad / desktop large).
    //   - Hauteur ~ 80% de l'écran, capée à 720 px.
    //   - Centré horizontalement ET verticalement.
    // Le backdrop noir 35% donne un effet "le focus est sur le pop-up,
    // le reste est en arrière-plan".
    final rect = _fullscreen
        ? () {
            final w = math.min(1100.0, screen.width * 0.9);
            final h = math.min(720.0, screen.height * 0.8);
            return Rect.fromLTWH(
              (screen.width - w) / 2,
              (screen.height - h) / 2,
              w,
              h,
            );
          }()
        : Rect.fromLTWH(
            _pos.dx.clamp(0, math.max(0, screen.width - 120)),
            _pos.dy.clamp(0, math.max(0, screen.height - 60)),
            _size.width,
            _size.height,
          );

    // Animation d'ouverture/fermeture (parité showSoftDialog) :
    //   - Backdrop : fade 0→0.35 d'alpha
    //   - Pop-up   : fade 0→1 + scale 0.94→1.0
    //   - 220 ms, easeOutCubic
    final curved = CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final scaleTween = Tween<double>(begin: 0.94, end: 1.0).animate(curved);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _animateClose,
            child: FadeTransition(
              opacity: curved,
              child: Container(color: Colors.black.withValues(alpha: 0.35)),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
          child: FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: scaleTween,
              child: Material(
            elevation: 12,
            borderRadius: BorderRadius.circular(16),
            color: Colors.white,
            child: Column(
              children: [
                // Barre draggable
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: _fullscreen
                      ? null
                      : (details) {
                          setState(() {
                            _pos += details.delta;
                            _pos = Offset(
                              _pos.dx.clamp(
                                  0, math.max(0, screen.width - 120)),
                              _pos.dy.clamp(
                                  0, math.max(0, screen.height - 60)),
                            );
                          });
                        },
                  child: MouseRegion(
                    cursor: _fullscreen
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.move,
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.gripHorizontal,
                              size: 16, color: Colors.grey.shade500),
                          const SizedBox(width: 8),
                          Text(
                            widget.title,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: _fullscreen ? 'Réduire' : 'Plein écran',
                            icon: Icon(
                              _fullscreen
                                  ? LucideIcons.minimize2
                                  : LucideIcons.maximize2,
                              size: 16,
                            ),
                            onPressed: () =>
                                setState(() => _fullscreen = !_fullscreen),
                          ),
                          IconButton(
                            tooltip: 'Fermer',
                            icon: const Icon(LucideIcons.x, size: 16),
                            // Route via _animateClose pour rejouer
                            // l'animation de fermeture (fade-out +
                            // scale-down) avant de retirer l'overlay.
                            onPressed: _animateClose,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: widget.placeholder,
                        hintStyle: TextStyle(color: Colors.grey.shade500),
                        isCollapsed: true,
                      ),
                    ),
                  ),
                ),
                if (!_fullscreen)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (details) {
                        setState(() {
                          final w = (_size.width + details.delta.dx).clamp(
                              280.0, screen.width - 40);
                          final h = (_size.height + details.delta.dy).clamp(
                              200.0, screen.height - 40);
                          _size = Size(w, h);
                        });
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeDownRight,
                        child: Container(
                          width: 18,
                          height: 18,
                          margin: const EdgeInsets.all(4),
                          child: CustomPaint(
                            painter: _ResizeHandlePainter(
                                color: Colors.grey.shade400),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
            ), // close ScaleTransition
          ), // close FadeTransition
        ),
      ],
    );
  }
}

class _ResizeHandlePainter extends CustomPainter {
  _ResizeHandlePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.4;
    for (var i = 1; i <= 3; i++) {
      final offset = i * 4.0;
      canvas.drawLine(
        Offset(size.width - offset, size.height),
        Offset(size.width, size.height - offset),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResizeHandlePainter oldDelegate) =>
      oldDelegate.color != color;
}

// =============================================================================
// Petits widgets utilitaires
// =============================================================================

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 18,
          color: onTap == null ? Colors.grey.shade300 : Colors.grey.shade600,
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}

class _PillIconButton extends StatelessWidget {
  const _PillIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 16,
            color:
                onTap == null ? Colors.grey.shade300 : Colors.grey.shade700,
          ),
        ),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip!, child: btn);
  }
}

/// Bouton chevron en violet pour la pagination centrée de la mise en
/// page "deux cartes empilées". Grisé quand `enabled == false`, sans
/// fond ni contour. Zone de tap 44×44 pour respecter les guidelines
/// tablette (Apple HIG minimum 44pt).
class _StackedChevronButton extends StatelessWidget {
  const _StackedChevronButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            child: Opacity(
              opacity: enabled ? 1 : 0.3,
              child: Icon(
                icon,
                size: 22,
                color: _kStackedViolet,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseIcon extends StatefulWidget {
  const _PulseIcon({
    required this.icon,
    required this.animate,
    required this.size,
    required this.color,
  });

  final IconData icon;
  final bool animate;
  final double size;
  final Color color;

  @override
  State<_PulseIcon> createState() => _PulseIconState();
}

class _PulseIconState extends State<_PulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    if (widget.animate) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _PulseIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.animate && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final alpha = 1.0 - (_controller.value * 0.3);
        return Opacity(
          opacity: alpha,
          child: Icon(widget.icon, size: widget.size, color: widget.color),
        );
      },
    );
  }
}

// Clipboard helper (pour couper le warning sur SystemChannels unused).
// ignore: unused_element
Future<void> _copyToClipboard(String value) async {
  await Clipboard.setData(ClipboardData(text: value));
}

/// Variante violette de `_HeaderIconButton` — même taille / padding que
/// les autres boutons du header de note, fond violet **clair** (#EDE8F5)
/// + icône violet **foncé** (#7C6DAA) pour signaler l'action primaire
/// « ajouter une page » de manière douce, en cohérence avec la palette
/// pastel du reste de l'app (sub-nav du relevé de visite, badges
/// EPCI…). Avant : fond violet foncé + icône blanche, qui détonnait.
class _VioletHeaderIconButton extends StatelessWidget {
  const _VioletHeaderIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    const bg = Color(0xFFEDE8F5); // violet clair
    const fg = _kAccentColor; // violet foncé #7C6DAA
    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled ? bg : bg.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              icon,
              size: 18,
              color: enabled ? fg : fg.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}
