import 'package:flutter/material.dart';

/// Bannière titre au-dessus des `NotesWidget` du relevé de visite.
///
/// Demande user 2026-05-15 : les libellés exacts des sections PDF
/// (« Observations sur l'accessibilité », « Habitudes de vie »,
/// « Environnement », « Projet de l'usager », « Résumé des
/// préconisations »…) doivent être affichés en TITRE permanent en
/// haut du cadre note avec un fond violet clair, et NON noyés en
/// hintText du TextField (où ils disparaissent dès la première frappe).
///
/// Utilisé par :
///  - `visit_report_screen.dart::_buildNotesPanel` pour les notes
///    de chaque sous-section (Contexte, Accessibilité, Sanitaires…).
///  - `summary_tab.dart` pour les cadres compacts « Projet de l'usager »
///    et « Résumé des préconisations » en haut du Résumé.
class NotesPanelTitleBanner extends StatelessWidget {
  const NotesPanelTitleBanner({
    super.key,
    required this.title,
    this.attachedToBelow = false,
  });
  final String title;
  final bool attachedToBelow;

  @override
  Widget build(BuildContext context) {
    final borderRadius = attachedToBelow
        ? const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          )
        : BorderRadius.circular(12);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(color: const Color(0xFFEDE9EF), width: 1),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 42),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: const Color(0xFFEDE8F5), // mauve-100 (brand light)
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Color(0xFF554265), // mauve-700
              letterSpacing: 0.1,
            ),
          ),
        ),
      ),
    );
  }
}
