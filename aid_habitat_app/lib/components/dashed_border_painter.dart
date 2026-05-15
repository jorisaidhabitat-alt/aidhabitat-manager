import 'package:flutter/material.dart';

/// Peint un border en pointillés sur un rectangle arrondi.
///
/// Extrait de `documents_screen.dart` 2026-05-15 (audit P0 #9). Le
/// composant est strictement utilitaire (zéro coupling avec l'écran
/// hôte) et candidat naturel à la réutilisation : drag-target, drop
/// zones, placeholder vide, etc.
///
/// Utilisation typique :
/// ```dart
/// CustomPaint(
///   painter: DashedBorderPainter(
///     color: Colors.grey,
///     strokeWidth: 1.5,
///     radius: 12,
///     dashLength: 6,
///     dashGap: 4,
///   ),
///   child: Container(...),
/// )
/// ```
class DashedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double radius;
  final double dashLength;
  final double dashGap;

  DashedBorderPainter({
    required this.color,
    required this.strokeWidth,
    required this.radius,
    required this.dashLength,
    required this.dashGap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final rect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rect);
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dashLength).clamp(0.0, metric.length);
        canvas.drawPath(
          metric.extractPath(distance, end),
          paint,
        );
        distance = end + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedBorderPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.radius != radius ||
      old.dashLength != dashLength ||
      old.dashGap != dashGap;
}
