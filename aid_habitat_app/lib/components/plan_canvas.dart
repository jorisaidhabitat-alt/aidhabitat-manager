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

  _PlanStroke({
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
    this.rotation = 0,
  });

  Map<String, dynamic> toJson() => {
        'tool': tool.name,
        'color': color,
        'size': size,
        'points': points.map((p) => [p.dx, p.dy]).toList(),
        if (rotation != 0) 'rotation': rotation,
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
      return _PlanStroke(
        tool: tool,
        color: color,
        size: size,
        points: points,
        rotation: rotation,
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
  double _penSize = 2;

  // Sélection d'un symbole architectural placé — -1 = rien de sélectionné.
  int _selectedIndex = -1;
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
      });
      _loadStrokes();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
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
        sizeForStroke = 24;
        break;
      case PlanTool.highlighter:
        // 35% d'opacité → effet fluo par-dessus le contenu existant.
        colorForStroke = (_penColor & 0x00FFFFFF) | 0x59000000;
        sizeForStroke = _penSize * 4;
        break;
      case PlanTool.wall:
        // Mur : épaisseur multipliée, noir plein.
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
    setState(() {
      _strokes.add(cur);
      _current = null;
    });
    _scheduleSave();
  }

  // ----- Actions -----

  void _clearAll() async {
    final confirmed = await showDialog<bool>(
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
    PlanTool.window: Size(120, 8),
    PlanTool.door: Size(80, 80),
    PlanTool.toilet: Size(60, 100),
    PlanTool.shower: Size(90, 90),
    PlanTool.bath: Size(170, 75),
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
    const hitRadius = 14.0;
    if ((local - bounds.topLeft).distance < hitRadius) {
      return _SymbolHandle.topLeft;
    }
    if ((local - bounds.topRight).distance < hitRadius) {
      return _SymbolHandle.topRight;
    }
    if ((local - bounds.bottomLeft).distance < hitRadius) {
      return _SymbolHandle.bottomLeft;
    }
    if ((local - bounds.bottomRight).distance < hitRadius) {
      return _SymbolHandle.bottomRight;
    }
    // Flèche de rotation au-dessus du bord haut, à `rotateOffset` px.
    const rotateOffset = 34.0;
    final rotateLocal =
        Offset(bounds.center.dx, bounds.top - rotateOffset);
    if ((local - rotateLocal).distance < hitRadius) {
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
    return Column(
      children: [
        _buildToolbar(),
        const SizedBox(height: 0),
        Expanded(child: _buildCanvas()),
      ],
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Outils de tracé.
          _toolBtn(PlanTool.pen, LucideIcons.penTool, 'Crayon'),
          _toolBtn(PlanTool.highlighter, LucideIcons.highlighter, 'Surligneur'),
          _toolBtn(PlanTool.line, LucideIcons.minus, 'Ligne'),
          _toolBtn(PlanTool.rect, LucideIcons.square, 'Rectangle'),
          _toolBtn(PlanTool.wall, LucideIcons.rectangleHorizontal, 'Mur'),
          _toolBtn(PlanTool.eraser, LucideIcons.eraser, 'Gomme'),
          _divider(),
          // Menu déroulant "Insérer un élément" — symboles architecturaux
          // (fenêtre, porte, WC, douche, baignoire). Au choix, l'élément
          // apparaît au centre du canvas avec poignées de taille + rotation.
          _buildInsertSymbolMenu(),
          _divider(),
          // Palette de couleurs.
          ..._presetColors.map((c) => _colorDot(c)),
          _divider(),
          // Épaisseur : pill indissociable [− | N | +]. Le Container
          // empêche le Wrap de séparer ces 3 éléments sur deux lignes.
          _buildThicknessPill(),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(LucideIcons.download, size: 18),
            color: Colors.grey.shade600,
            tooltip: 'Télécharger le plan',
            onPressed: _downloadPng,
          ),
          // "Effacer tout" (corbeille pleine = tout jeter).
          IconButton(
            icon: const Icon(LucideIcons.trash2, size: 18),
            color: Colors.red.shade400,
            tooltip: 'Effacer tout',
            onPressed: _clearAll,
          ),
          // Pagination inline (si fournie par le parent).
          if (widget.currentPage != null && widget.totalPages != null) ...[
            _divider(),
            IconButton(
              icon: const Icon(LucideIcons.chevronLeft, size: 18),
              color: Colors.grey.shade600,
              tooltip: 'Page précédente',
              onPressed: (widget.currentPage! > 0) ? widget.onPrevPage : null,
            ),
            Text(
              '${widget.currentPage! + 1}/${widget.totalPages}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF334155),
              ),
            ),
            IconButton(
              icon: const Icon(LucideIcons.chevronRight, size: 18),
              color: Colors.grey.shade600,
              tooltip: 'Page suivante',
              onPressed: (widget.currentPage! < widget.totalPages! - 1)
                  ? widget.onNextPage
                  : null,
            ),
            IconButton(
              icon: const Icon(LucideIcons.plus, size: 18),
              color: Colors.grey.shade600,
              tooltip: 'Ajouter une page',
              onPressed: widget.onAddPage,
            ),
            // "Supprimer la page" : icône fichier barré pour différencier
            // de l'action "Effacer tout" (corbeille) juste au-dessus.
            IconButton(
              icon: const Icon(LucideIcons.fileX, size: 18),
              color: const Color(0xFFB91C1C),
              tooltip: 'Supprimer la page',
              onPressed: widget.totalPages! > 1 ? widget.onDeletePage : null,
            ),
          ],
        ],
      ),
    );
  }

  // Pill − | N | + garantie toujours sur une même ligne (Container seul,
  // Wrap ne peut pas le découper).
  Widget _buildThicknessPill() {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sizeStepButton(
            icon: LucideIcons.minus,
            tooltip: "Diminuer l'épaisseur",
            onTap: _penSize > 1
                ? () =>
                    setState(() => _penSize = (_penSize - 1).clamp(1, 20))
                : null,
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 24),
            alignment: Alignment.center,
            child: Text(
              '${_penSize.toInt()}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Color(0xFF334155),
              ),
            ),
          ),
          _sizeStepButton(
            icon: LucideIcons.plus,
            tooltip: "Augmenter l'épaisseur",
            onTap: _penSize < 20
                ? () =>
                    setState(() => _penSize = (_penSize + 1).clamp(1, 20))
                : null,
          ),
        ],
      ),
    );
  }

  // Menu déroulant "Insérer un élément" — remplace les 5 boutons dédiés
  // (fenêtre, porte, WC, douche, baignoire). À la sélection, le symbole
  // apparaît au centre du canvas, taille par défaut, sélectionné pour
  // manipulation immédiate.
  Widget _buildInsertSymbolMenu() {
    return PopupMenuButton<PlanTool>(
      tooltip: '',
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
      elevation: 6,
      onSelected: _insertSymbolAtCenter,
      itemBuilder: (ctx) => const [
        PopupMenuItem(
          value: PlanTool.window,
          child: _SymbolMenuRow(
              icon: LucideIcons.appWindow, label: 'Fenêtre'),
        ),
        PopupMenuItem(
          value: PlanTool.door,
          child: _SymbolMenuRow(
              icon: LucideIcons.doorOpen, label: 'Porte'),
        ),
        PopupMenuItem(
          value: PlanTool.toilet,
          child: _SymbolMenuRow(
              icon: LucideIcons.armchair, label: 'WC'),
        ),
        PopupMenuItem(
          value: PlanTool.shower,
          child: _SymbolMenuRow(
              icon: LucideIcons.droplets, label: 'Douche'),
        ),
        PopupMenuItem(
          value: PlanTool.bath,
          child: _SymbolMenuRow(
              icon: LucideIcons.bath, label: 'Baignoire'),
        ),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
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
              'Insérer un élément',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(width: 4),
            Icon(LucideIcons.chevronDown, size: 14, color: Colors.white),
          ],
        ),
      ),
    );
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
    // Bouton icône seul (tooltip au survol pour le libellé).
    final active = _tool == tool;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: () => setState(() => _tool = tool),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? _kTeal : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 18,
            color: active ? Colors.white : Colors.grey.shade600,
          ),
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
    final picked = await showDialog<int>(
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
      ),
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
                  onTapDown: _onCanvasTapDown,
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
              // Overlay des poignées quand un symbole est sélectionné.
              if (_selectedIndex >= 0 && _selectedIndex < _strokes.length)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _HandlesPainter(
                        stroke: _strokes[_selectedIndex],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Gestures routing — distingue tracé libre vs manipulation de symbole.
  // ---------------------------------------------------------------------

  void _onCanvasTapDown(TapDownDetails d) {
    // Un tap rapide = soit sélectionner un symbole existant, soit
    // désélectionner. Le tracé libre se déclenche seulement sur pan.
    final pt = _localPoint(d.globalPosition);
    // On regarde d'abord le symbole sélectionné (poignées prioritaires).
    if (_selectedIndex >= 0) {
      final sel = _strokes[_selectedIndex];
      final h = _handleAt(sel, pt);
      if (h != null && h != _SymbolHandle.body) return; // drag prendra la main
    }
    // Sinon, on cherche un symbole sous le tap (du plus récent au plus
    // ancien pour privilégier le top visuel).
    for (var i = _strokes.length - 1; i >= 0; i--) {
      final s = _strokes[i];
      if (!_symbolTools.contains(s.tool)) continue;
      final h = _handleAt(s, pt);
      if (h != null) {
        setState(() => _selectedIndex = i);
        return;
      }
    }
    // Rien trouvé → désélection.
    if (_selectedIndex != -1) {
      setState(() => _selectedIndex = -1);
    }
  }

  void _onPanStartRouted(DragStartDetails d) {
    final pt = _localPoint(d.globalPosition);
    // Si on a un symbole sélectionné, tester les poignées / corps.
    if (_selectedIndex >= 0) {
      final sel = _strokes[_selectedIndex];
      final h = _handleAt(sel, pt);
      if (h != null) {
        _activeHandle = h;
        _dragAnchor = pt;
        _dragInitialCenter = sel.points[0];
        _dragInitialCorner = sel.points[1];
        _dragInitialRotation = sel.rotation;
        return;
      }
    }
    // Sinon, comportement tracé libre existant.
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
        final newAngle = math.atan2(vec.dy, vec.dx) + math.pi / 2;
        setState(() => sel.rotation = newAngle);
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
enum _SymbolHandle { topLeft, topRight, bottomLeft, bottomRight, rotate, body }

/// Petite ligne d'un PopupMenuItem pour le menu "Insérer un élément".
class _SymbolMenuRow extends StatelessWidget {
  const _SymbolMenuRow({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: const Color(0xFF334155)),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF0F172A),
          ),
        ),
      ],
    );
  }
}

