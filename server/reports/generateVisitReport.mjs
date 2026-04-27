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
import { PDFDocument, PDFTextField, PDFCheckBox, PDFRadioGroup, PDFDropdown } from 'pdf-lib';

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
      // APA : Dropdown5 du PDF prend 'Oui' / 'Non' littéral.
      apaLabel: patient.apa ? 'Oui' : 'Non',
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
      // String() pour les nombres/booléens éventuels.
      field.setText(value == null ? '' : String(value));
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
 * @param {boolean} [options.flatten=true] — aplatit les champs (PDF
 *                  non-modifiable). Mettre à false pour debug : le PDF
 *                  rendu reste éditable champ par champ dans Acrobat.
 * @returns {Promise<Uint8Array>} les bytes du PDF généré.
 */
export async function generateVisitReport({
  dossier,
  sanitaires,
  observations,
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

  const stats = { applied: 0, missingField: 0, missingValue: 0 };

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
 * Construit un nom de fichier propre pour le PDF généré, du genre
 * `Rapport_DUPONT_Marie_2024-07-22.pdf`.
 */
export function buildReportFileName(dossier) {
  const patient = dossier?.patient || {};
  const last = String(patient.lastName || '').toUpperCase().replace(/[^A-Z0-9_-]+/g, '_');
  const first = String(patient.firstName || '').replace(/[^A-Za-zÀ-ÿ0-9_-]+/g, '_');
  const dateRaw = dossier?.visitDate;
  const date = dateRaw ? new Date(dateRaw) : new Date();
  const yyyy = date.getUTCFullYear();
  const mm = String(date.getUTCMonth() + 1).padStart(2, '0');
  const dd = String(date.getUTCDate()).padStart(2, '0');
  return `Rapport_${last || 'Beneficiaire'}_${first || ''}_${yyyy}-${mm}-${dd}.pdf`
    .replace(/_+/g, '_')
    .replace(/_\./g, '.');
}
