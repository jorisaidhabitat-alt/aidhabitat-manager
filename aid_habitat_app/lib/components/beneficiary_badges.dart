import 'package:flutter/material.dart';

/// Canonicalise la valeur brute du champ `natureAccompagnement` (stocké
/// en minuscules côté NocoDB) vers une forme affichable :
///   • `diagnostic` → "Diagnostic ergo"
///   • `ergo` → "Ergo"
///   • `complet` → "Complet"
///   • autre → valeur trimmée telle quelle (respecte d'éventuels
///     libellés personnalisés saisis par un admin).
String formatAccompanimentType(String raw) {
  final v = raw.trim().toLowerCase();
  switch (v) {
    case 'diagnostic':
      return 'Diagnostic ergo';
    case 'ergo':
      return 'Ergo';
    case 'complet':
      return 'Complet';
    default:
      return raw.trim();
  }
}

/// Badge "type d'accompagnement" (ex. "Complet", "Diagnostic ergo",
/// "Ergo") — fond violet clair, bordure violette, typographie violet
/// foncé. Utilisé dans les en-têtes de dossier et relevé de visite
/// pour signaler visuellement la nature de l'accompagnement.
class AccompanimentBadge extends StatelessWidget {
  final String value;
  const AccompanimentBadge({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F0F5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFD8CFE0)),
      ),
      child: Text(
        value,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF554A63),
        ),
      ),
    );
  }
}

/// Badge "catégorie de revenu" (Très modeste, Modeste, Intermédiaire…)
/// avec une palette couleur dédiée :
///   • Très modeste → bleu pastel
///   • Modeste → jaune pastel
///   • Intermédiaire → vert pastel
///   • défaut → gris pastel
class IncomeCategoryBadge extends StatelessWidget {
  final String value;
  const IncomeCategoryBadge({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final palette = _paletteFor(value);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: palette.fg,
        ),
      ),
    );
  }

  _BeneficiaryBadgePalette _paletteFor(String raw) {
    final normalized = raw.toLowerCase().trim();
    if (normalized.contains('très modeste') ||
        normalized.contains('tres modeste')) {
      return const _BeneficiaryBadgePalette(
        bg: Color(0xFFDBEAFE),
        fg: Color(0xFF1D4ED8),
      );
    }
    if (normalized == 'modeste' || normalized.startsWith('modeste')) {
      return const _BeneficiaryBadgePalette(
        bg: Color(0xFFFEF3C7),
        fg: Color(0xFFB45309),
      );
    }
    if (normalized.contains('intermédiaire') ||
        normalized.contains('intermediaire')) {
      return const _BeneficiaryBadgePalette(
        bg: Color(0xFFDCFCE7),
        fg: Color(0xFF15803D),
      );
    }
    return const _BeneficiaryBadgePalette(
      bg: Color(0xFFF1F5F9),
      fg: Color(0xFF475569),
    );
  }
}

class _BeneficiaryBadgePalette {
  final Color bg;
  final Color fg;
  const _BeneficiaryBadgePalette({required this.bg, required this.fg});
}
