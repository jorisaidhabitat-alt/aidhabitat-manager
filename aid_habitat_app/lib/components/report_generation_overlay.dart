import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../services/report_generation_service.dart';
import 'brand_colors.dart';

/// Bandeau global affiché au-dessus de tous les écrans signalant qu'une
/// génération de rapport PDF est en cours en arrière-plan. Permet à
/// l'utilisateur de quitter le VAD et naviguer ailleurs (dashboard,
/// autre dossier, documents) sans perdre la visibilité sur la
/// progression.
///
/// Émet aussi un SnackBar de succès/erreur GLOBAL via le
/// [ScaffoldMessenger] racine quand la génération se termine, peu
/// importe l'écran courant. Demande utilisateur 2026-05-11 :
///   « Le bandeau vert qui indique qu'il a été mis dans l'espace
///     document doit également apparaitre en bas même si je suis sur
///     une autre page une fois la generation effectuée. »
class ReportGenerationOverlay extends StatefulWidget {
  /// L'écran qu'on enveloppe (typiquement le `MainScreen` complet,
  /// avec sidebar + zone principale). L'overlay est positionné en
  /// haut à droite par-dessus, non-bloquant (`IgnorePointer` quand
  /// caché).
  final Widget child;
  const ReportGenerationOverlay({super.key, required this.child});

  @override
  State<ReportGenerationOverlay> createState() =>
      _ReportGenerationOverlayState();
}

class _ReportGenerationOverlayState extends State<ReportGenerationOverlay> {
  StreamSubscription<ReportGenerationState>? _sub;
  ReportGenerationState _state = const ReportGenerationState();

  @override
  void initState() {
    super.initState();
    _state = ReportGenerationService.instance.currentState;
    _sub = ReportGenerationService.instance.stateStream.listen(_onStateChange);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onStateChange(ReportGenerationState next) {
    if (!mounted) return;
    // Délai post-frame pour éviter les setState pendant un build en
    // cours (peut arriver si le notify tombe pile dans le build d'un
    // autre widget abonné au même stream).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Affiche les snackbars AVANT de remplacer _state — pour qu'on
      // capture bien les events transitoires (`lastSuccess` /
      // `lastFailure`) avant qu'ils soient acquittés.
      if (next.lastSuccess != null) {
        _showSuccessSnackBar(next.lastSuccess!);
        ReportGenerationService.instance.acknowledgeLastEvent();
      } else if (next.lastFailure != null) {
        _showFailureSnackBar(next.lastFailure!);
        ReportGenerationService.instance.acknowledgeLastEvent();
      }
      setState(() => _state = next);
    });
  }

  void _showSuccessSnackBar(ReportGenerationSuccess success) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF166534),
        duration: const Duration(seconds: 6),
        content: Row(
          children: [
            const Icon(LucideIcons.checkCircle2, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Rapport ${success.patientLabel} ajouté à l\'espace '
                'Documents (${success.fileName})',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFailureSnackBar(ReportGenerationFailure failure) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.clearSnackBars();
    final bgColor = failure.deferred
        ? kBrandPurple // violet — différé, pas une erreur dure
        : const Color(0xFFB91C1C); // rouge — erreur sèche
    final icon = failure.deferred
        ? LucideIcons.clock
        : LucideIcons.alertTriangle;
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: bgColor,
        duration: const Duration(seconds: 7),
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Rapport ${failure.patientLabel} — ${failure.message}',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_state.inProgress)
          Positioned(
            top: 16,
            right: 16,
            child: SafeArea(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: kBrandPurple,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: Text(
                          _state.progressLabel.isNotEmpty
                              ? _state.progressLabel
                              : 'Génération du rapport...',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
