import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/data_service.dart';
import '../services/pencil_interaction_service.dart';
import 'confirmation_dialog.dart';

// ---------------------------------------------------------------------------
// Grid constants — 1 cell = 20cm in real world, major line every 5 cells
// ---------------------------------------------------------------------------

const Color _kToolbarActiveBg = Color(0xFFF2ECF5);
const Color _kToolbarActiveText = Color(0xFF554265);
const Color _kToolbarIcon = Color(0xFF2B323A);
const Color _kToolbarHoverBg = Color(0xFFF2F4F6);
const double _kDefaultEraserSize = 18.0;
const List<double> _kEraserSizePresets = <double>[8.0, 18.0, 44.0];

// ---------------------------------------------------------------------------
// Stroke model
// ---------------------------------------------------------------------------

enum PlanTool {
  pen,
  highlighter,
  line,
  rect,
  // Symboles architecturaux — placés par glisser-déposer (P0→P1 définit
  // la position, la taille et l'orientation).
  wall,
  window,
  windowDouble,
  door,
  toilet,
  shower,
  bath,
  sink,
  eraser,
}

/// Ensemble des outils qui produisent un SYMBOLE placé (pas un stroke de
/// tracé libre). Ces symboles sont sélectionnables et manipulables avec
/// des poignées (4 coins pour la taille + 1 flèche pour la rotation).
const Set<PlanTool> _symbolTools = {
  PlanTool.window,
  PlanTool.windowDouble,
  PlanTool.door,
  PlanTool.toilet,
  PlanTool.shower,
  PlanTool.bath,
  PlanTool.sink,
};

class _PlanStroke {
  final PlanTool tool;
  final int color; // ARGB
  final double size;

  /// pen/highlighter/eraser : liste de points.
  /// line/rect/wall : [start, end].
  /// Symboles (window/door/toilet/shower/bath) : [centerPoint, cornerPoint]
  /// où le rectangle englobant (non tourné) est centré sur centerPoint
  /// et va jusqu'à cornerPoint en coordonnées LOCALES (avant rotation).
  final List<Offset> points;

  /// Rotation (radians, horaire). N'a de sens que pour les symboles
  /// architecturaux. Par défaut 0 (pas de rotation).
  double rotation;

  /// Flip visuel sur l'axe X (mirror gauche↔droite). Ne change pas la
  /// bounding box — juste le rendu. Utilisé pour inverser le sens d'une
  /// porte, d'un lavabo, etc.
  bool flipX;

  /// Flip visuel sur l'axe Y (mirror haut↔bas).
  bool flipY;

  _PlanStroke({
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
    this.rotation = 0,
    this.flipX = false,
    this.flipY = false,
  });

  Map<String, dynamic> toJson() => {
    'tool': tool.name,
    'color': color,
    'size': size,
    'points': points.map((p) => [p.dx, p.dy]).toList(),
    if (rotation != 0) 'rotation': rotation,
    if (flipX) 'flipX': true,
    if (flipY) 'flipY': true,
  };

  static _PlanStroke? fromJson(Map<String, dynamic> json) {
    try {
      final toolName = json['tool']?.toString() ?? 'pen';
      final tool = PlanTool.values.firstWhere(
        (t) => t.name == toolName,
        orElse: () => PlanTool.pen,
      );
      final color = (json['color'] as num?)?.toInt() ?? 0xFF1A1A1A;
      final size = (json['size'] as num?)?.toDouble() ?? 2.0;
      final pts = (json['points'] as List?) ?? const [];
      final points = pts.whereType<List>().map<Offset>((pt) {
        return Offset((pt[0] as num).toDouble(), (pt[1] as num).toDouble());
      }).toList();
      final rotation = (json['rotation'] as num?)?.toDouble() ?? 0.0;
      final flipX = json['flipX'] == true;
      final flipY = json['flipY'] == true;
      return _PlanStroke(
        tool: tool,
        color: color,
        size: size,
        points: points,
        rotation: rotation,
        flipX: flipX,
        flipY: flipY,
      );
    } catch (_) {
      return null;
    }
  }

  /// Rectangle englobant LOCAL (sans rotation) du symbole. [center] est
  /// au milieu, les dimensions proviennent de la différence avec
  /// cornerPoint. Utilisé pour rendre + hit-test.
  Rect? get symbolLocalBounds {
    if (!_symbolTools.contains(tool) || points.length < 2) return null;
    final c = points[0];
    final corner = points[1];
    final halfW = (corner.dx - c.dx).abs();
    final halfH = (corner.dy - c.dy).abs();
    return Rect.fromCenter(
      center: c,
      width: (halfW * 2).clamp(16, 4000),
      height: (halfH * 2).clamp(16, 4000),
    );
  }
}

// ---------------------------------------------------------------------------
// PlanCanvas widget
// ---------------------------------------------------------------------------

class PlanCanvasController {
  _PlanCanvasState? _state;

  Future<void> flush() async {
    await _state?._flushPendingSave();
  }
}

class PlanCanvas extends StatefulWidget {
  final String patientId;
  final String tabKey;
  final PlanCanvasController? controller;

  /// Page number (0-based). Each page stores its own set of strokes.
  final int pageNumber;

  /// Regenerates the PNG preview once after loading existing strokes.
  /// Useful when a page has just been seeded from another drawing.
  final bool refreshPreviewOnLoad;

  /// Optional pagination info rendered inline dans la toolbar.
  final int? currentPage;
  final int? totalPages;
  final VoidCallback? onPrevPage;
  final VoidCallback? onNextPage;

  /// Ajoute une nouvelle page VIERGE après la page courante.
  final VoidCallback? onAddPage;

  /// Duplique la page courante (clone des strokes + symboles) — demande
  /// utilisateur 2026-05-04 : « possibilité d'ajouter une page (vierge)
  /// ou de dupliquer la page actuelle ». Si null, l'option n'apparaît
  /// pas dans le menu trois points.
  final VoidCallback? onDuplicatePage;
  final VoidCallback? onDeletePage;

  const PlanCanvas({
    super.key,
    required this.patientId,
    this.controller,
    this.tabKey = 'Plans',
    this.pageNumber = 0,
    this.refreshPreviewOnLoad = false,
    this.currentPage,
    this.totalPages,
    this.onPrevPage,
    this.onNextPage,
    this.onAddPage,
    this.onDuplicatePage,
    this.onDeletePage,
  });

  @override
  State<PlanCanvas> createState() => _PlanCanvasState();
}

class _PlanCanvasState extends State<PlanCanvas> {
  final _dataService = DataService();
  final GlobalKey _drawAreaKey = GlobalKey();
  StreamSubscription<PencilDoubleTapEvent>? _pencilDoubleTapSubscription;

  PlanTool _tool = PlanTool.pen;
  int _penColor = 0xFF1A1A1A;
  double _eraserSize = _kDefaultEraserSize;
  bool _showEraserSizeGauge = false;
  final Object _eraserSizeTapRegion = Object();
  bool _showWindowTypeBundle = false;
  final Object _windowTypeTapRegion = Object();
  double get _penSize =>
      _tool == PlanTool.eraser ? _eraserSize : _defaultStrokeSizeFor(_tool);

  // Sélection d'un symbole architectural placé — -1 = rien de sélectionné.
  int _selectedIndex = -1;
  // Mode édition : quand true, poignées + boutons flottants (flip,
  // supprimer) sont visibles et actifs. Déclenché par un TAP sur le
  // symbole (finger down + up sans drag). Un drag direct sur un
  // symbole déplace sans activer le mode édition — l'action primaire
  // reste le déplacement.
  bool _editingMode = false;
  // Action en cours sur le symbole sélectionné (drag d'une poignée, du
  // corps, rotation). `null` entre les gestures.
  _SymbolHandle? _activeHandle;
  // Backup pour les drags (valeurs initiales du symbole au début du geste).
  Offset? _dragAnchor;
  Offset? _dragInitialCenter;
  Offset? _dragInitialCorner;
  double? _dragInitialRotation;

  // Committed strokes
  final List<_PlanStroke> _strokes = [];
  // In-progress stroke (pen/eraser) or shape preview (line/rect)
  _PlanStroke? _current;

  // Undo / redo — snapshots deep-copiés des traits à chaque mutation
  // (trait terminé, symbole placé/déplacé/supprimé, effacer tout…).
  // Limité à 50 entrées pour éviter la dérive mémoire.
  final List<List<_PlanStroke>> _undoStack = [];
  final List<List<_PlanStroke>> _redoStack = [];

  Timer? _saveTimer;
  bool _loaded = false;

  static const List<int> _presetColors = [
    0xFF1A1A1A,
    0xFFE53E3E,
    0xFF2B6CB0,
    0xFF2F855A,
    0xFFD69E2E,
  ];

