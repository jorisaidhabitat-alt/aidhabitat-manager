// Génère un rapport de visite PDF en remplissant les champs AcroForm
// du template `server/templates/visitReport.template.pdf` avec les
// données du dossier (récupérées depuis NocoDB).
//
// Approche choisie (cf. discussion projet) : on n'écrase JAMAIS le
// PDF original au rendu — on remplit juste les champs nommés via
// pdf-lib puis on aplatit (form.flatten()). La fidélité visuelle au
// pixel près est garantie, aucune police n'est resubstituée.
//
// Couverture POC actuelle (chunk 4.1) : ~10 champs page 1 + page 3
// pour valider la chaîne. L'extension aux 130 champs (logement,
// sanitaires, photos, plans, recommandations) viendra en chunk 4.2.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  PDFDocument,
  PDFTextField,
  PDFCheckBox,
  PDFRadioGroup,
  PDFDropdown,
  PDFButton,
  PDFName,
  StandardFonts,
  pushGraphicsState,
  popGraphicsState,
  rectangle,
  clip,
  endPath,
  rgb,
} from 'pdf-lib';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_TEMPLATE_PATH = path.resolve(
  __dirname,
  '../templates/visitReport.template.pdf',
);
const MAPPING_PATH = path.resolve(
  __dirname,
  '../templates/visitReport.mapping.json',
);

/**
 * Mapping ergothérapeute → chemin du PDF template dédié. La clé est
 * normalisée (lowercase + sans diacritiques) sur le prénom de l'ergo
 * dans NocoDB. Les ergos sans entrée explicite tombent sur
 * `DEFAULT_TEMPLATE_PATH` (Christelle = template historique).
 *
 * Convention de nommage : `visitReport.<prénom>.pdf` dans
 * `server/templates/`. Pour ajouter un ergo, drop le fichier + ajouter
 * une ligne ici.
 */
const ERGO_TEMPLATE_MAP = {
  // 'christelle' utilise le template par défaut (pas besoin d'entrée)
  coralie: path.resolve(
    __dirname,
    '../templates/visitReport.coralie.pdf',
  ),
};

/**
 * Normalise une chaîne pour le lookup `ERGO_TEMPLATE_MAP` : lowercase,
 * retire les diacritiques (accents), trim. Tolère les variantes
 * d'encoding NFC/NFD et les casses incohérentes côté NocoDB.
 */
function normalizeErgoKey(raw) {
  return String(raw || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .trim();
}

/**
 * Résout le PDF template à utiliser pour un dossier donné, en se
 * basant sur le prénom de l'ergothérapeute. Sources de candidats
 * essayées dans l'ordre :
 *   1. `dossier.ergo.firstName` / `prenom` / `name` / `label` (objet
 *      ergo embarqué — pas toujours présent dans la payload).
 *   2. `dossier.ergoId` — string label défini côté NocoDB
 *      (`dossiers.ergo_id`), souvent égal au prénom de l'ergo
 *      (« Coralie », « Christelle », …). C'est ce que renvoie
 *      `getDossiersForApp` aujourd'hui pour la VAD.
 *   3. `dossier.assignedErgoLabel` (alias historique).
 *
 * Sans cette extension #2, un dossier avec `ergoId='Coralie'` mais
 * sans objet `ergo` populé tombait sur `DEFAULT_TEMPLATE_PATH`
 * (Christelle) — bug reporté 2026-04-29 : « j'ai généré un rapport
 * depuis le compte de Coralie et ça m'a quand meme mis les
 * coodonnées de Christelle sur le rapport ».
 *
 * Fallback sur `DEFAULT_TEMPLATE_PATH` si aucun candidat ne matche
 * une entrée d'`ERGO_TEMPLATE_MAP` (ergo non encore configuré).
 *
 * Cette résolution se fait à chaque appel (pas cachée par dossier)
 * pour rester réactive aux changements d'attribution d'ergo.
 */
function resolveTemplatePath(dossier) {
  const ergo = dossier?.ergo;
  const candidates = [
    ergo?.firstName,
    ergo?.prenom,
    ergo?.name,
    ergo?.label,
    dossier?.ergoId,
    dossier?.assignedErgoLabel,
  ];
  for (const candidate of candidates) {
    const key = normalizeErgoKey(candidate);
    if (key && ERGO_TEMPLATE_MAP[key]) {
      return ERGO_TEMPLATE_MAP[key];
    }
  }
  return DEFAULT_TEMPLATE_PATH;
}

// ---------------------------------------------------------------------------
// Adresse Aid'Habitat — utilisée à 2 endroits dans le rapport :
//
//   - Page 1 (couverture) : texte hardcodé par Affinity Publisher dans
//     le PDF. Pas un champ de formulaire → on le masque + redessine
//     dynamiquement (cf. `applyErgoContactOverlay` plus bas).
//
//   - Page 3 (renseignements ergothérapeute) : champ AcroForm `adresse`
//     pré-rempli avec l'ancienne valeur. Override simple via le
//     mapping JSON qui pointe sur `constants.ergoAddressOneLine`.
//
// Quand l'adresse change, on modifie juste cet objet — les deux
// emplacements suivent automatiquement. Coordonnées page 1 trouvées
// avec `pdftotext -bbox-layout` ; ajuster les `line1.y` / `line2.y` /
// `mask.y` si la mise en page bouge à un futur ré-export Affinity.
// ---------------------------------------------------------------------------

/// Coordonnées de l'ergothérapeute injectées dans les champs AcroForm
/// du template (page 3, champ `adresse` notamment). `page3OneLine`
/// reste exposé via `view.constants.ergoAddressOneLine` pour le mapping
/// JSON.
///
/// Note : le bloc page 1 (overlay peach + redessin du texte adresse)
/// a été supprimé en avril 2026 — l'adresse est désormais correcte
/// directement dans le PDF source Affinity Publisher (les 2 templates
/// Christelle + Coralie partagent la même adresse Aid'Habitat). Plus
/// besoin de patch côté pdf-lib.
const ERGO_CONTACT = {
  page3OneLine: '16 rue Léo Lagrange, 35131 Chartres-de-Bretagne',
};

/// Cache mémoire des bytes de PDF templates, keyed par chemin absolu.
/// Chaque template fait ~2,7 Mo — on évite la relecture disque à chaque
/// génération. Cache invalidé au redémarrage du process Node (=
/// nouveau deploy Vercel), donc pas besoin de TTL explicite.
const templateBytesCache = new Map();
let cachedMapping = null;

/**
 * Charge le template PDF (par chemin) + le mapping JSON. Le mapping
 * est partagé entre tous les templates (même structure AcroForm).
 */
async function loadTemplate(templatePath = DEFAULT_TEMPLATE_PATH) {
  if (!templateBytesCache.has(templatePath)) {
    templateBytesCache.set(templatePath, await fs.readFile(templatePath));
  }
  if (!cachedMapping) {
    const mappingRaw = await fs.readFile(MAPPING_PATH, 'utf8');
    cachedMapping = JSON.parse(mappingRaw);
  }
  return {
    templateBytes: templateBytesCache.get(templatePath),
    mapping: cachedMapping,
  };
}

/**
 * Lookup d'un chemin dotted ('patient.firstName') dans un payload.
 * Renvoie undefined si une portion du chemin manque.
 */
function getByPath(obj, dotted) {
  if (!obj || !dotted) return undefined;
  return dotted.split('.').reduce((acc, key) => {
    if (acc == null) return undefined;
    return acc[key];
  }, obj);
}

/**
 * Convertit une date ISO (`2024-07-22`) ou un timestamp en `JJ/MM/AAAA`.
 * Renvoie '' si la date est vide / invalide — pas de chaîne d'erreur
 * affichée dans le PDF, on préfère un champ vide.
 */
function formatFrenchDate(raw) {
  if (raw == null || raw === '') return '';
  const date = new Date(raw);
  if (Number.isNaN(date.getTime())) return '';
  const dd = String(date.getUTCDate()).padStart(2, '0');
  const mm = String(date.getUTCMonth() + 1).padStart(2, '0');
  const yyyy = date.getUTCFullYear();
  return `${dd}/${mm}/${yyyy}`;
}

/**
 * Remplace les caractères non-WinAnsi par des équivalents ASCII.
 *
 * Pourquoi : la police par défaut des formulaires AcroForm exportés
 * par Affinity Publisher est encodée en WinAnsi (CP-1252). pdf-lib,
 * lors du flatten, regénère les appearances en passant par cette
 * police — et bloque sur les caractères Unicode hors plage. Les
 * accents français passent (ils SONT dans WinAnsi), mais pas ≤, …,
 * tirets cadratins, etc. Plutôt que d'embarquer une police Unicode
 * (~800 Ko de bundle), on dégrade ces caractères en équivalents ASCII
 * lisibles. Acceptable pour un rapport ergothérapie.
 */
function sanitizeForPdfFont(text) {
  if (text == null) return '';
  return String(text)
    .replace(/≤/g, '<=')
    .replace(/≥/g, '>=')
    .replace(/÷/g, '/')
    .replace(/…/g, '...')
    .replace(/[—–]/g, '-')
    .replace(/[“”„]/g, '"')
    .replace(/[‘’‚]/g, "'")
    .replace(/•/g, '*')
    .replace(/·/g, '·')
    .replace(/→/g, '->')
    .replace(/±/g, '+/-')
    .replace(/[′″]/g, "'");
}

/**
 * Aplatit une zone de description multi-occupant (Contexte de vie page
 * 4 du PDF) en un bloc de texte lisible. Évite les libellés vides et
 * les sauts de ligne triples.
 */
function joinNonEmpty(lines, separator = '\n') {
  return lines.map((line) => String(line || '').trim()).filter(Boolean).join(separator);
}

/**
 * Marqueur zero-width space utilisé côté Flutter (accessibility_tab) pour
 * préserver l'état "Localisé sans texte" dans `volets_*_localisation`.
 * Côté PDF on l'enlève avant affichage (sinon vide visuel suffit).
 */
const VOLETS_LOCALIZED_MARKER = '​';

/**
 * Format ligne unique pour un type de volet — entrée :
 *   - status : 'Aucun' (entier=false, loc=='') / 'Entier' (entier=true)
 *             / 'Localisé' (entier=false, loc!='')
 *   - loc    : description fournie par l'ergo (ou marqueur ZWSP si vide)
 * Renvoie '' si "Aucun" (on saute la ligne dans le récap), sinon
 *   "Entier" ou "Localisé : <texte>" / "Localisé" si pas de précision.
 */
function formatVoletLine(label, entier, rawLoc) {
  const loc = String(rawLoc || '').replace(VOLETS_LOCALIZED_MARKER, '').trim();
  if (entier) return `${label} : Entier`;
  if (loc) return `${label} : Localisé (${loc})`;
  // Localisé sans précision — on l'affiche pour signaler la présence,
  // mais sans valeur si l'ergo n'a pas rempli le détail.
  if (rawLoc && rawLoc.length > 0) return `${label} : Localisé`;
  return ''; // Aucun → on saute
}

/**
 * Récap textuel des champs accessibilité « extras » qui n'ont pas leur
 * propre case dans le template PDF (volets, motorisations, accès rue).
 * Injecté dans le champ `Observations1` page 5 (auparavant orphelin).
 *
 * Format compact, une ligne par valeur non-Aucun, ordre stable :
 *   Accès depuis la rue : Facile / À revoir
 *   Volets roulants manuels : Entier
 *   Volets roulants électriques : Localisé (chambres)
 *   Volets persiennes : Aucun         ← (skipped si Aucun)
 *   Porte de garage : Manuel
 *   Portail : Électrique
 *
 * Si aucune donnée pertinente, retourne '' → champ PDF vide (ce qui
 * est acceptable, page 5 le tolère sans casser la mise en page).
 */
function buildAccessExtrasText(housing) {
  const lines = [];
  // Accès depuis la rue — toujours rendu (binaire bool, sens utile dans les 2 cas).
  lines.push(`Accès depuis la rue : ${housing.easyAccess ? 'Facile' : 'À revoir'}`);
  // Volets — 3 types, on saute si Aucun.
  const v1 = formatVoletLine(
    'Volets roulants manuels',
    Boolean(housing.voletsRoulantsManuelsEntier),
    housing.voletsRoulantsManuelsLocalisation,
  );
  if (v1) lines.push(v1);
  const v2 = formatVoletLine(
    'Volets roulants électriques',
    Boolean(housing.voletsRoulantsElectriquesEntier),
    housing.voletsRoulantsElectriquesLocalisation,
  );
  if (v2) lines.push(v2);
  const v3 = formatVoletLine(
    'Volets persiennes',
    Boolean(housing.voletsPersiennesEntier),
    housing.voletsPersiennesLocalisation,
  );
  if (v3) lines.push(v3);
  // Motorisations — saute si 'Aucun' / vide.
  const garage = String(housing.motorisationPorteGarage || '').trim();
  if (garage && garage !== 'Aucun') {
    lines.push(`Porte de garage : ${garage}`);
  }
  const portail = String(housing.motorisationPortail || '').trim();
  if (portail && portail !== 'Aucun') {
    lines.push(`Portail : ${portail}`);
  }
  return lines.join('\n');
}

/** Format français concis "X cm / Y kg" — vide si rien. */
function formatHeightWeight(heightCm, weightKg) {
  const parts = [];
  if (heightCm != null && heightCm !== '') parts.push(`${heightCm} cm`);
  if (weightKg != null && weightKg !== '') parts.push(`${weightKg} kg`);
  return parts.join(' · ');
}

/**
 * Sérialise la zone "I- Environnement" de la page 4 :
 * pathologies, suivi médical, atteintes sensorielles, taille/poids.
 * On accepte aussi bien `dossier.medicalContext` (legacy) qu'un
 * tableau `medicalContextJson[]` ou `autonomy.occupants[].medical`.
 */
function buildEnvironnementText(dossier) {
  const out = [];
  // 1) cas "legacy" : un seul medicalContext aplati
  const mc = dossier?.medicalContext;
  if (mc && (mc.pathology || mc.followUp || mc.sensory || mc.heightCm || mc.weightKg)) {
    if (mc.pathology) out.push(`Pathologies : ${mc.pathology}`);
    if (mc.followUp) out.push(`Suivi médical : ${mc.followUp}`);
    if (mc.sensory) out.push(`Atteintes sensorielles : ${mc.sensory}`);
    const hw = formatHeightWeight(mc.heightCm, mc.weightKg);
    if (hw) out.push(`Mensurations : ${hw}`);
  }
  // 2) cas multi-occupants : medicalContextJson[] (forme app)
  const arr = Array.isArray(dossier?.medicalContextJson)
    ? dossier.medicalContextJson
    : [];
  arr.forEach((entry, i) => {
    const header = arr.length > 1 ? `Occupant ${i + 1}` : null;
    const lines = [];
    if (entry.pathology) lines.push(`Pathologies : ${entry.pathology}`);
    if (entry.followUp) lines.push(`Suivi médical : ${entry.followUp}`);
    if (entry.sensory) lines.push(`Atteintes sensorielles : ${entry.sensory}`);
    const hw = formatHeightWeight(entry.heightCm, entry.weightKg);
    if (hw) lines.push(`Mensurations : ${hw}`);
    if (lines.length > 0) {
      if (header) out.push(`— ${header} —`);
      out.push(...lines);
    }
  });
  return joinNonEmpty(out);
}

/**
 * Sérialise la zone "II- Habitudes de vie" de la page 4 :
 * activités d'autonomie cochées, aide humaine, points d'attention.
 */
function buildHabitudesText(dossier) {
  const out = [];
  // Forme legacy : `dossier.autonomy.checklist[]`
  const legacy = dossier?.autonomy;
  if (legacy?.checklist && Array.isArray(legacy.checklist)) {
    const done = legacy.checklist
      .filter((it) => it.checked)
      .map((it) => `• ${it.name}`);
    if (done.length > 0) {
      out.push('Autonomie observée :');
      out.push(...done);
    }
  }
  // Forme app : occupants[].autonomy[] / humanHelp[] / attention[]
  const occupants = Array.isArray(dossier?.autonomy?.occupants)
    ? dossier.autonomy.occupants
    : Array.isArray(dossier?.autonomyJson)
      ? dossier.autonomyJson
      : [];
  occupants.forEach((occ, i) => {
    const header = occupants.length > 1 ? `Occupant ${i + 1}` : null;
    const lines = [];
    const auto = (occ.autonomy || []).filter((it) => it.checked).map((it) => it.name);
    if (auto.length > 0) lines.push(`Activités autonomes : ${auto.join(', ')}`);
    const help = (occ.humanHelp || []).filter((it) => it.checked).map((it) => it.name);
    if (help.length > 0) lines.push(`Aide humaine nécessaire : ${help.join(', ')}`);
    const att = (occ.attention || []).filter((it) => it.checked).map((it) => it.name);
    if (att.length > 0) lines.push(`Points d'attention : ${att.join(', ')}`);
    if (lines.length > 0) {
      if (header) out.push(`— ${header} —`);
      out.push(...lines);
    }
  });
  return joinNonEmpty(out);
}

/**
 * Construit l'adresse complète (rue + zip + ville) sans doubler les
 * espaces. Utilisée pour le champ `Adresse` page 5 du PDF.
 */
function buildFullAddress(patient) {
  const parts = [
    String(patient?.address || '').trim(),
    [String(patient?.zipCode || '').trim(), String(patient?.city || '').trim()]
      .filter(Boolean)
      .join(' '),
  ].filter(Boolean);
  return parts.join(', ');
}

/**
 * Renvoie un nombre (entier) compatible avec le DropDown
 * "nombre d'étage" — qui n'accepte que '1', '2', '3', '4'.
 * Au-delà → '4'. Vide/null → '1'.
 */
function clampLevels(raw) {
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 1) return '1';
  if (n > 4) return '4';
  return String(Math.round(n));
}

