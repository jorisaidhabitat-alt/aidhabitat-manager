import 'package:flutter/material.dart';

/// Canonicalise la valeur brute du champ `natureAccompagnement` (stocké
/// en minuscules côté NocoDB) vers une forme affichable. Les libellés
/// internes ("diagnostic" / "ergo" / "complet") restent inchangés côté
/// NocoDB et code — seul l'affichage utilisateur reflète la
/// terminologie métier MPA / Diag (demande utilisateur 2026-05-04).
///
///   • `diagnostic` → "Diag ergo"
///   • `ergo`       → "MPA ergo"
///   • `complet`    → "MPA complet"
///   • autre        → valeur trimmée telle quelle.
String formatAccompanimentType(String raw) {
  final v = raw.trim().toLowerCase();
  switch (v) {
    case 'diagnostic':
      return 'Diag ergo';
    case 'ergo':
      return 'MPA ergo';
    case 'complet':
      return 'MPA complet';
    default:
      return raw.trim();
  }
}

/// Palette du type d'accompagnement — 3 couleurs PASTEL distinctes,
/// utilisées partout où l'accompagnement est rendu (badge dans le
/// header de dossier / relevé de visite / documents, ET avatar du
/// bénéficiaire dans la liste « Mes dossiers » — demande utilisateur
/// 2026-05-04 : "qui serait la même sur la photo de profil").
///
/// Refonte 2026-05-04 v2 : teintes adoucies pour mieux s'intégrer à
/// la charte (violet pastel #EDE8F5 / catégories de revenu pastel
/// bleu+jaune). Demande utilisateur : "fait 3 couleurs plus pastel
/// cohérentes avec le reste de la charte graphique".
///
/// Choix des teintes :
///   • Diagnostic → ROSE PASTEL doux (`#FFE4EC` / `#A8336B`) — plus
///     léger que l'ancien rose-magenta, harmonisé avec l'ambre/jaune
///     pastel de la palette des revenus.
///   • Ergo       → VERT SAUGE PASTEL (`#E5F0D7` / `#5C7A3E`) — plus
///     doux que l'ancien vert un peu vif ; même tonalité que les
///     autres badges pastel pour une lecture sereine côte à côte.
///   • Complet    → VIOLET PASTEL (`#EDE8F5` / `#554A63`) — couleur
///     historique de la charte. Conservée telle quelle, sert de
///     pivot pour les deux autres pastels.
///   • autre / vide → gris neutre (`#F1F5F9` / `#334155`).
class AccompanimentPalette {
  final Color bg;
  final Color fg;
  const AccompanimentPalette({required this.bg, required this.fg});
}

AccompanimentPalette accompanimentPaletteFor(String raw) {
  final v = raw.trim().toLowerCase();
  if (v == 'diagnostic') {
    return const AccompanimentPalette(
      bg: Color(0xFFFFE4EC),
      fg: Color(0xFFA8336B),
    );
  }
  if (v == 'ergo') {
    return const AccompanimentPalette(
      bg: Color(0xFFE5F0D7),
      fg: Color(0xFF5C7A3E),
    );
  }
  if (v == 'complet') {
    // Teal pastel — sortie du violet `#EDE8F5` historique (demande
    // utilisateur 2026-05-04 : « pas de violet clair comme le reste de
    // l'application »). Le violet était partagé avec le fallback
    // neutre du badge revenu et le fond des avatars sidebar → plus
    // possible de distinguer un MPA complet du reste de l'UI au
    // premier coup d'œil. Le teal reste cool/professionnel sans
    // entrer en collision avec :
    //   - Diagnostic (rose poudré)
    //   - Ergo       (vert sauge)
    //   - ANAH déjà fait (vert pomme)  — saturation différente, vert
    //                                    moins pastel
    //   - Income Très modeste (bleu acier) — bleu vs teal distincts
    return const AccompanimentPalette(
      bg: Color(0xFFCCEFE8),
      fg: Color(0xFF1F6F66),
    );
  }
  // Fallback neutre quand le dossier n'a pas (encore) de type
  // d'accompagnement renseigné. Visuellement discret, n'attire pas
  // l'œil — l'ergo sait qu'il faut compléter le champ.
  return const AccompanimentPalette(
    bg: Color(0xFFF1F5F9),
    fg: Color(0xFF334155),
  );
}