  static double _defaultStrokeSizeFor(PlanTool tool) {
    switch (tool) {
      case PlanTool.highlighter:
        return 6.0;
      case PlanTool.eraser:
        return _kDefaultEraserSize;
      case PlanTool.pen:
      case PlanTool.line:
      case PlanTool.rect:
      case PlanTool.wall:
      case PlanTool.window:
      case PlanTool.windowDouble:
      case PlanTool.door:
      case PlanTool.toilet:
      case PlanTool.shower:
      case PlanTool.bath:
      case PlanTool.sink:
        return 2.0;
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
    _loadStrokes();
    _pencilDoubleTapSubscription = PencilInteractionService.instance.onDoubleTap
        .listen((_) {
          if (!mounted) return;
          if (_tool == PlanTool.eraser) return;
          setState(() => _tool = PlanTool.eraser);
        });
  }

  @override
  void didUpdateWidget(covariant PlanCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
    if (oldWidget.pageNumber != widget.pageNumber ||
        oldWidget.patientId != widget.patientId ||
        oldWidget.tabKey != widget.tabKey) {
      // Flush any pending save for the previous page before we switch.
      final hadPendingSave = _saveTimer?.isActive ?? false;
      _saveTimer?.cancel();
      if (hadPendingSave) {
        // Persist synchronously-ish; small best-effort. Important même si
        // `_strokes` est vide : un "effacer tout" doit aussi être sauvé.
        _persistForKey(
          oldWidget.patientId,
          oldWidget.tabKey,
          oldWidget.pageNumber,
        );
      }
      setState(() {
        _loaded = false;
        _strokes.clear();
        _current = null;
        _undoStack.clear();
        _redoStack.clear();
        _selectedIndex = -1;
        _editingMode = false;
      });
      _loadStrokes();
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) {
      widget.controller?._state = null;
    }
    final hadPendingSave = _saveTimer?.isActive ?? false;
    _saveTimer?.cancel();
    if (hadPendingSave) {
      unawaited(_persist());
    }
    _pencilDoubleTapSubscription?.cancel();
    _pencilDoubleTapSubscription = null;
    super.dispose();
  }

  // ----- Undo / redo -----

  /// Clone profond de la liste courante des strokes via un round-trip
  /// JSON (les `_PlanStroke` ont des champs mutables : `points`,
  /// `rotation`, donc une copie de référence ne suffit pas).
  List<_PlanStroke> _cloneStrokes() {
    final encoded = jsonEncode(_strokes.map((s) => s.toJson()).toList());
    final decoded = jsonDecode(encoded) as List;
    return decoded
        .map((m) => _PlanStroke.fromJson((m as Map).cast<String, dynamic>()))
        .whereType<_PlanStroke>()
        .toList();
  }

  /// Snapshot l'état courant AVANT une mutation, vide la pile redo.
  void _pushUndo() {
    _undoStack.add(_cloneStrokes());
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _redoStack.add(_cloneStrokes());
      final prev = _undoStack.removeLast();
      _strokes
        ..clear()
        ..addAll(prev);
      _selectedIndex = -1;
      _activeHandle = null;
      _current = null;
    });
    _scheduleSave();
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      _undoStack.add(_cloneStrokes());
      final next = _redoStack.removeLast();
      _strokes
        ..clear()
        ..addAll(next);
      _selectedIndex = -1;
      _activeHandle = null;
      _current = null;
    });
    _scheduleSave();
  }

  // ----- Persistence -----

  List<_PlanStroke> _decodeStrokesJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['format'] != 'plan_canvas_v1') return const [];
      final strokes = (decoded['strokes'] as List?) ?? const [];
      return strokes
          .whereType<Map>()
          .map((m) => _PlanStroke.fromJson(m.cast<String, dynamic>()))
          .whereType<_PlanStroke>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _loadStrokes() async {
    final json = await _dataService.fetchNoteDrawingJson(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
      pageNumber: widget.pageNumber,
    );
    if (!mounted) return;
    _strokes
      ..clear()
      ..addAll(_decodeStrokesJson(json));
    if (!mounted) return;
    setState(() => _loaded = true);
    if (widget.refreshPreviewOnLoad && _strokes.isNotEmpty) {
      // Refresh the preview after loading a seeded page so report generation
      // sees the copied editable drawing even if the user does not redraw.
      _scheduleSave();
    }
  }

  Future<void> _persistForKey(
    String patientId,
    String tabKey,
    int pageNumber,
  ) async {
    final payload = jsonEncode({
      'format': 'plan_canvas_v1',
      'strokes': _strokes.map((s) => s.toJson()).toList(),
    });
    // Rasterisation du dessin → data URL PNG. Indispensable pour
    // alimenter les pages 9 (avant) et 10 (après) du rapport PDF :
    // pdf-lib n'a aucun moyen de re-rendre les strokes vectoriels
    // côté serveur, on doit lui livrer une image prête.
    //
    // Échec gracieux : si la rasterisation foire (canvas démonté,
    // `toImage` indisponible — rare), on save quand même les
    // strokes JSON. Le rapport aura juste page 9/10 vide pour cette
    // visite.
    final previewDataUrl = await _rasterizeCanvasDataUrl();
    await _dataService.saveNoteDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
      drawingJson: payload,
      previewDataUrl: previewDataUrl,
    );
  }

  /// Rasterise le contenu actuel du canvas (fond blanc + grille +
  /// strokes) en PNG encodé en data URL. Utilise un PictureRecorder
  /// indépendant — comme `_downloadPng()` — plutôt qu'un
  /// RepaintBoundary, pour éviter d'avoir à wrapper la zone de dessin
  /// dans un nouveau widget tree.
  ///
  /// Retourne `null` si le canvas n'est pas encore monté ou si le
  /// rendu échoue. Le caller garde alors `drawingJson` seul — le
  /// rapport aura juste un slot vide.
  Future<String?> _rasterizeCanvasDataUrl() async {
    try {
      final box = _drawAreaKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return null;
      final size = box.size;
      if (size.width < 1 || size.height < 1) return null;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = Colors.white,
      );
      _GridPainter().paint(canvas, size);
      _DrawPainter.paintStrokes(canvas, _strokes, null);
      final picture = recorder.endRecording();
      final img = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      final base64 = base64Encode(byteData.buffer.asUint8List());
      return 'data:image/png;base64,$base64';
    } catch (_) {
      return null;
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _persist);
  }

  Future<void> _flushPendingSave() async {
    final hadPendingSave = _saveTimer?.isActive ?? false;
    _saveTimer?.cancel();
    if (!hadPendingSave) return;
    await _persist();
  }

  Future<void> _persist() async {
    await _persistForKey(widget.patientId, widget.tabKey, widget.pageNumber);
  }

  // ----- Gesture handlers -----

  Offset _localPoint(Offset global) {
    final box = _drawAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return global;
    return box.globalToLocal(global);
  }

  void _onPanStart(DragStartDetails d) {
    final pt = _localPoint(d.globalPosition);
    // Couleur et taille dépendent de l'outil.
    int colorForStroke;
    double sizeForStroke;
    switch (_tool) {
      case PlanTool.eraser:
        colorForStroke = 0x00000000;
        // Épaisseur propre à la gomme (modifiable via son popover).
        sizeForStroke = _penSize;
        break;
      case PlanTool.highlighter:
        // 35% d'opacité → effet fluo par-dessus le contenu existant.
        // Épaisseur propre au surligneur, pas de multiplicateur : la
        // valeur par défaut est plus élevée que le crayon.
        colorForStroke = (_penColor & 0x00FFFFFF) | 0x59000000;
        sizeForStroke = _penSize;
        break;
      case PlanTool.wall:
        // Mur (legacy) : épaisseur multipliée, noir plein. L'outil
        // mur a été retiré de la toolbar mais le case reste pour
        // compat avec les plans anciens.
        colorForStroke = 0xFF0F172A;
        sizeForStroke = (_penSize * 3).clamp(6, 24);
        break;
      default:
        colorForStroke = _penColor;
        sizeForStroke = _penSize;
    }
    final stroke = _PlanStroke(
      tool: _tool,
      color: colorForStroke,
      size: sizeForStroke,
      points: [pt],
    );
    setState(() => _current = stroke);
  }

  /// Outils "tracé libre" qui accumulent des points pendant le drag.
  /// Tous les autres (line/rect/symboles architecturaux) conservent un
  /// couple [start, current] pour dessiner la forme dynamiquement.
  static const _freehandTools = {
    PlanTool.pen,
    PlanTool.highlighter,
    PlanTool.eraser,
  };

  void _onPanUpdate(DragUpdateDetails d) {
    final cur = _current;
    if (cur == null) return;
    final pt = _localPoint(d.globalPosition);
    setState(() {
      if (_freehandTools.contains(cur.tool)) {
        cur.points.add(pt);
      } else {
        // Shape/symbole : toujours [start, current]
        if (cur.points.length < 2) {
          cur.points.add(pt);
        } else {
          cur.points[1] = pt;
        }
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    final cur = _current;
    if (cur == null) return;
    if (_freehandTools.contains(cur.tool) && cur.points.length < 2) {
      // Ensure a dot renders by duplicating the point
      cur.points.add(cur.points.first.translate(0.1, 0));
    }
    // Symbole architectural posé en tap (sans drag) → on se donne une
    // taille par défaut pour que l'objet apparaisse quand même.
    if (!_freehandTools.contains(cur.tool) && cur.points.length < 2) {
      cur.points.add(cur.points.first.translate(60, 40));
    }
    _pushUndo();
    setState(() {
      _strokes.add(cur);
      _current = null;
    });
    _scheduleSave();
  }

  // ----- Actions -----

  void _clearAll() async {
    final confirmed = await showAppDestructiveConfirmation(
      context: context,
      title: 'Effacer le plan ?',
      message: 'Toutes les annotations seront supprimées définitivement.',
      confirmLabel: 'Effacer',
      icon: LucideIcons.eraser,
    );
    if (confirmed != true) return;
    _pushUndo();
    setState(() {
      _strokes.clear();
      _current = null;
    });
    _scheduleSave();
  }

  Future<void> _downloadPng() async {
    final box = _drawAreaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final size = box.size;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Background white
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.white,
    );

    // Quadrillage simple + strokes.
    _GridPainter().paint(canvas, size);
    _DrawPainter.paintStrokes(canvas, _strokes, null);

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.width.toInt(), size.height.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return;
    final bytes = byteData.buffer.asUint8List();

    try {
      final dir = await getApplicationDocumentsDirectory();
      final outPath = p.join(
        dir.path,
        'plan-visite-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(outPath).writeAsBytes(bytes);
      if (!mounted) return;

      // Let user pick an export location (on web this triggers download)
      try {
        final savedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Enregistrer le plan',
          fileName: p.basename(outPath),
          bytes: bytes,
        );
        if (savedPath == null) {
          _showSnack('Plan exporté dans ${p.basename(outPath)}');
        } else {
          _showSnack('Plan exporté.');
        }
      } catch (_) {
        _showSnack('Plan exporté dans ${p.basename(outPath)}');
      }
    } catch (err) {
      _showSnack('Export impossible: $err');
    }
  }

  // ---------------------------------------------------------------------
  // Insertion d'un symbole architectural depuis le menu déroulant.
  // ---------------------------------------------------------------------

  static const Map<PlanTool, Size> _defaultSymbolSize = {
    // Fenêtre simple : cadre carré autour de l'arc d'ouverture.
    PlanTool.window: Size(72, 72),
    // Fenêtre double : deux ouvertures côte à côte.
    PlanTool.windowDouble: Size(112, 72),
    PlanTool.door: Size(80, 80),
    // WC : plus petit + plus large (proportions cuvette réelle ~2:1,
    // l'axe long étant horizontal). Orientable ensuite via la rotation.
    PlanTool.toilet: Size(68, 40),
    PlanTool.shower: Size(90, 90),
    PlanTool.bath: Size(170, 75),
    // Lavabo : plus large que profond (typ. 60 × 45 cm en vue du dessus).
    PlanTool.sink: Size(70, 50),
  };

  void _insertSymbolAtCenter(PlanTool tool) {
    final box = _drawAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final canvasSize = box?.size ?? const Size(800, 600);
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final defaultSize = _defaultSymbolSize[tool] ?? const Size(100, 100);
    final corner = Offset(defaultSize.width / 2, defaultSize.height / 2);
    // Couleur du symbole = couleur active du crayon (demande utilisateur
    // 2026-05-04 : « le changement de couleur doit également changer la
    // couleur de l'élément ajouté »). Avant : `0xFF0F172A` hardcodé →
    // les fenêtres/portes/WC restaient toujours en gris foncé même
    // après changement de couleur.
    final stroke = _PlanStroke(
      tool: tool,
      color: _penColor,
      size: 2,
      points: [center, center + corner],
      rotation: 0,
    );
    _pushUndo();
    setState(() {
      _strokes.add(stroke);
      _selectedIndex = _strokes.length - 1;
      _showWindowTypeBundle = false;
      // On repasse sur le crayon pour que le prochain drag sur le canvas
      // ne réouvre pas le menu / ne dessine pas un outil figé inattendu.
      _tool = PlanTool.pen;
    });
    _scheduleSave();
  }

  // ---------------------------------------------------------------------
  // Hit testing & handles autour du symbole sélectionné.
  // ---------------------------------------------------------------------

  /// Convertit un point local canvas en coordonnée LOCALE du symbole
  /// (pré-rotation) — utile pour tester l'intersection avec le bounds
  /// non tourné ou les poignées.
  Offset _toSymbolLocal(_PlanStroke s, Offset p) {
    final c = s.points.first;
    final v = p - c;
    final cos = math.cos(-s.rotation);
    final sin = math.sin(-s.rotation);
    return Offset(v.dx * cos - v.dy * sin, v.dx * sin + v.dy * cos) + c;
  }

  Offset _rotateVector(Offset v, double angle) {
    final cos = math.cos(angle);
    final sin = math.sin(angle);
    return Offset(v.dx * cos - v.dy * sin, v.dx * sin + v.dy * cos);
  }

  _SymbolHandle? _handleAt(_PlanStroke s, Offset globalCanvasPoint) {
    final local = _toSymbolLocal(s, globalCanvasPoint);
    final bounds = s.symbolLocalBounds;
    if (bounds == null) return null;
    // Déplacer est l'action PRIMAIRE : si le doigt est clairement dans
    // l'intérieur du symbole, on court-circuite tout test de poignée et
    // on prend direct le body drag. Évite que les poignées ne mangent
    // la zone centrale et rendent le déplacement impossible.
    final innerMargin = math.min(
      16.0,
      math.min(bounds.width, bounds.height) / 3.0,
    );
    final inner = bounds.deflate(innerMargin);
    if (!inner.isEmpty && inner.contains(local)) {
      return _SymbolHandle.body;
    }
    // Hitbox resserrée : les poignées sont plus petites (visuellement
    // et tactilement) pour ne pas concurrencer le body drag près des
    // bords.
    const cornerHit = 18.0;
    const midHit = 14.0;
    const rotateHit = 20.0;
    // Les coins ont priorité sur les milieux d'arête (le coin couvre
    // géométriquement la fin de l'arête → on teste les coins d'abord).
    if ((local - bounds.topLeft).distance < cornerHit) {
      return _SymbolHandle.topLeft;
    }
    if ((local - bounds.topRight).distance < cornerHit) {
      return _SymbolHandle.topRight;
    }
    if ((local - bounds.bottomLeft).distance < cornerHit) {
      return _SymbolHandle.bottomLeft;
    }
    if ((local - bounds.bottomRight).distance < cornerHit) {
      return _SymbolHandle.bottomRight;
    }
    // Milieux d'arête (resize 1D).
    final topMid = Offset(bounds.center.dx, bounds.top);
    final bottomMid = Offset(bounds.center.dx, bounds.bottom);
    final leftMid = Offset(bounds.left, bounds.center.dy);
    final rightMid = Offset(bounds.right, bounds.center.dy);
    if ((local - topMid).distance < midHit) return _SymbolHandle.topMid;
    if ((local - bottomMid).distance < midHit) {
      return _SymbolHandle.bottomMid;
    }
    if ((local - leftMid).distance < midHit) return _SymbolHandle.leftMid;
    if ((local - rightMid).distance < midHit) {
      return _SymbolHandle.rightMid;
    }
    // Flèche de rotation au-dessus du bord haut, à `rotateOffset` px.
    const rotateOffset = 52.0;
    final rotateLocal = Offset(bounds.center.dx, bounds.top - rotateOffset);
    if ((local - rotateLocal).distance < rotateHit) {
      return _SymbolHandle.rotate;
    }
    if (bounds.contains(local)) return _SymbolHandle.body;
    return null;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ----- Build -----

  @override
  Widget build(BuildContext context) {
    // Le canvas prend toute la place. Les outils génériques restent dans
    // le dock bas, les symboles flottent en haut-gauche et la pagination
    // en haut-droite.
    return Stack(
      children: [
        Positioned.fill(child: _buildCanvas()),
        Positioned(top: 16, left: 16, child: _buildSymbolOverlayTools()),
        if (_showWindowTypeBundle)
          Positioned(
            top: 86,
            left: 16,
            child: TapRegion(
              groupId: _windowTypeTapRegion,
              child: _buildWindowTypeBundle(),
            ),
          ),
        Positioned(top: 16, right: 16, child: _buildPaginationOverlayTools()),
        if (_showEraserSizeGauge)
          Positioned(
            left: 0,
            right: 0,
            bottom: 80,
            child: Center(
              child: TapRegion(
                groupId: _eraserSizeTapRegion,
                child: _buildEraserSizePopover(),
              ),
            ),
          ),
        Positioned(left: 0, right: 0, bottom: 16, child: _buildToolbarDock()),
      ],
    );
  }

  Widget _buildToolbarDock() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildPlanToolbar(),
        ),
      ),
    );
  }

  /// Toolbar principale. Ordre :
  ///   [Crayon][Surligneur][Gomme][Ligne][Rect] [Couleur]
  ///   [Undo][Redo][Effacer tout]
  /// Style volontairement aligné sur la barre Mesures (NotesWidget) :
  /// pill blanc, boutons 36×36, actif violet clair, icônes ink-700.
  Widget _buildPlanToolbar() {
    final buttons = <Widget>[
      _toolBtn(PlanTool.pen, LucideIcons.pencil, 'Crayon'),
      _toolBtn(PlanTool.highlighter, LucideIcons.highlighter, 'Surligneur'),
      _eraserToolBtn(),
      _toolBtn(PlanTool.line, LucideIcons.minus, 'Ligne'),
      _toolBtn(PlanTool.rect, LucideIcons.square, 'Rectangle'),
      _buildActiveColorDot(),
      _iconBtn(
        icon: LucideIcons.undo2,
        tooltip: 'Annuler',
        onTap: _undoStack.isEmpty ? null : _undo,
      ),
      _iconBtn(
        icon: LucideIcons.redo2,
        tooltip: 'Rétablir',
        onTap: _redoStack.isEmpty ? null : _redo,
      ),
      _iconBtn(
        icon: LucideIcons.x,
        tooltip: 'Effacer tout le plan',
        onTap: _strokes.isEmpty ? null : _clearAll,
        activeColor: const Color(0xFFB4232F),
        backgroundColor: _strokes.isEmpty
            ? const Color(0xFFFFF1F2)
            : const Color(0xFFFFE4E6),
      ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          buttons[i],
        ],
      ],
    );
  }

  Widget _buildSymbolOverlayTools() {
    return _buildOverlayDock(_symbolButtons());
  }

  Widget _buildPaginationOverlayTools() {
    if (widget.currentPage == null || widget.totalPages == null) {
      return const SizedBox.shrink();
    }
    return _buildOverlayDock([
      _iconBtn(
        icon: LucideIcons.chevronLeft,
        tooltip: 'Page précédente',
        onTap: (widget.currentPage! > 0) ? widget.onPrevPage : null,
      ),
      _buildPageCounter(),
      _iconBtn(
        icon: LucideIcons.chevronRight,
        tooltip: 'Page suivante',
        onTap: (widget.currentPage! < widget.totalPages! - 1)
            ? widget.onNextPage
            : null,
      ),
      _buildMoreMenu(),
    ]);
  }

  Widget _buildOverlayDock(List<Widget> buttons) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              buttons[i],
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _symbolButtons() {
    return [
      _windowBundleButton(),
      _symbolInsertBtn(
        PlanTool.door,
        Icon(LucideIcons.doorClosed, size: 18, color: _kToolbarIcon),
        'Porte',
      ),
      _symbolInsertBtn(
        PlanTool.toilet,
        ToiletPictogram(size: 18, color: _kToolbarIcon),
        'WC',
      ),
      _symbolInsertBtn(
        PlanTool.shower,
        Icon(LucideIcons.showerHead, size: 18, color: _kToolbarIcon),
        'Douche',
      ),
      _symbolInsertBtn(
        PlanTool.bath,
        Icon(LucideIcons.bath, size: 18, color: _kToolbarIcon),
        'Baignoire',
      ),
      _symbolInsertBtn(
        PlanTool.sink,
        Icon(LucideIcons.droplets, size: 18, color: _kToolbarIcon),
        'Lavabo',
      ),
    ];
  }

  Widget _buildPageCounter() {
    return SizedBox(
      height: 36,
      child: Center(
        child: Text(
          '${widget.currentPage! + 1}/${widget.totalPages}',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: _kToolbarIcon,
          ),
        ),
      ),
    );
  }

  Widget _windowBundleButton() {
    return TapRegion(
      groupId: _windowTypeTapRegion,
      onTapOutside: (_) => _hideWindowTypeBundle(),
      child: _symbolButtonShell(
        iconChild: Icon(LucideIcons.columns, size: 18, color: _kToolbarIcon),
        tooltip: 'Choisir une fenêtre',
        onTap: () {
          setState(() {
            _showWindowTypeBundle = !_showWindowTypeBundle;
            _showEraserSizeGauge = false;
          });
        },
      ),
    );
  }

  void _hideWindowTypeBundle() {
    if (!_showWindowTypeBundle || !mounted) return;
    setState(() => _showWindowTypeBundle = false);
  }

  Widget _buildWindowTypeBundle() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, 4),
            spreadRadius: -4,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _windowTypeChoice(
            tool: PlanTool.window,
            label: 'Simple',
            icon: Icons.looks_one,
          ),
          const SizedBox(width: 8),
          _windowTypeChoice(
            tool: PlanTool.windowDouble,
            label: 'Double',
            icon: Icons.looks_two,
          ),
        ],
      ),
    );
  }

  Widget _windowTypeChoice({
    required PlanTool tool,
    required String label,
    required IconData icon,
  }) {
    return Tooltip(
      message: 'Insérer : fenêtre $label',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          _insertSymbolAtCenter(tool);
          _hideWindowTypeBundle();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _kToolbarActiveBg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: _kToolbarActiveText),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: _kToolbarActiveText,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Menu "trois points verticaux" avec téléchargement, ajout/
  /// suppression de page et effacement complet du plan.
  Widget _buildMoreMenu() {
    return SizedBox(
      width: 36,
      height: 36,
      child: PopupMenuButton<String>(
        tooltip: 'Plus d\'actions',
        padding: EdgeInsets.zero,
        icon: const Icon(LucideIcons.moreVertical, size: 18),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        onSelected: (v) {
          switch (v) {
            case 'download':
              _downloadPng();
              break;
            case 'addPage':
              widget.onAddPage?.call();
              break;
            case 'duplicatePage':
              widget.onDuplicatePage?.call();
              break;
            case 'deletePage':
              widget.onDeletePage?.call();
              break;
          }
        },
        itemBuilder: (ctx) => [
          const PopupMenuItem(
            value: 'download',
            child: Row(
              children: [
                Icon(LucideIcons.download, size: 16, color: Color(0xFF2B323A)),
                SizedBox(width: 10),
                Text('Télécharger le plan'),
              ],
            ),
          ),
          if (widget.onAddPage != null)
            const PopupMenuItem(
              value: 'addPage',
              child: Row(
                children: [
                  Icon(
                    LucideIcons.filePlus,
                    size: 16,
                    color: Color(0xFF2B323A),
                  ),
                  SizedBox(width: 10),
                  Text('Ajouter une page vierge'),
                ],
              ),
            ),
          if (widget.onDuplicatePage != null)
            const PopupMenuItem(
              value: 'duplicatePage',
              child: Row(
                children: [
                  Icon(LucideIcons.copy, size: 16, color: Color(0xFF2B323A)),
                  SizedBox(width: 10),
                  Text('Dupliquer la page actuelle'),
                ],
              ),
            ),
          if (widget.onDeletePage != null && (widget.totalPages ?? 1) > 1)
            const PopupMenuItem(
              value: 'deletePage',
              child: Row(
                children: [
                  Icon(LucideIcons.fileX, size: 16, color: Color(0xFFB91C1C)),
                  SizedBox(width: 10),
                  Text(
                    'Supprimer la page',
                    style: TextStyle(color: Color(0xFFB91C1C)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Cercle coloré unique affichant la couleur courante. Tap ouvre un
  /// petit popup qui propose les 5 couleurs presets (noir, rouge,
  /// bleu, vert, jaune) — pas de HSL/hex pour éviter la confusion.
  final GlobalKey _colorDotKey = GlobalKey();
  Widget _buildActiveColorDot() {
    final disabled = _tool == PlanTool.eraser;
    return Tooltip(
      message: 'Changer la couleur',
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          key: _colorDotKey,
          onTap: _openColorPresetMenu,
          borderRadius: BorderRadius.circular(999),
          hoverColor: disabled ? Colors.transparent : _kToolbarHoverBg,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(
                  LucideIcons.palette,
                  size: 18,
                  color: disabled ? const Color(0xFFB9C0C7) : _kToolbarIcon,
                ),
                Positioned(
                  top: 3,
                  right: 3,
                  child: Opacity(
                    opacity: disabled ? 0.35 : 1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: Color(_penColor),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.10),
                            blurRadius: 3,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openColorPresetMenu() async {
    if (_tool == PlanTool.eraser) return;
    _hideEraserSizeGauge();
    final ctx = _colorDotKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(
      Offset(0, box.size.height + 6),
      ancestor: overlayBox,
    );
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(topLeft.dx, topLeft.dy, 0, 0),
      Offset.zero & overlayBox.size,
    );
    final picked = await showMenu<int>(
      context: context,
      position: position,
      color: Colors.white,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: [
        PopupMenuItem<int>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _presetColors
                  .map(
                    (c) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).pop(c),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _penColor == c
                                  ? const Color(0xFF0E1116)
                                  : Color(0xFFB9C0C7),
                              width: _penColor == c ? 2.5 : 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ],
    );
    if (picked != null && mounted) {
      setState(() => _penColor = picked);
    }
  }

  /// Bouton icône compact (tooltip inline). [activeColor] permet
  /// d'afficher un accent couleur (ex: corbeille rouge).
  Widget _iconBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    Color? activeColor,
    Color? backgroundColor,
  }) {
    final enabled = onTap != null;
    final enabledColor = activeColor ?? _kToolbarIcon;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          hoverColor: backgroundColor == null
              ? _kToolbarHoverBg
              : Colors.transparent,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: backgroundColor ?? Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: Icon(icon, size: 18, color: enabledColor),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolBtn(PlanTool tool, IconData icon, String label) {
    // Bouton rond (cercle plein quand l'outil est actif), tooltip au
    // survol. Les tailles de tracé sont fixes pour rester cohérentes
    // avec les autres barres d'outils.
    final active = _tool == tool;
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: () => setState(() {
            _tool = tool;
            _showEraserSizeGauge = tool == PlanTool.eraser;
            _showWindowTypeBundle = false;
          }),
          customBorder: const CircleBorder(),
          hoverColor: active ? Colors.transparent : _kToolbarHoverBg,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? _kToolbarActiveBg : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 18,
              color: active ? _kToolbarActiveText : _kToolbarIcon,
            ),
          ),
        ),
      ),
    );
  }

  Widget _eraserToolBtn() {
    return TapRegion(
      groupId: _eraserSizeTapRegion,
      onTapOutside: (_) => _hideEraserSizeGauge(),
      child: _toolBtn(PlanTool.eraser, LucideIcons.eraser, 'Gomme'),
    );
  }

  void _hideEraserSizeGauge() {
    if (!_showEraserSizeGauge || !mounted) return;
    setState(() => _showEraserSizeGauge = false);
  }

  Widget _buildEraserSizePopover() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, 4),
            spreadRadius: -4,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _kEraserSizePresets.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            _eraserSizeDot(
              size: _kEraserSizePresets[i],
              visualDiameter: switch (i) {
                0 => 8.0,
                1 => 12.0,
                _ => 16.0,
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _eraserSizeDot({
    required double size,
    required double visualDiameter,
  }) {
    final selected = (_eraserSize - size).abs() < 0.1;
    return Tooltip(
      message: switch (visualDiameter.round()) {
        8 => 'Gomme fine',
        12 => 'Gomme moyenne',
        _ => 'Gomme large',
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => setState(() => _eraserSize = size),
          child: SizedBox(
            width: 30,
            height: 30,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                width: selected ? visualDiameter + 8 : visualDiameter,
                height: selected ? visualDiameter + 8 : visualDiameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? _kToolbarActiveBg : Colors.transparent,
                  border: selected
                      ? Border.all(color: _kToolbarActiveText, width: 1.5)
                      : null,
                ),
                child: Center(
                  child: Container(
                    width: visualDiameter,
                    height: visualDiameter,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kToolbarActiveText,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Bouton d'insertion instantanée d'un symbole architectural au
  /// centre du canvas. Rond, bordé. Tap = insertion. [iconChild] peut
  /// être un Icon Lucide ou un Text (emoji) quand aucune icône Lucide
  /// ne correspond exactement (ex : 🚽 pour les WC).
  Widget _symbolInsertBtn(PlanTool tool, Widget iconChild, String label) {
    return _symbolButtonShell(
      iconChild: iconChild,
      tooltip: 'Insérer : $label',
      onTap: () => _insertSymbolAtCenter(tool),
    );
  }

  Widget _symbolButtonShell({
    required Widget iconChild,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: _kToolbarHoverBg,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(child: iconChild),
          ),
        ),
      ),
    );
  }

  Widget _buildCanvas() {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    return Container(
      decoration: const BoxDecoration(color: Colors.white),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // Full area incl rulers
          return Stack(
            children: [
              // Grid + ruler overlay (non-interactive)
              Positioned.fill(
                child: CustomPaint(
                  painter: _GridPainter(),
                  child: const SizedBox.expand(),
                ),
              ),
              // Draw area — remplit tout le canvas.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _onCanvasTapUp,
                  onPanStart: _onPanStartRouted,
                  onPanUpdate: _onPanUpdateRouted,
                  onPanEnd: _onPanEndRouted,
                  child: MouseRegion(
                    cursor: _tool == PlanTool.eraser
                        ? SystemMouseCursors.cell
                        : SystemMouseCursors.precise,
                    child: CustomPaint(
                      key: _drawAreaKey,
                      painter: _DrawPainter(
                        strokes: _strokes,
                        currentStroke: _current,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
              // Overlay des poignées + boutons flottants : UNIQUEMENT
              // en mode édition (après un tap explicite sur l'élément).
              // Un simple drag sur un symbole le déplace sans afficher
              // de poignées, pour que le mouvement reste l'action
              // primaire sans gêne visuelle.
              if (_editingMode &&
                  _selectedIndex >= 0 &&
                  _selectedIndex < _strokes.length)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _HandlesPainter(
                        stroke: _strokes[_selectedIndex],
                      ),
                    ),
                  ),
                ),
              if (_editingMode &&
                  _selectedIndex >= 0 &&
                  _selectedIndex < _strokes.length &&
                  _symbolTools.contains(_strokes[_selectedIndex].tool))
                _buildSelectedSymbolActions(),
              // (Bouton "Supprimer la page" FAB retiré : l'option vit
              // maintenant dans le menu "trois points" de la toolbar.)
            ],
          );
        },
      ),
    );
  }

  /// Place une petite barre d'actions (flip H / flip V / supprimer)
  /// au-dessus du coin haut-droit du symbole sélectionné. Suit la
  /// rotation du symbole pour rester "collé" à son coin visuel.
  Widget _buildSelectedSymbolActions() {
    final sel = _strokes[_selectedIndex];
    final bounds = sel.symbolLocalBounds;
    if (bounds == null) return const SizedBox.shrink();
    final center = sel.points.first;
    final localTR = Offset(bounds.right, bounds.top);
    final relative = localTR - center;
    final cos = math.cos(sel.rotation);
    final sin = math.sin(sel.rotation);
    final rotated = Offset(
      relative.dx * cos - relative.dy * sin,
      relative.dx * sin + relative.dy * cos,
    );
    final canvasPoint = center + rotated;
    // Barre horizontale : ~3 boutons de 30px + 2 gaps de 6px = ~106px,
    // on la place centrée au-dessus du coin.
    const barWidth = 108.0;
    final btnLeft = canvasPoint.dx - barWidth + 10;
    final btnTop = canvasPoint.dy - 42;
    return Positioned(
      left: btnLeft,
      top: btnTop,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _floatingAction(
            icon: LucideIcons.moveHorizontal,
            tooltip: 'Inverser gauche / droite',
            color: const Color(0xFF2B323A),
            bg: Colors.white,
            onTap: () {
              _pushUndo();
              setState(() => sel.flipX = !sel.flipX);
              _scheduleSave();
            },
          ),
          const SizedBox(width: 6),
          _floatingAction(
            icon: LucideIcons.moveVertical,
            tooltip: 'Inverser haut / bas',
            color: const Color(0xFF2B323A),
            bg: Colors.white,
            onTap: () {
              _pushUndo();
              setState(() => sel.flipY = !sel.flipY);
              _scheduleSave();
            },
          ),
          const SizedBox(width: 6),
          _floatingAction(
            icon: LucideIcons.trash2,
            tooltip: 'Supprimer',
            color: Colors.white,
            bg: Colors.red.shade600,
            onTap: _deleteSelectedSymbol,
          ),
        ],
      ),
    );
  }

  Widget _floatingAction({
    required IconData icon,
    required String tooltip,
    required Color color,
    required Color bg,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        elevation: 4,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(icon, color: color, size: 16),
          ),
        ),
      ),
    );
  }

  void _deleteSelectedSymbol() {
    if (_selectedIndex < 0 || _selectedIndex >= _strokes.length) return;
    _pushUndo();
    setState(() {
      _strokes.removeAt(_selectedIndex);
      _selectedIndex = -1;
      _activeHandle = null;
    });
    _scheduleSave();
  }

  // ---------------------------------------------------------------------
  // Gestures routing — distingue tracé libre vs manipulation de symbole.
  // ---------------------------------------------------------------------

  /// Tap sur un symbole = entrée en MODE ÉDITION (poignées + boutons
  /// flottants visibles). Tap sur du vide = désélection. Un drag sur
  /// un symbole est géré par _onPanStartRouted et fait un simple
  /// déplacement sans entrer en mode édition.
  void _onCanvasTapUp(TapUpDetails d) {
    final pt = _localPoint(d.globalPosition);
    // Si déjà en mode édition : tester si le tap est sur une poignée
    // (ne rien faire, le pan va gérer) ou dans le body → on garde
    // le mode édition. Tap ailleurs sur le même symbole → idem.
    for (var i = _strokes.length - 1; i >= 0; i--) {
      final s = _strokes[i];
      if (!_symbolTools.contains(s.tool)) continue;
      final bounds = s.symbolLocalBounds;
      if (bounds == null) continue;
      final local = _toSymbolLocal(s, pt);
      if (bounds.contains(local)) {
        setState(() {
          _selectedIndex = i;
          _editingMode = true; // tap → mode édition
        });
        return;
      }
    }
    // Tap ailleurs → désélectionner.
    if (_selectedIndex != -1 || _editingMode) {
      setState(() {
        _selectedIndex = -1;
        _editingMode = false;
      });
    }
  }

  void _onPanStartRouted(DragStartDetails d) {
    final pt = _localPoint(d.globalPosition);
    // Mode édition : les poignées ont priorité (resize / rotation /
    // déplacement depuis le body).
    if (_selectedIndex >= 0 && _editingMode) {
      final sel = _strokes[_selectedIndex];
      final h = _handleAt(sel, pt);
      if (h != null) {
        _pushUndo();
        _activeHandle = h;
        _dragAnchor = pt;
        _dragInitialCenter = sel.points[0];
        _dragInitialCorner = sel.points[1];
        _dragInitialRotation = sel.rotation;
        return;
      }
    }
    // Pas en mode édition : un drag qui commence sur un symbole le
    // déplace directement. Prioriser le symbole du dessus (le dernier
    // placé) si plusieurs se superposent.
    for (var i = _strokes.length - 1; i >= 0; i--) {
      final s = _strokes[i];
      if (!_symbolTools.contains(s.tool)) continue;
      final bounds = s.symbolLocalBounds;
      if (bounds == null) continue;
      final local = _toSymbolLocal(s, pt);
      if (bounds.contains(local)) {
        _pushUndo();
        setState(() {
          _selectedIndex = i;
          _editingMode = false; // drag = simple déplacement, pas d'édition
          _activeHandle = _SymbolHandle.body;
          _dragAnchor = pt;
          _dragInitialCenter = s.points[0];
          _dragInitialCorner = s.points[1];
          _dragInitialRotation = s.rotation;
        });
        return;
      }
    }
    // Aucun symbole sous le doigt → tracé libre (pen / line / rect…).
    _onPanStart(d);
  }

  void _onPanUpdateRouted(DragUpdateDetails d) {
    if (_activeHandle != null) {
      _updateSelectedSymbol(d.globalPosition);
      return;
    }
    _onPanUpdate(d);
  }

  void _onPanEndRouted(DragEndDetails d) {
    if (_activeHandle != null) {
      setState(() {
        _activeHandle = null;
        _dragAnchor = null;
        _dragInitialCenter = null;
        _dragInitialCorner = null;
        _dragInitialRotation = null;
      });
      _scheduleSave();
      return;
    }
    _onPanEnd(d);
  }

  void _updateSelectedSymbol(Offset globalPoint) {
    final handle = _activeHandle;
    if (handle == null || _selectedIndex < 0) return;
    final sel = _strokes[_selectedIndex];
    final pt = _localPoint(globalPoint);
    final initCenter = _dragInitialCenter!;
    final initCorner = _dragInitialCorner!;
    final initRotation = _dragInitialRotation!;
    final anchor = _dragAnchor!;

    switch (handle) {
      case _SymbolHandle.body:
        // Déplacement : delta appliqué au centre ET au corner (pour
        // garder la taille constante).
        final delta = pt - anchor;
        setState(() {
          sel.points[0] = initCenter + delta;
          sel.points[1] = initCorner + delta;
        });
        break;
      case _SymbolHandle.rotate:
        // Nouvel angle = angle entre le centre et le curseur.
        final vec = pt - initCenter;
        // Décaler de 90° car la poignée rotation est au-dessus.
        var newAngle = math.atan2(vec.dy, vec.dx) + math.pi / 2;
        // Snap magnétique sur les multiples de 90° (0°, 90°, 180°, 270°).
        // Seuil 10° : à moins de 10° d'un angle droit, on "colle" dessus
        // pour que les murs/portes/fenêtres s'alignent parfaitement.
        const quarter = math.pi / 2;
        const snapTolerance = math.pi / 18; // 10°
        final nearestQuarter = (newAngle / quarter).round() * quarter;
        if ((newAngle - nearestQuarter).abs() < snapTolerance) {
          newAngle = nearestQuarter;
        }
        setState(() => sel.rotation = newAngle);
        break;
      case _SymbolHandle.topMid:
      case _SymbolHandle.bottomMid:
      case _SymbolHandle.leftMid:
      case _SymbolHandle.rightMid:
      case _SymbolHandle.topLeft:
      case _SymbolHandle.topRight:
      case _SymbolHandle.bottomLeft:
      case _SymbolHandle.bottomRight:
        _resizeSelectedSymbolFromHandle(
          sel: sel,
          handle: handle,
          pointer: pt,
          initCenter: initCenter,
          initCorner: initCorner,
          initRotation: initRotation,
        );
        break;
    }
  }

  void _resizeSelectedSymbolFromHandle({
    required _PlanStroke sel,
    required _SymbolHandle handle,
    required Offset pointer,
    required Offset initCenter,
    required Offset initCorner,
    required double initRotation,
  }) {
    const minSize = 16.0;
    final initHalfW = (initCorner.dx - initCenter.dx).abs().clamp(
      minSize / 2,
      2000.0,
    );
    final initHalfH = (initCorner.dy - initCenter.dy).abs().clamp(
      minSize / 2,
      2000.0,
    );

    // Repère local initial du symbole : les côtés/coins opposés restent
    // fixes dans ce repère, puis le nouveau centre est reconverti dans
    // le canvas. Ça garde l'ancrage visuel correct même si l'objet est
    // tourné.
    final pointerLocal = _rotateVector(pointer - initCenter, -initRotation);

    var left = -initHalfW;
    var right = initHalfW;
    var top = -initHalfH;
    var bottom = initHalfH;

    switch (handle) {
      case _SymbolHandle.leftMid:
        left = math.min(pointerLocal.dx, right - minSize);
        break;
      case _SymbolHandle.rightMid:
        right = math.max(pointerLocal.dx, left + minSize);
        break;
      case _SymbolHandle.topMid:
        top = math.min(pointerLocal.dy, bottom - minSize);
        break;
      case _SymbolHandle.bottomMid:
        bottom = math.max(pointerLocal.dy, top + minSize);
        break;
      case _SymbolHandle.topLeft:
        left = math.min(pointerLocal.dx, right - minSize);
        top = math.min(pointerLocal.dy, bottom - minSize);
        break;
      case _SymbolHandle.topRight:
        right = math.max(pointerLocal.dx, left + minSize);
        top = math.min(pointerLocal.dy, bottom - minSize);
        break;
      case _SymbolHandle.bottomLeft:
        left = math.min(pointerLocal.dx, right - minSize);
        bottom = math.max(pointerLocal.dy, top + minSize);
        break;
      case _SymbolHandle.bottomRight:
        right = math.max(pointerLocal.dx, left + minSize);
        bottom = math.max(pointerLocal.dy, top + minSize);
        break;
      case _SymbolHandle.body:
      case _SymbolHandle.rotate:
        return;
    }

    final localCenter = Offset((left + right) / 2, (top + bottom) / 2);
    final nextCenter = initCenter + _rotateVector(localCenter, initRotation);
    final nextHalfW = ((right - left) / 2).clamp(minSize / 2, 2000.0);
    final nextHalfH = ((bottom - top) / 2).clamp(minSize / 2, 2000.0);

    setState(() {
      sel.points[0] = nextCenter;
      sel.points[1] = nextCenter + Offset(nextHalfW, nextHalfH);
      sel.rotation = initRotation;
    });
  }
}

/// Identifie quelle poignée est active durant un drag (ou le corps).
/// - corners : redimensionnement ancré sur le coin opposé
/// - midpoints (topMid / …) : redimensionnement 1D sur un seul axe
/// - rotate : rotation libre (snap 90°)
/// - body : drag déplacement
enum _SymbolHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  topMid,
  bottomMid,
  leftMid,
  rightMid,
  rotate,
  body,
}

