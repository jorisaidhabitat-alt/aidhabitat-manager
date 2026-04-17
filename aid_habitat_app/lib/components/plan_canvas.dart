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

const double _kRulerSize = 36;
const double _kCellCm = 20;
const int _kCellsPerMajor = 5;

// Brand colors
const Color _kTeal = Color(0xFF597E8D);
const Color _kGridMinor = Color(0xFFE2E6EB);
const Color _kGridMajor = Color(0xFFC8CFD8);
const Color _kRulerBg = Color(0xFFF4F6F8);
const Color _kRulerCorner = Color(0xFFE8ECF0);
const Color _kRulerBorder = Color(0xFFBCC5D0);
const Color _kRulerText = Color(0xFF6B7A8D);

// ---------------------------------------------------------------------------
// Stroke model
// ---------------------------------------------------------------------------

enum PlanTool { pen, line, rect, eraser }

class _PlanStroke {
  final PlanTool tool;
  final int color; // ARGB
  final double size;
  final List<Offset> points; // pen/eraser: list. line: [start,end]. rect: [topLeft, bottomRight]

  _PlanStroke({
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
  });

  Map<String, dynamic> toJson() => {
        'tool': tool.name,
        'color': color,
        'size': size,
        'points': points.map((p) => [p.dx, p.dy]).toList(),
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
      return _PlanStroke(
        tool: tool,
        color: color,
        size: size,
        points: points,
      );
    } catch (_) {
      return null;
    }
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