/** Format hauteur cm utilisable dans un champ texte ("78 cm" ou ""). */
function formatHeightCm(value) {
  if (value == null || value === '') return '';
  const n = Number(value);
  if (!Number.isFinite(n)) return String(value);
  return `${n} cm`;
}

/** Pareil pour des mm/cm de largeur de porte. */
function formatWidthCm(value) {
  if (value == null || value === '') return '';
  const n = Number(value);
  if (!Number.isFinite(n)) return String(value);
  return `${n} cm`;
}

/**
 * Normalise un libellé de situation familiale renvoyé par NocoDB
 * (variants : "Marié(e)", "Mariée", "marié", …) vers le label exact
 * attendu par le PDF (`Célibataire`, `En concubinage`, `Mariée`,
 * `Veufve`, `Divorcée`). Renvoie '' si on ne reconnaît rien.
 */
function normalizeFamilySituation(raw) {
  const s = String(raw || '').trim().toLowerCase();
  if (!s) return '';
  if (s.startsWith('célib') || s.startsWith('celib')) return 'Célibataire';
  if (s.includes('concubin')) return 'En concubinage';
  if (s.startsWith('mari')) return 'Mariée';
  if (s.startsWith('veuf') || s.startsWith('veuv')) return 'Veufve';
  if (s.startsWith('divorc')) return 'Divorcée';
  return '';
}

/**
 * Idem pour le statut d'occupation : `Propriétaire` / `Locataire` /
 * `Usufruitiere` (sans accent côté PDF — c'est le nom du champ tel
 * qu'on l'a vu dans Affinity Publisher).
 */
function normalizeOccupationStatus(raw) {
  const s = String(raw || '').trim().toLowerCase();
  if (!s) return '';
  if (s.startsWith('proprié') || s.startsWith('proprie')) return 'Propriétaire';
  if (s.startsWith('locat')) return 'Locataire';
  if (s.startsWith('usufrui')) return 'Usufruitiere';
  return '';
}

/**
 * Construit un payload "view-friendly" à partir des objets passés au
 * générateur. Ajoute tous les champs dérivés (`fullNameUpper`,
 * `housing.heating.electric`, `sanitaires.sdbBaignoireHeight`, etc.)
 * que le mapping JSON peut référencer sans logique inline.
 *
 * Tous les paramètres en plus du `dossier` sont OPTIONNELS — si on
 * ne les a pas (ex. : pas de SDB renseignée), les champs PDF restent
 * vides plutôt que de bloquer la génération.
 *
 * @param {object} args
 * @param {object} args.dossier — payload brut /api/dossiers
 * @param {object} [args.sanitaires] — payload /api/diagnostic-sanitaires
 * @param {object} [args.observations] — payload /api/observations
 */
/**
 * Concatène les `textContent` de toutes les pages d'un sous-onglet
 * de la note Contexte de vie (Médical ou Autonomie). Si l'ergo a
 * plusieurs pages dans la même note, on les sépare par une ligne
 * vide. Strip les whitespaces périphériques pour éviter les blocs
 * vides en tête/fin de section dans le PDF.
 */
function joinNotePagesText(pages) {
  // Extraction du texte depuis le `drawing_json` (NotesWidget bundle
  // text + strokes en `{"text":"…","strokes":[...]}`). Fallback sur
  // `textContent` si le JSON est invalide ou si la page legacy
  // utilisait directement la colonne text. Sans ce parsing, la lecture
  // brute de `textContent` retournait toujours vide → bug reporté
  // 2026-04-29 (« Habitudes de vie et environnement dans le PDF ne
  // sont pas connectés à un espace de l'application »).
  const extractText = (pg) => {
    const drawingRaw = String(pg?.drawingJson || '');
    if (drawingRaw) {
      try {
        const decoded = JSON.parse(drawingRaw);
        if (
          decoded &&
          typeof decoded === 'object' &&
          typeof decoded.text === 'string' &&
          decoded.text.trim()
        ) {
          return decoded.text.trim();
        }
      } catch {
        // drawing_json non-JSON → on tombe sur le fallback textContent
      }
    }
    return String(pg?.textContent || '').trim();
  };
  return pages
    .map(extractText)
    .filter((s) => s.length > 0)
    .join('\n\n')
    .trim();
}

/**
 * Pour le champ "Dépendance" du PDF, on n'affiche que l'un des 4
 * mots-clés : « Aucune » / « Canne » / « Déambulateur » /
 * « Fauteuil roulant ». Tout ce qui n'est pas l'un de ces 3 derniers
 * (vide, "Non" legacy NocoDB, texte libre non-classifiable…) ⇒
 * « Aucune ».
 *
 * Pourquoi : côté Flutter, sélectionner « Aucune » dans la pill list
 * stocke `dependenceTxt = ''` (cf. beneficiary_tab.dart). Et certaines
 * lignes NocoDB historiques gardent « Non » dans
 * `dependance_particuliere_txt`. Avant ce fix, ces deux cas
 * affichaient soit du vide, soit littéralement « Non » dans le PDF —
 * confusant car « Aucune » est l'option par défaut visible dans l'app.
 */
function normalizeDependenceForReport(raw) {
  const text = String(raw || '').trim();
  const positives = ['Canne', 'Déambulateur', 'Fauteuil roulant'];
  if (text) {
    const lc = text.toLowerCase();
    for (const opt of positives) {
      if (lc.includes(opt.toLowerCase())) return opt;
    }
  }
  // Vide, "Aucune", "Non", ou texte non-classifiable → on affiche
  // « Aucune » (canonique, équivalent à la pill par défaut Flutter).
  return 'Aucune';
}

