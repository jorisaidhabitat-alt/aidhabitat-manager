import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'brand_colors.dart';
import 'soft_transitions.dart';

const Color kConfirmationDanger = Color(0xFFB91C1C);

enum AppConfirmationTone { danger, warning, info }

class AppConfirmationAction<T> {
  const AppConfirmationAction({
    required this.label,
    required this.value,
    this.icon,
    this.isPrimary = false,
    this.isDestructive = false,
  });

  final String label;
  final T value;
  final IconData? icon;
  final bool isPrimary;
  final bool isDestructive;
}

Future<T?> showAppConfirmationDialog<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget? content,
  required List<AppConfirmationAction<T>> actions,
  AppConfirmationTone tone = AppConfirmationTone.danger,
  IconData? icon,
  bool barrierDismissible = false,
}) {
  return showSoftDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => AppConfirmationDialog<T>(
      title: title,
      message: message,
      content: content,
      actions: actions,
      tone: tone,
      icon: icon,
    ),
  );
}

Future<bool> showAppDestructiveConfirmation({
  required BuildContext context,
  required String title,
  required String message,
  String cancelLabel = 'Annuler',
  String confirmLabel = 'Supprimer',
  IconData? icon,
}) async {
  return await showAppConfirmationDialog<bool>(
        context: context,
        title: title,
        message: message,
        tone: AppConfirmationTone.danger,
        icon: icon ?? LucideIcons.trash2,
        actions: [
          AppConfirmationAction(label: cancelLabel, value: false),
          AppConfirmationAction(
            label: confirmLabel,
            value: true,
            icon: icon ?? LucideIcons.trash2,
            isPrimary: true,
            isDestructive: true,
          ),
        ],
      ) ??
      false;
}

Future<bool> showAppDiscardChangesConfirmation({
  required BuildContext context,
  String title = 'Quitter sans enregistrer ?',
  String message =
      'Les modifications en cours seront perdues si vous quittez maintenant.',
  String cancelLabel = 'Continuer l’édition',
  String confirmLabel = 'Quitter sans enregistrer',
}) async {
  return await showAppConfirmationDialog<bool>(
        context: context,
        title: title,
        message: message,
        tone: AppConfirmationTone.warning,
        icon: LucideIcons.fileWarning,
        actions: [
          AppConfirmationAction(label: cancelLabel, value: false),
          AppConfirmationAction(
            label: confirmLabel,
            value: true,
            icon: LucideIcons.logOut,
            isPrimary: true,
            isDestructive: true,
          ),
        ],
      ) ??
      false;
}

class AppConfirmationDialog<T> extends StatelessWidget {
  const AppConfirmationDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    required this.actions,
    this.tone = AppConfirmationTone.danger,
    this.icon,
  });

  final String title;
  final String? message;
  final Widget? content;
  final List<AppConfirmationAction<T>> actions;
  final AppConfirmationTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final accent = _accentColor(tone);
    final iconData = icon ?? _defaultIcon(tone);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 430),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 24,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ConfirmationIcon(icon: iconData, color: accent),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          title,
                          style: GoogleFonts.nunito(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            height: 1.18,
                            letterSpacing: 0,
                            color: const Color(0xFF111827),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (message != null || content != null) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(left: 56),
                    child: DefaultTextStyle(
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.35,
                        color: Color(0xFF5C6670),
                      ),
                      child: content ?? Text(message!),
                    ),
                  ),
                ],
                const SizedBox(height: 22),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      for (final action in actions)
                        _ConfirmationButton<T>(action: action),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _accentColor(AppConfirmationTone tone) {
    switch (tone) {
      case AppConfirmationTone.danger:
        return kConfirmationDanger;
      case AppConfirmationTone.warning:
        return const Color(0xFFD97706);
      case AppConfirmationTone.info:
        return kBrandPurple;
    }
  }

  static IconData _defaultIcon(AppConfirmationTone tone) {
    switch (tone) {
      case AppConfirmationTone.danger:
        return LucideIcons.trash2;
      case AppConfirmationTone.warning:
        return LucideIcons.alertTriangle;
      case AppConfirmationTone.info:
        return LucideIcons.info;
    }
  }
}

class _ConfirmationIcon extends StatelessWidget {
  const _ConfirmationIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 21, color: color),
    );
  }
}

class _ConfirmationButton<T> extends StatelessWidget {
  const _ConfirmationButton({required this.action});

  final AppConfirmationAction<T> action;

  @override
  Widget build(BuildContext context) {
    if (action.isPrimary) {
      final background = action.isDestructive
          ? kConfirmationDanger
          : kBrandPurple;
      final style = FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      );
      if (action.icon != null) {
        return FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(action.value),
          style: style,
          icon: Icon(action.icon, size: 16),
          label: Text(action.label),
        );
      }
      return FilledButton(
        onPressed: () => Navigator.of(context).pop(action.value),
        style: style,
        child: Text(action.label),
      );
    }

    final foreground = action.isDestructive
        ? kConfirmationDanger
        : kBrandDarkPurple;
    final style = TextButton.styleFrom(
      foregroundColor: foreground,
      minimumSize: const Size(0, 42),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
    );
    if (action.icon != null) {
      return TextButton.icon(
        onPressed: () => Navigator.of(context).pop(action.value),
        style: style,
        icon: Icon(action.icon, size: 16),
        label: Text(action.label),
      );
    }
    return TextButton(
      onPressed: () => Navigator.of(context).pop(action.value),
      style: style,
      child: Text(action.label),
    );
  }
}
