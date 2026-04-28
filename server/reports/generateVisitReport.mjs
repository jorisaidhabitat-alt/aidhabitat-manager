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

const TEMPLATE_PATH = path.resolve(
  __dirname,
  '../templates/visitReport.template.pdf',
);
const MAPPING_PATH = path.resolve(
  __dirname,
  '../templates/visitReport.mapping.json',
);

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

const ERGO_CONTACT = {
  page3OneLine: '16 rue Léo Lagrange, 35131 Chartres-de-Bretagne',
  page1: {
    addressLine1: '16 rue Léo Lagrange',
    addressLine2: '35131 Chartres-de-Bretagne',
    // Police Affinity du bloc = SegoeUI 12pt noir (lu via la DA des
    // champs voisins). pdf-lib fallback sur Helvetica 12pt sans
    // fontkit — la différence de rendu reste minime à cette taille.
    fontSize: 12,
    color: rgb(0, 0, 0), // noir, demande utilisateur
    // Baselines : itérations user → 100/80 (trop bas), 115/95, 110/90,
    // 105/85 (toujours trop hauts). À +2pt → y=102/82.
    line1: { x: 47, y: 102 },
    line2: { x: 47, y: 82 },
    // Rectangle de masquage — strictement dimensionné autour des 2
    // lignes de texte (Helvetica 12pt : baseline + ~8pt en haut +
    // ~3pt descender en bas). Un masque trop grand débordait sur la
    // ligne « Aid'Habitat » au-dessus ou sur le téléphone en dessous
    // (demande utilisateur). Calcul :
    //   - bottom : line2.y - 4 = 78
    //   - top    : line1.y + 9 = 111
    //   - height : 33
    mask: { x: 44, y: 78, width: 184, height: 33 },
    maskColor: rgb(244 / 255, 219 / 255, 196 / 255), // #F4DBC4
  },
};

let cachedTemplate = null;
let cachedMapping = null;

/**
 * Charge le template PDF + le mapping JSON une seule fois (cache mémoire).
 * Le template fait ~2,7 Mo, on évite de le relire du disque à chaque génération.
 */
async function loadTemplate() {
  if (cachedTemplate && cachedMapping) {
    return { templateBytes: cachedTemplate, mapping: cachedMapping };
  }
  const [templateBytes, mappingRaw] = await Promise.all([
    fs.readFile(TEMPLATE_PATH),
    fs.readFile(MAPPING_PATH, 'utf8'),
  ]);
  cachedTemplate = templateBytes;
  cachedMapping = JSON.parse(mappingRaw);
  return { templateBytes: cachedTemplate, mapping: cachedMapping };
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
  return pages
    .map((pg) => String(pg?.textContent || '').trim())
    .filter((s) => s.length > 0)
    .join('\n\n')
    .trim();
}

/**
 * Pour le champ "Dépendance" du PDF, l'ergo saisit souvent du texte
 * libre du genre "Canne, marche difficilement". Le rapport ne garde
 * que le mot-clé (Aucune / Canne / Déambulateur / Fauteuil roulant)
 * — match d'abord contre les options connues, sinon fallback sur la
 * 1ère portion avant virgule ou point.
 */
function normalizeDependenceForReport(raw) {
  const text = String(raw || '').trim();
  if (!text) return '';
  const known = ['Aucune', 'Canne', 'Déambulateur', 'Fauteuil roulant'];
  const lc = text.toLowerCase();
  for (const opt of known) {
    if (lc.includes(opt.toLowerCase())) return opt;
  }
  // Fallback : 1er segment avant virgule/point.
  const first = text.split(/[,.;]/)[0]?.trim() || text;
  return first;
}

