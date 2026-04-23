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
        color: const Color(0xFFF6EDFB),
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

/// Badge "catégorie de revenu" (Très modeste, Modeste, Intermédiaire…).
/// Style unique bleu pastel (demande utilisateur) — fond `#D9EAF3`,
/// bordure + texte `#4492B6` quelle que soit la catégorie.
class IncomeCategoryBadge extends StatelessWidget {
  final String value;
  const IncomeCategoryBadge({super.key, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFD9EAF3),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF4492B6)),
      ),
      child: Text(
        value,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFF4492B6),
        ),
      ),
    );
  }
}
