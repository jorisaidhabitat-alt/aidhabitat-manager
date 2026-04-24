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
import 'soft_transitions.dart';

// ---------------------------------------------------------------------------
// Grid constants — 1 cell = 20cm in real world, major line every 5 cells
// ---------------------------------------------------------------------------

// Brand color.
const Color _kTeal = Color(0xFF597E8D);

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
        return Offset(
          (pt[0] as num).toDouble(),
          (pt[1] as num).toDouble(),
        );
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

class PlanCanvas extends StatefulWidget {
  final String patientId;
  final String tabKey;

  /// Page number (0-based). Each page stores its own set of strokes.
  final int pageNumber;

  /// Optional pagination info rendered inline dans la toolbar.
  final int? currentPage;
  final int? totalPages;
  final VoidCallback? onPrevPage;
  final VoidCallback? onNextPage;
  final VoidCallback? onAddPage;
  final VoidCallback? onDeletePage;

  const PlanCanvas({
    super.key,
    required this.patientId,
    this.tabKey = 'Plans',
    this.pageNumber = 0,
    this.currentPage,
    this.totalPages,
    this.onPrevPage,
    this.onNextPage,
    this.onAddPage,
    this.onDeletePage,
  });

  @override
  State<PlanCanvas> createState() => _PlanCanvasState();
}

class _PlanCanvasState extends State<PlanCanvas> {
  final _dataService = DataService();
  final GlobalKey _drawAreaKey = GlobalKey();

  PlanTool _tool = PlanTool.pen;
  int _penColor = 0xFF1A1A1A;
  // Épaisseur PAR OUTIL — chaque outil (crayon, surligneur, gomme,
  // ligne, rectangle) mémorise sa propre taille. Modifier l'épaisseur
  // d'un outil n'affecte pas les autres. Les symboles (équipements)
  // utilisent leur propre taille fixée à l'insertion et ne sont pas
  // impactés par ces valeurs.
  final Map<PlanTool, double> _thicknessByTool = {
    PlanTool.pen: 2.0,
    PlanTool.highlighter: 6.0,
    PlanTool.line: 2.0,
    PlanTool.rect: 2.0,
    PlanTool.eraser: 14.0,
  };
  double get _penSize => _thicknessByTool[_tool] ?? 2.0;
  // Si non-null, on affiche en overlay un slider d'épaisseur pour cet
  // outil. Déclenché par un 2e tap sur un outil de tracé déjà actif.
  PlanTool? _thicknessPopoverTool;

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

  @override
  void initState() {
    super.initState();
    _loadStrokes();
  }

  @override
  void didUpdateWidget(covariant PlanCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageNumber != widget.pageNumber ||
        oldWidget.patientId != widget.patientId ||
        oldWidget.tabKey != widget.tabKey) {
      // Flush any pending save for the previous page before we switch.
      _saveTimer?.cancel();
      if (_strokes.isNotEmpty) {
        // Persist synchronously-ish; small best-effort.
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
    _saveTimer?.cancel();
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
        .map((m) => _PlanStroke.fromJson(
            (m as Map).cast<String, dynamic>()))
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

  Future<void> _loadStrokes() async {
    final json = await _dataService.fetchNoteDrawingJson(
      patientId: widget.patientId,
      tabKey: widget.tabKey,
      pageNumber: widget.pageNumber,
    );
    if (!mounted) return;
    if (json == null || json.isEmpty) {
      setState(() => _loaded = true);
      return;
    }
    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      if (decoded['format'] == 'plan_canvas_v1') {
        final strokes = (decoded['strokes'] as List?) ?? const [];
        _strokes
          ..clear()
          ..addAll(strokes
              .whereType<Map>()
              .map((m) => _PlanStroke.fromJson(m.cast<String, dynamic>()))
              .whereType<_PlanStroke>());
      }
    } catch (_) {
      // Either legacy scribble data or corrupt — start fresh
    }
    if (!mounted) return;
    setState(() => _loaded = true);
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
    await _dataService.saveNoteDrawingJson(
      patientId: patientId,
      tabKey: tabKey,
      pageNumber: pageNumber,
      drawingJson: payload,
    );
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _persist);
  }