  const PlanCanvas({
    super.key,
    required this.patientId,
    this.tabKey = 'Plans',
    this.pageNumber = 0,
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
    final stroke = _PlanStroke(
      tool: _tool,
      color: _tool == PlanTool.eraser ? 0x00000000 : _penColor,
      size: _tool == PlanTool.eraser ? 24 : _penSize,
      points: [pt],
    );
    setState(() => _current = stroke);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final cur = _current;
    if (cur == null) return;
    final pt = _localPoint(d.globalPosition);
    setState(() {
      if (cur.tool == PlanTool.pen || cur.tool == PlanTool.eraser) {
        cur.points.add(pt);
      } else {
        // Shape: always [start, current]
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
    if ((cur.tool == PlanTool.pen || cur.tool == PlanTool.eraser) &&
        cur.points.length < 2) {
      // Ensure a dot renders by duplicating the point
      cur.points.add(cur.points.first.translate(0.1, 0));
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

    // Grid (with ruler, at 0,0 offset)
    _GridPainter.paintGrid(
      canvas,
      Size(size.width + _kRulerSize, size.height + _kRulerSize),
    );

    // Shift so draw area starts at (0,0) after grid painted ruler zone
    // Actually for export we want the drawing area only
    // Redraw strokes at origin
    canvas.translate(_kRulerSize, _kRulerSize);
    _DrawPainter.paintStrokes(canvas, _strokes, null);

    final picture = recorder.endRecording();
    final img = await picture.toImage(
      (size.width + _kRulerSize).toInt(),
      (size.height + _kRulerSize).toInt(),
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
          const Text(
            'OUTILS',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Colors.grey,
              letterSpacing: 1,
            ),
          ),
          _toolBtn(PlanTool.pen, LucideIcons.penTool, 'Crayon'),
          _toolBtn(PlanTool.line, LucideIcons.minus, 'Ligne'),
          _toolBtn(PlanTool.rect, LucideIcons.square, 'Rectangle'),
          _toolBtn(PlanTool.eraser, LucideIcons.eraser, 'Gomme'),
          _divider(),
          const Text('Couleur',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          ..._presetColors.map((c) => _colorDot(c)),
          _customColorDot(),
          _divider(),
          const Text('Épaisseur',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          SizedBox(
            width: 100,
            child: Slider(
              value: _penSize,
              min: 1,
              max: 10,
              divisions: 9,
              activeColor: _kTeal,
              onChanged: (v) => setState(() => _penSize = v),
            ),
          ),
          Text('${_penSize.toInt()}',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(LucideIcons.download, size: 18),
            color: Colors.grey.shade600,
            tooltip: 'Télécharger le plan',
            onPressed: _downloadPng,
          ),
          IconButton(
            icon: const Icon(LucideIcons.trash2, size: 18),
            color: Colors.red.shade400,
            tooltip: 'Effacer tout',
            onPressed: _clearAll,
          ),
        ],
      ),
    );
  }

  Widget _toolBtn(PlanTool tool, IconData icon, String label) {
    final active = _tool == tool;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: () => setState(() => _tool = tool),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? _kTeal : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 16, color: active ? Colors.white : Colors.grey.shade600),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: active ? Colors.white : Colors.grey.shade600,
                ),
              ),
            ],
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
              // Draw area is offset by ruler size
              Positioned(
                left: _kRulerSize,
                top: _kRulerSize,
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _onPanStart,
                  onPanUpdate: _onPanUpdate,
                  onPanEnd: _onPanEnd,
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
              // Legend badge
              Positioned(
                right: 12,
                bottom: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '1 carreau = 20 cm',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Grid + ruler painter
// ---------------------------------------------------------------------------

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    paintGrid(canvas, size);
  }

  static void paintGrid(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= _kRulerSize || h <= _kRulerSize) return;

    final drawW = w - _kRulerSize;
    final drawH = h - _kRulerSize;
    final cellPx = math.max(10.0, (drawW / 100 * 4).round().toDouble());

    // Ruler backgrounds
    final rulerBg = Paint()..color = _kRulerBg;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, _kRulerSize), rulerBg);
    canvas.drawRect(Rect.fromLTWH(0, 0, _kRulerSize, h), rulerBg);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, _kRulerSize, _kRulerSize),
      Paint()..color = _kRulerCorner,
    );

    // Grid lines
    final cols = (drawW / cellPx).ceil();
    final rows = (drawH / cellPx).ceil();
    for (var c = 0; c <= cols; c++) {
      final x = _kRulerSize + c * cellPx;
      final major = c % _kCellsPerMajor == 0;
      final paint = Paint()
        ..color = major ? _kGridMajor : _kGridMinor
        ..strokeWidth = major ? 1 : 0.5;
      canvas.drawLine(Offset(x, _kRulerSize), Offset(x, h), paint);
    }
    for (var r = 0; r <= rows; r++) {
      final y = _kRulerSize + r * cellPx;
      final major = r % _kCellsPerMajor == 0;
      final paint = Paint()
        ..color = major ? _kGridMajor : _kGridMinor
        ..strokeWidth = major ? 1 : 0.5;
      canvas.drawLine(Offset(_kRulerSize, y), Offset(w, y), paint);
    }

    // Ruler ticks + labels
    final tickPaint = Paint()
      ..color = const Color(0xFF9AA5B4)
      ..strokeWidth = 1;

    final textStyle = ui.TextStyle(
      color: _kRulerText,
      fontSize: 9,
      fontWeight: FontWeight.w700,
    );
    final paraStyle = ui.ParagraphStyle(textAlign: TextAlign.center);

    // Top ruler
    for (var c = 0; c <= cols; c++) {
      final x = _kRulerSize + c * cellPx;
      final major = c % _kCellsPerMajor == 0;
      canvas.drawLine(
        Offset(x, major ? _kRulerSize - 10 : _kRulerSize - 5),
        Offset(x, _kRulerSize),
        tickPaint,
      );
      if (major) {
        final cm = c * _kCellCm.toInt();
        final pb = ui.ParagraphBuilder(paraStyle)
          ..pushStyle(textStyle)
          ..addText('$cm');
        final paragraph = pb.build()..layout(const ui.ParagraphConstraints(width: 40));
        canvas.drawParagraph(
          paragraph,
          Offset(x - 20, _kRulerSize / 2 - paragraph.height / 2),
        );
      }
    }

    // Left ruler
    for (var r = 0; r <= rows; r++) {
      final y = _kRulerSize + r * cellPx;
      final major = r % _kCellsPerMajor == 0;
      canvas.drawLine(
        Offset(major ? _kRulerSize - 10 : _kRulerSize - 5, y),
        Offset(_kRulerSize, y),
        tickPaint,
      );
      if (major) {
        final cm = r * _kCellCm.toInt();
        final pb = ui.ParagraphBuilder(paraStyle)
          ..pushStyle(textStyle)
          ..addText('$cm');
        final paragraph = pb.build()..layout(const ui.ParagraphConstraints(width: 30));
        // Draw rotated label
        canvas.save();
        canvas.translate(_kRulerSize / 2, y);
        canvas.rotate(-math.pi / 2);
        canvas.drawParagraph(
          paragraph,
          Offset(-15, -paragraph.height / 2),
        );
        canvas.restore();
      }
    }

    // Ruler borders
    final border = Paint()
      ..color = _kRulerBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(
      Rect.fromLTWH(0.5, 0.5, _kRulerSize, h - 1),
      border,
    );
    canvas.drawRect(
      Rect.fromLTWH(0.5, 0.5, w - 1, _kRulerSize),
      border,
    );
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
        if (s.points.length == 1) {
          canvas.drawCircle(s.points.first, s.size / 2, paint..style = PaintingStyle.fill);
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
    }
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
