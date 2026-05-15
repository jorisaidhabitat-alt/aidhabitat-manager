import 'package:flutter/material.dart';

/// Modèle de stroke + painters + helpers extraits de `notes_widget.dart`
/// (refonte 2026-05-15, audit P0 #9). Le widget hôte (`NotesWidget`)
/// fait 3200 lignes ; isoler les briques auto-contenues (sans coupling
/// avec la State du widget) dans un fichier dédié permet :
///   • d'éviter la "god file" qui décourage le refactor
///   • de tester unitairement la sérialisation Stroke
///     (toJson/fromJson, plafond 2000 points, etc.) sans monter un
///     widget tree complet
///   • de garder les peintres réutilisables si une autre surface canvas
///     (annotateur d'images, planches…) en a besoin
///
/// Les enums `NoteTool` et `NoteCanvasMode` vivaient historiquement
/// dans `notes_widget.dart` ; ils sont déplacés ici parce que `Stroke`
/// en dépend (cycle de dépendance évité). `notes_widget.dart` les
/// ré-exporte pour les consommateurs externes (`note_window_screen`,
/// `summary_tab`, `mesures_tab`) qui les importent toujours via
/// `notes_widget.dart`.

// =============================================================================
// Enums — outils & modes de fond
// =============================================================================

/// Outils de dessin disponibles (identiques à la version React).
enum NoteTool { pen, highlighter, eraser, line, rect }

/// Mode de fond du canvas — équivalent de la prop `mode`.
enum NoteCanvasMode { freeform, grid }

// =============================================================================
// Constantes partagées (fond, grille)
// =============================================================================

/// Taille de la cellule de grille (mode `NoteCanvasMode.grid`). En
/// pixels logiques.
const double kGridCell = 24.0;

// =============================================================================
// Sérialisation tool ↔ string (format JSON identique à celui de React)
// =============================================================================

String toolToString(NoteTool tool) {
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

NoteTool? toolFromString(String value) {
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

String colorToHex(int argb) {
  final rgb = argb & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}

int colorFromHex(String hex) {
  var value = hex.replaceFirst('#', '');
  if (value.length == 6) {
    value = 'ff$value';
  } else if (value.length != 8) {
    return 0xff111827;
  }
  return int.tryParse(value, radix: 16) ?? 0xff111827;
}

// =============================================================================
// Modèle Stroke (un trait de dessin) — persisté en JSON
// =============================================================================

class Stroke {
  final NoteTool tool;
  final int color; // ARGB int
  final double size;
  final List<Offset> points; // normalisés 0..1

  Stroke({
    required this.tool,
    required this.color,
    required this.size,
    required this.points,
  });

  Map<String, dynamic> toJson() => {
    'tool': toolToString(tool),
    'color': colorToHex(color),
    'size': size,
    'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
  };

  static Stroke? fromJson(Map<String, dynamic> json) {
    final tool = toolFromString(json['tool']?.toString() ?? 'pen');
    if (tool == null) return null;
    final color = colorFromHex(json['color']?.toString() ?? '#111827');
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
    // Plafonne à 2000 points par stroke (parité React — protection
    // mémoire en cas de trait extrêmement long).
    if (points.length > 2000) {
      return Stroke(
        tool: tool,
        color: color,
        size: size,
        points: points.sublist(0, 2000),
      );
    }
    return Stroke(tool: tool, color: color, size: size, points: points);
  }
}

// =============================================================================
// Painter du fond (blanc ou grille)
// =============================================================================

class BackgroundPainter extends CustomPainter {
  BackgroundPainter({required this.mode});

  final NoteCanvasMode mode;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (mode == NoteCanvasMode.grid) {
      final paint = Paint()
        ..color = const Color(0xFF8A939D).withValues(alpha: 0.22)
        ..strokeWidth = 1;
      for (double x = kGridCell; x < size.width; x += kGridCell) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
      for (double y = kGridCell; y < size.height; y += kGridCell) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant BackgroundPainter oldDelegate) =>
      oldDelegate.mode != mode;
}

// =============================================================================
// Painter des traits — gère pen, highlighter, eraser (blendmode clear),
// line, rect.
// =============================================================================

class StrokePainter extends CustomPainter {
  StrokePainter({required this.strokes, required this.activeStroke});

  final List<Stroke> strokes;
  final Stroke? activeStroke;

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

  void _drawStroke(Canvas canvas, Size size, Stroke stroke) {
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
        canvas.drawRect(
          Rect.fromPoints(realPoints.first, realPoints.last),
          paint,
        );
        break;
    }
  }

  @override
  bool shouldRepaint(covariant StrokePainter oldDelegate) => true;
}
