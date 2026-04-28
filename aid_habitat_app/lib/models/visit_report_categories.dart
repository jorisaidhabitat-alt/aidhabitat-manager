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

/// Tag fourre-tout — photos de la visite qui ne tombent dans aucune
/// des autres catégories (anomalies, détail particulier, etc.).
const String kPhotoTagAutres = 'Visite - Autres';

/// Tous les tags photos visite réunis pour faciliter le filtrage
/// dans DocumentsScreen et l'onglet Photos. L'ordre détermine l'ordre
/// d'affichage des sections dans l'UI :
///   ligne 1 : Logement / Accessibilité / Sanitaires
///   ligne 2 : Plan avant / Plan après / Autres
const List<String> kVisitPhotoTags = [
  kPhotoTagLogement,
  kPhotoTagAccessibilite,
  kPhotoTagSanitaires,
  kPhotoTagPlanAvant,
  kPhotoTagPlanApres,
  kPhotoTagAutres,
];

/// Nombre max de photos utilisées par le PDF dans chaque catégorie.
/// Au-delà, les photos restent en base mais sont marquées « non
/// utilisées dans le rapport » (pastille rouge `+` sur la tile).
/// Les 3 catégories de la 2e ligne (plans + autres) n'ont pas de
/// slot PDF — la limite est purement indicative pour l'UI.
const Map<String, int> kVisitPhotoSlotCount = {
  kPhotoTagLogement: 2,
  kPhotoTagAccessibilite: 3,
  kPhotoTagSanitaires: 3,
  // 2 slots pour Plan avant / Plan après / Autres — demande user
  // 2026-04-28 : "les deux parties plans et la partie autres
  // nécessitent seulement 2 images pas 6".
  kPhotoTagPlanAvant: 2,
  kPhotoTagPlanApres: 2,
  kPhotoTagAutres: 2,
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