/// Badge "type d'accompagnement" (ex. "Complet", "Diagnostic ergo",
/// "Ergo") — couleur dérivée du type via [accompanimentPaletteFor]
/// pour que rose ↔ Diagnostic, vert ↔ Ergo, violet ↔ Complet sur
/// TOUS les écrans qui affichent ce badge.
///
/// Le paramètre [large] augmente la taille (padding + typo) pour les
/// contextes où le badge apparaît à côté d'un titre imposant — en
/// particulier le header de la page d'un dossier (nom à 22pt).
class AccompanimentBadge extends StatelessWidget {
  final String value;
  final bool large;

  /// Le `value` est toujours la forme affichée ("Diagnostic ergo",
  /// "Ergo", "Complet"…). Pour récupérer la palette on a besoin de la
  /// valeur brute NocoDB (`diagnostic` / `ergo` / `complet`) — soit
  /// l'appelant la passe via [rawType], soit on la déduit du libellé
  /// affiché (cas des call-sites historiques qui ne passent que
  /// `value`). Cf. [_resolveRawType].
  final String? rawType;

  const AccompanimentBadge({
    super.key,
    required this.value,
    this.large = false,
    this.rawType,
  });

  /// Si l'appelant ne fournit pas le rawType, on inverse le mapping
  /// du `formatAccompanimentType` : "Diag ergo" / "Diagnostic ergo"
  /// → 'diagnostic', "MPA ergo" / "Ergo" → 'ergo', "MPA complet" /
  /// "Complet" → 'complet'. Tolère les anciens libellés (avant le
  /// rename MPA / Diag du 2026-05-04) ainsi que les variantes de
  /// casse, pour rester compatible avec d'éventuels textes legacy.
  String _resolveRawType() {
    if (rawType != null && rawType!.isNotEmpty) return rawType!.toLowerCase();
    final v = value.trim().toLowerCase();
    if (v.contains('diag')) return 'diagnostic';
    if (v.contains('complet')) return 'complet';
    if (v.contains('ergo')) return 'ergo';
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final palette = accompanimentPaletteFor(_resolveRawType());
    return Container(
      padding: large
          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 7)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: large ? 14 : 12,
          fontWeight: FontWeight.w700,
          color: palette.fg,
        ),
      ),
    );
  }
}

/// Palette unique par catégorie de revenu utilisée partout dans
/// l'app (dossier, relevé de visite, liste des dossiers). La couleur
/// de fond ET la couleur de typo dépendent de la catégorie. Mise à
/// jour 2026-05-04 : 4 catégories ANAH désormais explicitement
/// couleur-codées (avant : Intermédiaire et Supérieur tombaient sur
/// le fallback violet).
///   • Très modeste → fond bleu clair,   typo bleu acier
///   • Modeste      → fond jaune clair,  typo orange brûlé
///   • Intermédiaire→ fond violet pastel,typo violet graphite (charte)
///   • Supérieur    → fond rouge pastel, typo rouge bordeaux #8B181A
///   • inconnue     → fallback violet pastel (≈ Intermédiaire)
class IncomeCategoryPalette {
  final Color bg;
  final Color fg;
  const IncomeCategoryPalette({required this.bg, required this.fg});
}