function buildViewModel({
  dossier,
  sanitaires,
  observations,
  contexteNotes = [],
  caisseComplementaireResolved = null,
}) {
  const patient = dossier?.patient || {};
  const housing = dossier?.housing || {};
  const firstName = String(patient.firstName || '').trim();
  const lastName = String(patient.lastName || '').trim();

  // Affichage de l'aide à domicile : si l'ergo a saisi du texte, on
  // « Aide à domicile » : binaire pur — Oui/Non (demande utilisateur,
  // « met simplement oui ou non »). On IGNORE désormais le texte
  // détaillé (ex. « aide-ménagère 2h/sem ») : il pollue la ligne du
  // PDF et l'ergo veut une réponse courte. Le détail reste consultable
  // dans NocoDB pour les besoins administratifs.
  const homeHelp = Boolean(patient.homeHelp);
  const homeHelpDisplay = homeHelp ? 'Oui' : 'Non';

  // Reconnaissance MDPH (demande utilisateur 2026-04-29 v2) :
  //   - case cochée + texte (ex. « 80 % »)        → texte tel quel
  //   - case cochée sans détail                    → 'Oui'
  //   - case décochée                              → 'Non' systématique
  //
  // V1 du fix : `invalidityTxt || (invalidity ? 'Oui' : 'Non')` —
  // problème quand le user a coché puis décoché : `invalidityTxt`
  // gardait l'ancienne valeur en NocoDB (le côté Flutter ne le wipe
  // pas toujours), donc on lisait « Inférieur à 50 % » alors que
  // `invalidity = false`. Maintenant on regarde D'ABORD `invalidity`
  // et on n'utilise `invalidityTxt` QUE si la case est cochée — le
  // champ texte legacy ne peut plus polluer un statut « non MDPH ».
  const invalidityTxt = String(patient.invalidityTxt || '').trim();
  // `Boolean()` gère true/1/"true" comme truthy. Si NocoDB stocke
  // "false" en string, `Boolean('false')` est true (piège classique
  // JS), donc on ajoute un check explicite — symptôme précédemment
  // observé sur d'autres champs bool stockés en string par NocoDB.
  const invalidity = patient.invalidity === true
      || patient.invalidity === 1
      || patient.invalidity === '1'
      || patient.invalidity === 'true';
  const invalidityDisplay = invalidity
      ? (invalidityTxt || 'Oui')
      : 'Non';

  // Dates de naissance : on utilise les variantes Mr/Mme dédiées
  // (mapPatient les expose déjà). `patient.birthDate` fallback sur
  // madame dans certains dossiers — on l'évite pour bien remplir
  // chaque slot du PDF.
  const birthDateMrFr = formatFrenchDate(
    patient.birthDateMr || patient.occupant1BirthDate || patient.birthDate,
  );
  const birthDateMmeFr = formatFrenchDate(
    patient.birthDateMme || patient.occupant2BirthDate,
  );

  // --- Page 5 : Logement ---
  const heat = housing.heatingDetails || {};
  const housingView = {
    fullAddress: buildFullAddress(patient),
    yearConstruction: String(housing.yearConstruction || '').trim(),
    yearHabitation: String(housing.yearHabitation || '').trim(),
    // Surface habitable : on suffixe " m²" si la valeur est un nombre
    // (ou une chaîne numérique) — l'ergo saisit juste un nombre dans
    // l'app, c'est nous qui décorons côté rendu PDF. Si l'ergo a déjà
    // tapé "120 m²" ou "120m2", on respecte sa saisie tel quel.
    surface: (() => {
      const raw = String(housing.surface || '').trim();
      if (!raw) return '';
      const isPureNumber = /^[\d.,]+$/.test(raw);
      return isPureNumber ? `${raw} m²` : raw;
    })(),
    typology: String(housing.typology || '').trim(),
    isMaison: /maison/i.test(String(housing.typology || '')),
    isAppartement: /appart/i.test(String(housing.typology || '')),
    levels: clampLevels(housing.levels),
    basement: Boolean(housing.basement),
    rdc: Boolean(housing.rdc),
    floor: Boolean(housing.floor),
    secondFloor: Boolean(housing.secondFloor),
    thirdFloor: Boolean(housing.thirdFloor),
    basementDesc: String(housing.basementDesc || '').trim(),
    rdcDesc: String(housing.rdcDesc || '').trim(),
    floorDesc: String(housing.floorDesc || '').trim(),
    garage: Boolean(housing.garage),
    veranda: Boolean(housing.veranda),
    balcon: Boolean(housing.balcon),
    terrasse: Boolean(housing.terrasse),
    jardin: Boolean(housing.jardin),
    // `heatingMain` (case « Existe-t-il une installation de chauffage »
    // page 5 PDF) — auto-dérivé : si AU MOINS UN type est sélectionné
    // (radiateurs élec, gaz, fioul, PAC, collectif, bois, granulés,
    // autre), alors heatingMain=true. Évite que l'ergo doive cocher
    // 2 cases (existence + type) dans l'app — la 1ère est redondante
    // dès qu'il pick un type. Demande utilisateur 2026-04-29 :
    // « si un chauffage est coché tu mets forcément oui à existe
    //  t-il une installation de chauffage ».
    heatingMain: Boolean(
      heat.electric || heat.gas || heat.oil || heat.heatPump ||
      heat.collective || heat.wood || heat.pellet || heat.other ||
      housing.heatingMain,
    ),
    heating: {
      electric: Boolean(heat.electric),
      gas: Boolean(heat.gas),
      oil: Boolean(heat.oil),
      heatPump: Boolean(heat.heatPump),
      collective: Boolean(heat.collective),
      wood: Boolean(heat.wood),
      pellet: Boolean(heat.pellet),
      other: Boolean(heat.other),
    },
    // Champ `Observations1` page 5 — « Observations sur l'accessibilité ».
    //
    // Source UNIQUE (demande utilisateur 2026-04-29) : la note écrite
    // par l'ergo dans le panneau latéral de l'onglet Accessibilité
    // (toutes sous-sections : Général / Niveaux / Équipements /
    // Extérieur). Cette note est récupérée côté serveur dans
    // `fetchVadOverlayNotesForReport` et passée ici via
    // `observations.accessibiliteObservation`.
    //
    // Pas de fallback auto-gen (volets / motorisations / accès rue) —
    // l'utilisateur a explicitement demandé : « Observations sur
    // l'accessibilité doit reprendre la note ecrite de accessibilité
    // c'est tout pas des champs comme accès depuis la rue porte de
    // garage ou portail ». Si la note est vide, le champ PDF reste
    // vide.
    accessObservation:
        String(observations?.accessibiliteObservation || '').trim(),
  };

  // --- Page 6 : Sanitaires ---
  // On consolide en une "vue 1ère SDB / 1er WC" pour les ÉQUIPEMENTS
  // (baignoire, hauteurs, porte…). Si l'ergo a plusieurs instances,
  // les autres seront servies via pages bonus (chunk 4.2c).
  //
  // EXCEPTION pour les checkboxes de NIVEAU (demande utilisateur
  // 2026-04-29) : on agrège sur TOUTES les instances pour répondre
  // à la sémantique métier :
  //   • SDB « située au niveau pièces de vie » = Oui si AU MOINS une
  //     SDB est au RDC, Non si elles sont uniquement à l'étage ou
  //     au sous-sol.
  //   • WC « à niveau (RDC) » = au moins un WC au RDC.
  //   • WC « à l'étage (autre) » = au moins un WC ailleurs qu'au RDC
  //     (étage, 2e étage, sous-sol…).
  // Les deux cases WC peuvent donc être cochées simultanément si
  // l'ergo a renseigné un WC à chaque niveau.
  const sdbInstancesArr = Array.isArray(sanitaires?.sdbInstances)
    ? sanitaires.sdbInstances
    : [];
  const wcInstancesArr = Array.isArray(sanitaires?.wcInstances)
    ? sanitaires.wcInstances
    : [];
  const sdb = sdbInstancesArr[0] || {};
  const wc = wcInstancesArr[0] || {};
  // Helpers : matching robuste sur `levelField`. RDC = 'rdc' ou
  // 'pieces_de_vie' (variantes historiques côté client). Tout le
  // reste est considéré « non-RDC » dès que la valeur est non vide.
  const isRdc = (lvl) => /(^|_)(rdc|pieces_de_vie)(_|$)/i.test(
    String(lvl || ''),
  );
  const sdbAtRdc = sdbInstancesArr.some((s) => isRdc(s?.levelField));
  const wcAtRdc = wcInstancesArr.some((w) => isRdc(w?.levelField));
  const wcAtEtage = wcInstancesArr.some(
    (w) => Boolean(w?.levelField) && !isRdc(w?.levelField),
  );
  const sanitairesView = {
    // SDB située au niveau pièces de vie : Oui si au moins une SDB
    // est au RDC. Fallback sur le legacy `sdbNiveauPiecesVie` (booléen
    // sur l'instance) pour les dossiers historiques sans `levelField`.
    sdbAuNiveauPieceVie: sdbAtRdc || Boolean(sdb.sdbNiveauPiecesVie),
    // Équipements
    sdbBaignoire: Boolean(sdb.sdbBaignoire),
    sdbBaignoireHauteurFr: formatHeightCm(sdb.sdbBaignoireHauteur),
    sdbBacDouche: Boolean(sdb.sdbBacDouche),
    sdbBacDoucheHauteurFr: formatHeightCm(sdb.sdbBacDoucheHauteur),
    sdbVasqueSuspendue: Boolean(sdb.sdbVasqueSuspendue),
    sdbVasqueColonne: Boolean(sdb.sdbVasqueColonne),
    sdbMeubleVasque: Boolean(sdb.sdbMeubleVasque),
    sdbBidet: Boolean(sdb.sdbBidet),
    sdbParoiDouche: Boolean(sdb.sdbParoiDouche),
    sdbSolGlissant: Boolean(sdb.sdbSolGlissant),
    sdbMachineALaver: Boolean(sdb.sdbMachineALaver),
    // Porte SDB
    porteSdbLargeurSuffisante: Boolean(sdb.porteSdbLargeurSuffisante),
    porteSdbDimensionFr: formatWidthCm(sdb.porteSdbDimension),
    porteSdbSensInterieur: Boolean(sdb.porteSdbSensAdapte),
    porteSdbSensExterieur: !sdb.porteSdbSensAdapte && (sdb.porteSdbDimension != null),
    // WC
    wcCuvetteBonneHauteur: Boolean(wc.wcCuvetteBonneHauteur),
    wcCuvetteTropBasse: Boolean(wc.wcCuvetteTropBasse),
    wcCuvetteHauteurFr: formatHeightCm(wc.wcCuvetteHauteur),
    wcBarreRelevement: Boolean(wc.wcBarreRelevement),
    // Niveau WC — agrégé sur TOUTES les instances WC (cf. comment
    // au-dessus). Les deux cases peuvent être cochées en parallèle
    // si l'ergo a un WC RDC ET un WC étage.
    wcAuNiveau: wcAtRdc,
    wcEtage: wcAtEtage,
    // Porte WC
    porteWcLargeurSuffisante: Boolean(wc.porteWcLargeurSuffisante),
    porteWcDimensionFr: formatWidthCm(wc.porteWcDimension),
    porteWcSensInterieur: Boolean(wc.porteWcSensAdapte),
    porteWcSensExterieur: !wc.porteWcSensAdapte && (wc.porteWcDimension != null),
    // Observations sur les équipements et utilisation (champ `obs`
    // page 6 PDF). Source 2026-04-29 : la NOTE PARTAGÉE SDB+WC saisie
    // dans le panneau de droite de l'app (tabKey `Sanitaires-Notes`),
    // synthétisée par `fetchVadOverlayNotesForReport.sanitaires` puis
    // injectée dans `observations.observationEquipements`. Avant ce
    // fix, on lisait uniquement `wc.observationEquipementsUtilisation`
    // — un ancien champ texte par-instance WC qui n'était plus
    // alimenté par l'UI depuis l'unification des notes Sanitaires.
    // Fallback : le champ legacy si la note partagée est absente.
    observationsEquipements: String(
      observations?.observationEquipements || wc.observationEquipementsUtilisation || '',
    ).trim(),
  };

  // --- Page 7 : Projet + Résumé ---
  // + champ `observationEquipements` exposé pour le mapping `obs`
  // page 6 (« Observations sur les équipements et utilisation »).
  // Bug 2026-04-29 : le mapping pointait vers `observations.observationEquipements`
  // mais cette clé n'existait PAS dans le view model — `obs` restait
  // toujours vide quoique l'app envoie. Source priorisée : la note
  // panneau Sanitaires (déjà mergée côté `index.mjs` dans `observations`)
  // → fallback sur le legacy `wc.observationEquipementsUtilisation`.
  const observationsView = {
    projetSouhaitUsage: String(observations?.projetSouhaitUsage || '').trim(),
    resumePreconisations: String(observations?.resumePreconisations || '').trim(),
    observationEquipements: String(
      observations?.observationEquipements || wc.observationEquipementsUtilisation || '',
    ).trim(),
  };

  return {
    patient: {
      firstName,
      lastName,
      fullNameUpper: [lastName.toUpperCase(), firstName].filter(Boolean).join(' '),
      // birthDateFr garde le sens "monsieur" pour la compat ascendante
      // avec le mapping POC.
      birthDateFr: birthDateMrFr,
      birthDateMrFr,
      birthDateMmeFr,
      phone: String(patient.phone || '').trim(),
      email: String(patient.email || '').trim(),
      trustedName: String(patient?.trustedPerson?.name || '').trim(),
      trustedPhone: String(patient?.trustedPerson?.phone || '').trim(),
      trustedEmail: String(patient?.trustedPerson?.email || '').trim(),
      // Champs dérivés pour les checkbox-radios.
      familySituationNormalized: normalizeFamilySituation(patient.familySituation),
      occupationStatusNormalized: normalizeOccupationStatus(patient.occupationStatus),
      // APA : Dropdown5 du PDF n'accepte que 'Oui' / 'Non' / 'En cours'
      // (options figées dans le template). On garde ces valeurs strictes
      // pour la dropdown, et on rend le GIR séparément via un overlay
      // texte (cf. `applyApaGirOverlay`) à côté du dropdown — sinon
      // pdf-lib refuse les chaînes hors-options.
      //
      // `apaGir` est stocké PAR OCCUPANT dans `occupants_json` (pas de
      // colonne dédiée sur le patient). On lit donc l'occupant 0 qui
      // est le bénéficiaire principal. Demande utilisateur 2026-04-29 :
      // « bénéficiaire APA c'est marqué oui mais sans le gir alors que
      // je l'ai sélectionné » — avant ce fix, on lisait `patient.apaGir`
      // qui n'existe pas → toujours vide → l'overlay était skippé.
      apaLabel: patient.apa ? 'Oui' : 'Non',
      apaGirRaw: patient.apa
        ? (() => {
            const occupants = Array.isArray(patient.occupants)
              ? patient.occupants
              : [];
            const primary = occupants[0] || {};
            return String(
              patient.apaGir
                || primary.apaGir
                || primary.gir
                || '',
            ).trim();
          })()
        : '',
      invalidityDisplay,
      homeHelpDisplay,
      // Dépendance particulière : on n'affiche QUE le mot-clé (Canne /
      // Déambulateur / Fauteuil roulant / Aucune) et pas la description
      // libre saisie en complément. Demande utilisateur : « simplement
      // un élément ». On match d'abord le texte contre les options
      // connues, fallback sur le 1er segment avant virgule/point si
      // aucune correspondance.
      dependenceTxt: normalizeDependenceForReport(patient.dependenceTxt),
      // Cellule « Caisse de retraite complémentaire » de la page
      // « Descriptif des aides prévisionnelles » — pré-résolu côté
      // `index.mjs` (cf. `resolveCaisseComplementaireLabel`). Vaut
      // soit `'/'` soit `'<nom de caisse> sous conditions*'`.
      // Demande utilisateur 2026-04-29.
      caisseComplementaireLabel: caisseComplementaireResolved == null
        ? ''
        : String(caisseComplementaireResolved),
    },
    dossier: {
      personnesPresentesVisite: String(dossier?.personnesPresentesVisite || '').trim(),
      visitDateFr: formatFrenchDate(dossier?.visitDate),
      // Cellule « AMO » de la page « Descriptif des aides
      // prévisionnelles » — montant fonction de la nature
      // d'accompagnement (demande utilisateur 2026-04-29) :
      //   • 'ergo'       → 600 €
      //   • 'complet'    → 800 €
      //   • 'diagnostic' → '/' (pas d'AMO sur un dossier diagnostic seul)
      //   • autre/vide   → '/' (sécurité — on n'invente pas un montant)
      amoLabel: (() => {
        const nat = String(dossier?.natureAccompagnement || '')
          .trim()
          .toLowerCase();
        if (nat === 'complet') return '800 €';
        if (nat === 'ergo') return '600 €';
        return '/';
      })(),
    },
    contexte: (() => {
      // Source primaire : les NOTES écrites par l'ergo dans
      // `Contexte de vie > Médical` (Environnement) et
      // `Contexte de vie > Autonomie` (Habitudes de vie). Demande
      // utilisateur — la note libre est plus riche que les données
      // structurées du formulaire (cases cochées + textes courts).
      //
      // Fallback : si aucune note n'a été saisie, on retombe sur
      // l'ancienne agrégation des champs structurés du dossier
      // (`buildEnvironnementText` / `buildHabitudesText`) pour ne
      // jamais avoir de section vide.
      const medicalPages = contexteNotes.filter(
        (pg) => String(pg?.tabKey || '') === 'Contexte de vie-Médical',
      );
      const autonomyPages = contexteNotes.filter(
        (pg) => String(pg?.tabKey || '') === 'Contexte de vie-Autonomie',
      );
      const envFromNotes = joinNotePagesText(medicalPages);
      const habFromNotes = joinNotePagesText(autonomyPages);
      return {
        environnement: envFromNotes || buildEnvironnementText(dossier),
        habitudes: habFromNotes || buildHabitudesText(dossier),
      };
    })(),
    housing: housingView,
    sanitaires: sanitairesView,
    observations: observationsView,
    // Constantes Aid'Habitat — exposées via mapping JSON pour
    // override des valeurs pré-remplies dans le template (notamment
    // l'adresse de l'ergothérapeute page 3).
    constants: {
      ergoAddressOneLine: ERGO_CONTACT.page3OneLine,
    },
  };
}

