import 'package:flutter/material.dart';
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
  bool showCloseButton = false,
  T? closeValue,
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
      showCloseButton: showCloseButton,
      closeValue: closeValue,
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
        showCloseButton: true,
        closeValue: false,
        actions: [
          AppConfirmationAction(label: cancelLabel, value: false),
          AppConfirmationAction(
            label: confirmLabel,
            value: true,
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
    this.showCloseButton = false,
    this.closeValue,
  });

  final String title;
  final String? message;
  final Widget? content;
  final List<AppConfirmationAction<T>> actions;
  final AppConfirmationTone tone;
  final IconData? icon;
  final bool showCloseButton;
  final T? closeValue;

  @override
  Widget build(BuildContext context) {
    final topPadding = showCloseButton ? 16.0 : 22.0;
    final rightPadding = showCloseButton ? 16.0 : 24.0;

    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: EdgeInsets.fromLTRB(24, topPadding, rightPadding, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(top: showCloseButton ? 8 : 0),
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                  ),
                  if (showCloseButton)
                    IconButton(
                      tooltip: 'Annuler',
                      icon: const Icon(LucideIcons.x, size: 20),
                      onPressed: () => Navigator.of(context).pop(closeValue),
                    ),
                ],
              ),
              if (message != null || content != null) ...[
                const SizedBox(height: 4),
                DefaultTextStyle(
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: Color(0xFF5C6670),
                  ),
                  child: content ?? Text(message!),
                ),
              ],
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final action in actions)
                      _ConfirmationButton<T>(action: action, tone: tone),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConfirmationButton<T> extends StatelessWidget {
  const _ConfirmationButton({required this.action, required this.tone});

  final AppConfirmationAction<T> action;
  final AppConfirmationTone tone;

  @override
  Widget build(BuildContext context) {
    if (action.isPrimary) {
      final background = action.isDestructive
          ? kConfirmationDanger
          : _primaryColor(tone);
      final style = FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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
    final background = action.isDestructive
        ? const Color(0xFFFEF2F2)
        : kBrandPurple.withValues(alpha: 0.12);
    final style = TextButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
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

  static Color _primaryColor(AppConfirmationTone tone) {
    switch (tone) {
      case AppConfirmationTone.danger:
      case AppConfirmationTone.warning:
      case AppConfirmationTone.info:
        return kBrandPurple;
    }
  }
}