function buildViewModel({
  dossier,
  sanitaires,
  observations,
  contexteNotes = [],
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

  // Reconnaissance MDPH : on privilégie le texte (qui contient
  // typiquement le %) mais on retombe sur "Oui" si la case est cochée
  // sans détail. Vide sinon — on n'écrit pas "Non" car le PDF n'a
  // pas vraiment de UI Non explicite à côté du champ.
  const invalidityTxt = String(patient.invalidityTxt || '').trim();
  const invalidity = Boolean(patient.invalidity);
  const invalidityDisplay =
    invalidityTxt || (invalidity ? 'Oui' : '');

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
    basementDesc: String(housing.basementDesc || '').trim(),
    rdcDesc: String(housing.rdcDesc || '').trim(),
    floorDesc: String(housing.floorDesc || '').trim(),
    garage: Boolean(housing.garage),
    veranda: Boolean(housing.veranda),
    balcon: Boolean(housing.balcon),
    terrasse: Boolean(housing.terrasse),
    jardin: Boolean(housing.jardin),
    heatingMain: Boolean(housing.heatingMain),
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
    accessObservation: joinNonEmpty([
      housing.accessObservation,
      housing.comments,
    ], '\n'),
  };

  // --- Page 6 : Sanitaires ---
  // On consolide en une "vue 1ère SDB / 1er WC". Si l'ergo a
  // plusieurs instances, les autres seront servies via pages bonus
  // (chunk 4.2c). Pour l'instant on remplit juste la première.
  const sdb = (Array.isArray(sanitaires?.sdbInstances) && sanitaires.sdbInstances[0]) || {};
  const wc = (Array.isArray(sanitaires?.wcInstances) && sanitaires.wcInstances[0]) || {};
  const sanitairesView = {
    // SDB située au niveau pièces de vie ?
    sdbAuNiveauPieceVie: Boolean(sdb.sdbNiveauPiecesVie),
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
    // Niveau WC : levelField peut être 'rdc' / 'etage' / 'sous_sol'
    wcAuNiveau: /(rdc|niveau|pieces_de_vie)/i.test(String(wc.levelField || '')),
    wcEtage: /etage|floor/i.test(String(wc.levelField || '')),
    // Porte WC
    porteWcLargeurSuffisante: Boolean(wc.porteWcLargeurSuffisante),
    porteWcDimensionFr: formatWidthCm(wc.porteWcDimension),
    porteWcSensInterieur: Boolean(wc.porteWcSensAdapte),
    porteWcSensExterieur: !wc.porteWcSensAdapte && (wc.porteWcDimension != null),
    // Observations
    observationsEquipements: String(wc.observationEquipementsUtilisation || '').trim(),
  };

  // --- Page 7 : Projet + Résumé ---
  const observationsView = {
    projetSouhaitUsage: String(observations?.projetSouhaitUsage || '').trim(),
    resumePreconisations: String(observations?.resumePreconisations || '').trim(),
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
      apaLabel: patient.apa ? 'Oui' : 'Non',
      apaGirRaw: patient.apa
        ? String(patient.apaGir || '').trim()
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
    },
    dossier: {
      personnesPresentesVisite: String(dossier?.personnesPresentesVisite || '').trim(),
      visitDateFr: formatFrenchDate(dossier?.visitDate),
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
 * Dessine « GIR n » en texte libre juste à droite du dropdown
 * « Dropdown5 » (APA Oui/Non/En cours). Sans ça, le GIR saisi par
 * l'ergo ne pouvait s'afficher nulle part — la dropdown du template
 * ne propose que les 3 options figées et n'a pas de slot dédié au
 * GIR. On localise le widget du dropdown pour récupérer sa page +
 * ses coordonnées, puis on pose le texte juste à côté.
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
  // Baseline aligné avec le centre vertical du dropdown : y = bottom +
  // (height - fontSize) / 2 ≈ bottom + 5 pour un texte de 11 pt dans
  // une box de 21 pt. Décalage horizontal : 8 pt après le bord droit
  // de la pill.
  const fontSize = 11;
  const x = rect.x + rect.width + 8;
  const y = rect.y + (rect.height - fontSize) / 2 + 1;

  const helvetica = await pdfDoc.embedFont(StandardFonts.Helvetica);
  page.drawText(`GIR ${apaGir}`, {
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
async function applyErgoContactOverlay(pdfDoc) {
  try {
    const page = pdfDoc.getPage(0);
    const cfg = ERGO_CONTACT.page1;
    // 1) Masquage : rectangle de la couleur du bandeau (pêche) pour
    // que la zone se fonde dans le fond Affinity sans liseré blanc
    // visible.
    page.drawRectangle({
      x: cfg.mask.x,
      y: cfg.mask.y,
      width: cfg.mask.width,
      height: cfg.mask.height,
      color: cfg.maskColor,
    });
    // 2) Redraw : 2 lignes de texte avec Helvetica embedded.
    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);
    page.drawText(sanitizeForPdfFont(cfg.addressLine1), {
      x: cfg.line1.x,
      y: cfg.line1.y,
      size: cfg.fontSize,
      font,
      color: cfg.color,
    });
    page.drawText(sanitizeForPdfFont(cfg.addressLine2), {
      x: cfg.line2.x,
      y: cfg.line2.y,
      size: cfg.fontSize,
      font,
      color: cfg.color,
    });
  } catch (error) {
    console.warn('[generateVisitReport] applyErgoContactOverlay :', error?.message || error);
  }
}

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

export async function generateVisitReport({
  dossier,
  sanitaires,
  observations,
  documents = [],
  notePages = [],
  contexteNotes = [],
  recommendations = [],
  fetchImageBytes,
  flatten = true,
}) {
  const { templateBytes, mapping } = await loadTemplate();
  const view = buildViewModel({
    dossier,
    sanitaires,
    observations,
    contexteNotes,
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
  // Pages 9-10 — Plans avant / après. Une fois pris depuis l'app
  // (preview_data_url poussé par le canvas Flutter à la sauvegarde).
  // ---------------------------------------------------------------
  for (const phase of ['avant', 'apres']) {
    const slotNames = PLAN_SLOTS[phase];
    const phasePages = notePages
      .filter((pg) => pg && pg.planPhase === phase)
      .slice(0, slotNames.length);
    for (let i = 0; i < phasePages.length; i += 1) {
      const fieldName = slotNames[i];
      const page = phasePages[i];
      // 0. note_page (cache inline embarqué dans la requête HTTP).
      //    Cas typique : plan dessiné offline, pas encore synchronisé
      //    vers NocoDB → previewDataUrl absent côté serveur, mais le
      //    client a envoyé les bytes PNG en multipart. Le wrapper
      //    fetchImageBytes (cf. buildInlineFirstFetcher dans index.mjs)
      //    retourne le buffer directement. Si pas d'inline, retourne
      //    null et on tombe sur les fallbacks suivants.
      const inlineNotePageBytes = await fetchImageBytes({
        kind: 'note_page',
        id: page.id,
      }).catch(() => null);
      if (inlineNotePageBytes?.buffer && inlineNotePageBytes.buffer.length > 0) {
        // On utilise une descriptor `dataurl` factice pour réutiliser
        // setImageInField — mais on contourne fetchImageBytes en
        // passant un fetcher qui retourne directement les bytes déjà
        // résolus. Évite un deuxième appel inutile.
        await setImageInField(
          pdfDoc, form, fieldName,
          { kind: 'inline_resolved' },
          async () => inlineNotePageBytes,
          stats,
        );
        continue;
      }
      // 1. preview_data_url (data URL prête à l'emploi)
      if (page.previewDataUrl) {
        await setImageInField(
          pdfDoc, form, fieldName,
          { kind: 'dataurl', dataUrl: page.previewDataUrl },
          fetchImageBytes, stats,
        );
        continue;
      }
      // 2. preview_url (URL HTTP renvoyée par /api/note-pages → preview)
      if (page.previewUrl) {
        await setImageInField(
          pdfDoc, form, fieldName,
          { kind: 'url', url: page.previewUrl },
          fetchImageBytes, stats,
        );
        continue;
      }
      // 3. Pas de preview → on log et on saute. Le canvas Flutter
      //    devrait pousser une preview à la sauvegarde — si ce n'est
      //    pas le cas, c'est un bug du sync, pas du générateur.
      console.warn(
        `[generateVisitReport] note Plans ${page.id} sans preview, slot ${fieldName} laissé vide`,
      );
      stats.imagesMissingValue += 1;
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

  // Override de l'adresse Aid'Habitat sur la couverture (texte
  // hardcodé dans le PDF — pas un champ de formulaire).
  await applyErgoContactOverlay(pdfDoc);
  // Et alignement de la couleur du champ adresse page 3 sur les
  // champs voisins (compensation Helvetica vs SegoeUI).
  applyAdresseFieldColorTweak(form);
  // Et bump de la taille de police du bloc « Le Logement » (page 5)
  // de ~10 pt à 12 pt pour s'aligner sur le reste du rapport.
  applyLogementFontSizeTweak(form);

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
        // Itérations user sur épaisseur : 0.5 → 0.4 → 0.35 → 0.2 → 0.1 pt.
        // Limite extrême — selon le viewer (Aperçu macOS, Acrobat, Preview
        // iOS) le rendu peut faire un sub-pixel rendering ; à l'impression
        // A4 reste discret mais visible.
        partialPage.drawRectangle({
          x: hLineXInset,
          y: orangeLineY,
          width: partialPage.getSize().width - hLineXInset * 2,
          height: 0.1,
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