/**
 * Pose une valeur sur un champ AcroForm en respectant son type. pdf-lib
 * typecheckera lui-même via les sous-classes (PDFTextField, PDFCheckBox…).
 *
 * - TEXT : appelle setText (la valeur est cast en string, '' = vide).
 * - CHECK : appelle check() / uncheck() selon truthiness.
 * - RADIO : pose la valeur si elle matche `entry.match`, sinon ignore.
 *
 * Toute erreur de cast est avalée et loggée — on ne bloque pas la
 * génération pour un seul champ qui aurait été renommé côté template.
 */
function applyEntryToField(field, entry, value) {
  const type = entry.type || 'text';

  try {
    if (type === 'text') {
      if (!(field instanceof PDFTextField)) {
        console.warn(`[generateVisitReport] champ "${field.getName()}" mappé en text mais c'est un ${field.constructor.name}`);
        return;
      }
      // pdf-lib tronque à `getMaxLength()` si défini ; sinon laisse passer.
      // sanitizeForPdfFont remplace les chars hors WinAnsi (cf. helper).
      field.setText(sanitizeForPdfFont(value));
    } else if (type === 'check') {
      if (!(field instanceof PDFCheckBox)) {
        console.warn(`[generateVisitReport] champ "${field.getName()}" mappé en check mais c'est un ${field.constructor.name}`);
        return;
      }
      if (value) {
        field.check();
      } else {
        forceUncheckField(field);
      }
    } else if (type === 'radio') {
      if (!(field instanceof PDFRadioGroup)) {
        // Cas typique : Affinity Publisher exporte les "radios" comme
        // checkbox indépendantes. On gère via `match` côté checkbox.
        if (field instanceof PDFCheckBox && entry.match != null) {
          if (value === entry.match) {
            field.check();
          } else {
            // `field.uncheck()` seul ne suffit pas pour les templates
            // Affinity où la box a un état "checked" par défaut : pdf-lib
            // ne réécrit pas l'AS du widget si la valeur courante est
            // déjà non-Off, donc le flatten conserve l'apparence cochée.
            // `forceUncheckField` écrit explicitement /Off dans
            // l'AcroField + tous les widgets pour garantir la remise à
            // zéro. Sans ce reset, le radio « Propriétaire » restait
            // coché par défaut quand l'utilisateur n'avait rien
            // sélectionné dans l'app — bug remonté par Joris sur DENA Paul.
            forceUncheckField(field);
          }
        } else if (entry.match != null) {
          // Field d'un type inattendu (PDFButton, etc.) — on tente
          // quand même un reset bas niveau si value !== match.
          if (value !== entry.match) forceUncheckField(field);
        }
        return;
      }
      if (entry.match != null && value === entry.match) {
        field.select(entry.match);
      }
    } else if (type === 'dropdown') {
      if (!(field instanceof PDFDropdown)) return;
      if (value != null && value !== '') field.select(String(value));
    }
  } catch (error) {
    console.warn(`[generateVisitReport] échec écriture "${field.getName()}" (${type}) :`, error?.message || error);
  }
}

/**
 * Force un champ AcroForm à l'état « Off » de manière agressive : appel
 * `field.uncheck()` standard PUIS écriture directe dans le dict de
 * l'AcroField + tous les widgets enfants (`AS` = appearance state,
 * `V` = value). Cette double approche est nécessaire pour les templates
 * Affinity Publisher où certains checkbox ont un état coché par défaut
 * que pdf-lib ne réécrit pas via le simple `uncheck()`.
 */
function forceUncheckField(field) {
  try {
    if (typeof field?.uncheck === 'function') field.uncheck();
  } catch (_) {}
  try {
    const acro = field?.acroField;
    if (acro?.dict) {
      acro.dict.set(PDFName.of('AS'), PDFName.of('Off'));
      acro.dict.set(PDFName.of('V'), PDFName.of('Off'));
    }
    const widgets = (typeof acro?.getWidgets === 'function')
      ? acro.getWidgets()
      : [];
    for (const widget of widgets) {
      if (widget?.dict) {
        widget.dict.set(PDFName.of('AS'), PDFName.of('Off'));
      }
    }
  } catch (_) {}
}

/**
 * Dessine « (GIR n) » en texte libre juste après le mot « Oui » à
 * l'intérieur du dropdown « Dropdown5 » (APA Oui/Non/En cours). Sans
 * ça, le GIR saisi par l'ergo ne pouvait s'afficher nulle part — la
 * dropdown du template ne propose que les 3 options figées et n'a pas
 * de slot dédié au GIR. On localise le widget du dropdown pour
 * récupérer sa page + ses coordonnées, puis on pose le texte
 * directement à côté du « Oui » (pas en bout de pill).
 *
 * Idempotent : s'exécute toujours, mais ne dessine rien si l'APA
 * est à 'Non' / vide ou si le GIR n'est pas renseigné.
 */
async function applyApaGirOverlay({ pdfDoc, fieldsByName, view }) {
  const apaLabel = getByPath(view, 'patient.apaLabel');
  const apaGir = getByPath(view, 'patient.apaGirRaw');
  if (apaLabel !== 'Oui') return;
  if (!apaGir) return;

  const dropdown = fieldsByName.get('Dropdown5');
  if (!dropdown) return;

  const widgets = dropdown.acroField.getWidgets?.() || [];
  const widget = widgets[0];
  if (!widget) return;

  // Récupère la page qui héberge ce widget. `widget.P()` renvoie le
  // `PDFRef` de la page parent — on le matche contre `page.ref` de
  // chaque page du document. pdf-lib n'expose pas de `widget.getPage()`
  // direct.
  const pageRef = widget.P?.();
  if (!pageRef) return;
  const page = pdfDoc.getPages().find((p) => p.ref === pageRef);
  if (!page) return;

  const rect = widget.getRectangle();
  const helvetica = await pdfDoc.embedFont(StandardFonts.Helvetica);

  // On veut « Oui (GIR n) » : le « Oui » est rendu par le widget
  // dropdown lui-même (left-aligned avec un padding interne ≈ 4 pt),
  // donc on calcule x = bord gauche + padding + largeur de « Oui » +
  // espace, ce qui place « (GIR n) » juste après le « Oui ». L'ancien
  // calcul (`rect.x + rect.width + 8`) plaçait le texte tout au bout
  // de la pill, créant un grand vide visuel.
  const fontSize = 11;
  const widgetPadding = 4;
  const ouiWidth = helvetica.widthOfTextAtSize('Oui', fontSize);
  const x = rect.x + widgetPadding + ouiWidth + 4;
  const y = rect.y + (rect.height - fontSize) / 2 + 1;

  page.drawText(`(GIR ${apaGir})`, {
    x,
    y,
    size: fontSize,
    font: helvetica,
    color: rgb(0, 0, 0),
  });
}

/**
 * Dessine l'adresse de l'ergo en texte libre dans le bandeau orange
 * « Renseignements sur l'ergothérapeute », EN PARALLÈLE de la mise à
 * vide du widget natif `adresse` du template.
 *
 * Pourquoi cet overlay : Affinity Publisher a pré-baké le widget
 * `adresse` avec une apparence à coordonnées fixes ; pdf-lib ignore
 * les changements de rect lors du `form.flatten()`, donc
 * `nudgeFieldRect` ne déplace pas l'adresse à l'écran (testé jusqu'à
 * dy: +50, aucun effet visible). Solution : on vide le widget pour
 * supprimer le rendu original mal-positionné, puis on dessine la
 * chaîne nous-mêmes via `page.drawText` à la position visuelle
 * correcte (entre la ligne « Aid'Habitat » et le numéro de
 * téléphone, comme demandé par l'utilisateur).
 *
 * Position calibrée : `widget.rect.y` du template est ~219 (pdf-lib
 * coords, origine bas-gauche). On dessine à y = rect.y + ~30 pour
 * remonter au-dessus du téléphone tout en restant en dessous de
 * « Aid'Habitat ». Ajustable si l'œil exige plus ou moins.
 */
/**
 * Décale verticalement le rectangle du widget [fieldName] de [dy]
 * points (positif = vers le haut, négatif = vers le bas — repère
 * PDF). Sert à corriger un mauvais alignement texte/label dans le
 * template sans repasser par Affinity Publisher.
 *
 * Silencieux si le champ n'existe pas — pour qu'un mapping
 * obsolète ne fasse pas planter le rendu.
 */
function nudgeFieldRect({ fieldsByName, fieldName, dy }) {
  const field = fieldsByName.get(fieldName);
  if (!field) return;
  const widgets = field.acroField.getWidgets?.() || [];
  for (const widget of widgets) {
    const rect = widget.getRectangle();
    if (!rect) continue;
    widget.setRectangle({
      x: rect.x,
      y: rect.y + dy,
      width: rect.width,
      height: rect.height,
    });
  }
}

/**
 * Embeds des bytes d'image dans le PDF en détectant le format
 * (JPEG / PNG) à la magic number. Renvoie un PDFImage ou null si
 * le format n'est pas géré (pdf-lib ne sait pas faire de WebP, par
 * exemple — on log et on skip plutôt que de bloquer).
 */
async function embedImageAuto(pdfDoc, buffer, mimeHint) {
  if (!buffer || buffer.length < 8) return null;
  const isPng =
    buffer[0] === 0x89 &&
    buffer[1] === 0x50 &&
    buffer[2] === 0x4e &&
    buffer[3] === 0x47;
  const isJpg = buffer[0] === 0xff && buffer[1] === 0xd8;
  try {
    if (isPng) return await pdfDoc.embedPng(buffer);
    if (isJpg) return await pdfDoc.embedJpg(buffer);
    // Hint mime — on tente quand même
    if (/png/i.test(String(mimeHint || ''))) return await pdfDoc.embedPng(buffer);
    if (/jpe?g/i.test(String(mimeHint || ''))) return await pdfDoc.embedJpg(buffer);
    console.warn('[generateVisitReport] format image non supporté', {
      mime: mimeHint,
      head: buffer.slice(0, 4).toString('hex'),
    });
    return null;
  } catch (error) {
    console.warn('[generateVisitReport] embed image a échoué :', error?.message || error);
    return null;
  }
}