/// Painter overlay qui dessine les 4 poignées de coin + la flèche de
/// rotation autour du symbole sélectionné.
class _HandlesPainter extends CustomPainter {
  _HandlesPainter({required this.stroke});
  final _PlanStroke stroke;

  // Taille visuelle des poignées. Réduite à 8px pour ne pas empiéter
  // sur la zone de drag du symbole — le déplacement est l'action
  // primaire, les poignées restent discrètes mais visibles.
  static const double _handleRadius = 8.0;
  static const double _rotateOffset = 52.0;
  static const Color _accent = Color(0xFF597E8D);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = stroke.symbolLocalBounds;
    if (bounds == null) return;
    final center = stroke.points.first;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(stroke.rotation);
    canvas.translate(-center.dx, -center.dy);

    // Cadre fin en pointillés.
    final frame = Paint()
      ..color = _accent.withValues(alpha: 0.6)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(bounds, frame);

    // Ligne vers la poignée rotation.
    final rotateTop = Offset(bounds.center.dx, bounds.top - _rotateOffset);
    canvas.drawLine(Offset(bounds.center.dx, bounds.top), rotateTop, frame);

    // 4 coins (redimensionnement proportionnel).
    final handleFill = Paint()..color = _accent;
    final handleBorder = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final pt in [
      bounds.topLeft,
      bounds.topRight,
      bounds.bottomLeft,
      bounds.bottomRight,
    ]) {
      canvas.drawCircle(pt, _handleRadius, handleFill);
      canvas.drawCircle(pt, _handleRadius, handleBorder);
    }
    // 4 milieux d'arête (redimensionnement 1D uniquement) : petits
    // rectangles discrets, plus petits que les coins pour marquer la
    // différence d'usage sans empiéter sur le body drag.
    final midHandles = <Offset>[
      Offset(bounds.center.dx, bounds.top), // topMid
      Offset(bounds.center.dx, bounds.bottom), // bottomMid
      Offset(bounds.left, bounds.center.dy), // leftMid
      Offset(bounds.right, bounds.center.dy), // rightMid
    ];
    for (final pt in midHandles) {
      final rect = Rect.fromCenter(center: pt, width: 11, height: 11);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        handleFill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        handleBorder,
      );
    }

    // Poignée rotation : cercle + icône flèche simplifiée.
    canvas.drawCircle(rotateTop, _handleRadius + 2, handleFill);
    canvas.drawCircle(rotateTop, _handleRadius + 2, handleBorder);
    // Mini "↻" en dessinant un arc. Taille alignée sur la poignée élargie.
    final arcPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: rotateTop, radius: 6),
      -math.pi / 2,
      math.pi * 1.5,
      false,
      arcPaint,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HandlesPainter oldDelegate) =>
      oldDelegate.stroke != stroke;
}

