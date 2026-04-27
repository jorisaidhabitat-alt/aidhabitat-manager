import 'package:flutter/material.dart';

/// Palettes pastel partagées entre `DossiersListScreen` et
/// `DashboardScreen` — le même bénéficiaire (via hash de ses initiales) et
/// la même communauté de communes doivent garder leur couleur à travers
/// tous les écrans de l'app.

// ---------------------------------------------------------------------------
// Avatar bénéficiaire — mint / pêche / ciel
// ---------------------------------------------------------------------------

const List<Color> kBeneficiaryAvatarBgs = [
  Color(0xFFB8DDCC), // mint
  Color(0xFFF4D5C4), // pêche
  Color(0xFFCFE3F0), // ciel
];

const Color kBeneficiaryAvatarFg = Color(0xFF554A63);

Color beneficiaryAvatarBgFor(String seed) {
  if (seed.isEmpty) return kBeneficiaryAvatarBgs.first;
  int hash = 0;
  for (final rune in seed.runes) {
    hash = (hash * 31 + rune) & 0x7FFFFFFF;
  }
  return kBeneficiaryAvatarBgs[hash % kBeneficiaryAvatarBgs.length];
}

// ---------------------------------------------------------------------------
// Communauté de communes (EPCI) — 5 pastels : mint, pêche, ciel, lavande,
// sable. Même EPCI = même couleur à chaque rendu (hash du label).
// ---------------------------------------------------------------------------

class EpciPalette {
  final Color bg;
  final Color fg;
  const EpciPalette({required this.bg, required this.fg});
}

const Color _kPastelEpciFg = Color(0xFF334155);

const List<EpciPalette> kEpciPalettes = [
  EpciPalette(bg: Color(0xFFC8E6D0), fg: _kPastelEpciFg), // mint
  EpciPalette(bg: Color(0xFFF5D6B8), fg: _kPastelEpciFg), // pêche
  EpciPalette(bg: Color(0xFFD9EAF3), fg: _kPastelEpciFg), // ciel
  EpciPalette(bg: Color(0xFFE8E2F0), fg: _kPastelEpciFg), // lavande
  EpciPalette(bg: Color(0xFFF0E4CC), fg: _kPastelEpciFg), // sable
];

EpciPalette epciPaletteFor(String label) {
  if (label.isEmpty) {
    return const EpciPalette(
      bg: Color(0xFFF1F5F9),
      fg: _kPastelEpciFg,
    );
  }
  int hash = 0;
  for (final rune in label.runes) {
    hash = (hash * 31 + rune) & 0x7FFFFFFF;
  }
  return kEpciPalettes[hash % kEpciPalettes.length];
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
          style: TextStyle(
            fontSize: large ? 14 : 12,
            fontWeight: FontWeight.w700,
            color: palette.fg,
          ),
        ),
      ),
    );
  }
}