  Future<void> _persist() async {
    await _persistForKey(widget.patientId, widget.tabKey, widget.pageNumber);
  }

  // ----- Gesture handlers -----

  Offset _localPoint(Offset global) {
    final box =
        _drawAreaKey.currentContext?.findRenderObject() as RenderBox?;
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
    final confirmed = await showSoftDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Effacer le plan ?'),
        content: const Text(
            'Toutes les annotations seront supprimées définitivement.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Effacer'),
          ),
        ],
      ),
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
    final box =
        _drawAreaKey.currentContext?.findRenderObject() as RenderBox?;
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
    final img = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
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
    // Fenêtre : deux vantaux côte à côte, chaque vantail plus petit
    // qu'une porte (largeur totale > porte, mais vantail = ~50 px
    // contre 80 px pour une porte).
    PlanTool.window: Size(100, 45),
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
    final box =
        _drawAreaKey.currentContext?.findRenderObject() as RenderBox?;
    final canvasSize = box?.size ?? const Size(800, 600);
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final defaultSize = _defaultSymbolSize[tool] ?? const Size(100, 100);
    final corner = Offset(defaultSize.width / 2, defaultSize.height / 2);
    final stroke = _PlanStroke(
      tool: tool,
      color: 0xFF0F172A,
      size: 2,
      points: [center, center + corner],
      rotation: 0,
    );
    _pushUndo();
    setState(() {
      _strokes.add(stroke);
      _selectedIndex = _strokes.length - 1;
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
    final rotateLocal =
        Offset(bounds.center.dx, bounds.top - rotateOffset);
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
    // On empile en Stack pour que le popover d'épaisseur soit un
    // OVERLAY flottant au-dessus du canvas — sans shifter la mise
    // en page (demande utilisateur : ne pas faire bouger le plan
    // quand on règle l'épaisseur).
    return Column(
      children: [
        _buildTopToolbar(),
        _buildSymbolsRow(),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _buildCanvas()),
              if (_thicknessPopoverTool != null)
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: TapRegion(
                      // Ferme le popover dès qu'on tape ailleurs
                      // (canvas, autre outil, n'importe quelle zone
                      // hors de cette bulle).
                      onTapOutside: (_) {
                        if (_thicknessPopoverTool != null) {
                          setState(() => _thicknessPopoverTool = null);
                        }
                      },
                      child: _buildThicknessPopover(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Toolbar principale (1ère ligne). Ordre :
  ///   [Crayon][Surligneur][Gomme][Ligne][Rect]  [Couleur]
  ///   [Undo][Redo][Effacer tout]  …  [Pagination]  [⋮]
  /// Les boutons sont plus grands et plus espacés qu'avant pour un
  /// toucher plus confortable sur iPad.
  Widget _buildTopToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Row(
        children: [
          _toolBtn(PlanTool.pen, LucideIcons.pencil, 'Crayon'),
          const SizedBox(width: 10),
          _toolBtn(PlanTool.highlighter, LucideIcons.highlighter,
              'Surligneur'),
          const SizedBox(width: 10),
          // Gomme placée juste à côté du surligneur (demande utilisateur)
          _toolBtn(PlanTool.eraser, LucideIcons.eraser, 'Gomme'),
          const SizedBox(width: 10),
          _toolBtn(PlanTool.line, LucideIcons.minus, 'Ligne'),
          const SizedBox(width: 10),
          _toolBtn(PlanTool.rect, LucideIcons.square, 'Rectangle'),
          const SizedBox(width: 14),
          _buildActiveColorDot(),
          const SizedBox(width: 14),
          _iconBtn(
            icon: LucideIcons.undo2,
            tooltip: 'Annuler',
            onTap: _undoStack.isEmpty ? null : _undo,
          ),
          const SizedBox(width: 4),
          _iconBtn(
            icon: LucideIcons.redo2,
            tooltip: 'Rétablir',
            onTap: _redoStack.isEmpty ? null : _redo,
          ),
          const SizedBox(width: 4),
          _iconBtn(
            icon: LucideIcons.trash2,
            tooltip: 'Effacer tout le plan',
            onTap: _clearAll,
            activeColor: Colors.red.shade400,
          ),
          const Spacer(),
          // Pagination d'abord (chevrons + "1/3")…
          if (widget.currentPage != null && widget.totalPages != null) ...[
            _iconBtn(
              icon: LucideIcons.chevronLeft,
              tooltip: 'Page précédente',
              onTap: (widget.currentPage! > 0) ? widget.onPrevPage : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '${widget.currentPage! + 1}/${widget.totalPages}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF334155),
                ),
              ),
            ),
            _iconBtn(
              icon: LucideIcons.chevronRight,
              tooltip: 'Page suivante',
              onTap: (widget.currentPage! < widget.totalPages! - 1)
                  ? widget.onNextPage
                  : null,
            ),
            const SizedBox(width: 6),
          ],
          // … puis 3 points tout au bout à droite.
          _buildMoreMenu(),
        ],
      ),
    );
  }

  /// 2ème ligne d'outils : symboles architecturaux, alignés à gauche
  /// sous les outils de tracé.
  Widget _buildSymbolsRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      color: Colors.white,
      child: Row(
        children: [
          // Fenêtre : icône "columns" = panneaux verticaux, évoque bien
          // une fenêtre à montants.
          _symbolInsertBtn(
            PlanTool.window,
            Icon(LucideIcons.columns,
                size: 22, color: Colors.grey.shade700),
            'Fenêtre',
          ),
          const SizedBox(width: 8),
          _symbolInsertBtn(
            PlanTool.door,
            Icon(LucideIcons.doorClosed,
                size: 22, color: Colors.grey.shade700),
            'Porte',
          ),
          const SizedBox(width: 8),
          // WC : Material Icons fournit un pictogramme "WC"
          // sémantique (restroom) — remplace l'emoji par un vrai
          // glyphe vectoriel cohérent avec les autres icônes.
          _symbolInsertBtn(
            PlanTool.toilet,
            Icon(Icons.wc, size: 22, color: Colors.grey.shade700),
            'WC',
          ),
          const SizedBox(width: 8),
          _symbolInsertBtn(
            PlanTool.shower,
            Icon(LucideIcons.showerHead,
                size: 22, color: Colors.grey.shade700),
            'Douche',
          ),
          const SizedBox(width: 8),
          _symbolInsertBtn(
            PlanTool.bath,
            Icon(LucideIcons.bath,
                size: 22, color: Colors.grey.shade700),
            'Baignoire',
          ),
          const SizedBox(width: 8),
          // Lavabo : simples gouttes d'eau (demande utilisateur).
          _symbolInsertBtn(
            PlanTool.sink,
            Icon(LucideIcons.droplets,
                size: 22, color: Colors.grey.shade700),
            'Lavabo',
          ),
        ],
      ),
    );
  }

  /// Popover d'épaisseur flottant au-dessus du canvas : petit fond
  /// blanc arrondi avec ombre, NE shifte PAS la mise en page (ouvert
  /// en overlay via un Stack dans build()). Aperçu = trait qui
  /// grossit progressivement dans la couleur courante, glisser dessus
  /// ajuste l'épaisseur entre 1 et 24 px.
  Widget _buildThicknessPopover() {
    const minThickness = 1.0;
    const maxThickness = 24.0;
    const sliderWidth = 220.0;
    // On lit la taille de l'outil ciblé par le popover (et pas _tool /
    // _penSize), pour que le slider reste cohérent même si l'outil
    // actif venait à changer juste avant l'ouverture.
    final target = _thicknessPopoverTool ?? _tool;
    final size = _thicknessByTool[target] ?? 2.0;
    final pos = ((size - minThickness) / (maxThickness - minThickness))
        .clamp(0.0, 1.0);
    return Material(
      elevation: 6,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _updateThicknessFromOffset(
              d.localPosition.dx, sliderWidth, minThickness, maxThickness),
          onPanUpdate: (d) => _updateThicknessFromOffset(
              d.localPosition.dx, sliderWidth, minThickness, maxThickness),
          child: SizedBox(
            width: sliderWidth,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: const Size(sliderWidth, 36),
                  painter: _ThicknessTrackPainter(
                    color: Color(_penColor),
                    min: minThickness,
                    max: maxThickness,
                  ),
                ),
                Positioned(
                  left: (sliderWidth * pos) - 10,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Color(_penColor),
                        width: 2.5,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 2,
                          offset: Offset(0, 1),
                        ),
                      ],
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

  void _updateThicknessFromOffset(
    double dx,
    double width,
    double minT,
    double maxT,
  ) {
    final t = (dx / width).clamp(0.0, 1.0);
    final target = _thicknessPopoverTool ?? _tool;
    setState(() {
      _thicknessByTool[target] = minT + (maxT - minT) * t;
    });
  }

  /// Menu "trois points verticaux" avec téléchargement, ajout/
  /// suppression de page et effacement complet du plan.
  Widget _buildMoreMenu() {
    return PopupMenuButton<String>(
      tooltip: 'Plus d\'actions',
      icon: const Icon(LucideIcons.moreVertical, size: 18),
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      onSelected: (v) {
        switch (v) {
          case 'download':
            _downloadPng();
            break;
          case 'addPage':
            widget.onAddPage?.call();
            break;
          case 'deletePage':
            widget.onDeletePage?.call();
            break;
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem(
          value: 'download',
          child: Row(children: [
            Icon(LucideIcons.download, size: 16, color: Color(0xFF334155)),
            SizedBox(width: 10),
            Text('Télécharger le plan'),
          ]),
        ),
        if (widget.onAddPage != null)
          const PopupMenuItem(
            value: 'addPage',
            child: Row(children: [
              Icon(LucideIcons.plus, size: 16, color: Color(0xFF334155)),
              SizedBox(width: 10),
              Text('Ajouter une page'),
            ]),
          ),
        if (widget.onDeletePage != null &&
            (widget.totalPages ?? 1) > 1)
          const PopupMenuItem(
            value: 'deletePage',
            child: Row(children: [
              Icon(LucideIcons.fileX, size: 16, color: Color(0xFFB91C1C)),
              SizedBox(width: 10),
              Text('Supprimer la page',
                  style: TextStyle(color: Color(0xFFB91C1C))),
            ]),
          ),
      ],
    );
  }

  /// Cercle coloré unique affichant la couleur courante. Tap ouvre un
  /// petit popup qui propose les 5 couleurs presets (noir, rouge,
  /// bleu, vert, jaune) — pas de HSL/hex pour éviter la confusion.
  final GlobalKey _colorDotKey = GlobalKey();
  Widget _buildActiveColorDot() {
    return Tooltip(
      message: 'Changer la couleur',
      child: GestureDetector(
        key: _colorDotKey,
        onTap: _openColorPresetMenu,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Color(_penColor),
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.grey.shade300,
              width: 2,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openColorPresetMenu() async {
    final ctx = _colorDotKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft =
        box.localToGlobal(Offset(0, box.size.height + 6), ancestor: overlayBox);
    final position = RelativeRect.fromRect(
      Rect.fromLTWH(topLeft.dx, topLeft.dy, 0, 0),
      Offset.zero & overlayBox.size,
    );
    final picked = await showMenu<int>(
      context: context,
      position: position,
      color: Colors.white,
      elevation: 6,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: [
        PopupMenuItem<int>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: _presetColors
                  .map((c) => Padding(
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
                                    ? const Color(0xFF0F172A)
                                    : Colors.grey.shade300,
                                width: _penColor == c ? 2.5 : 1.5,
                              ),
                            ),
                          ),
                        ),
                      ))
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
  }) {
    final enabled = onTap != null;
    final enabledColor = activeColor ?? Colors.grey.shade700;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(
            icon,
            size: 20,
            color: enabled ? enabledColor : Colors.grey.shade300,
          ),
        ),
      ),
    );
  }

  // (Ancien pill d'épaisseur [− | N | +] retiré — remplacé par le
  // popover flottant activé au 2e tap sur un outil de tracé.)

  // Menu "Insérer un élément" — ouvre un overlay custom en grille 3
  // colonnes au lieu du PopupMenu linéaire natif.
  final GlobalKey _insertMenuKey = GlobalKey();

  Widget _buildInsertSymbolMenu() {
    // Bouton compact — largeur ajustée au contenu (IntrinsicWidth) pour
    // ne pas monopoliser la ligne dans le Wrap de la toolbar. Reste
    // reconnaissable (fond teal + chevron) mais tient au même niveau
    // que les autres outils (gomme, crayon, rectangle…).
    return IntrinsicWidth(
      child: GestureDetector(
        key: _insertMenuKey,
        onTap: _openInsertSymbolOverlay,
        child: Tooltip(
          message: 'Insérer un élément',
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _kTeal,
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.plus, size: 14, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  'Insérer',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(width: 2),
                Icon(LucideIcons.chevronDown, size: 12, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openInsertSymbolOverlay() async {
    final ctx = _insertMenuKey.currentContext;
    if (ctx == null) return;
    final RenderBox button = ctx.findRenderObject() as RenderBox;
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          Offset(0, button.size.height + 6),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + const Offset(0, 6),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final tool = await showMenu<PlanTool>(
      context: context,
      position: position,
      color: Colors.white,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      items: [
        PopupMenuItem<PlanTool>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: _SymbolGridMenu(
            onPick: (t) => Navigator.of(context).pop(t),
          ),
        ),
      ],
    );
    if (tool != null) _insertSymbolAtCenter(tool);
  }

  Widget _sizeStepButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 14,
            color: enabled
                ? const Color(0xFF334155)
                : const Color(0xFFCBD5E1),
          ),
        ),
      ),
    );
  }

  Widget _toolBtn(PlanTool tool, IconData icon, String label) {
    // Bouton rond (cercle plein quand l'outil est actif), tooltip au
    // survol. Un 2e tap sur un outil crayon / surligneur déjà actif
    // ouvre un slider d'épaisseur sous la toolbar (voir _thicknessPopover).
    final active = _tool == tool;
    // Tous les outils de tracé ont maintenant leur propre épaisseur
    // réglable via 2e tap (popover slider) — chaque valeur est
    // mémorisée indépendamment dans `_thicknessByTool`.
    final supportsThickness =
        tool == PlanTool.pen ||
            tool == PlanTool.highlighter ||
            tool == PlanTool.line ||
            tool == PlanTool.rect ||
            tool == PlanTool.eraser;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: () {
          if (active && supportsThickness) {
            setState(() {
              _thicknessPopoverTool =
                  _thicknessPopoverTool == tool ? null : tool;
            });
            return;
          }
          setState(() {
            _tool = tool;
            _thicknessPopoverTool = null;
          });
        },
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? _kTeal : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 22,
            color: active ? Colors.white : Colors.grey.shade600,
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
    return Tooltip(
      message: 'Insérer : $label',
      child: InkWell(
        onTap: () => _insertSymbolAtCenter(tool),
        customBorder: const CircleBorder(),
        child: Container(
          width: 46,
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFFE2E8F0),
              width: 1,
            ),
          ),
          child: iconChild,
        ),
      ),
    );
  }

  Widget _colorDot(int color) {
    final active = _penColor == color;
    return GestureDetector(
      onTap: () => setState(() => _penColor = color),
      child: Container(
        width: 22,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: Color(color),
          shape: BoxShape.circle,
          border: active
              ? Border.all(color: Colors.grey.shade900, width: 2)
              : null,
        ),
      ),
    );
  }

  /// Bouton "autre couleur" qui ouvre un sélecteur de couleur libre
  /// (parité avec `<input type="color">` de la version React).
  Widget _customColorDot() {
    final isCustom = !_presetColors.contains(_penColor);
    return Tooltip(
      message: 'Autre couleur',
      child: GestureDetector(
        onTap: _pickCustomColor,
        child: Container(
          width: 22,
          height: 22,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: isCustom ? Color(_penColor) : Colors.white,
            shape: BoxShape.circle,
            gradient: isCustom
                ? null
                : const SweepGradient(
                    colors: [
                      Color(0xFFE53E3E),
                      Color(0xFFD69E2E),
                      Color(0xFF2F855A),
                      Color(0xFF2B6CB0),
                      Color(0xFF805AD5),
                      Color(0xFFE53E3E),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickCustomColor() async {
    final picked = await showSoftDialog<int>(
      context: context,
      builder: (ctx) => _ColorPickerDialog(initial: _penColor),
    );
    if (picked != null) {
      setState(() => _penColor = picked);
    }
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 20,
      color: Colors.grey.shade200,
      margin: const EdgeInsets.symmetric(horizontal: 4),
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

  Widget _buildDeletePageFab() {
    return Tooltip(
      message: 'Supprimer la page',
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onDeletePage,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFFFCA5A5),
                width: 1,
              ),
            ),
            child: const Icon(
              LucideIcons.fileX,
              size: 20,
              color: Color(0xFFB91C1C),
            ),
          ),
        ),
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
            color: const Color(0xFF334155),
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
            color: const Color(0xFF334155),
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
        // Redimensionnement 1D : on ne touche qu'une seule dimension
        // (largeur OU hauteur), la rotation est préservée. Utilisé
        // pour étirer le symbole sans altérer ses proportions sur
        // l'autre axe (ex : allonger une baignoire sans grossir sa
        // profondeur).
        final local = _toSymbolLocal(sel, pt);
        final initHalfW =
            (initCorner.dx - initCenter.dx).abs().clamp(8.0, 2000.0);
        final initHalfH =
            (initCorner.dy - initCenter.dy).abs().clamp(8.0, 2000.0);
        final sx = (initCorner.dx - initCenter.dx) >= 0 ? 1 : -1;
        final sy = (initCorner.dy - initCenter.dy) >= 0 ? 1 : -1;
        double newHalfW = initHalfW;
        double newHalfH = initHalfH;
        if (handle == _SymbolHandle.leftMid ||
            handle == _SymbolHandle.rightMid) {
          newHalfW = (local.dx - initCenter.dx).abs().clamp(8.0, 2000.0);
        } else {
          newHalfH = (local.dy - initCenter.dy).abs().clamp(8.0, 2000.0);
        }
        setState(() {
          sel.points[1] = Offset(
            initCenter.dx + newHalfW * sx,
            initCenter.dy + newHalfH * sy,
          );
          sel.rotation = initRotation;
        });
        break;
      default:
        // Redimensionnement PROPORTIONNEL depuis un coin — on calcule
        // un facteur d'échelle basé sur la distance du curseur au
        // centre (en coordonnées locales non-tournées), et on applique
        // ce même facteur à largeur ET hauteur pour préserver le ratio.
        final local = _toSymbolLocal(sel, pt);
        final initHalfW =
            (initCorner.dx - initCenter.dx).abs().clamp(8.0, 2000.0);
        final initHalfH =
            (initCorner.dy - initCenter.dy).abs().clamp(8.0, 2000.0);
        final initDiag = math.sqrt(initHalfW * initHalfW + initHalfH * initHalfH);
        final curDiag = (local - initCenter).distance;
        final scale = (curDiag / initDiag).clamp(0.15, 10.0);
        final newHalfW = (initHalfW * scale).clamp(8.0, 2000.0);
        final newHalfH = (initHalfH * scale).clamp(8.0, 2000.0);
        setState(() {
          final sx = (initCorner.dx - initCenter.dx) >= 0 ? 1 : -1;
          final sy = (initCorner.dy - initCenter.dy) >= 0 ? 1 : -1;
          sel.points[1] = Offset(
            initCenter.dx + newHalfW * sx,
            initCenter.dy + newHalfH * sy,
          );
          // Rotation préservée pendant le resize proportionnel.
          sel.rotation = initRotation;
        });
    }
  }
}

/// Identifie quelle poignée est active durant un drag (ou le corps).
/// - corners : redimensionnement PROPORTIONNEL
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

/// Grille 3 colonnes affichée dans un PopupMenuItem unique pour le menu
/// "Insérer un élément".
class _SymbolGridMenu extends StatelessWidget {
  const _SymbolGridMenu({required this.onPick});
  final ValueChanged<PlanTool> onPick;

  static const List<({PlanTool tool, IconData icon, String label})> _items = [
    (tool: PlanTool.window, icon: LucideIcons.appWindow, label: 'Fenêtre'),
    (tool: PlanTool.door, icon: LucideIcons.doorOpen, label: 'Porte'),
    (tool: PlanTool.toilet, icon: LucideIcons.armchair, label: 'WC'),
    (tool: PlanTool.shower, icon: LucideIcons.droplets, label: 'Douche'),
    (tool: PlanTool.bath, icon: LucideIcons.bath, label: 'Baignoire'),
    (tool: PlanTool.sink, icon: LucideIcons.hand, label: 'Lavabo'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: _items.map((item) {
            return SizedBox(
              width: (280 - 16 - 12) / 3, // 3 colonnes
              height: 72,
              child: InkWell(
                onTap: () => onPick(item.tool),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(item.icon,
                          size: 22, color: const Color(0xFF334155)),
                      const SizedBox(height: 6),
                      Text(
                        item.label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
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
    canvas.drawLine(
      Offset(bounds.center.dx, bounds.top),
      rotateTop,
      frame,
    );

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
      final rect = Rect.fromCenter(
        center: pt,
        width: 11,
        height: 11,
      );
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

/// Quadrillage simple (parité React) — pas de règles, pas d'échelle.
/// Peint un trait qui grossit progressivement de gauche à droite,
/// utilisé comme aperçu visuel dans le slider d'épaisseur.
class _ThicknessTrackPainter extends CustomPainter {
  _ThicknessTrackPainter({
    required this.color,
    required this.min,
    required this.max,
  });
  final Color color;
  final double min;
  final double max;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    final centerY = size.height / 2;
    // On dessine une forme rectangulaire où la hauteur varie linéairement
    // de `min` à `max` de gauche à droite.
    path.moveTo(0, centerY - min / 2);
    path.lineTo(size.width, centerY - max / 2);
    path.lineTo(size.width, centerY + max / 2);
    path.lineTo(0, centerY + min / 2);
    path.close();
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ThicknessTrackPainter old) =>
      old.color != color || old.min != min || old.max != max;
}

class _GridPainter extends CustomPainter {
  static const double _cellPx = 24;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF94A3B8).withValues(alpha: 0.22)
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
    final drawBounds = Rect.fromLTWH(
      -100000,
      -100000,
      200000,
      200000,
    );
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
          canvas.drawCircle(s.points.first, s.size / 2,
              paint..style = PaintingStyle.fill);
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
    final rect = Rect.fromCenter(
        center: Offset.zero, width: w, height: h);
    final color = Color(s.color);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;
    switch (s.tool) {
      case PlanTool.window:
        _paintWindowLocal(canvas, rect, stroke);
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

  /// Fenêtre : deux vantaux côte à côte (comme deux petites portes)
  /// avec leurs arcs d'ouverture vers l'intérieur. Le mur est
  /// représenté par la ligne bas. Flip H/V inversent les charnières
  /// et le sens d'ouverture (porte gauche/droite, ouverture
  /// intérieure/extérieure) — utile pour signifier une fenêtre
  /// entrebâillée ou fermée.
  static void _paintWindowLocal(Canvas canvas, Rect r, Paint stroke) {
    // Mur en bas (épaisseur visuelle).
    canvas.drawLine(r.bottomLeft, r.bottomRight, stroke);
    final dashed = Paint()
      ..color = stroke.color.withValues(alpha: 0.6)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final midX = r.center.dx;
    // Rayon des arcs = hauteur du vantail = hauteur de la fenêtre.
    final radius = r.height;

    // --- Vantail gauche : charnière bas-gauche, battant fermé
    //     vertical vers le haut, ouverture CW vers le centre. ---
    final leftHinge = r.bottomLeft;
    canvas.drawLine(leftHinge, Offset(r.left, r.top), stroke);
    canvas.drawArc(
      Rect.fromCircle(center: leftHinge, radius: radius),
      -math.pi / 2, // pointe vers le haut
      math.pi / 2,  // 90° CW → vers la droite
      false,
      dashed,
    );
    // Petit battant ouvert symbolique (ligne du haut vers centre-haut).
    canvas.drawLine(
      Offset(r.left, r.top),
      Offset(midX, r.top),
      dashed,
    );

    // --- Vantail droit : charnière bas-droit, battant fermé
    //     vertical vers le haut, ouverture CCW vers le centre. ---
    final rightHinge = r.bottomRight;
    canvas.drawLine(rightHinge, Offset(r.right, r.top), stroke);
    canvas.drawArc(
      Rect.fromCircle(center: rightHinge, radius: radius),
      -math.pi / 2,  // pointe vers le haut
      -math.pi / 2,  // 90° CCW → vers la gauche
      false,
      dashed,
    );
    canvas.drawLine(
      Offset(r.right, r.top),
      Offset(midX, r.top),
      dashed,
    );

    // Montant central (séparation des deux vantaux) — fin trait gris.
    final center = Paint()
      ..color = stroke.color.withValues(alpha: 0.4)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(midX, r.top),
      Offset(midX, r.bottom),
      center,
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
    canvas.drawCircle(
      r.center,
      3,
      Paint()..color = stroke.color,
    );
  }

  /// Lavabo : rectangle arrondi englobant (meuble), vasque ovale
  /// centrée légèrement décalée vers l'avant, et 1 point (robinet) au
  /// fond. Axe long = largeur horizontale dans le repère local.
  static void _paintSinkLocal(Canvas canvas, Rect r, Paint stroke) {
    // Meuble / plan de travail = rectangle arrondi.
    final furniture =
        RRect.fromRectAndRadius(r, const Radius.circular(6));
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
  bool shouldRepaint(_DrawPainter oldDelegate) =>
      oldDelegate.strokes.length != strokes.length ||
      oldDelegate.currentStroke != currentStroke;
}

// Suppress unused import warning (Uint8List reserved for future export needs)
// ignore: unused_element
Uint8List _unusedTypedData() => Uint8List(0);

// ---------------------------------------------------------------------------
// Custom color picker dialog — parité avec React `<input type="color">`
// ---------------------------------------------------------------------------

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.initial});
  final int initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late double _hue;
  late double _saturation;
  late double _value;

  @override
  void initState() {
    super.initState();
    final hsv = HSVColor.fromColor(Color(widget.initial));
    _hue = hsv.hue;
    _saturation = hsv.saturation;
    _value = hsv.value;
  }

  Color get _color => HSVColor.fromAHSV(1, _hue, _saturation, _value).toColor();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choisir une couleur'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Aperçu
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: _color,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 16),
            // Teinte
            Row(
              children: [
                const SizedBox(width: 60, child: Text('Teinte')),
                Expanded(
                  child: Slider(
                    value: _hue,
                    min: 0,
                    max: 360,
                    onChanged: (v) => setState(() => _hue = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 60, child: Text('Saturation')),
                Expanded(
                  child: Slider(
                    value: _saturation,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setState(() => _saturation = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 60, child: Text('Luminosité')),
                Expanded(
                  child: Slider(
                    value: _value,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setState(() => _value = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '#${_color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _color.toARGB32()),
          child: const Text('Valider'),
        ),
      ],
    );
  }
}
