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
  StandardFonts,
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
    fontSize: 10,
    color: rgb(0, 0, 0), // texte noir comme l'original Affinity
    line1: { x: 47, y: 97 },           // baseline de "47 avenue ..."
    line2: { x: 47, y: 77 },           // baseline de "35200 Rennes"
    // Rectangle de masquage — un poil plus grand que le bbox texte
    // pour absorber les ascendants/descendants éventuels. Couleur
    // matchée sur le fond pêche du bandeau Affinity (#F4DBC4 sampled
    // sur le rendu PNG du template — sinon le mask blanc est visible).
    mask: { x: 44, y: 73, width: 180, height: 44 },
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
function buildViewModel({ dossier, sanitaires, observations }) {
  const patient = dossier?.patient || {};
  const housing = dossier?.housing || {};
  const firstName = String(patient.firstName || '').trim();
  const lastName = String(patient.lastName || '').trim();

  // Affichage de l'aide à domicile : si l'ergo a saisi du texte, on
  // l'affiche tel quel (ex. "2x/semaine, ADMR"). Sinon "Oui" si la
  // case est cochée, "Non" si elle ne l'est pas (UX confirmée par
  // l'utilisateur : "si ce n'est pas coché c'est forcément non").
  const homeHelpTxt = String(patient.homeHelpTxt || '').trim();
  const homeHelp = Boolean(patient.homeHelp);
  const homeHelpDisplay =
    homeHelpTxt || (homeHelp ? 'Oui' : 'Non');

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
    surface: String(housing.surface || '').trim(),
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
      dependenceTxt: String(patient.dependenceTxt || '').trim(),
    },
    dossier: {
      personnesPresentesVisite: String(dossier?.personnesPresentesVisite || '').trim(),
      visitDateFr: formatFrenchDate(dossier?.visitDate),
    },
    contexte: {
      environnement: buildEnvironnementText(dossier),
      habitudes: buildHabitudesText(dossier),
    },
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
      if (value) field.check(); else field.uncheck();
    } else if (type === 'radio') {
      if (!(field instanceof PDFRadioGroup)) {
        // Cas typique : Affinity Publisher exporte les "radios" comme
        // checkbox indépendantes. On gère via `match` côté checkbox.
        if (field instanceof PDFCheckBox && entry.match != null) {
          if (value === entry.match) field.check(); else field.uncheck();
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
 */
async function setImageInField(pdfDoc, form, fieldName, descriptor, fetchImageBytes, stats) {
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
  try {
    field.setImage(pdfImage);
    stats.imagesApplied += 1;
  } catch (error) {
    console.warn(`[generateVisitReport] setImage("${fieldName}") a échoué :`, error?.message || error);
    stats.imagesFailedEmbed += 1;
  }
}

/**
 * Filtre + trie les photos d'une catégorie visite donnée. Le serveur
 * ne synchronise pas `categoryOrder` (local-only en v1) — on retombe
 * sur l'ordre date DESC fourni par `listDocumentsByPatient`.
 */
function photosForVisitTag(documents, tag) {
  return documents.filter((doc) =>
    Array.isArray(doc?.tags) && doc.tags.includes(tag),
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
 * image). On alterne `Image*_af_image` (top de page) et
 * `croquis*_af_image` (bot de page). En v1 (décision utilisateur),
 * les croquis restent vides — donc on remplit uniquement les `Image`.
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
// Index pair (0, 2, 4, 6) → image de la reco impaire (1ère, 3ème…)
// posée dans le champ `Image*` du haut de page. Index impair → champ
// `croquis*` du bas de page (laissé vide en v1).
const RECO_IMAGE_FIELDS_TOP = [
  'Image8_af_image',
  'Image85_af_image',
  'Image874_af_image',
  'Image846_af_image',
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

export async function generateVisitReport({
  dossier,
  sanitaires,
  observations,
  documents = [],
  notePages = [],
  recommendations = [],
  fetchImageBytes,
  flatten = true,
}) {
  const { templateBytes, mapping } = await loadTemplate();
  const view = buildViewModel({ dossier, sanitaires, observations });

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

  // ---------------------------------------------------------------
  // Page 8 — Photos visite : 2 Logement, 3 Accès, 3 Sanitaires
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
    // Image : seulement les recos d'index pair (0, 2, 4, 6) ont leur
    // wiki photo en haut de page (les croquis bas-de-page restent vides
    // par décision utilisateur).
    if (i % 2 === 0) {
      const imageFieldName = RECO_IMAGE_FIELDS_TOP[Math.floor(i / 2)];
      const wikiUrl = String(reco?.wikiImageUrl || '').trim();
      if (imageFieldName && wikiUrl) {
        await setImageInField(
          pdfDoc, form, imageFieldName,
          { kind: 'url', url: wikiUrl },
          fetchImageBytes, stats,
        );
      }
    }
  }

  // Override de l'adresse Aid'Habitat sur la couverture (texte
  // hardcodé dans le PDF — pas un champ de formulaire).
  await applyErgoContactOverlay(pdfDoc);

  // Aplatissement final : convertit chaque champ en contenu fixe (le
  // texte/cocheur devient un objet graphique inerte). Le résultat n'est
  // plus un formulaire éditable. Mettre flatten=false pour debug.
  if (flatten) {
    form.flatten();
  }

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
