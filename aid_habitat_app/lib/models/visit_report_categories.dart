// Catégorisation utilisée par le générateur de rapport PDF
// (`server/reports/generateVisitReport.mjs`).
//
// Ce fichier centralise les constantes partagées entre :
//   - L'onglet Photos du relevé de visite (capture/tag)
//   - L'écran Documents (filtrage par tag)
//   - Le backend Express qui injecte les images dans le PDF
//
// Pourquoi ici plutôt qu'en dur dans chaque écran : une seule
// modification (renommer un tag, ajouter une catégorie) propage
// instantanément le filtre côté UI ET le mapping côté serveur.

// ---------------------------------------------------------------------------
// Tags des photos prises pendant la visite
// ---------------------------------------------------------------------------

/// Tag attribué aux photos générales du logement (vue extérieure,
/// pièces principales). Maps vers les slots PDF `logement` /
/// `logement2` (page 8, max 2 photos paysage 256×202pt).
const String kPhotoTagLogement = 'Visite - Logement';

/// Tag attribué aux photos d'accessibilité (entrée, escaliers,
/// circulations). Maps vers les slots PDF `acces1` / `acces2` /
/// `acces3` (page 8, max 3 photos portrait 153×191pt).
const String kPhotoTagAccessibilite = 'Visite - Accessibilité';

/// Tag attribué aux photos des sanitaires (douche, baignoire, WC).
/// Maps vers les slots PDF `sani1` / `sani2` / `sani3` (page 8,
/// max 3 photos portrait 153×191pt).
const String kPhotoTagSanitaires = 'Visite - Sanitaires';

/// Tag attribué aux clichés/photos du plan du logement avant travaux
/// (croquis main, plan archi existant, photo d'un plan papier…).
/// Catégorie d'organisation pour l'ergo — pas de slot PDF dédié dans
/// le rapport actuel, mais vit dans l'onglet Photos pour ne pas
/// polluer l'espace Documents général.
const String kPhotoTagPlanAvant = 'Visite - Plan avant';

/// Tag attribué aux clichés/photos du plan des travaux préconisés
/// (croquis ergo, plan modifié, mockup). Pareil que [kPhotoTagPlanAvant] :
/// catégorie d'organisation, pas de slot PDF dédié.
const String kPhotoTagPlanApres = 'Visite - Plan après';

/// Tag fourre-tout (LEGACY) — retiré de l'UI 2026-05-04 (demande
/// utilisateur : « supprime la partie autres, elle est inutile »).
/// La constante reste exportée pour ne pas casser le mapping des
/// anciens dossiers qui auraient encore des photos taggées « Autres » ;
/// elles seront simplement filtrées et n'apparaîtront plus dans
/// l'onglet Photos.
const String kPhotoTagAutres = 'Visite - Autres';

/// Tag MAGIQUE (commence par `__`) — quand présent sur une photo
/// visite, le générateur PDF n'affiche PAS l'overlay de titre en
/// haut de la photo dans le rapport (page 8 / pages 9-10). Permet
/// à l'ergo de masquer ponctuellement le label sur certains clichés
/// (ex. photo « pure » sans légende voulue) sans perdre le `title`
/// éditable côté app. Ne pas afficher dans les UIs qui listent les
/// tags humains (filtré par préfixe `__`).
const String kPhotoTagPdfNoLabel = '__pdf_no_label';

/// Tous les tags photos visite réunis pour faciliter le filtrage
/// dans DocumentsScreen et l'onglet Photos. Ordre = ordre des
/// catégories proposées au choix dans le menu « Ajouter une partie » :
///   Logement / Accessibilité / Sanitaires / Plan avant / Plan après
const List<String> kVisitPhotoTags = [
  kPhotoTagLogement,
  kPhotoTagAccessibilite,
  kPhotoTagSanitaires,
  kPhotoTagPlanAvant,
  kPhotoTagPlanApres,
];

/// Variante incluant le tag legacy `Autres` — utilisée UNIQUEMENT pour
/// purger côté DocumentsScreen les anciennes photos de visite (qu'on
/// ne veut pas voir réapparaître dans la grille générale). Ne pas
/// utiliser pour l'affichage dans l'onglet Photos.
const List<String> kVisitPhotoTagsIncludingLegacy = [
  ...kVisitPhotoTags,
  kPhotoTagAutres,
];

/// Nombre max de photos utilisées par le PDF dans chaque catégorie.
/// Au-delà, les photos restent en base mais sont marquées « non
/// utilisées dans le rapport » (pastille rouge `+` sur la tile).
/// Les catégories Plan avant / Plan après n'ont pas de slot PDF dédié
/// dans le rapport actuel — la limite est purement indicative pour
/// l'UI.
const Map<String, int> kVisitPhotoSlotCount = {
  kPhotoTagLogement: 2,
  kPhotoTagAccessibilite: 3,
  kPhotoTagSanitaires: 3,
  kPhotoTagPlanAvant: 2,
  kPhotoTagPlanApres: 2,
};

/// Libellé court pour l'UI (sans le préfixe « Visite - »).
String visitPhotoTagShortLabel(String tag) {
  switch (tag) {
    case kPhotoTagLogement:
      return 'Logement';
    case kPhotoTagAccessibilite:
      return 'Accessibilité';
    case kPhotoTagSanitaires:
      return 'Sanitaires';
    case kPhotoTagPlanAvant:
      return 'Plan avant travaux';
    case kPhotoTagPlanApres:
      return 'Plan travaux préconisés';
    case kPhotoTagAutres:
      // Legacy — ne devrait plus s'afficher dans l'onglet Photos
      // (catégorie retirée 2026-05-04), mais on garde le label au
      // cas où une vue legacy l'utilise.
      return 'Autres';
    default:
      return tag;
  }
}

// ---------------------------------------------------------------------------
// Phase d'un dessin de plan (avant / après travaux)
// ---------------------------------------------------------------------------

/// Phase d'un dessin de l'onglet Plans — détermine dans quel
/// emplacement du PDF (page 9 « avant travaux » ou page 10 « après
/// travaux ») le plan sera injecté lors de la génération du rapport.
enum PlanPhase {
  /// Plan du logement avant aménagements — slots `plan avt_af_image`
  /// et `plan avt1_af_image` (page 9 du PDF).
  avant,

  /// Plan des travaux préconisés — slots `plan apt_af_image` et
  /// `plan apt1_af_image` (page 10 du PDF).
  apres,
}

/// Sérialisation pour la colonne `note_pages.plan_phase` (SQLite +
/// NocoDB). On utilise les chaînes ASCII `'avant'` et `'apres'`
/// (sans accent) pour éviter les soucis d'encodage entre stockages.
String? planPhaseToDb(PlanPhase? phase) {
  switch (phase) {
    case PlanPhase.avant:
      return 'avant';
    case PlanPhase.apres:
      return 'apres';
    case null:
      return null;
  }
}

PlanPhase? planPhaseFromDb(String? raw) {
  switch (raw) {
    case 'avant':
      return PlanPhase.avant;
    case 'apres':
    case 'après':
      return PlanPhase.apres;
    default:
      return null;
  }
}

/// Libellé affiché à l'utilisateur — accent gardé.
String planPhaseLabel(PlanPhase phase) {
  switch (phase) {
    case PlanPhase.avant:
      return 'Avant travaux';
    case PlanPhase.apres:
      return 'Après travaux';
  }
}
