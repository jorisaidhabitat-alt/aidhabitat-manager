import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

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
  // 'complet' OU valeur vide / non-reconnue → palette Complet (teal
  // pastel). Demande utilisateur 2026-05-04 : « tout doit avoir un
  // type d'accompagnement, pas de gris "(inconnue)" ». Un dossier
  // sans type renseigné est visuellement traité comme MPA complet ;
  // la validation pré-génération PDF (cf. `_checkBeneficiaryAdmin`
  // dans visit_report_screen.dart) flagge le champ vide pour que
  // l'ergo le complète au prochain rapport.
  return const AccompanimentPalette(
    bg: Color(0xFFCCEFE8),
    fg: Color(0xFF1F6F66),
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
    // Refonte 2026-05-13 : variante `large` alignée sur AnahStatusBadge
    // et le bouton « Générer » du header (13px w600, padding 14×6).
    return Container(
      padding: large
          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value,
        // Refonte 2026-05-13 : Nunito w800 pour plus de poids visuel
        // sur les badges du header (Quicksand plafonne à w700).
        style: GoogleFonts.nunito(
          fontSize: large ? 13 : 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: palette.fg,
        ),
      ),
    );
  }
}

/// Palette unique par catégorie de revenu utilisée partout dans
/// l'app (dossier, relevé de visite, liste des dossiers). 4 catégories
/// ANAH explicitement couleur-codées — chaque dossier doit retomber
/// sur l'une d'elles (le serveur calcule `categorie_revenu_calculee`
/// à partir de `numberPeople` × `fiscalRevenue` via les barèmes ANAH,
/// puis tombe sur 'Modeste' si le RFR n'a jamais été saisi — cf.
/// `mapPatient` dans server/index.mjs ligne 1675).
///
/// Demande utilisateur 2026-05-04 : « il ne doit pas y avoir
/// d'(inconnue), tout doit être catégorisé ». Le fallback final reste
/// la couleur d'Intermédiaire (violet pastel charte) — pas une 5e
/// teinte « inconnue » distincte — pour qu'un dossier mal-typé soit
/// visuellement traité comme Intermédiaire le temps que la donnée
/// soit corrigée côté NocoDB.
///
///   • Très modeste → fond bleu clair,    typo bleu acier
///   • Modeste      → fond jaune clair,   typo orange brûlé
///   • Intermédiaire→ fond violet pastel, typo violet graphite (charte)
///   • Supérieur    → fond rouge pastel,  typo rouge bordeaux #8B181A
class IncomeCategoryPalette {
  final Color bg;
  final Color fg;
  const IncomeCategoryPalette({required this.bg, required this.fg});
}

IncomeCategoryPalette incomePaletteFor(String value) {
  final v = value.trim().toLowerCase();
  // Ordre important : "très modeste" doit être testé AVANT "modeste"
  // (sinon `contains('modeste')` capture les deux).
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
  // `intermédiaire` OU valeur vide / non-reconnue → palette
  // Intermédiaire (violet pastel charte). Visuellement un dossier
  // mal-typé sera traité comme Intermédiaire ; la donnée reste à
  // corriger côté NocoDB mais l'UI ne montre jamais d'« inconnue ».
  return const IncomeCategoryPalette(
    bg: Color(0xFFEDE8F5),
    fg: Color(0xFF554265),
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
    final bg = monochrome ? const Color(0xFFF2F4F6) : palette.bg;
    final fg = monochrome ? const Color(0xFF2B323A) : palette.fg;
    // Refonte 2026-05-13 : variante `large` alignée sur AnahStatusBadge
    // et le bouton « Générer » du header (13px w600, padding 14×6).
    return Container(
      padding: large
          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value,
        // Refonte 2026-05-13 : Nunito w800 (cf. AccompanimentBadge).
        style: GoogleFonts.nunito(
          fontSize: large ? 13 : 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
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
    // Refonte 2026-05-13 (visit-pages.js `.vp-anah` lignes 230-235) :
    // couleurs sémantiques canoniques du design system.
    if (v == 'déjà fait' || v == 'deja fait') {
      bg = const Color(0xFFE6F4EA); // done : vert pâle
      fg = const Color(0xFF1F7A3A); // done : vert texte
      label = 'Anah · déjà fait';
    } else if (v == 'a vérifier' || v == 'a verifier') {
      bg = const Color(0xFFFFF4E2); // check : orange pâle
      fg = const Color(0xFFA66700); // check : orange texte
      label = 'Anah · à vérifier';
    } else if (v == 'a faire') {
      bg = const Color(0xFFFDEAEA); // todo : rouge pâle
      fg = const Color(0xFFA6371F); // todo : rouge texte
      label = 'Anah · à faire';
    } else {
      // Statut inconnu — affichage neutre.
      bg = const Color(0xFFF2F4F6); // ink-100
      fg = const Color(0xFF2B323A); // ink-700
      label = 'Anah · ${status.trim()}';
    }
    return Container(
      padding: large
          ? const EdgeInsets.symmetric(horizontal: 14, vertical: 6)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        // Refonte 2026-05-13 : Nunito w800 (cf. AccompanimentBadge).
        style: GoogleFonts.nunito(
          fontSize: large ? 13 : 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: fg,
        ),
      ),
    );
  }
}
