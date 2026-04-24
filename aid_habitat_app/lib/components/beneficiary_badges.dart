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
/// "Ergo") — fond violet clair `#EDE8F5`, typographie violet foncé.
/// Style flat (pas de bordure), aligné avec les autres badges.
class AccompanimentBadge extends StatelessWidget {
  final String value;
  const AccompanimentBadge({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE8F5),
        borderRadius: BorderRadius.circular(999),
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

/// Palette unique par catégorie de revenu utilisée partout dans
/// l'app (dossier, relevé de visite, liste des dossiers). La couleur
/// de fond ET la couleur de typo dépendent de la catégorie :
///   • Très modeste → fond bleu clair, typo bleu
///   • Modeste      → fond jaune clair, typo orange
///   • autres       → fond violet doux, typo violet foncé (neutre)
class IncomeCategoryPalette {
  final Color bg;
  final Color fg;
  const IncomeCategoryPalette({required this.bg, required this.fg});
}

IncomeCategoryPalette incomePaletteFor(String value) {
  final v = value.trim().toLowerCase();
  if (v.contains('très modeste') || v.contains('tres modeste')) {
    return const IncomeCategoryPalette(
      bg: Color(0xFFCFE3F0),
      fg: Color(0xFF2D7EB8),
    );
  }
  if (v.contains('modeste')) {
    return const IncomeCategoryPalette(
      bg: Color(0xFFF7E3A8),
      fg: Color(0xFFC2660C),
    );
  }
  // Neutre pour Intermédiaire, Supérieur ou toute catégorie inconnue.
  return const IncomeCategoryPalette(
    bg: Color(0xFFEDE8F5),
    fg: Color(0xFF554A63),
  );
}

/// Badge "catégorie de revenu" (Très modeste, Modeste, Intermédiaire…).
/// Utilise la palette unifiée [incomePaletteFor] pour que le même
/// libellé ait toujours la même couleur où qu'il apparaisse.
class IncomeCategoryBadge extends StatelessWidget {
  final String value;
  const IncomeCategoryBadge({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    final palette = incomePaletteFor(value);
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
}