/**
 * Pose une image dans un champ AcroForm "Btn" (les `_af_image` créés
 * par Affinity Publisher). Si le champ n'est pas trouvé ou si pdf-lib
 * ne peut pas y poser une image, on log et on continue.
 *
 * Modes de fit (paramètre [fit]) :
 *   - 'contain' (défaut) : utilise `field.setImage()` de pdf-lib qui
 *     préserve le ratio en laissant des marges blanches si l'image
 *     n'a pas le même ratio que le slot. Bon pour les images wiki des
 *     préconisations (illustrations carrées qui ne doivent pas être
 *     coupées).
 *   - 'cover' : on dessine l'image directement sur la page via
 *     `page.drawImage()` après calcul des dimensions qui couvrent
 *     entièrement le slot (le surplus déborde des bords courts est
 *     clippé via le rect du slot). Bon pour les photos plein cadre
 *     du logement / accessibilité / sanitaires : la photo remplit
 *     la vignette comme dans une mise en page magazine, sans bandes
 *     blanches gênantes quand le ratio diffère.
 *
 * En mode 'cover' on remplace en plus l'apparence du champ par un
 * stream vide → le placeholder gris d'Affinity ("image_placeholder")
 * disparaît derrière notre image, sinon il pourrait transparaître si
 * notre image est translucide (pas le cas en JPEG mais en PNG oui).
 */
async function setImageInField(
  pdfDoc, form, fieldName, descriptor, fetchImageBytes, stats,
  { fit = 'contain' } = {},
) {
  if (!fieldName || !descriptor || !fetchImageBytes) return;
  let field;
  try {
    field = form.getField(fieldName);
  } catch {
    stats.imagesMissingField += 1;
    return;
  }
  if (!(field instanceof PDFButton)) {
    console.warn(`[generateVisitReport] "${fieldName}" n'est pas un PDFButton (got ${field.constructor.name})`);
    return;
  }
  const fetched = await fetchImageBytes(descriptor);
  if (!fetched?.buffer || fetched.buffer.length === 0) {
    stats.imagesMissingValue += 1;
    return;
  }
  const pdfImage = await embedImageAuto(pdfDoc, fetched.buffer, fetched.mimeType);
  if (!pdfImage) {
    stats.imagesFailedEmbed += 1;
    return;
  }

  if (fit === 'cover') {
    try {
      drawImageWithCoverFit(pdfDoc, field, pdfImage);
      stats.imagesApplied += 1;
    } catch (error) {
      console.warn(`[generateVisitReport] cover-fit("${fieldName}") a échoué :`, error?.message || error);
      // Fallback contain via setImage natif → mieux que rien.
      try {
        field.setImage(pdfImage);
        stats.imagesApplied += 1;
      } catch (e2) {
        stats.imagesFailedEmbed += 1;
      }
    }
    return;
  }

  // fit === 'contain' : chemin pdf-lib classique.
  try {
    field.setImage(pdfImage);
    stats.imagesApplied += 1;
  } catch (error) {
    console.warn(`[generateVisitReport] setImage("${fieldName}") a échoué :`, error?.message || error);
    stats.imagesFailedEmbed += 1;
  }
}

/**
 * Dessine [pdfImage] dans le rect du widget de [field] avec un fit
 * "cover" : l'image remplit toute la zone, les côtés courts qui
 * dépasseraient sont coupés via un q/Q + clip rect en PDF. Recharge
 * également l'apparence du champ avec un stream vide pour que le
 * placeholder gris d'Affinity soit purgé.
 */
function drawImageWithCoverFit(pdfDoc, field, pdfImage) {
  const widgets = field.acroField.getWidgets?.() || [];
  for (const widget of widgets) {
    const rect = widget.getRectangle();
    if (!rect || rect.width <= 0 || rect.height <= 0) continue;

    const pageRef = widget.P?.();
    if (!pageRef) continue;
    const page = pdfDoc.getPages().find((p) => p.ref === pageRef);
    if (!page) continue;

    const slotRatio = rect.width / rect.height;
    const imgRatio = pdfImage.width / pdfImage.height;

    // Cover : on agrandit jusqu'à ce que les DEUX dimensions remplissent
    // ou dépassent celles du slot. Pas de bandes blanches.
    let drawW;
    let drawH;
    if (imgRatio > slotRatio) {
      // Image plus large que le slot → on cale à la hauteur, ça déborde
      // sur les côtés (clippé).
      drawH = rect.height;
      drawW = drawH * imgRatio;
    } else {
      // Image plus haute → on cale à la largeur, ça déborde haut/bas.
      drawW = rect.width;
      drawH = drawW / imgRatio;
    }
    const drawX = rect.x + (rect.width - drawW) / 2;
    const drawY = rect.y + (rect.height - drawH) / 2;

    // Clip rectangle au slot pour cacher le débordement de l'image
    // (mode cover). Séquence PDF standard :
    //   q                    push graphics state
    //   x y w h re           rectangle path
    //   W                    set as clipping path
    //   n                    end path (no fill, no stroke)
    //   ... drawImage ...
    //   Q                    pop graphics state
    // Sans le `q ... Q`, le clip contaminerait tout le reste de la page.
    // Sans `endPath()` (`n`), certains lecteurs PDF tracent un fin
    // trait noir le long du clip.
    page.pushOperators(
      pushGraphicsState(),
      rectangle(rect.x, rect.y, rect.width, rect.height),
      clip(),
      endPath(),
    );
    page.drawImage(pdfImage, {
      x: drawX,
      y: drawY,
      width: drawW,
      height: drawH,
    });
    page.pushOperators(popGraphicsState());

    // Remplace l'apparence du champ par un stream vide → le placeholder
    // gris d'Affinity ("image_placeholder.png" embedé dans le template)
    // disparaît au flatten au lieu de transparaître derrière une image
    // PNG semi-transparente. Pour les JPEG opaques c'est un no-op
    // visuel, mais on l'applique systématiquement pour éviter le
    // double-rendu (le button + notre drawImage par-dessus).
    const emptyStream = pdfDoc.context.formXObject([], {
      BBox: pdfDoc.context.obj([0, 0, rect.width, rect.height]),
      Matrix: pdfDoc.context.obj([1, 0, 0, 1, 0, 0]),
      Resources: pdfDoc.context.obj({}),
    });
    const emptyRef = pdfDoc.context.register(emptyStream);
    const apDict = pdfDoc.context.obj({});
    apDict.set(PDFName.of('N'), emptyRef);
    widget.dict.set(PDFName.of('AP'), apDict);
  }
}

/**
 * Filtre + trie les photos d'une catégorie visite donnée. Le serveur
 * ne synchronise pas `categoryOrder` (local-only en v1) — on retombe
 * sur l'ordre date DESC fourni par `listDocumentsByPatient`.
 */
