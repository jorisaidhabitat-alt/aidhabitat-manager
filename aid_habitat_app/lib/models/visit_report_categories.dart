/// Catégorisation utilisée par le générateur de rapport PDF
/// (`server/reports/generateVisitReport.mjs`).
///
/// Ce fichier centralise les constantes partagées entre :
///   - L'onglet Photos du relevé de visite (capture/tag)
///   - L'écran Documents (filtrage par tag)
///   - Le backend Express qui injecte les images dans le PDF
///
/// **Pourquoi ici plutôt qu'en dur dans chaque écran :** une seule
/// modification (renommer un tag, ajouter une catégorie) propage
/// instantanément le filtre côté UI ET le mapping côté serveur.

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

/// Tous les tags photos visite réunis pour faciliter le filtrage
/// dans DocumentsScreen et l'onglet Photos. L'ordre détermine l'ordre
/// d'affichage des sections dans l'UI.
const List<String> kVisitPhotoTags = [
  kPhotoTagLogement,
  kPhotoTagAccessibilite,
  kPhotoTagSanitaires,
];

/// Nombre max de photos utilisées par le PDF dans chaque catégorie.
/// Au-delà, les photos restent en base mais sont marquées « non
/// utilisées dans le rapport ».
const Map<String, int> kVisitPhotoSlotCount = {
  kPhotoTagLogement: 2,
  kPhotoTagAccessibilite: 3,
  kPhotoTagSanitaires: 3,
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
