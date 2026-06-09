import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palettes pastel partagées entre `DossiersListScreen` et
/// `DashboardScreen` — le même bénéficiaire (via hash de ses initiales) et
/// la même communauté de communes doivent garder leur couleur à travers
/// tous les écrans de l'app.

// ---------------------------------------------------------------------------
// Avatar bénéficiaire — mauve clair uniforme, aligné sur la sidebar active.
// ---------------------------------------------------------------------------

const Color kBeneficiaryAvatarBg = Color(0xFFF2ECF5); // mauve-100
const Color kBeneficiaryAvatarFg = Color(0xFF554265);

Color beneficiaryAvatarBgFor(String _) {
  return kBeneficiaryAvatarBg;
}

// ---------------------------------------------------------------------------
// Communauté de communes (EPCI) — couleur UNIQUE par EPCI, dérivée d'un
// hash stable du libellé via HSL.
//
// Avant : 5 pastels fixes (mint, pêche, ciel, lavande, sable) → collisions
// dès qu'on dépassait 5 EPCIs distincts (et la base NocoDB en compte
// largement plus). Maintenant : on hash le libellé en un angle de teinte
// (0-359°) et on génère la couleur via `HSLColor.fromAHSL(hue, S, L)` en
// gardant saturation + luminance dans la plage de la DA pastel
// existante (S ≈ 0.50, L ≈ 0.87) — donc chaque EPCI a sa propre teinte
// unique mais l'aspect global "pastel doux slate-700" reste identique.
//
// Le multiplicateur 137 (proche de l'angle d'or 137.508°) répartit
// uniformément les teintes sur le cercle chromatique : deux libellés
// proches (Roche aux Fées vs Roche-aux-Fées) tombent sur des couleurs
// volontairement différentes pour éviter toute confusion visuelle.
// ---------------------------------------------------------------------------

class EpciPalette {
  final Color bg;
  final Color fg;
  const EpciPalette({required this.bg, required this.fg});
}

const Color _kPastelEpciFg = Color(0xFF2B323A);
const double _kEpciSaturation = 0.50;
const double _kEpciLightness = 0.87;

EpciPalette epciPaletteFor(String label) {
  if (label.isEmpty) {
    // Pas de libellé → gris neutre slate-100. Distinct visuellement
    // d'un vrai EPCI pour signaler "non renseigné".
    return const EpciPalette(bg: Color(0xFFF2F4F6), fg: _kPastelEpciFg);
  }
  int hash = 0;
  for (final rune in label.runes) {
    hash = (hash * 31 + rune) & 0x7FFFFFFF;
  }
  // Spread sur les 360° du cercle chromatique avec un multiplicateur
  // proche de l'angle d'or (137° ≈ 137.508° / golden angle) pour que
  // deux hashes consécutifs donnent des teintes éloignées.
  final hue = ((hash * 137) % 360).toDouble();
  final hsl = HSLColor.fromAHSL(1.0, hue, _kEpciSaturation, _kEpciLightness);
  return EpciPalette(bg: hsl.toColor(), fg: _kPastelEpciFg);
}

/// Pill affichant le nom de la communauté de communes — fond coloré
/// stable par EPCI, texte slate-700.
///
/// Le drapeau [large] augmente le padding et la typo (16×9, fontSize
/// 14) pour les contextes où le badge accompagne un titre imposant
/// (ex. preview du bloc Bénéficiaire dans la fiche dossier). La taille
/// par défaut (12×6, fontSize 12) reste utilisée dans la liste "Mes
/// dossiers" pour ne pas alourdir le tableau.
class EpciBadge extends StatelessWidget {
  const EpciBadge({
    super.key,
    required this.label,
    this.maxWidth = 220,
    this.large = false,
  });
  final String label;
  final double maxWidth;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final palette = epciPaletteFor(label);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: large
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 9)
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: palette.bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // Refonte 2026-05-13 : Nunito w600 — aligné sur les autres
          // titres / badges de page de l'app.
          style: GoogleFonts.nunito(
            fontSize: large ? 14 : 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
            color: palette.fg,
          ),
        ),
      ),
    );
  }
}
