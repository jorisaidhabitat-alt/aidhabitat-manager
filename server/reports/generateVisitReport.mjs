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
 * Construit un payload "view-friendly" à partir de l'objet dossier
 * récupéré côté NocoDB. Ajoute des champs dérivés (`fullNameUpper`,
 * `visitDateFr`, etc.) que le mapping JSON peut référencer directement
 * sans logique inline.
 *
 * On accepte l'objet brut tel que renvoyé par `/api/dossiers` ou
 * `/api/dossiers/:id` côté serveur — il a déjà la structure {
 *   patient: { firstName, lastName, ... },
 *   ... champs dossier à plat ... }
 * Voir `helpers.mjs` mapStoredDossier pour la liste complète.
 */
function buildViewModel(dossier) {
  const patient = dossier?.patient || {};
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
 * @param {boolean} [options.flatten=true] — aplatit les champs (PDF
 *                  non-modifiable). Mettre à false pour debug : le PDF
 *                  rendu reste éditable champ par champ dans Acrobat.
 * @returns {Promise<Uint8Array>} les bytes du PDF généré.
 */
export async function generateVisitReport({ dossier, flatten = true }) {
  const { templateBytes, mapping } = await loadTemplate();
  const view = buildViewModel(dossier);

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
