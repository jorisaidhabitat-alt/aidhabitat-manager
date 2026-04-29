import 'package:flutter/material.dart';

/// Détecte les swipes horizontaux et déclenche l'un de DEUX callbacks
/// selon la distance parcourue, en fraction de la largeur du widget :
///
///   - **Swipe léger** (≥ [lightMinRatio] et ≤ [lightMaxRatio] de la
///     largeur) → [onLightSwipeLeft] / [onLightSwipeRight]. Pensé pour
///     un changement « interne » comme passer d'un occupant à un autre.
///   - **Swipe large** (≥ [wideMinRatio] de la largeur) →
///     [onWideSwipeLeft] / [onWideSwipeRight]. Pensé pour un changement
///     « majeur » comme passer d'une sous-section à une autre.
///   - Zone morte entre [lightMaxRatio] et [wideMinRatio] → aucun
///     callback déclenché. Évite que l'ergo déclenche un changement de
///     sous-section par accident en cherchant à atteindre un occupant.
///
/// Demande utilisateur 2026-04-28 : « le slide vers la gauche ou vers
/// la droite doit être léger et centré pour que ça switch entre les
/// occupants, cependant si le slide est sur toute la majeur partie de
/// la largeur d'une sous partie, alors cela change de sous partie ».
///
/// Si un seul des couples de callbacks est fourni (par ex. seulement
/// `onWideSwipe*` pour les onglets sans occupants), le widget se
/// comporte en single-threshold : tout swipe ≥ [wideMinRatio]
/// déclenche le wide.
class TwoThresholdSwipe extends StatefulWidget {
  final Widget child;
  final VoidCallback? onLightSwipeLeft;
  final VoidCallback? onLightSwipeRight;
  final VoidCallback? onWideSwipeLeft;
  final VoidCallback? onWideSwipeRight;

  /// Distance minimale (ratio de la largeur) pour qu'un swipe soit
  /// pris en compte. En dessous → considéré comme un tap accidentel.
  final double lightMinRatio;

  /// Distance max d'un swipe pour rester catégorisé « léger ».
  final double lightMaxRatio;

  /// Distance min d'un swipe pour basculer en catégorie « large ».
  /// Doit être > [lightMaxRatio] pour laisser une zone morte.
  final double wideMinRatio;

  /// Vitesse minimale (px/s) au-delà de laquelle un swipe est traité
  /// comme « large » même s'il n'a pas atteint [wideMinRatio] en
  /// distance. Permet de déclencher un changement de sous-section
  /// d'un flick rapide sans devoir traîner le doigt sur 30 % de la
  /// largeur. ~600 px/s = un coup de pouce franc mais pas violent.
  final double wideVelocityFallback;

  const TwoThresholdSwipe({
    super.key,
    required this.child,
    this.onLightSwipeLeft,
    this.onLightSwipeRight,
    this.onWideSwipeLeft,
    this.onWideSwipeRight,
    // Seuils assouplis 2026-04-28 (« le slide entre les sous sections
    // demande trop d'effort ») :
    //   - Swipe léger : 5 → 18 % de la largeur (occupant)
    //   - Zone morte  : 18 → 30 %
    //   - Swipe large : ≥ 30 % de la largeur OU ≥ 600 px/s en vélocité
    //     (sous-section / niveau)
    // Avant : light max 35 %, wide min 55 % → trop demandant.
    this.lightMinRatio = 0.05,
    this.lightMaxRatio = 0.18,
    this.wideMinRatio = 0.30,
    this.wideVelocityFallback = 600,
  })  : assert(lightMinRatio < lightMaxRatio),
        assert(lightMaxRatio < wideMinRatio);

  @override
  State<TwoThresholdSwipe> createState() => _TwoThresholdSwipeState();
}

class _TwoThresholdSwipeState extends State<TwoThresholdSwipe> {
  double _startX = 0;
  double _currentX = 0;
  bool _dragging = false;
  double _capturedWidth = 0;

  bool get _hasLight =>
      widget.onLightSwipeLeft != null || widget.onLightSwipeRight != null;
  bool get _hasWide =>
      widget.onWideSwipeLeft != null || widget.onWideSwipeRight != null;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          // Opaque pour que le drag soit capté même sur un padding ou
          // un espace transparent du child. Les widgets enfants avec
          // leur propre `onTap` (boutons, pills, champs texte) gagnent
          // leur arène locale → on ne casse pas leur ergonomie.
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (details) {
            _startX = details.globalPosition.dx;
            _currentX = _startX;
            _capturedWidth = width;
            _dragging = true;
          },
          onHorizontalDragUpdate: (details) {
            if (!_dragging) return;
            _currentX = details.globalPosition.dx;
          },
          onHorizontalDragEnd: (details) {
            if (!_dragging) return;
            _dragging = false;
            if (_capturedWidth <= 0) return;
            final delta = _currentX - _startX;
            final absDelta = delta.abs();
            final ratio = absDelta / _capturedWidth;
            if (ratio < widget.lightMinRatio) return;

            final goingLeft = delta < 0;
            final velocity = (details.primaryVelocity ?? 0).abs();
            final velocityQualifiesAsWide =
                velocity >= widget.wideVelocityFallback;

            // Swipe LARGE prioritaire si activé. Trigger sur :
            //   - distance ≥ wideMinRatio (30 %), OU
            //   - flick rapide (vélocité ≥ wideVelocityFallback) ET
            //     distance déjà ≥ lightMaxRatio (sinon un simple tap
            //     glissé pourrait passer la barre).
            if (_hasWide &&
                (ratio >= widget.wideMinRatio ||
                    (velocityQualifiesAsWide &&
                        ratio >= widget.lightMaxRatio))) {
              if (goingLeft) {
                widget.onWideSwipeLeft?.call();
              } else {
                widget.onWideSwipeRight?.call();
              }
              return;
            }
            // Swipe LÉGER : entre lightMin et lightMax.
            if (_hasLight && ratio <= widget.lightMaxRatio) {
              if (goingLeft) {
                widget.onLightSwipeLeft?.call();
              } else {
                widget.onLightSwipeRight?.call();
              }
              return;
            }
            // Zone morte ou catégorie non câblée → no-op.
          },
          child: widget.child,
        );
      },
    );
  }
}