// ---------------------------------------------------------------------------
// Grid + ruler painter
// ---------------------------------------------------------------------------

class _GridPainter extends CustomPainter {
  static const double _cellPx = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF8A939D).withValues(alpha: 0.22)
      ..strokeWidth = 1;
    // Lignes verticales
    for (double x = _cellPx; x < size.width; x += _cellPx) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    // Lignes horizontales
    for (double y = _cellPx; y < size.height; y += _cellPx) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Stroke painter
// ---------------------------------------------------------------------------

class _DrawPainter extends CustomPainter {
  final List<_PlanStroke> strokes;
  final _PlanStroke? currentStroke;

  _DrawPainter({required this.strokes, this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    paintStrokes(canvas, strokes, currentStroke);
  }

  /// Peint les traits en 2 couches :
  ///  1. Traits libres + formes de base (pen / highlighter / line / rect
  ///     / wall) dans une couche isolée où la gomme opère (dstOut).
  ///  2. Symboles architecturaux (fenêtre / porte / WC / …) PAR-DESSUS,
  ///     hors de la couche gomme → la gomme ne peut pas les effacer.
  ///     Pour supprimer un symbole, l'utilisateur doit le sélectionner
  ///     et utiliser la corbeille.
  static void paintStrokes(
    Canvas canvas,
    List<_PlanStroke> strokes,
    _PlanStroke? current,
  ) {
    final drawBounds = Rect.fromLTWH(-100000, -100000, 200000, 200000);
    // Couche 1 : traits effaçables.
    canvas.saveLayer(drawBounds, Paint());
    for (final s in strokes) {
      if (_symbolTools.contains(s.tool)) continue;
      _paintOne(canvas, s);
    }
    if (current != null && !_symbolTools.contains(current.tool)) {
      _paintOne(canvas, current);
    }
    canvas.restore();
    // Couche 2 : symboles inviolables, dessinés après la gomme.
    for (final s in strokes) {
      if (!_symbolTools.contains(s.tool)) continue;
      _paintOne(canvas, s);
    }
    if (current != null && _symbolTools.contains(current.tool)) {
      _paintOne(canvas, current);
    }
  }

  static void _paintOne(Canvas canvas, _PlanStroke s) {
    if (s.points.isEmpty) return;

    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.size;

    if (s.tool == PlanTool.eraser) {
      paint.blendMode = BlendMode.dstOut;
      paint.color = Colors.black;
    } else {
      paint.color = Color(s.color);
    }

    switch (s.tool) {
      case PlanTool.pen:
      case PlanTool.eraser:
      case PlanTool.highlighter:
        if (s.points.length == 1) {
          canvas.drawCircle(
            s.points.first,
            s.size / 2,
            paint..style = PaintingStyle.fill,
          );
          return;
        }
        final path = Path()..moveTo(s.points.first.dx, s.points.first.dy);
        for (var i = 1; i < s.points.length; i++) {
          final p0 = s.points[i - 1];
          final p1 = s.points[i];
          final mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
          path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
        }
        path.lineTo(s.points.last.dx, s.points.last.dy);
        canvas.drawPath(path, paint);
        break;
      case PlanTool.line:
        if (s.points.length < 2) return;
        canvas.drawLine(s.points[0], s.points[1], paint);
        break;
      case PlanTool.rect:
        if (s.points.length < 2) return;
        final r = Rect.fromPoints(s.points[0], s.points[1]);
        canvas.drawRect(r, paint);
        break;
      case PlanTool.wall:
        if (s.points.length < 2) return;
        // Mur = ligne épaisse noire entre deux points.
        canvas.drawLine(s.points[0], s.points[1], paint);
        break;
      case PlanTool.window:
      case PlanTool.windowDouble:
      case PlanTool.door:
      case PlanTool.toilet:
      case PlanTool.shower:
      case PlanTool.bath:
      case PlanTool.sink:
        if (s.points.length < 2) return;
        _paintSymbol(canvas, s);
        break;
    }
  }

  // --- Symboles architecturaux ------------------------------------------

  /// Rend un symbole architectural en appliquant la rotation autour du
  /// centre. Chaque dessin est fait dans le repère local où la bounding
  /// box est centrée sur l'origine — lisible et rotation-aware.
  static void _paintSymbol(Canvas canvas, _PlanStroke s) {
    final bounds = s.symbolLocalBounds;
    if (bounds == null) return;
    final center = s.points.first;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(s.rotation);
    // Flip : mirror le repère selon X et/ou Y pour inverser le visuel
    // du symbole (ex : porte qui s'ouvre à droite au lieu de gauche).
    if (s.flipX || s.flipY) {
      canvas.scale(s.flipX ? -1.0 : 1.0, s.flipY ? -1.0 : 1.0);
    }
    // À ce stade, le repère est centré sur le centre du symbole et
    // tourné selon rotation. On dessine relativement à (0,0).
    final w = bounds.width;
    final h = bounds.height;
    final rect = Rect.fromCenter(center: Offset.zero, width: w, height: h);
    final color = Color(s.color);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    switch (s.tool) {
      case PlanTool.window:
        _paintWindowLocal(canvas, rect, stroke);
        break;
      case PlanTool.windowDouble:
        _paintDoubleWindowLocal(canvas, rect, stroke);
        break;
      case PlanTool.door:
        _paintDoorLocal(canvas, rect, stroke);
        break;
      case PlanTool.toilet:
        _paintToiletLocal(canvas, rect, stroke);
        break;
      case PlanTool.shower:
        _paintShowerLocal(canvas, rect, stroke);
        break;
      case PlanTool.bath:
        _paintBathLocal(canvas, rect, stroke);
        break;
      case PlanTool.sink:
        _paintSinkLocal(canvas, rect, stroke);
        break;
      default:
        break;
    }
    canvas.restore();
  }

  /// Fenêtre : simple battant (comme la porte) entouré d'un encadré
  /// matérialisant le dormant. Demande utilisateur 2026-05-04 :
  /// « fenêtre à mettre en simple battant mais pas en double comme la
  /// porte mais avec un encadré ».
  ///
  /// Composition :
  ///   - Mur (ligne bas du bounds) — porte/fenêtre se posent dessus
  ///   - Encadré (rectangle fin) délimitant le dormant de la fenêtre
  ///   - Vantail simple (charnière bas-gauche, battant vertical)
  ///   - Arc d'ouverture 90° vers l'intérieur (dashed)
  static void _paintWindowLocal(Canvas canvas, Rect r, Paint stroke) {
    final side = math.min(r.width, r.height);
    final frame = Rect.fromCenter(center: r.center, width: side, height: side);

    final framePaint = Paint()
      ..color = stroke.color.withValues(alpha: 0.55)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawRect(frame, framePaint);

    // Vantail unique — charnière bas-gauche, battant fermé vertical
    // vers le haut, ouverture CW vers la droite (mêmes conventions
    // que `_paintDoorLocal` pour cohérence visuelle).
    final hinge = frame.bottomLeft;
    final closedEnd = Offset(frame.left, frame.top);
    canvas.drawLine(hinge, closedEnd, stroke);

    final dashed = Paint()
      ..color = stroke.color.withValues(alpha: 0.6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final arcRect = Rect.fromCircle(center: hinge, radius: frame.height);
    // Arc de -90° (vers le haut) à 0° (vers la droite).
    canvas.drawArc(arcRect, -math.pi / 2, math.pi / 2, false, dashed);
  }

  /// Fenêtre double : deux battants symétriques, avec un arc de chaque
  /// côté pour représenter la double ouverture.
  static void _paintDoubleWindowLocal(Canvas canvas, Rect r, Paint stroke) {
    final height = r.height;
    final width = math.max(r.width, height * 1.45);
    final frame = Rect.fromCenter(
      center: r.center,
      width: width,
      height: height,
    );
    final left = Rect.fromLTWH(
      frame.left,
      frame.top,
      frame.width / 2,
      frame.height,
    );
    final right = Rect.fromLTWH(
      frame.center.dx,
      frame.top,
      frame.width / 2,
      frame.height,
    );

    final framePaint = Paint()
      ..color = stroke.color.withValues(alpha: 0.55)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawRect(frame, framePaint);
    canvas.drawLine(
      Offset(frame.center.dx, frame.top),
      Offset(frame.center.dx, frame.bottom),
      framePaint,
    );

    final dashed = Paint()
      ..color = stroke.color.withValues(alpha: 0.6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final leftHinge = left.bottomLeft;
    canvas.drawLine(leftHinge, left.topLeft, stroke);
    canvas.drawArc(
      Rect.fromCircle(center: leftHinge, radius: left.height),
      -math.pi / 2,
      math.pi / 2,
      false,
      dashed,
    );

    final rightHinge = right.bottomRight;
    canvas.drawLine(rightHinge, right.topRight, stroke);
    canvas.drawArc(
      Rect.fromCircle(center: rightHinge, radius: right.height),
      math.pi,
      math.pi / 2,
      false,
      dashed,
    );
  }

  /// Porte : segment fixe du côté gauche + arc 90° indiquant l'ouverture.
  static void _paintDoorLocal(Canvas canvas, Rect r, Paint stroke) {
    // Charnière en bas-gauche, battant fermé va vers le haut-gauche.
    final hinge = r.bottomLeft;
    final closedEnd = Offset(r.left, r.top);
    canvas.drawLine(hinge, closedEnd, stroke);
    final radius = r.height;
    final arcRect = Rect.fromCircle(center: hinge, radius: radius);
    final dashed = Paint()
      ..color = stroke.color.withValues(alpha: 0.6)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    // Arc de -90° (vers le haut) à 0° (vers la droite).
    canvas.drawArc(arcRect, -math.pi / 2, math.pi / 2, false, dashed);
  }

  /// Toilettes : réservoir (rectangle) + cuvette (ovale), alignées sur
  /// l'axe horizontal du bounds (réservoir à gauche, cuvette à droite).
  static void _paintToiletLocal(Canvas canvas, Rect r, Paint stroke) {
    // Cuvette (ovale) — occupe les 2/3 droits du bounds
    final bowl = Rect.fromLTWH(
      r.left + r.width * 0.28,
      r.top + r.height * 0.08,
      r.width * 0.70,
      r.height * 0.84,
    );
    canvas.drawOval(bowl, stroke);
    // Réservoir — 30% gauche
    final tank = Rect.fromLTWH(
      r.left,
      r.top + r.height * 0.20,
      r.width * 0.27,
      r.height * 0.60,
    );
    canvas.drawRect(tank, stroke);
  }

  /// Douche : rectangle + croix en pointillés + bonde centrale.
  static void _paintShowerLocal(Canvas canvas, Rect r, Paint stroke) {
    canvas.drawRect(r, stroke);
    final dashed = Paint()
      ..color = stroke.color.withValues(alpha: 0.6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(r.topLeft, r.bottomRight, dashed);
    canvas.drawLine(r.topRight, r.bottomLeft, dashed);
    canvas.drawCircle(r.center, 3, Paint()..color = stroke.color);
  }

  /// Lavabo : rectangle arrondi englobant (meuble), vasque ovale
  /// centrée légèrement décalée vers l'avant, et 1 point (robinet) au
  /// fond. Axe long = largeur horizontale dans le repère local.
  static void _paintSinkLocal(Canvas canvas, Rect r, Paint stroke) {
    // Meuble / plan de travail = rectangle arrondi.
    final furniture = RRect.fromRectAndRadius(r, const Radius.circular(6));
    canvas.drawRRect(furniture, stroke);
    // Vasque = ovale centré, 70% largeur / 60% hauteur.
    final basin = Rect.fromCenter(
      center: Offset(r.center.dx, r.center.dy + r.height * 0.05),
      width: r.width * 0.72,
      height: r.height * 0.60,
    );
    canvas.drawOval(basin, stroke);
    // Robinet : petit cercle plein en arrière (haut) du meuble.
    final tapCenter = Offset(r.center.dx, r.top + r.height * 0.18);
    canvas.drawCircle(
      tapCenter,
      (r.height * 0.08).clamp(2, 6),
      Paint()..color = stroke.color,
    );
  }

  /// Baignoire : rectangle arrondi + bonde à gauche.
  static void _paintBathLocal(Canvas canvas, Rect r, Paint stroke) {
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(14));
    canvas.drawRRect(rr, stroke);
    final side = r.width < r.height ? r.width : r.height;
    final drainCenter = Offset(
      r.left + r.width * 0.20,
      r.top + r.height * 0.50,
    );
    canvas.drawCircle(drainCenter, side * 0.06, stroke);
  }

  @override
  bool shouldRepaint(_DrawPainter oldDelegate) => true;
}

// Suppress unused import warning (Uint8List reserved for future export needs)
// ignore: unused_element
Uint8List _unusedTypedData() => Uint8List(0);

// ---------------------------------------------------------------------------
// Pictogramme WC — petit dessin vectoriel "vue de dessus" identique au
// symbole tracé sur le canvas (réservoir + cuvette ovale). Utilisé dans
// la palette d'insertion à la place de l'icône lettre `Icons.wc` qui ne
// montrait pas l'élément. Cohérent avec `LucideIcons.bath` pour la
// baignoire : on voit immédiatement de quel équipement il s'agit.
// ---------------------------------------------------------------------------
class ToiletPictogram extends StatelessWidget {
  const ToiletPictogram({
    super.key,
    this.size = 22,
    this.color = const Color(0xFF2B323A),
  });
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Ratio 2:1 (réservoir + cuvette horizontale) — même proportion que
    // le symbole dessiné sur le plan (`_kSymbolDefaultSize.toilet`).
    return SizedBox(
      width: size,
      height: size * 0.62,
      child: CustomPaint(painter: _ToiletIconPainter(color: color)),
    );
  }
}

class _ToiletIconPainter extends CustomPainter {
  _ToiletIconPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final r = Offset.zero & size;
    // Cuvette (ovale) — 2/3 droits.
    final bowl = Rect.fromLTWH(
      r.left + r.width * 0.28,
      r.top + r.height * 0.08,
      r.width * 0.70,
      r.height * 0.84,
    );
    canvas.drawOval(bowl, stroke);
    // Réservoir — 30 % gauche.
    final tank = Rect.fromLTWH(
      r.left,
      r.top + r.height * 0.20,
      r.width * 0.27,
      r.height * 0.60,
    );
    canvas.drawRect(tank, stroke);
  }

  @override
  bool shouldRepaint(_ToiletIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