function photosForVisitTag(documents, tag) {
  // Comparaison normalisée (lowercase + NFD strip-accents + spaces
  // collapse) — même logique que dans `fetchVisitPhotosForPatient`
  // côté serveur. Garantit qu'un tag NocoDB stocké sous une forme
  // légèrement différente de la constante Flutter (NFC vs NFD,
  // espace insécable, casse) tombe quand même dans le bon slot.
  const normalize = (s) => String(s || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  const target = normalize(tag);
  return documents.filter((doc) =>
    Array.isArray(doc?.tags) &&
    doc.tags.some((t) => normalize(t) === target),
  );
}

/**
 * Slot map page 8 du PDF : 2 photos paysage Logement (haut) + 3
 * portraits Accessibilité (milieu) + 3 portraits Sanitaires (bas).
 */
const PAGE8_PHOTO_SLOTS = [
  { tag: 'Visite - Logement', fields: ['logement', 'logement2'] },
  { tag: 'Visite - Accessibilité', fields: ['acces1', 'acces2', 'acces3'] },
  { tag: 'Visite - Sanitaires', fields: ['sani1', 'sani2', 'sani3'] },
];

/**
 * Slot map pages 9 (avant) et 10 (après). Le PDF a 4 emplacements :
 * 2 par page, l'un en haut (`plan avt_af_image`) et l'autre en bas
 * (`plan avt1_af_image`). On remplit dans l'ordre des pages Plans
 * de l'app — premier dessin de phase 'avant' → slot 1, deuxième →
 * slot 2 ; idem pour 'apres'.
 */
const PLAN_SLOTS = {
  avant: ['plan avt_af_image', 'plan avt1_af_image'],
  apres: ['plan apt_af_image', 'plan apt1_af_image'],
};

/**
 * Slot map pages 11-14 : 8 préconisations × (champ texte + champ
 * image). Chaque page contient 2 préconisations :
 *   - haut de page : `Préconisations avec argumentaire(N)` + `Image*_af_image`
 *   - bas de page  : `Préconisations avec argumentaire(N+1)` + `croquis*_af_image`
 *
 * Avant : seules les recos d'index pair recevaient leur image wiki —
 * les `croquis*` du bas de page restaient toujours vides. Conséquence :
 * dès que l'ergo permutait l'ordre des préconisations OU en ajoutait
 * une au milieu, certaines images "disparaissaient" du PDF (la
 * position dans le tableau changeait → l'index passait de pair à
 * impair → l'image n'était plus dessinée). Symptôme reporté : "tout
 * les textes s'ajoutent bien mais certaines images de certaines
 * précos ne s'affichent pas (ex : evier cuisine évidé)".
 *
 * Maintenant : tableau aligné 1-1 sur les positions des recos
 * (index 0…7), chaque slot reçoit l'image de SA reco — qu'il soit
 * en haut (`Image*`) ou en bas (`croquis*`). Le contenu suit donc
 * exactement l'ordre des préconisations dans le dossier.
 */
const RECO_TEXT_FIELDS = [
  'Préconisations avec argumentaire',
  'Préconisations avec argumentaire2',
  'Préconisations avec argumentaire3',
  'Préconisations avec argumentaire4',
  'Préconisations avec argumentaire5',
  'Préconisations avec argumentaire6',
  'Préconisations avec argumentaire7',
  'Préconisations avec argumentaire8',
];
const RECO_IMAGE_FIELDS = [
  'Image8_af_image',     // reco 0 — page 11 haut
  'croquis2_af_image',   // reco 1 — page 11 bas
  'Image85_af_image',    // reco 2 — page 12 haut
  'croquis4_af_image',   // reco 3 — page 12 bas
  'Image874_af_image',   // reco 4 — page 13 haut
  'croquis6_af_image',   // reco 5 — page 13 bas
  'Image846_af_image',   // reco 6 — page 14 haut
  'croquis8_af_image',   // reco 7 — page 14 bas
];

/**
 * Met en forme une recommandation pour le champ texte : titre en
 * début, puis blank line, puis l'argumentaire de l'ergo. pdf-lib
 * ne supporte pas le rich text, donc tout est en plain text.
 */
function formatRecoText(reco) {
  const title = sanitizeForPdfFont(reco?.customTitle || reco?.wikiTitle || '').trim();
  const note = sanitizeForPdfFont(reco?.note || '').trim();
  if (title && note) return `${title}\n\n${note}`;
  return title || note;
}

/**
 * Calcule le bounding box englobant les widgets (texte + image) d'une
 * case de préconisation, identifiée par son index dans
 * RECO_TEXT_FIELDS / RECO_IMAGE_FIELDS. Retourne null si ni le champ
 * texte ni le champ image ne sont trouvés.
 *
 * Sert à blanchir précisément la zone d'une case BOT vide quand on
 * conserve la page (TOP rempli, BOT vide).
 */
function getRecoCaseBoundingBox(fieldsByName, recoIdx) {
  const textName = RECO_TEXT_FIELDS[recoIdx];
  const imgName = RECO_IMAGE_FIELDS[recoIdx];
  const text = fieldsByName.get(textName);
  const img = fieldsByName.get(imgName);
  const rects = [];
  const collectRects = (field) => {
    const widgets = field?.acroField?.getWidgets?.();
    if (!Array.isArray(widgets)) return;
    for (const widget of widgets) {
      const r = widget.getRectangle?.();
      if (r) rects.push(r);
    }
  };
  collectRects(text);
  collectRects(img);
  if (rects.length === 0) return null;
  const xMin = Math.min(...rects.map((r) => r.x));
  const yMin = Math.min(...rects.map((r) => r.y));
  const xMax = Math.max(...rects.map((r) => r.x + r.width));
  const yMax = Math.max(...rects.map((r) => r.y + r.height));
  return { x: xMin, y: yMin, width: xMax - xMin, height: yMax - yMin };
}

/**
 * Trouve l'index de la page qui héberge le widget d'un champ donné.
 * Retourne -1 si le champ n'a pas de widget ou si la page parente
 * ne correspond à aucune page du PDF.
 *
 * Utilise `widget.P()` (référence vers la page parente) puis matche
 * contre `pdfDoc.getPages()` — robuste à n'importe quelle structure
 * de template (pas besoin de connaître les numéros de page absolus).
 */
function findPageIndexForField(pdfDoc, field) {
  const widgets = field?.acroField?.getWidgets?.() || [];
  if (widgets.length === 0) return -1;
  let pageRef;
  try {
    pageRef = widgets[0].P();
  } catch (_) {
    return -1;
  }
  if (!pageRef) return -1;
  const pages = pdfDoc.getPages();
  for (let i = 0; i < pages.length; i += 1) {
    if (pages[i].ref === pageRef) return i;
  }
  return -1;
}

/**
 * Génère un PDF rempli pour le dossier fourni.
 *
 * @param {object} options
 * @param {object} options.dossier — payload brut tel que renvoyé par
 *                  /api/dossiers/:id côté serveur.
 * @param {object} [options.sanitaires] — payload
 *                  /api/diagnostic-sanitaires/:dossierId. Optionnel —
 *                  page 6 reste vide si non fourni.
 * @param {object} [options.observations] — payload
 *                  /api/observations/:dossierId. Optionnel — page 7
 *                  reste vide si non fourni.
 * @param {Array}  [options.documents=[]] — photos visite (filtrées
 *                  par tags `Visite - *`) pour la page 8.
 * @param {Array}  [options.notePages=[]] — pages Plans avec phase
 *                  'avant' / 'apres' pour pages 9 et 10.
 * @param {Array}  [options.recommendations=[]] — recos pour pages
 *                  11-14 (8 max en v1 — extension au-delà = chunk
 *                  4.2c bonus pages).
 * @param {Function} [options.fetchImageBytes] — async callback qui
 *                  prend un descripteur `{kind, id|url|dataUrl}` et
 *                  renvoie `{ buffer, mimeType }` ou null. Sans ce
 *                  callback, les pages images restent vides.
 * @param {boolean} [options.flatten=true] — aplatit les champs (PDF
 *                  non-modifiable). Mettre à false pour debug : le PDF
 *                  rendu reste éditable champ par champ dans Acrobat.
 * @returns {Promise<Uint8Array>} les bytes du PDF généré.
 */

/**
 * Couvre le bloc adresse Aid'Habitat hardcodé dans le PDF par
 * Affinity Publisher (page 1, en bas-gauche) avec un rectangle blanc
 * puis redessine la nouvelle adresse à la même position. Voir
 * `ERGO_CONTACT.page1` pour les coordonnées et la couleur.
 *
 * Echec gracieux : si la page 1 manque ou si le redraw échoue,
 * on log et on continue — le PDF aura juste l'ancienne adresse.
 */
// applyErgoContactOverlay supprimé en avril 2026 : l'adresse page 1
// est désormais baked directement dans le PDF source Affinity (au lieu
// d'être patchée par-dessus avec un rectangle peach + redraw texte).
// Cf. commentaire sur ERGO_CONTACT plus haut.

/**
 * Aligne la couleur du champ AcroForm `adresse` (page 3) sur celle
 * des champs voisins — visuellement plus claire que le rendu pdf-lib
 * par défaut.
 *
 * Pourquoi : le template Affinity utilise SegoeUI dans la DA des
 * champs `entreprise`, `adresse`, `Nom et prénom`, `contact`. pdf-lib
 * ne sait pas embarquer SegoeUI sans fontkit → fallback Helvetica.
 * Helvetica rend un poil plus dense → l'adresse apparaît visuellement
 * plus foncée que les autres champs (eux, déjà rendus par Affinity au
 * moment de l'export et préservés par les viewers PDF).
 *
 * Compensation : on pose une DA personnalisée sur le seul champ
 * `adresse` avec un gris clair (`0.3 0.3 0.3 rg` ≈ #4D4D4D) — l'avg
 * perçu après anti-aliasing tombe sur ~#363233, identique aux autres
 * champs sampled depuis le rendu PNG.
 */
function applyAdresseFieldColorTweak(form) {
  try {
    const adresseField = form.getField('adresse');
    if (adresseField instanceof PDFTextField) {
      // Format DA standard PDF : `/<font> <size> Tf <gray> g`.
      // Helvetica 12pt en noir pur (demande utilisateur — préfère
      // l'uniformité noire même si pdf-lib rend un poil plus dense
      // que les autres champs Affinity-SegoeUI).
      adresseField.acroField.setDefaultAppearance('/Helv 12 Tf 0 g');
    }
  } catch (error) {
    console.warn('[generateVisitReport] applyAdresseFieldColorTweak :', error?.message || error);
  }
}

/**
 * Aligne la taille de police des champs texte du bloc « Le Logement »
 * (page 5) sur celle du reste du rapport (12 pt).
 *
 * Pourquoi : l'utilisateur a remonté que « dans la partie Le Logement
 * les textes sont plus petits, ils doivent être de la meme taille que
 * les autres textes ». Le template Affinity a une DA plus petite
 * (~10 pt) sur ces champs, on l'override en /Helv 12 Tf 0 g comme
 * `adresse` (page 3). pdf-lib regénère l'apparence avec cette DA
 * quand on setText.
 *
 * Champs concernés : Adresse, annee1, annee2, surface, Sous sol, rdc,
 * etage, Observations1. EXCLU : `nombre d'étage` (PDFDropdown — sa
 * pill a un baseline déjà OK et toucher la DA déforme l'affichage).
 */
function applyLogementFontSizeTweak(form) {
  const logementTextFields = [
    'Adresse',
    'annee1',
    'annee2',
    'surface',
    'Sous sol',
    'rdc',
    'etage',
    'Observations1',
  ];
  for (const fieldName of logementTextFields) {
    try {
      const field = form.getField(fieldName);
      if (field instanceof PDFTextField) {
        field.acroField.setDefaultAppearance('/Helv 12 Tf 0 g');
      }
    } catch {
      // Silencieux : un champ inexistant ne doit pas planter le rendu
      // (template peut évoluer indépendamment du code).
    }
  }
}

/**
 * Coordonnées du bloc « Étage » dans le template (page 5) — utilisées
 * par `applyMultiEtageOverlay` pour rendre dynamiquement Étage 1 / 2
 * / 3 quand l'ergo a sélectionné plusieurs niveaux d'étage. Lues une
 * fois via `tools/inspect-page5-fields.mjs`.
 *
 * Layout existant (template Affinity) :
 *   - Sous-sol (y=623), RDC (y=595), Étage (y=566) — pas vertical 28-29 pt
 *   - Annexes commencent à y=505 → 61 pt d'espace entre Étage et Annexes
 * Pour 2 lignes étage supplémentaires, on utilise un pas serré de 22 pt
 * → Étage 1 (564), Étage 2 (542), Étage 3 (520) — ne touche pas les
 * annexes (y=505) et n'oblige pas à rétrécir Observations1.
 */
const ETAGE_LAYOUT = {
  pageIndex: 4, // page 5 (0-indexée)
  // 1ère ligne Étage = position du champ original.
  line1: { checkboxY: 566, descY: 564 },
  checkboxX: 96,
  checkboxSize: 11,
  descX: 125,
  descY: 564,
  descWidth: 428,
  descHeight: 18,
  fontSize: 11,
  // Espacement entre lignes étage en mode multi.
  lineGap: 22,
  // Couleur du label "Étage N" et du check (parité avec le reste).
  textColor: rgb(0, 0, 0),
};

/**
 * Si l'ergo a sélectionné plusieurs niveaux d'étage (1er, 2e, 3e),
 * masque l'étiquette "Étage" du template et la remplace par une
 * étiquette "Étage 1 / 2 / 3" devant la case existante, puis
 * dessine 1 ou 2 lignes supplémentaires en dessous (checkbox + label
 * + zone de description).
 *
 * Demande utilisateur 2026-04-29 : « s'il y'a plusieurs etage tu
 * dupliques la ligne étage pour une ligne étage + numéro ». Pas de
 * shrink de Observations1 : on tient dans les 61 pt disponibles entre
 * la ligne Étage du template et la rangée des annexes (y=505) avec un
 * pas serré de 22 pt.
 *
 * Si un seul étage est sélectionné (ou aucun), on ne fait rien — la
 * ligne "Étage" du template reste affichée telle quelle. Si plusieurs,
 * on relabelle "Étage" → "Étage 1" pour clarté.
 */
function applyMultiEtageOverlay({ pdfDoc, view }) {
  const housing = view.housing || {};
  // Construit la liste des étages actifs dans l'ordre 1er → 2e → 3e.
  const flags = [
    Boolean(housing.floor),
    Boolean(housing.secondFloor),
    Boolean(housing.thirdFloor),
  ];
  const activeCount = flags.filter(Boolean).length;
  if (activeCount <= 1) return; // un seul étage → pas d'overlay

  const pages = pdfDoc.getPages();
  const page = pages[ETAGE_LAYOUT.pageIndex];
  if (!page) return;

  // Pour chaque étage qui doit recevoir un label numéroté, on dessine :
  //   1. (étage 2/3 seulement) un rectangle de masque blanc à la
  //      position où la nouvelle ligne va apparaître, sinon les
  //      éléments du template (s'il y en a) pourraient leak à travers
  //   2. une checkbox dessinée (rectangle + ✓ si actif)
  //   3. le label "Étage N" à droite du checkbox (avant la zone desc)
  //
  // Note : pour la ligne 1 (qui correspond au champ AcroForm "Étage"
  // existant), on relabelle juste avec "Étage 1" en superposition au
  // mot "Étage" du template (le template n'écrit pas "Étage" comme
  // texte en dur — c'est juste le widget/label PDF, qui est
  // re-dessinable). On utilise un masque blanc pour cacher le label
  // original.
  for (let i = 0; i < 3; i++) {
    const isActive = flags[i];
    // L'index visuel (1, 2 ou 3) est 1-based.
    const visualNumber = i + 1;

    // Position Y de la ligne (Y descendant : étage 1 en haut, 3 en bas).
    const lineCenterY = ETAGE_LAYOUT.line1.checkboxY - i * ETAGE_LAYOUT.lineGap;
    const descBaselineY = ETAGE_LAYOUT.line1.descY - i * ETAGE_LAYOUT.lineGap;

    // Pour les lignes 2 et 3 (i ≥ 1), on dessine la nouvelle case +
    // le label. Pour la ligne 1, on garde la case AcroForm existante
    // (déjà cochée par le mapping `Étage`) — on ajoute juste un label
    // " 1" à côté pour la cohérence visuelle.
    if (i === 0) {
      // Ligne 1 : ajout du suffixe " 1" derrière le label "Étage" du
      // template, en superposition. Coordonnée du début du texte :
      // immédiatement après "Étage" (~6 caractères × 6.5 px ≈ 39 px).
      // Approximé visuellement, à affiner si nécessaire.
      page.drawText(`1`, {
        x: ETAGE_LAYOUT.checkboxX + 50, // après le mot "Étage" du template
        y: descBaselineY + 4,
        size: ETAGE_LAYOUT.fontSize,
        color: ETAGE_LAYOUT.textColor,
      });
      continue;
    }

    // Lignes 2 et 3 : ajout complet (checkbox + label + ligne de
    // description vide).
    // Checkbox : carré 11×11 avec border noir, et ✓ si actif.
    const cbX = ETAGE_LAYOUT.checkboxX;
    const cbY = lineCenterY;
    const cbSize = ETAGE_LAYOUT.checkboxSize;
    page.drawRectangle({
      x: cbX,
      y: cbY,
      width: cbSize,
      height: cbSize,
      borderColor: rgb(0, 0, 0),
      borderWidth: 0.5,
      color: rgb(1, 1, 1),
    });
    if (isActive) {
      // Croix simple — 2 lignes en X. pdf-lib n'a pas de drawLine
      // natif, on utilise drawText avec "X" centré.
      page.drawText('X', {
        x: cbX + 1.5,
        y: cbY + 1,
        size: 10,
        color: rgb(0, 0, 0),
      });
    }
    // Label "Étage N" + ligne de séparation (description vide).
    page.drawText(`Étage ${visualNumber}`, {
      x: ETAGE_LAYOUT.descX,
      y: descBaselineY + 4,
      size: ETAGE_LAYOUT.fontSize,
      color: ETAGE_LAYOUT.textColor,
    });
  }
}

export async function generateVisitReport({
  dossier,
  sanitaires,
  observations,
  documents = [],
  notePages = [],
  contexteNotes = [],
  recommendations = [],
  caisseComplementaireResolved = null,
  fetchImageBytes,
  flatten = true,
}) {
  // Résolution du template PDF en fonction de l'ergothérapeute du
  // dossier (cf. ERGO_TEMPLATE_MAP). Les ergos sans entrée explicite
  // tombent sur DEFAULT_TEMPLATE_PATH (Christelle).
  const templatePath = resolveTemplatePath(dossier);
  const { templateBytes, mapping } = await loadTemplate(templatePath);
  const view = buildViewModel({
    dossier,
    sanitaires,
    observations,
    contexteNotes,
    caisseComplementaireResolved,
  });

  // pdf-lib ne supporte pas un updateFieldAppearances "léger" sur un
  // PDF chargé avec ignoreEncryption — on charge proprement, le PDF
  // template n'est pas chiffré.
  const pdfDoc = await PDFDocument.load(templateBytes);
  const form = pdfDoc.getForm();

  // Index par nom pour éviter le for-each * field-by-name.
  const fieldsByName = new Map();
  for (const field of form.getFields()) {
    fieldsByName.set(field.getName(), field);
  }

  const stats = {
    applied: 0,
    missingField: 0,
    missingValue: 0,
    imagesApplied: 0,
    imagesMissingField: 0,
    imagesMissingValue: 0,
    imagesFailedEmbed: 0,
    recoTextApplied: 0,
    recoOverflow: 0,
    recoPagesRemoved: 0,
    descriptifMerged: false,
  };

  for (const [fieldName, entry] of Object.entries(mapping)) {
    if (fieldName.startsWith('$')) continue; // commentaires/meta dans le JSON
    const field = fieldsByName.get(fieldName);
    if (!field) {
      stats.missingField += 1;
      console.warn(`[generateVisitReport] champ "${fieldName}" absent du template — mapping obsolète ?`);
      continue;
    }
    const value = getByPath(view, entry.source);
    if (value === undefined || value === null || value === '') {
      // Pour les TEXT, on laisse vide (n'écrase rien). Pour les
      // CHECK/RADIO, value falsy → uncheck explicite, ce qui est OK.
      if (entry.type !== 'check' && entry.type !== 'radio') {
        stats.missingValue += 1;
        continue;
      }
    }
    applyEntryToField(field, entry, value);
    stats.applied += 1;
  }

  // ---------------------------------------------------------------
  // Ajustements ciblés post-mapping (champs sans simple bind 1-1)
  // ---------------------------------------------------------------
  // Overlay « GIR n » à côté du dropdown APA quand l'option est 'Oui'.
  // Le dropdown du template n'accepte que les 3 options figées
  // ('Oui'/'Non'/'En cours') — on ne peut pas y mettre "Oui (GIR 4)".
  // On dessine donc le GIR en texte libre juste à droite de la pill.
  await applyApaGirOverlay({ pdfDoc, fieldsByName, view });

  // Descend de quelques points le rectangle des champs « aide à
  // domicile » et « dépendance » : leurs valeurs apparaissaient au
  // ras du label en haut de la box, désalignées avec le ":" de la
  // ligne. On baisse la box de ~4 pt pour que le baseline du texte
  // soit pile sur la ligne du libellé (demande utilisateur).
  nudgeFieldRect({ fieldsByName, fieldName: 'aide.à domicile', dy: -4 });
  nudgeFieldRect({ fieldsByName, fieldName: 'dépendance', dy: -4 });

  // Même symptôme « baseline trop haute » pour les autres champs texte
  // des blocs Bénéficiaire / Coordonnées usager / Renseignements visite
  // (page 1) et Ergo (page 3). Demande utilisateur : « redescendre
  // légèrement les résultats pour qu'ils s'affichent bien en face de
  // la ligne ». Référence d'alignement : `aide à domicile` et
  // `dépendance` (nudgés -4 ci-dessus, validés "parfaitement alignés").
  //
  // EXCEPTIONS : la date de naissance, la reconnaissance d'invalidité
  // (champ `MDPH`) et tous les champs des « Coordonnées de l'usager »
  // (tel/mail usager, personne de confiance) sont moins descendus (-2
  // au lieu de -4) : à -4 ils tombaient un tout petit peu trop bas.
  // Demande utilisateur explicite :
  //   « remonte légèrement le texte de la date de naissance »
  //   « pour les coordonnées de l'usager remonte tout les textes
  //    légèrement pour qu'ils soient bien alignés »
  //   « remonte légèrement le texte reponse de reconnaissance
  //    d'invalidité ».
  for (const fieldName of [
    // Bénéficiaire (page 1) — Nom/Prénom restent à -4
    'Nom',
    'Prénom',
  ]) {
    nudgeFieldRect({ fieldsByName, fieldName, dy: -4 });
  }
  for (const fieldName of [
    // Bénéficiaire — date de naissance (un peu moins descendu)
    'date de naissance',
    'date de naissance mme',
    // Reconnaissance d'invalidité (MDPH)
    'MDPH',
    // Coordonnées de l'usager (page 1) — un peu moins descendus
    'tel usager',
    'mail usager',
    'personne à contacter',
    'tel personne confiance',
    'mail personne confiance',
    // Renseignements sur la visite (page 1) — remontés à -2 (au lieu
    // de -4) pour s'aligner avec les libellés Affinity de la même
    // ligne. Demande utilisateur explicite : « parfait, remonte
    // légerement de la meme maniere dans renseignements sur la
    // visite ».
    'personne présente',
    'date',
  ]) {
    nudgeFieldRect({ fieldsByName, fieldName, dy: -2 });
  }

  // Bloc « Renseignements sur l'ergothérapeute » (page 3) : tous les
  // champs (Nom et prénom / entreprise / adresse / contact) ont leur
  // baseline un poil trop haute par rapport aux libellés Affinity de
  // la même ligne. On descend de 2 pt pour aligner sur les libellés
  // « Nom et prénom : », « Entreprise : », etc. Demande utilisateur :
  // « dans renseignements sur l'ergothérapeute redescend tout les
  //  textes légèrement pour qu'ils soient alignés aux textes
  //  correspondants ».
  // NB : `nudgeFieldRect` est silencieux si un champ n'existe pas —
  // si Affinity a baké certaines valeurs en dur dans le content
  // stream plutôt qu'en AcroForm, le nudge n'a juste pas d'effet
  // visible sur ces lignes-là.
  for (const fieldName of [
    'Nom et prénom',
    'entreprise',
    'adresse',
    'contact',
  ]) {
    nudgeFieldRect({ fieldsByName, fieldName, dy: -2 });
  }

  // Section "Logement" page 5 — baseline légèrement trop haute par
  // rapport au libellé Affinity. Premier essai à -4 pt mais l'ergo a
  // remonté que ça descendait alors TROP bas. On affine à -2 pt :
  // assez pour aligner le baseline avec le ":" du libellé sans le
  // pousser en-dessous de la ligne.
  // EXCLU explicite : `nombre d'étage` (PDFDropdown) — la dropdown a
  // déjà son propre baseline correct côté Affinity et le toucher
  // décalerait la pill.
  for (const fieldName of [
    'Adresse',
    'annee1',
    'annee2',
    'surface',
    'Sous sol',
    'rdc',
    'etage',
  ]) {
    nudgeFieldRect({ fieldsByName, fieldName, dy: -2 });
  }

  // ---------------------------------------------------------------
  // Page 8 — Photos visite : 2 Logement, 3 Accès, 3 Sanitaires.
  // Mode 'contain' (défaut) : la photo est insérée ENTIÈRE dans la
  // vignette en préservant son ratio. Si une photo paysage tombe
  // dans un slot portrait (ou l'inverse), du blanc apparaît
  // au-dessus/dessous (ou sur les côtés) plutôt que de cropper la
  // photo. Demande utilisateur : "les images ne doivent pas être
  // cropées si c'est un format paysage sur un encadré portrait,
  // elle doit simplement être plus petite pour que tout passe quitte
  // à laisser du blanc au dessus et en dessous de l'image qui sera
  // centrée dans son cadre". `setImage` de pdf-lib applique
  // exactement cette logique (scaleToFit + ImageAlignment.Center).
  // ---------------------------------------------------------------
  for (const slot of PAGE8_PHOTO_SLOTS) {
    const photos = photosForVisitTag(documents, slot.tag);
    for (let i = 0; i < slot.fields.length; i += 1) {
      const fieldName = slot.fields[i];
      const photo = photos[i];
      if (!photo) continue;
      await setImageInField(
        pdfDoc,
        form,
        fieldName,
        { kind: 'document', id: photo.id },
        fetchImageBytes,
        stats,
      );
    }
  }

  // ---------------------------------------------------------------
  // Pages 9-10 — Plans avant / après. Source : UNIQUEMENT les photos
  // taggées `Visite - Plan avant` / `Visite - Plan après` dans
  // l'onglet Photos du relevé. Demande user 2026-04-28 : "les pages
  // 9 et 10 doivent être uniquement câblés par les images qui seront
  // importées dans Photos, les plans dessinés sur l'app ne doivent
  // pas apparaître dans le rapport PDF".
  //
  // Conséquence : les notePages de l'onglet Plans (canvas dessinés)
  // ne sont plus utilisées par le générateur. Elles restent stockées
  // côté SQLite + NocoDB (l'ergo peut continuer à dessiner pour son
  // usage interne), simplement le rapport PDF ne les lit plus.
  //
  // Photos prises pour chaque slot : ordre = celui de
  // `photosForVisitTag` (date DESC par défaut), max 2 par phase.
  for (const slot of [
    { tag: 'Visite - Plan avant', fields: PLAN_SLOTS.avant },
    { tag: 'Visite - Plan après', fields: PLAN_SLOTS.apres },
  ]) {
    const photos = photosForVisitTag(documents, slot.tag);
    for (let i = 0; i < slot.fields.length; i += 1) {
      const fieldName = slot.fields[i];
      const photo = photos[i];
      if (!photo) continue;
      await setImageInField(
        pdfDoc,
        form,
        fieldName,
        { kind: 'document', id: photo.id },
        fetchImageBytes,
        stats,
        // Mode 'contain' (parité avec les photos page 8) — garde
        // l'image entière sans cropper, fond blanc autour si le ratio
        // diffère du slot.
      );
    }
  }

  // ---------------------------------------------------------------
  // Pages 11-14 — Recommandations (texte + image wiki). 8 slots
  // fixes en v1 ; au-delà, on incrémente `recoOverflow` mais on ne
  // génère pas (encore) de pages bonus dynamiques — TODO chunk 4.2c.
  // ---------------------------------------------------------------
  for (let i = 0; i < recommendations.length; i += 1) {
    if (i >= RECO_TEXT_FIELDS.length) {
      stats.recoOverflow += 1;
      continue;
    }
    const reco = recommendations[i];
    const textFieldName = RECO_TEXT_FIELDS[i];
    const textField = fieldsByName.get(textFieldName);
    if (textField instanceof PDFTextField) {
      try {
        textField.setText(formatRecoText(reco));
        stats.recoTextApplied += 1;
      } catch (error) {
        console.warn(
          `[generateVisitReport] setText("${textFieldName}") :`,
          error?.message || error,
        );
      }
    }
    // Image wiki : on cible le slot image qui correspond exactement à
    // la position de cette reco (haut OU bas de page). Permet de garder
    // l'image alignée avec son texte même quand l'ergo permute / ajoute
    // / retire des préconisations dans l'app.
    const imageFieldName = RECO_IMAGE_FIELDS[i];
    const wikiUrl = String(reco?.wikiImageUrl || '').trim();
    if (imageFieldName && wikiUrl) {
      await setImageInField(
        pdfDoc, form, imageFieldName,
        { kind: 'url', url: wikiUrl },
        fetchImageBytes, stats,
      );
    }
  }

  // ---------------------------------------------------------------
  // Élision des cases de préconisation vides (demande utilisateur :
  // "le nombre d'espace de préconisation doit être egal au nombre
  // de préconisations ajoutées… il ne doit pas y'avoir de cases
  // vides, elles doivent êtes retirées visuellement").
  //
  // Le template PDF a 4 pages × 2 cases (TOP + BOT) = 8 slots fixes.
  // On distingue 3 situations par page :
  //   - les 2 cases utilisées      → garder la page intacte
  //   - seule la case TOP utilisée → garder la page mais blanchir
  //                                   la zone de la case BOT
  //   - aucune case utilisée       → supprimer la page du PDF
  //
  // IMPORTANT : on retrouve l'index réel de chaque page via la
  // référence du widget TOP (`widget.P()`), au lieu de hardcoder
  // `recoPageBaseIndex + pageOffset`. C'était la cause du bug "la
  // dernière préco disparaît si c'est la 3ème ou la 4ème" : selon le
  // template Affinity, page 11 visuelle peut être à l'index 10 OU 11
  // (présence ou non d'une page de garde). En lisant la page directement
  // depuis le widget, on est immunisé contre ce décalage.
  //
  // L'itération se fait en SENS INVERSE (du dernier slot vers le
  // premier) pour que la suppression d'une page n'altère pas l'index
  // des pages restantes qu'on n'a pas encore traitées.
  // ---------------------------------------------------------------
  // ATTENTION — pdf-lib gotcha : `pdfDoc.getPages()` retourne un
  // tableau MIS EN CACHE qui ne se met PAS à jour après removePage.
  // `getPageCount()` et `getPage(idx)` reflètent bien la suppression
  // mais `findPageIndexForField` (qui itère `getPages()`) retournerait
  // un index obsolète. Pour éviter ce piège, on COLLECTE tous les
  // index AVANT flatten et AVANT toute removePage, on fait le travail
  // (cover, embedPage, drawPage) sur les pages encore en place, et on
  // groupe TOUS les removePage à la fin en ordre descendant.
  const recoCount = recommendations.length;
  const emptyPageIndices = []; // pages reco entièrement vides à retirer
  const pendingBotCovers = []; // { pageIdx, botRect, topRect } — partielles
  stats.recoPagesRemoved = 0;
  for (let pageOffset = 3; pageOffset >= 0; pageOffset -= 1) {
    const topRecoIdx = pageOffset * 2;
    const botRecoIdx = pageOffset * 2 + 1;
    const topUsed = topRecoIdx < recoCount;
    const botUsed = botRecoIdx < recoCount;
    const topField = fieldsByName.get(RECO_TEXT_FIELDS[topRecoIdx]);
    const pageIdx = findPageIndexForField(pdfDoc, topField);
    if (pageIdx === -1) continue;
    if (!topUsed && !botUsed) {
      emptyPageIndices.push(pageIdx);
    } else if (topUsed && !botUsed) {
      const botRect = getRecoCaseBoundingBox(fieldsByName, botRecoIdx);
      const topRect = getRecoCaseBoundingBox(fieldsByName, topRecoIdx);
      pendingBotCovers.push({ pageIdx, botRect, topRect });
    }
  }

  // Capture de l'index de la page "Descriptif des aides
  // prévisionnelles" — pareil, AVANT toute removePage et AVANT flatten
  // (les widgets sont consommés par flatten).
  let descriptifPageIdx = -1;
  if (pendingBotCovers.length === 1) {
    const descriptifAnchor =
      fieldsByName.get('Caisse de retraite complémentaire');
    descriptifPageIdx = findPageIndexForField(pdfDoc, descriptifAnchor);
  }

  // (Plus d'overlay page 1 — l'adresse est désormais correcte dans
  // le PDF source Affinity directement, plus besoin de patcher.)
  // Alignement de la couleur du champ adresse page 3 sur les champs
  // voisins (compensation Helvetica vs SegoeUI).
  applyAdresseFieldColorTweak(form);
  // Et bump de la taille de police du bloc « Le Logement » (page 5)
  // de ~10 pt à 12 pt pour s'aligner sur le reste du rapport.
  applyLogementFontSizeTweak(form);

  // Multi-étages page 5 : si l'ergo a sélectionné 2 ou 3 niveaux
  // d'étage (1er + 2e + 3e), on duplique la ligne « Étage » du
  // template en « Étage 1 / 2 / 3 ». Cf. `applyMultiEtageOverlay`.
  // S'exécute AVANT le flatten pour superposer aux widgets AcroForm
  // déjà rendus.
  applyMultiEtageOverlay({ pdfDoc, view });

  // Aplatissement final : convertit chaque champ en contenu fixe (le
  // texte/cocheur devient un objet graphique inerte). Le résultat n'est
  // plus un formulaire éditable. Mettre flatten=false pour debug.
  if (flatten) {
    form.flatten();
  }

  // Blanchiment de la zone BOT vide — fait APRÈS flatten pour passer
  // au-dessus des widgets aplatis. La case BOT du gabarit a sa propre
  // boîte noire + libellés ("Préconisations avec argumentaire" /
  // "Photos, croquis, illustration") qu'on ne veut pas voir traîner.
  //
  // Demande utilisateur : ne PAS recréer de trait orange ni de trait
  // noir de fermeture — on s'appuie sur le cadre orange du descriptif
  // (embedé juste en dessous) pour la fermeture visuelle naturelle.
  // Le cover monte donc jusqu'à `topRect.y` (bord bas de la bbox TOP),
  // ce qui efface aussi le trait noir bas qui pendrait sinon dans le
  // vide sans BOT en dessous.
  //
  // Marges latérales (COVER_X_INSET) et basse (COVER_BOTTOM_Y)
  // préservent le cadre orange du gabarit qui entoure la page.
  const COVER_X_INSET = 25;
  const COVER_BOTTOM_Y = 18;
  // Décalage vers le bas du bord supérieur du masque. Plus la valeur
  // est grande, plus le bord haut du masque descend, donc plus les
  // traits orange verticaux du gabarit (qui s'étendent dans toute la
  // page) restent visibles bas dessous la case TOP. Demande user :
  // "redescend encore le masque pour que les traits orange verticaux
  // aillent légèrement plus bas et rejoignent le trait horizontal."
  // 20 → 34 = +14 pt de plus de verticales orange visibles.
  const COVER_TOP_DROP = 34;
  for (const { pageIdx, botRect, topRect } of pendingBotCovers) {
    if (!botRect) continue;
    let page;
    try {
      page = pdfDoc.getPage(pageIdx);
    } catch (_) {
      continue;
    }
    if (!page) continue;
    const { width: pageWidth, height: pageHeight } = page.getSize();
    const upperY = topRect != null
      ? Math.max(0, topRect.y - COVER_TOP_DROP)
      : pageHeight / 2;
    if (upperY <= COVER_BOTTOM_Y) continue;
    page.drawRectangle({
      x: COVER_X_INSET,
      y: COVER_BOTTOM_Y,
      width: pageWidth - COVER_X_INSET * 2,
      height: upperY - COVER_BOTTOM_Y,
      color: rgb(1, 1, 1),
    });
    // Le trait orange horizontal de fermeture de la zone préco est
    // dessiné PLUS BAS, dans le bloc descriptif (cf. après embedPage),
    // pour pouvoir être centré entre la TOP et le cadre orange du
    // descriptif et joindre exactement les traits verticaux.
  }

  // ---------------------------------------------------------------
  // Remontée du "Descriptif des aides prévisionnelles" sur la même
  // page que la dernière préconisation, quand celle-ci est seule sur
  // sa page (impair = 1, 3, 5, 7). Demande utilisateur : utiliser
  // l'espace libre laissé par la case BOT vide pour caser le tableau
  // descriptif au lieu d'imprimer une page presque blanche suivie
  // d'une page descriptif quasi vide elle aussi.
  //
  // Méthode :
  //   1. On localise dynamiquement la page descriptif via un de ses
  //      champs (`Caisse de retraite complémentaire`).
  //   2. embedPage avec un bbox cropé sur la zone du tableau orange
  //      (déterminé visuellement sur le rendu PNG du gabarit).
  //   3. drawPage de cet XObject sur la page partielle, dans la
  //      moitié BOT (sous le trait orange de fermeture, au-dessus du
  //      cadre orange bas du gabarit).
  //   4. removePage de la page descriptif d'origine pour ne pas la
  //      voir apparaître deux fois.
  // ---------------------------------------------------------------
  if (pendingBotCovers.length === 1 && descriptifPageIdx !== -1) {
    try {
      const descriptifPage = pdfDoc.getPage(descriptifPageIdx);
      // Bbox du tableau orange sur la page descriptif (coordonnées
      // PDF, origine bas-gauche). Ajusté visuellement pour englober
      // le titre, le tableau complet et la marge intérieure du cadre.
      const cropTop = 825;
      const cropBottom = 435;
      const embedded = await pdfDoc.embedPage(descriptifPage, {
        left: 20,
        bottom: cropBottom,
        right: 575,
        top: cropTop,
      });
      const cropHeight = cropTop - cropBottom; // 390 pt
      const { pageIdx: partialPageIdx, topRect } = pendingBotCovers[0];
      const partialPage = pdfDoc.getPage(partialPageIdx);
      // Position : on laisse une petite marge sous la case TOP avant
      // le haut du descriptif (demande utilisateur : "redescend
      // légèrement la coupure du cadre"). 22 pt = aération visible
      // entre le bord bas de la case TOP et le cadre orange du
      // descriptif, sans déborder hors de l'espace utile.
      const TOP_GAP = 50;
      const drawY = topRect != null
        ? Math.max(COVER_BOTTOM_Y, topRect.y - cropHeight - TOP_GAP)
        : 40;
      // Aspect ratio préservé : 555 × 390.
      partialPage.drawPage(embedded, {
        x: 20,
        y: drawY,
        width: 555,
        height: cropHeight,
      });
      // Trait orange horizontal de fermeture de la zone préco —
      // demande utilisateur. Centré verticalement entre le bord bas
      // de la TOP (`topRect.y`) et le bord HAUT du cadre orange du
      // descriptif (`drawY + cropHeight`).
      //
      // Calage horizontal : les traits verticaux orange du gabarit
      // sont à x ≈ 30 / pageWidth - 30 (mesurés sur le PDF rendu).
      // L'ancien `COVER_X_INSET` (25) faisait dépasser le trait
      // horizontal de ~5 pt à chaque extrémité. On utilise donc un
      // inset dédié `H_LINE_X_INSET = 30` qui aligne pile les
      // extrémités du trait horizontal avec les verticales du
      // gabarit. Épaisseur réduite à 0.3 pt (vs 0.5 avant) pour
      // matcher la finesse des verticales — l'utilisateur trouvait
      // 0.5 encore trop épais.
      if (topRect != null) {
        const descriptifFrameTop = drawY + cropHeight;
        // Centrage vertical entre la TOP et le cadre descriptif, puis
        // drop vers le bas. Itérations utilisateur : -3 → -6 pt
        // (demande "descend encore légèrement le trait horizontal").
        // Itérations user : -3 → -6 → -8 pt (descend un tout petit
        // peu de plus).
        const orangeLineY =
            (topRect.y + descriptifFrameTop) / 2 - 8;
        // Itérations user sur l'inset horizontal : 30 → 32 → 31 → 30
        // → 30.5 pt (demande "ça dépasse, reduis de 0.5 de chaque côté").
        const hLineXInset = 30.5;
        // Itérations user sur épaisseur : 0.5 → 0.4 → 0.35 → 0.2 → 0.1 → 0.2
        // (0.1 trop fin à l'œil, retour au sweet spot 0.2).
        partialPage.drawRectangle({
          x: hLineXInset,
          y: orangeLineY,
          width: partialPage.getSize().width - hLineXInset * 2,
          height: 0.2,
          color: rgb(0xED / 255, 0x98 / 255, 0x44 / 255),
        });
      }
      stats.descriptifMerged = true;
    } catch (error) {
      console.warn(
        '[generateVisitReport] descriptif merge a échoué :',
        error?.message || error,
      );
    }
  }

  // ---------------------------------------------------------------
  // SUPPRESSIONS — toutes regroupées en fin de pipeline et faites en
  // ORDRE DESCENDANT des index ORIGINAUX (les indices capturés AVANT
  // tout removePage). pdf-lib applique chaque removePage sur l'état
  // courant du page tree : en passant des indices originaux dans
  // l'ordre décroissant, on s'assure de viser à chaque fois la même
  // page logique qu'au moment de la capture.
  // ---------------------------------------------------------------
  const allRemovals = [...emptyPageIndices];
  if (stats.descriptifMerged && descriptifPageIdx !== -1) {
    allRemovals.push(descriptifPageIdx);
  }
  allRemovals.sort((a, b) => b - a);
  for (const idx of allRemovals) {
    try {
      pdfDoc.removePage(idx);
    } catch (error) {
      console.warn(
        `[generateVisitReport] removePage(${idx}) :`,
        error?.message || error,
      );
    }
  }
  stats.recoPagesRemoved = emptyPageIndices.length;

  const bytes = await pdfDoc.save({
    // On garde les xref tables compactes pour sortir un PDF d'environ
    // la même taille que le template (~2,7 Mo) sans bloat.
    useObjectStreams: true,
  });

  return { bytes, stats };
}

/**
 * Construit un nom de fichier propre pour le PDF généré, format
 * `Rapport - DUPONT Marie.pdf` (demande utilisateur — plus lisible que
 * l'ancien `Rapport_DUPONT_Marie_2024-07-22.pdf` snake_case + date).
 *
 * Caractères filtrés : on garde lettres accentuées + chiffres + tirets
 * + apostrophes (les caractères filesystem-safe sur les 3 OS cibles
 * macOS/Windows/Linux). Les autres deviennent des espaces qui sont
 * ensuite collapsés.
 */
export function buildReportFileName(dossier) {
  const patient = dossier?.patient || {};
  const sanitize = (raw) =>
    String(raw || '')
      // Bannir les caractères réservés sur Windows (`<>:"/\|?*`) et les
      // caractères de contrôle. Les autres restent (accents, espaces,
      // apostrophes, tirets).
      .replace(/[<>:"/\\|?*\x00-\x1F]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();

  const last = sanitize(patient.lastName).toUpperCase();
  const first = sanitize(patient.firstName);

  // Compose "DUPONT Marie" en sautant les parties vides — un dossier
  // sans nom renvoie "Bénéficiaire" pour qu'on n'ait jamais un
  // "Rapport - .pdf" malformé.
  const composed = [last, first].filter(Boolean).join(' ').trim();
  const display = composed || 'Bénéficiaire';

  return `Rapport - ${display}.pdf`;
}
