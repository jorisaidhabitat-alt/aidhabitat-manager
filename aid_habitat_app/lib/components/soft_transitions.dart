import 'package:flutter/material.dart';

/// Module d'animations "soft" partagées dans toute l'app — mêmes
/// sensations de légèreté / fluidité que les transitions de sous-sections
/// du relevé de visite.
///
/// Trois briques :
///   1. [SoftPageTransitionsBuilder] — transition de page globale (fade
///      + léger slide) à brancher dans `ThemeData.pageTransitionsTheme`.
///   2. [SoftTapScale] — widget qui anime un léger scale-down au clic
///      pour signaler l'appui sans agressivité (à wrapper autour d'un
///      bouton/pill/tile).
///   3. [showSoftDialog] / [softDialogRouteBuilder] — helper pour ouvrir
///      un dialog avec un fade + scale doux (~180 ms, easeOutCubic).

// ---------------------------------------------------------------------------
// Constantes partagées
// ---------------------------------------------------------------------------

const Duration kSoftFast = Duration(milliseconds: 140);
const Duration kSoftMedium = Duration(milliseconds: 220);
const Duration kSoftSlow = Duration(milliseconds: 320);

const Curve kSoftCurve = Curves.easeOutCubic;
const Curve kSoftCurveIn = Curves.easeInCubic;

// ---------------------------------------------------------------------------
// 1. Page transitions — à utiliser dans ThemeData
// ---------------------------------------------------------------------------

/// Transition de page : fade complet + glissement vertical de 12 px vers
/// le haut. Durée 220 ms, easeOutCubic. Appliquée sur toutes les plates-
/// formes pour une cohérence macOS ↔ iPad ↔ web.
class SoftPageTransitionsBuilder extends PageTransitionsBuilder {
  const SoftPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: kSoftCurve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.025),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. Scale-on-tap — wrapper léger autour d'un bouton
// ---------------------------------------------------------------------------

/// Enveloppe un enfant d'un léger scale-down quand pressé (down) puis
/// remonte en douceur au relâchement. 140 ms, easeOutCubic. N'intercepte
/// pas l'event tap : il faut passer [onTap] pour recevoir le clic.
///
/// Utilisation :
/// ```dart
/// SoftTapScale(
///   onTap: _doThing,
///   child: Container(padding: ..., child: Text('Action')),
/// )
/// ```
class SoftTapScale extends StatefulWidget {
  const SoftTapScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    // 0.92 au lieu de 0.97 : le « rebond » est nettement perceptible tout
    // en restant discret. Curve easeOutCubic → la remontée se fait en
    // douceur, sans rebond brusque.
    this.scale = 0.92,
    this.duration = kSoftFast,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale appliqué lors de l'appui (1 = pas d'animation). Défaut 0.97.
  final double scale;
  final Duration duration;
  final bool enabled;

  @override
  State<SoftTapScale> createState() => _SoftTapScaleState();
}

class _SoftTapScaleState extends State<SoftTapScale> {
  bool _pressed = false;

  void _set(bool v) {
    if (!widget.enabled) return;
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final targetScale = _pressed ? widget.scale : 1.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.enabled ? widget.onTap : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      child: AnimatedScale(
        scale: targetScale,
        duration: widget.duration,
        curve: kSoftCurve,
        child: widget.child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Dialog : fade + scale doux
// ---------------------------------------------------------------------------

/// Ouvre un dialog avec un fade + scale (0.94 → 1.0). Remplace avanta-
/// geusement `showDialog` quand on veut la même légèreté que le reste
/// de l'app.
Future<T?> showSoftDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color barrierColor = Colors.black54,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: barrierDismissible ? 'Dismiss' : null,
    barrierColor: barrierColor,
    transitionDuration: kSoftMedium,
    pageBuilder: (ctx, _, __) => builder(ctx),
    transitionBuilder: softDialogRouteBuilder,
  );
}

/// Builder de transition pour un dialog "soft" — fade + scale subtil.
/// Extrait pour pouvoir être réutilisé par d'autres routes.
Widget softDialogRouteBuilder(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final curved = CurvedAnimation(parent: animation, curve: kSoftCurve);
  return FadeTransition(
    opacity: curved,
    child: ScaleTransition(
      scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
      child: child,
    ),
  );
}

// ---------------------------------------------------------------------------
// 4. AnimatedSwitcher par défaut — fade + slide 8 px
// ---------------------------------------------------------------------------

/// Variante d'[AnimatedSwitcher] pré-configurée : fade + translation
/// verticale 8 px. Utile pour changer un contenu (texte, liste…) sans
/// coupure sèche.
class SoftSwitcher extends StatelessWidget {
  const SoftSwitcher({
    super.key,
    required this.child,
    this.duration = kSoftMedium,
  });
  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: kSoftCurve,
      switchOutCurve: kSoftCurveIn,
      // Par défaut AnimatedSwitcher centre les enfants dans un Stack ; on
      // utilise `Positioned.fill` pour laisser chaque vue occuper toute la
      // surface (sinon les écrans « pleine page » deviennent des petits
      // widgets centrés pendant la transition).
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      transitionBuilder: (child, anim) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