IncomeCategoryPalette incomePaletteFor(String value) {
  final v = value.trim().toLowerCase();
  // Ordre important : "très modeste" doit être testé AVANT "modeste"
  // (sinon `contains('modeste')` capture les deux). Idem "supérieur"
  // avant le fallback.
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
  if (v.contains('supérieur') || v.contains('superieur')) {
    // Bordeaux pastel : version éclaircie de `#8B181A` (HSL L décalé
    // ~32 % → ~86 %). Le fond reste discret tout en signalant un
    // foyer hors plafonds ANAH ; le texte conserve la teinte
    // d'origine pour bien lire et garder le sens « rouge » fort.
    return const IncomeCategoryPalette(
      bg: Color(0xFFF5D6D6),
      fg: Color(0xFF8B181A),
    );
  }
  if (v.contains('intermédiaire') || v.contains('intermediaire')) {
    return const IncomeCategoryPalette(
      bg: Color(0xFFEDE8F5),
      fg: Color(0xFF554A63),
    );
  }
  // Fallback neutre : catégorie inconnue → violet doux (identique à
  // Intermédiaire, n'attire pas l'œil).
  return const IncomeCategoryPalette(
    bg: Color(0xFFEDE8F5),
    fg: Color(0xFF554A63),
  );
}

/// Badge "catégorie de revenu" (Très modeste, Modeste, Intermédiaire…).
/// Utilise la palette unifiée [incomePaletteFor] pour que le même
/// libellé ait toujours la même couleur où qu'il apparaisse.
///
/// Le paramètre [large] augmente la taille (padding + typo) pour les
/// contextes où le badge apparaît à côté d'un titre imposant — en
/// particulier le header de la page d'un dossier (nom à 22pt).
class IncomeCategoryBadge extends StatelessWidget {
  final String value;
  final bool large;

  /// Variante sans couleur : fond gris neutre (slate-100), texte
  /// gris foncé. Utilisée dans la liste « Mes dossiers » où le badge
  /// doit rester discret pour ne pas concurrencer les autres
  /// informations affichées.
  final bool monochrome;

  const IncomeCategoryBadge({
    super.key,
    required this.value,
    this.large = false,
    this.monochrome = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = incomePaletteFor(value);
    final bg = monochrome ? const Color(0xFFF1F5F9) : palette.bg;
    final fg = monochrome ? const Color(0xFF334155) : palette.fg;
    return Container(
      padding: large
          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 7)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: large ? 14 : 12,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

/// Pastille « État du compte ANAH » — affichée dans le header du relevé
/// de visite (top-right). Demande utilisateur 2026-05-04 : permettre à
/// l'ergo de voir d'un coup d'œil l'avancement du dossier ANAH sans
/// devoir ouvrir l'onglet Bénéficiaire.
///
/// Couleurs en accord avec la sémantique :
///   • « Déjà fait »  → vert  (terminé, action OK)
///   • « A vérifier » → ambre (action en attente)
///   • « A faire »    → rouge (action requise)
///   • autre / vide   → ne s'affiche pas (caller filtre via isEmpty)
class AnahStatusBadge extends StatelessWidget {
  final String status;
  final bool large;

  const AnahStatusBadge({
    super.key,
    required this.status,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    final v = status.trim().toLowerCase();
    Color bg;
    Color fg;
    String label;
    if (v == 'déjà fait' || v == 'deja fait') {
      bg = const Color(0xFFD1F4DC); // vert clair
      fg = const Color(0xFF137333); // vert foncé
      label = 'ANAH déjà fait';
    } else if (v == 'a vérifier' || v == 'a verifier') {
      bg = const Color(0xFFFEF3C7); // ambre clair
      fg = const Color(0xFFB45309); // ambre foncé
      label = 'ANAH à vérifier';
    } else if (v == 'a faire') {
      bg = const Color(0xFFFEE2E2); // rouge clair
      fg = const Color(0xFFB91C1C); // rouge foncé
      label = 'ANAH à faire';
    } else {
      // Statut inconnu — affichage neutre (rare, mais on évite un
      // crash silencieux si la donnée est corrompue).
      bg = const Color(0xFFF1F5F9);
      fg = const Color(0xFF334155);
      label = 'ANAH ${status.trim()}';
    }
    return Container(
      padding: large
          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 7)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: large ? 14 : 12,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}