/// Painter overlay qui dessine les 4 poignées de coin + la flèche de
/// rotation autour du symbole sélectionné.
class _HandlesPainter extends CustomPainter {
  _HandlesPainter({required this.stroke});
  final _PlanStroke stroke;

  static const double _handleRadius = 6.0;
  static const double _rotateOffset = 34.0;
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

    // 4 coins.
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

    // Poignée rotation : cercle + icône flèche simplifiée.
    canvas.drawCircle(rotateTop, _handleRadius + 2, handleFill);
    canvas.drawCircle(rotateTop, _handleRadius + 2, handleBorder);
    // Mini "↻" en dessinant un arc.
    final arcPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawArc(
      Rect.fromCircle(center: rotateTop, radius: 3.5),
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
    // Use a layer so erasers using dstOut work over committed strokes
    canvas.saveLayer(Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    paintStrokes(canvas, strokes, currentStroke);
    canvas.restore();
  }

  static void paintStrokes(
    Canvas canvas,
    List<_PlanStroke> strokes,
    _PlanStroke? current,
  ) {
    for (final s in strokes) {
      _paintOne(canvas, s);
    }
    if (current != null) _paintOne(canvas, current);
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
      default:
        break;
    }
    canvas.restore();
  }

  /// Fenêtre : double ligne horizontale sur toute la largeur du bounds.
  static void _paintWindowLocal(Canvas canvas, Rect r, Paint stroke) {
    final gap = (r.height / 2).clamp(3, 8);
    canvas.drawLine(
      Offset(r.left, -gap.toDouble()),
      Offset(r.right, -gap.toDouble()),
      stroke,
    );
    canvas.drawLine(
      Offset(r.left, gap.toDouble()),
      Offset(r.right, gap.toDouble()),
      stroke,
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
