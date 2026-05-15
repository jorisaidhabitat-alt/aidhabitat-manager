import 'package:flutter/material.dart';

/// Palette des couleurs de marque Aid'Habitat — source unique de vérité.
///
/// Avant cette consolidation (audit code-review 2026-05-16), la couleur
/// mauve principale `0xFF8B6FA0` était hardcodée 174× dans 36 fichiers
/// sous des noms locaux différents (`_kPurple`, `_kAccentColor`,
/// `_kStackedViolet`, `kDocCardPurple`, …). Chaque écran avait sa
/// propre const, parfois avec une nuance d'écart d'un fichier à
/// l'autre — risque de dérive visuelle quand on ajustait le branding.
///
/// Désormais : on importe `brand_colors.dart` partout, on utilise ces
/// constantes nommées. Une seule ligne à changer si le branding
/// évolue.
///
/// Cohérent avec le `seedColor: kBrandPurple` du `ThemeData` dans
/// `main.dart`.

/// Couleur principale Aid'Habitat (mauve-500). Utilisée pour :
/// boutons primaires, surlignages actifs, icônes accent, badges,
/// header tabs, indicateurs de sélection, fond du splash, etc.
const Color kBrandPurple = Color(0xFF8B6FA0);

/// Variante foncée (mauve-700) — texte secondaire sur fond clair,
/// icônes "discrètes" mais marquées, états désactivés contrastés.
const Color kBrandDarkPurple = Color(0xFF554a63);
