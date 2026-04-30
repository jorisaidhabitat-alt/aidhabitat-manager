import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import express from 'express';
import { fileURLToPath, pathToFileURL } from 'node:url';
import dotenv from 'dotenv';
import multer from 'multer';
import { callNocoTool, closeMcpClient } from './nocodbMcpClient.mjs';
import { createMobileSyncStore } from './mobileSyncStore.mjs';
import {
  resyncBeneficiaireDenormalizedNames,
} from './resyncLegacyNames.mjs';
import { getRetirementFundMeta } from './retirementFundsCatalog.mjs';
import { WIKI_FILTER_TAGS, WIKI_LIBRARY_SEED } from './wikiLibraryCatalog.mjs';
import { LOCAL_SESSION_TOKEN_PREFIX } from '../shared/localAuthProfiles.js';
import {
  putObject,
  statObject,
  getJson,
  putJson,
  putChunk,
  reassembleChunks,
  deleteChunks,
  listChunks,
} from './storage.mjs';
import {
  generateVisitReport,
  buildReportFileName,
} from './reports/generateVisitReport.mjs';

dotenv.config({ path: '.env.local' });
dotenv.config();

// ---------------------------------------------------------------------------
// Constants (mirrors helpers.mjs — index.mjs is self-contained for Vercel)
// ---------------------------------------------------------------------------
const port = Number(process.env.API_PORT || 3001);
const SERVER_DIR_PATH = path.dirname(fileURLToPath(import.meta.url));
const DIST_DIR_PATH = path.resolve(SERVER_DIR_PATH, '../dist');
const DIST_INDEX_PATH = path.join(DIST_DIR_PATH, 'index.html');
const LOCAL_DATA_DIR_PATH = fileURLToPath(new URL('./data/', import.meta.url));
const DATA_DIR_PATH = process.env.VERCEL
  ? path.join('/tmp', 'aidhabitat-data')
  : LOCAL_DATA_DIR_PATH;
const DATA_DIR_URL = pathToFileURL(DATA_DIR_PATH.endsWith(path.sep) ? DATA_DIR_PATH : `${DATA_DIR_PATH}${path.sep}`);
const dataFileUrl = (relativePath) => new URL(relativePath, DATA_DIR_URL);
const AUTH_STORE_URL = dataFileUrl('auth-store.json');
const PROFILE_PHOTOS_DIR_URL = dataFileUrl('profile-photos/');
const DOCUMENTS_DIR_URL = dataFileUrl('documents/');
const VISIT_PLANS_DIR_URL = dataFileUrl('visit-plans/');
const WIKI_LIBRARY_DIR_URL = dataFileUrl('wiki-library/');
const DOCUMENT_STORE_URL = dataFileUrl('documents-store.json');
const NOTE_PAGES_STORE_URL = dataFileUrl('note-pages-store.json');
const RETIREMENT_FUNDS_STORE_URL = dataFileUrl('retirement-funds.json');
const VISIT_RECOMMENDATIONS_STORE_URL = dataFileUrl('visit-recommendations.json');
const VISIT_RECOMMENDATIONS_TABLE_NAME = process.env.NOCODB_VISIT_RECOMMENDATIONS_TABLE_NAME || 'mobile_visit_recommendations';
const WIKI_LIBRARY_STORE_URL = dataFileUrl('wikiLibraryStatic.json');
const BUNDLED_WIKI_LIBRARY_PATH = path.resolve(SERVER_DIR_PATH, '../data/wikiLibraryStatic.json');
const AUTH_CACHE_TTL_MS = 30_000;
const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 7;
const ANAH_STATUS_TTL_MS = 60_000;
const ANAH_PUBLIC_URL = 'https://www.anah.gouv.fr/';
const ANAH_REGISTRATION_URL = 'https://monprojet.anah.gouv.fr/';
const APP_PUBLIC_BASE_URL = String(process.env.APP_PUBLIC_BASE_URL || '').trim().replace(/\/+$/, '')
  || (process.env.VERCEL_URL ? `https://${String(process.env.VERCEL_URL).trim()}` : '');
const LOCALHOST_URL_PATTERN = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//i;
// Accepts every Vercel preview + prod host belonging to this project family:
//   - aid-habitat-manager.vercel.app      (legacy React + API root)
//   - aid-habitat-manager-xxx.vercel.app  (Vercel preview deploys)
//   - aid-habitat-app.vercel.app          (Flutter PWA iPad)
//   - aid-habitat-app-xxx.vercel.app      (Flutter PWA previews)
const PROJECT_VERCEL_HOST_PATTERN = /^aid-habitat-(manager|app)(?:-[a-z0-9-]+)?\.vercel\.app$/i;
let anahStatusCache = null;
let bundledWikiItemsCache = null;

const MEMBER_PROFILES = {
  'contact@aidhabitat.fr': { displayName: 'Renan', role: 'ADMIN', selectable: false, establishmentId: null, establishmentLabel: '' },
  'joris.aidhabitat@gmail.com': { displayName: 'Coralie', role: 'ERGO', selectable: true, establishmentId: 2, establishmentLabel: "Aid'habitat" },
  'joris.balluais@gmail.com': { displayName: 'Christelle', role: 'ERGO', selectable: true, establishmentId: 2, establishmentLabel: "Aid'habitat" },
};
const DEFAULT_LEGACY_ERGO_EMAIL = 'joris.aidhabitat@gmail.com';
let memberRegistryCache = null;

const app = express();

const ALLOWED_ORIGINS = new Set(
  [APP_PUBLIC_BASE_URL, process.env.CORS_EXTRA_ORIGIN].filter(Boolean),
);

function isOriginAllowed(origin) {
  if (!origin) return true; // same-origin / non-browser requests
  if (ALLOWED_ORIGINS.has(origin)) return true;
  try {
    const { hostname } = new URL(origin);
    if (hostname === 'localhost' || hostname === '127.0.0.1') return true;
    if (PROJECT_VERCEL_HOST_PATTERN.test(hostname)) return true;
  } catch { /* malformed origin */ }
  return false;
}

app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (isOriginAllowed(origin)) {
    res.header('Access-Control-Allow-Origin', origin || '*');
    res.header('Vary', 'Origin');
    // Only allow credentials when the origin is explicitly allowed — the
    // spec forbids `Allow-Origin: *` together with `Allow-Credentials: true`.
    // The Flutter PWA keeps its Express session via cookies in some
    // flows, so the browser needs this to accept responses served over
    // cross-origin requests made with `credentials: 'include'`.
    res.header('Access-Control-Allow-Credentials', 'true');
  }
  res.header('Access-Control-Allow-Headers', 'Content-Type, Authorization, X-App-Session, If-Unmodified-Since');
  res.header('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  // Expose les headers custom au JavaScript du PWA. Sans cette ligne, le
  // navigateur n'expose PAS `Content-Disposition` à `fetch()` — Flutter
  // ne pouvait donc pas extraire le nom de fichier proprement formaté du
  // rapport PDF (« Rapport - DENA Paul.pdf ») et tombait sur le fallback
  // hard-codé `'rapport.pdf'`. Conséquence : le doc apparaissait dans
  // l'espace Documents du bénéficiaire avec le titre « rapport » au lieu
  // du nom complet. On expose aussi `X-Report-Stats` qui sert au debug
  // du mapping AcroForm côté Flutter.
  res.header(
    'Access-Control-Expose-Headers',
    'Content-Disposition, X-Report-Stats, X-Saved-Doc-Uuid',
  );
  // The Flutter PWA runs in a crossOriginIsolated context
  // (COEP: credentialless + COOP: same-origin) so SharedArrayBuffer —
  // required by sqflite_common_ffi_web's shared worker — is available.
  // A side effect is that cross-origin responses without an explicit
  // Cross-Origin-Resource-Policy get blocked at the browser level,
  // producing a silent `TypeError: Failed to fetch`. Declaring the API
  // as `cross-origin` tells the browser these responses are safe to
  // consume from the PWA origin (CORS still gates the actual data).
  res.header('Cross-Origin-Resource-Policy', 'cross-origin');
  if (req.method === 'OPTIONS') {
    res.sendStatus(204);
    return;
  }
  next();
});

app.use(express.json({ limit: '30mb' }));

const documentUpload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 30 * 1024 * 1024 } });

/**
 * Multer dédié au endpoint /api/reports/visit/:dossierId. Plus tolérant
 * en taille (ergo peut envoyer 8-10 photos × ~3 MB en HEIC/JPG haute
 * résolution + 4 plans PNG rasterisés).
 *
 * Utilisation : `reportInlineUpload.any()` → tous les fichiers sont mis
 * dans `req.files`, on les pioche par `fieldname` (`inline_doc_<id>`,
 * `inline_plan_<id>`).
 */
const reportInlineUpload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: 30 * 1024 * 1024, // par fichier
    files: 32,                  // 8 photos + 4 plans + 8 reco-images + marge
  },
});

/**
 * Middleware conditionnel : applique `multer.any()` SEULEMENT si la
 * requête est en multipart/form-data. Sinon (JSON ou body vide), on
 * passe au handler sans rien parser. Permet aux anciens clients (POST
 * sans body) de continuer à fonctionner sans casser leur déploiement
 * pendant la transition.
 */
const conditionalReportMultipart = (req, res, next) => {
  const contentType = String(req.headers['content-type'] || '');
  if (contentType.toLowerCase().includes('multipart/form-data')) {
    return reportInlineUpload.any()(req, res, next);
  }
  return next();
};
app.use('/uploads/profile-photos', express.static(PROFILE_PHOTOS_DIR_URL.pathname));
app.use('/uploads/documents', express.static(DOCUMENTS_DIR_URL.pathname));
app.use('/uploads/visit-plans', express.static(VISIT_PLANS_DIR_URL.pathname));
app.use('/uploads/wiki-library', express.static(WIKI_LIBRARY_DIR_URL.pathname));

const TABLES = {
  beneficiaires: 'muvp56d5i9z2qbe',
  logements: 'mgdpvdrnzyy6n4k',
  dossiers: 'mez74y7ndoej30p',
  observations: 'mbkuomk0aazes1c',
  diagnosticSanitaires: 'mdukulxcd18ae3o',
  mesuresAnthropometriques: 'mbaj91z97utreco',
  // Photos visite — table dédiée (séparée de mobile_documents).
  // Demande utilisateur 2026-04-30 : « les photos de l'espace photos
  // ne doivent pas être mélangées avec les documents ». Les rows
  // existantes ont été migrées depuis mobile_documents le 2026-04-30.
  visitPhotos: 'mfeu4lijbge4opz',
  communes: 'mtwhx481kcfn19h',
  epci: 'mntevbq41mk4y6h',
  situationProprietaire: 'mqwqqzsfopejd5q',
  statutOccupation: 'mqgrx6hut8oskbr',
  dependancesParticulieres: 'm09p3a4xns7wqdg',
  etablissements: 'mw1ajdw6ictkdzf',
  ergotherapeutes: 'mww8mr4ngp3nbxh',
  caissesRetraite: 'mxmsm320nnljdmm',
  caissesRetraiteComplementaires: 'm067j5k5a03beog',
  wikiTags: 'mt36dqp3ybw5dtt',
  wiki: 'm34ho32msfz8b2x',
  typeDeLogement: 'mp34j2fxnupoxd0',
  porteDeGarage: 'my9em2miybwiwr0',
  portail: 'm8e1g1ab3a4ubtx',
  contexteDeVie: 'mjyj2lz4wfs5pd5',
  informationsAdministratives: 'mv2hgaqj3u5ittg',
  baremesAnah: 'mtg6pgm9t274ya9',
};

const FIELD_SETS = {
  beneficiaires: [
    'prenom', 'nom', 'prenom_occupant_2', 'nom_occupant_2', 'occupants_json', 'adresse_logement', 'ville_libre', 'code_postal_libre', 'commune', 'communes_id', 'code_postal',
    'telephone', 'mail', 'date_naissance_monsieur', 'date_naissance_madame', 'date_visite',
    'situation_proprietaire', 'statut_occupation', 'nombre_personnes', 'categorie_revenu_calculee',
    'revenu_fiscal_reference', 'beneficiaire_apa', 'reconnaissance_invalidite_mdph',
    'reconnaissance_invalidité_mdph_txt', 'aide_a_domicile', 'aide_a_domicile_txt',
    'dependance_particuliere', 'dependance_particuliere_txt', 'personne_confiance',
    'telephone_personne_confiance', 'mail_personne_confiance', 'numero_securite_sociale_monsieur',
    'numero_securite_sociale_madame', 'caisse_retraite_principale', 'caisse_retraite_secondaire',
    'CreatedAt', 'UpdatedAt',
  ],
  dossiers: [
    'uuid_source', 'patient_id', 'beneficiaires_id', 'status', 'ergo_id', 'visit_date', 'compte_anah',
    'nature_accompagnement', 'envoi_rapport', 'personnes_presentes_visite', 'created_at', 'CreatedAt', 'UpdatedAt',
  ],
  logements: [
    'uuid_source', 'beneficiaire_id', 'beneficiaires_id', 'type_de_logement', 'annee_construction', 'annee_habitation',
    'surface_habitable', 'nombre_niveaux', 'sous_sol', 'description_sous_sol', 'rdc', 'description_rdc',
    'etage', 'second_etage', 'third_etage', 'description_etage', 'garage', 'veranda', 'balcon', 'terrasse', 'jardin', 'chauffage',
    'radiateurs_electrique', 'chaudiere_gaz', 'chaudiere_fioul', 'pompe_a_chaleur', 'chaudiere_collective',
    'cheminee_pole_bois', 'poele_granules', 'autre_chauffage', 'volets_roulants_manuels_localisation',
    'volets_roulants_manuels_entier', 'volets_roulants_electriques_localisation',
    'volets_roulants_electriques_entier', 'volets_persiennes_localisation', 'volets_persiennes_entier',
    'cheminement_escalier_exterieur', 'cheminement_escalier_interieur', 'cheminement_pente_douce',
    'cheminement_plat', 'cheminement_quelques_marches', 'cheminement_par_arriere', 'cheminement_seuil_porte',
    'difficultes_circulation_interieure', 'porte_de_garage', 'portail', 'acces_facile_rue',
    'commentaire', 'observation_accessibilite', 'UpdatedAt',
  ],
  contexteDeVie: [
    'uuid_source', 'dossier_id', 'beneficiaire_id', 'beneficiaires_id', 'aide_technique_deplacement', 'restrictions_conduite',
    'difficultes_escalier', 'autonomie_toilette', 'autonomie_repas', 'autonomie_menage',
    'autonomie_demarches_admin', 'nom_pathologie', 'pathologie_maladie', 'maladie_evolutive',
    'suivi_medical', 'frequence_suivi_medical', 'deficience_auditive_visuelle', 'deficience_auditive',
    'deficience_visuelle', 'taille_approximative', 'poids_exact', 'surcharge_pondérale',
    'utilise_fauteuil', 'utilise_canne', 'utilise_deambulateur', 'occupants_json',
  ],
  informationsAdministratives: ['uuid_source', 'dossier_id', 'beneficiaire_id', 'beneficiaires_id', 'date_visite', 'personnes_presentes'],
  diagnosticSanitaires: [
    'uuid_source', 'dossier_id', 'sdb_niveau_pieces_vie', 'wc_niveau', 'wc_etage', 'sdb_baignoire',
    'sdb_baignoire_hauteur', 'sdb_bac_douche', 'sdb_bac_douche_hauteur', 'sdb_vasque_suspendue',
    'sdb_vasque_suspendue_hauteur', 'sdb_vasque_colonne', 'sdb_vasque_colonne_hauteur',
    'sdb_meuble_vasque', 'sdb_meuble_vasque_hauteur', 'sdb_bidet', 'sdb_bidet_hauteur',
    'sdb_paroi_douche', 'sdb_paroi_douche_hauteur', 'sdb_sol_glissant',
    'sdb_machine_a_laver', 'sdb_machine_a_laver_hauteur', 'wc_cuvette_bonne_hauteur', 'wc_cuvette_trop_basse', 'wc_cuvette_hauteur',
    'wc_barre_relevement', 'porte_sdb_largeur_suffisante', 'porte_sdb_dimension', 'porte_sdb_sens_adapte',
    'porte_wc_largeur_suffisante', 'porte_wc_dimension', 'porte_wc_sens_adapte',
    'observation_equipements_utilisation', 'sdb_instances_json', 'wc_instances_json', 'updated_at', 'UpdatedAt',
  ],
  mesuresAnthropometriques: [
    'uuid_source', 'dossier_id', 'debout_hauteur_coude', 'assis_hauteur_assise', 'assis_profondeur_genoux',
    'assis_hauteur_coudes', 'observations', 'updated_at', 'UpdatedAt',
  ],
  observations: ['uuid_source', 'dossier_id', 'observation_equipements', 'projet_souhait_usage', 'resume_preconisations', 'UpdatedAt'],
  referencesLibelle: ['libelle'],
  referencesNom: ['nom'],
  ergotherapeutes: ['uuid_source', 'nom', 'prenom', 'email', 'user_id', 'nom_etablissement_id', 'User', 'etablissements_id', 'etablissement', 'mot_de_passe'],
  communes: ['nom', 'code_postal', 'epci_id1', 'epci'],
  baremesAnah: ['libelle', 'nombre_personnes', 'annee_plafond'],
  caissesRetraiteComplementaires: ['nom', 'numero_telephone_contact', 'aide_complementaire', 'a_une_aide_specifique'],
  wikiTags: ['uuid_source', 'tags'],
  wiki: ['uuid_source', 'titre', 'photos', 'contenu', 'wiki_tags_id', 'wiki_tags'],
};

const AUTONOMY_ITEMS = [
  'Déplacements/transferts',
  'Escaliers',
  'Conduite automobile',
  'Transports en commun',
  'Toilette/habillage',
  'Continence',
  'Repas (y compris courses)',
  'Tâches ménagères.domestiques',
  'Démarches admin',
  'Cognition',
  'Communication',
];

const VISIT_RECOMMENDATION_FIELDS = [
  'uuid_source',
  'dossier_id',
  'beneficiaire_id',
  'beneficiaire_prenom',
  'beneficiaire_nom',
  'beneficiaire_nom_complet',
  'dossier_libelle',
  'wiki_item_id',
  'wiki_title',
  'wiki_image_url',
  'wiki_tag',
  'custom_title',
  'note',
  'created_at',
  'updated_at',
];

const asArray = (value) => Array.isArray(value) ? value : [];
const field = (record, name) => record?.fields?.[name];
const firstDefined = (...values) => values.find((value) => value !== undefined);
const stringValue = (value) => value == null ? '' : String(value);
const safeParseJsonArray = (value) => {
  try {
    const parsed = JSON.parse(stringValue(value) || '[]');
    return asArray(parsed).map((entry) => String(entry));
  } catch {
    return [];
  }
};
const normalizeEmail = (value) => String(value || '').trim().toLowerCase();
const nullableString = (value) => value == null || value === '' ? null : String(value);
const absoluteUrl = (value) => {
  const stringified = String(value || '').trim();
  if (!stringified) return '';
  if (LOCALHOST_URL_PATTERN.test(stringified)) {
    try {
      const parsed = new URL(stringified);
      const normalizedPath = `${parsed.pathname}${parsed.search}${parsed.hash}`;
      if (APP_PUBLIC_BASE_URL) {
        return `${APP_PUBLIC_BASE_URL}${normalizedPath.startsWith('/') ? normalizedPath : `/${normalizedPath}`}`;
      }
      return `http://127.0.0.1:${port}${normalizedPath.startsWith('/') ? normalizedPath : `/${normalizedPath}`}`;
    } catch {
      // Fall through to generic handling.
    }
  }
  if (/^https?:\/\//i.test(stringified)) {
    if (!APP_PUBLIC_BASE_URL) return stringified;
    try {
      const parsed = new URL(stringified);
      if (PROJECT_VERCEL_HOST_PATTERN.test(parsed.hostname)) {
        const normalizedPath = `${parsed.pathname}${parsed.search}${parsed.hash}`;
        return `${APP_PUBLIC_BASE_URL}${normalizedPath.startsWith('/') ? normalizedPath : `/${normalizedPath}`}`;
      }
    } catch {
      // Keep original absolute URL if parsing fails.
    }
    return stringified;
  }
  const normalizedPath = stringified.startsWith('/') ? stringified : `/${stringified}`;
  if (APP_PUBLIC_BASE_URL) {
    return `${APP_PUBLIC_BASE_URL}${normalizedPath}`;
  }
  return `http://127.0.0.1:${port}${normalizedPath}`;
};
const resolveClientMediaUrl = (value) => {
  const stringified = String(value || '').trim();
  if (!stringified) return '';
  if (LOCALHOST_URL_PATTERN.test(stringified)) {
    try {
      const parsed = new URL(stringified);
      return `${parsed.pathname}${parsed.search}${parsed.hash}`;
    } catch {
      return stringified.replace(/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?/i, '');
    }
  }
  if (/^https?:\/\//i.test(stringified)) return stringified;
  return stringified.startsWith('/') ? stringified : `/${stringified}`;
};
const withTimeout = async (promiseFactory, timeoutMs = 5000) => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await promiseFactory(controller.signal);
  } finally {
    clearTimeout(timeout);
  }
};
const toNumber = (value) => {
  if (value == null || value === '') return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
};
const toBool = (value) => {
  if (typeof value === 'boolean') return value;
  if (value == null) return false;
  return ['true', '1', 'yes', 'oui', 'x'].includes(String(value).trim().toLowerCase());
};
const boolText = (value) => String(Boolean(value));
const httpError = (statusCode, message) => Object.assign(new Error(message), { statusCode });
const latestRecord = (records) => {
  const sorted = [...records].sort((a, b) => {
    const aDate = new Date(field(a, 'UpdatedAt') || field(a, 'updated_at') || field(a, 'created_at') || 0).getTime();
    const bDate = new Date(field(b, 'UpdatedAt') || field(b, 'updated_at') || field(b, 'created_at') || 0).getTime();
    if (aDate !== bDate) return bDate - aDate;
    return Number(b.id) - Number(a.id);
  });
  return sorted[0];
};
const normalizeOccupation = (label) => label?.startsWith('Usufruitier') ? 'Usufruitier' : (label || '');

const parseOccupantsJson = (rawValue) => {
  const source = stringValue(rawValue).trim();
  if (!source) return [];
  try {
    const parsed = JSON.parse(source);
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((entry) => entry && typeof entry === 'object')
      .map((entry) => ({
        firstName: stringValue(entry.firstName).trim(),
        lastName: stringValue(entry.lastName).trim(),
        birthDate: stringValue(entry.birthDate).trim(),
        apa: Boolean(entry.apa),
        // GIR (Groupe Iso-Ressources) — sélectionné dans l'onglet
        // bénéficiaire quand `apa` est true. Doit être préservé sinon le
        // PDF affiche « Oui » sans le numéro de GIR (bug 2026-04-29).
        apaGir: stringValue(entry.apaGir).trim(),
        invalidity: Boolean(entry.invalidity),
        invalidityTxt: stringValue(entry.invalidityTxt).trim(),
        homeHelp: Boolean(entry.homeHelp),
        homeHelpTxt: stringValue(entry.homeHelpTxt).trim(),
        dependenceTxt: stringValue(entry.dependenceTxt).trim(),
        numeroSecuriteSociale: stringValue(entry.numeroSecuriteSociale).trim(),
        caisseRetraitePrincipale: stringValue(entry.caisseRetraitePrincipale).trim(),
        caissesRetraiteComplementaires: stringValue(entry.caissesRetraiteComplementaires).trim(),
      }));
  } catch {
    return [];
  }
};
const filterValue = (value) => `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
const unwrapRecordFields = (record) => (
  record && typeof record === 'object' && record.fields && typeof record.fields === 'object'
    ? record.fields
    : record
);

const refLabel = (record) => {
  if (record == null) return '';
  if (typeof record === 'string' || typeof record === 'number') return String(record);
  if (Array.isArray(record)) {
    for (const entry of record) {
      const label = refLabel(entry);
      if (label) return label;
    }
    return '';
  }

  const source = unwrapRecordFields(record);
  if (!source || typeof source !== 'object') return '';
  if (source.libelle) return String(source.libelle);
  if (source.nom && source.prenom) return `${source.prenom} ${source.nom}`.trim();
  if (source.nom) return String(source.nom);
  if (source.prenom) return String(source.prenom);
  if (source.title) return String(source.title);
  if (source.name) return String(source.name);
  return '';
};

const groupBy = (records, key) => {
  const map = new Map();
  for (const record of records) {
    const value = field(record, key);
    if (value == null || value === '') continue;
    const normalized = String(value);
    if (!map.has(normalized)) map.set(normalized, []);
    map.get(normalized).push(record);
  }
  return map;
};

const findByUuidSource = (records, sourceId) => records.find((record) => field(record, 'uuid_source') === sourceId);
const findByFieldValue = (records, fieldName, value) => records.find((record) => field(record, fieldName) === value);
const findByRecordId = (records, recordId) => records.find((record) => String(record.id) === String(recordId));
const latestByFieldValue = (records, fieldName, value) => latestRecord(
  records.filter((record) => String(field(record, fieldName) ?? '') === String(value ?? ''))
);
const getRecordUpdatedAt = (record) => {
  const raw = field(record, 'updated_at') || field(record, 'UpdatedAt') || field(record, 'created_at') || field(record, 'CreatedAt');
  return raw ? new Date(raw).toISOString() : null;
};
const sendConflictIfStale = (req, res, record) => {
  const expectedRaw = req.body?.expectedUpdatedAt || req.get('If-Unmodified-Since');
  if (!expectedRaw) return false;

  const remoteUpdatedAt = getRecordUpdatedAt(record);
  if (!remoteUpdatedAt) return false;

  const expectedTime = new Date(expectedRaw).getTime();
  const remoteTime = new Date(remoteUpdatedAt).getTime();
  if (isNaN(expectedTime) || isNaN(remoteTime)) return false;

  if (remoteTime > expectedTime) {
    const remoteData = {};
    if (record?.fields) {
      for (const [key, value] of Object.entries(record.fields)) {
        remoteData[key] = value;
      }
    }
    res.status(409).json({ conflict: true, remoteUpdatedAt, remoteData });
    return true;
  }
  return false;
};
const normalizeLabelForMatch = (value) => String(value || '')
  .normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/['’`()/-]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();
const findByLabel = (records, value) => {
  if (!value) return undefined;
  const normalized = normalizeLabelForMatch(value);
  if (!normalized) return undefined;
  return records.find((record) => normalizeLabelForMatch(refLabel(record)) === normalized)
    || records.find((record) => normalizeLabelForMatch(refLabel(record)).startsWith(normalized));
};
const normalizeCommuneKey = (value) => String(value || '')
  .normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/['’`-]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();
const findCommuneMatch = (records, city, zipCode) => {
  const normalizedCity = normalizeCommuneKey(city);
  const normalizedZip = String(zipCode || '').trim();

  if (normalizedCity && normalizedZip) {
    const exact = records.find((record) =>
      normalizeCommuneKey(field(record, 'nom')) === normalizedCity
      && String(field(record, 'code_postal') || '').trim() === normalizedZip
    );
    if (exact) return exact;
  }

  if (normalizedCity) {
    const byCity = records.find((record) => normalizeCommuneKey(field(record, 'nom')) === normalizedCity);
    if (byCity) return byCity;
    const byCityStartsWith = records.find((record) => normalizeCommuneKey(field(record, 'nom')).startsWith(normalizedCity));
    if (byCityStartsWith) return byCityStartsWith;
  }

  if (normalizedZip) {
    const byZip = records.filter((record) => String(field(record, 'code_postal') || '').trim() === normalizedZip);
    if (byZip.length === 1) return byZip[0];
  }

  return undefined;
};
const resolveCommuneMatch = async (city, zipCode, fallbackRecords = []) => {
  return findCommuneMatch(fallbackRecords, city, zipCode);
};
const specialMemberProfile = (email) => MEMBER_PROFILES[normalizeEmail(email)];
const splitDisplayName = (displayName) => {
  const parts = String(displayName || '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { prenom: '', nom: '' };
  if (parts.length === 1) return { prenom: parts[0], nom: '' };
  return { prenom: parts.slice(0, -1).join(' '), nom: parts.at(-1) };
};
const randomSecret = (size = 48) => crypto.randomBytes(size).toString('base64url');
const hashPassword = (password, salt) => crypto.scryptSync(String(password), salt, 64).toString('hex');
const generatePassword = (displayName) => {
  const base = String(displayName || 'AidHabitat').replace(/[^a-z0-9]/gi, '').slice(0, 8) || 'AidHab';
  return `${base}-${crypto.randomBytes(4).toString('hex')}`;
};
const encodeBase64Url = (payload) => Buffer.from(JSON.stringify(payload)).toString('base64url');
const decodeBase64Url = (payload) => JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
const decodeLocalAuthEmail = (token) => {
  if (!String(token || '').startsWith(LOCAL_SESSION_TOKEN_PREFIX)) return null;
  const rawPayload = String(token).slice(LOCAL_SESSION_TOKEN_PREFIX.length).trim();
  if (!rawPayload) return null;
  try {
    return Buffer.from(rawPayload, 'base64').toString('utf8');
  } catch {
    return rawPayload;
  }
};
const getTokenFromRequest = (req) => {
  const header = req.get('authorization') || '';
  if (header.toLowerCase().startsWith('bearer ')) {
    return header.slice(7).trim();
  }
  return String(req.get('x-app-session') || '').trim();
};
const syntheticBeneficiaryId = (recordId) => `nocodb-beneficiaire-${recordId}`;
const parseSyntheticBeneficiaryId = (value) => {
  const match = String(value || '').match(/^nocodb-beneficiaire-(\d+)$/);
  return match ? Number(match[1]) : null;
};
const mobileSyncStore = createMobileSyncStore({ absoluteUrl });
const deriveBeneficiaryAppId = ({ beneficiaryRecord, dossierRecords = [], housingRecords = [], contextRecords = [], infoRecords = [] }) => {
  const relatedExternalId = [
    latestRecord(dossierRecords) ? field(latestRecord(dossierRecords), 'patient_id') : undefined,
    latestRecord(housingRecords) ? field(latestRecord(housingRecords), 'beneficiaire_id') : undefined,
    latestRecord(contextRecords) ? field(latestRecord(contextRecords), 'beneficiaire_id') : undefined,
    latestRecord(infoRecords) ? field(latestRecord(infoRecords), 'beneficiaire_id') : undefined,
  ].find(Boolean);

  return String(relatedExternalId || syntheticBeneficiaryId(beneficiaryRecord.id));
};
const resolveBeneficiaryRecord = ({ beneficiaires, dossiers = [], logements = [], contextes = [], infosAdmin = [], appBeneficiaryId }) => {
  const syntheticId = parseSyntheticBeneficiaryId(appBeneficiaryId);
  if (syntheticId != null) {
    return findByRecordId(beneficiaires, syntheticId);
  }

  const linkedRecord = latestByFieldValue(dossiers, 'patient_id', appBeneficiaryId)
    || latestByFieldValue(logements, 'beneficiaire_id', appBeneficiaryId)
    || latestByFieldValue(contextes, 'beneficiaire_id', appBeneficiaryId)
    || latestByFieldValue(infosAdmin, 'beneficiaire_id', appBeneficiaryId);

  if (!linkedRecord) {
    return undefined;
  }

  return findByRecordId(beneficiaires, field(linkedRecord, 'beneficiaires_id'));
};

const parseChecklistDone = (contextRecord) => {
  if (!contextRecord) {
    return { done: false, checklist: AUTONOMY_ITEMS.map((name) => ({ name, checked: false })), occupants: [] };
  }

  const rawOccupantsJson = stringValue(field(contextRecord, 'occupants_json')).trim();
  if (rawOccupantsJson) {
    try {
      const parsed = JSON.parse(rawOccupantsJson);
      if (Array.isArray(parsed) && parsed.length > 0) {
        const normalizedOccupants = parsed
          .filter((entry) => entry && typeof entry === 'object')
          .map((entry) => ({
            medical: {
              pathology: stringValue(entry?.medical?.pathology),
              followUp: stringValue(entry?.medical?.followUp),
              sensory: stringValue(entry?.medical?.sensory),
              heightCm: stringValue(entry?.medical?.heightCm),
              weightKg: stringValue(entry?.medical?.weightKg),
            },
            autonomyDone: Boolean(entry?.autonomyDone),
            autonomy: AUTONOMY_ITEMS.map((name, index) => ({
              name,
              checked: Boolean(entry?.autonomy?.[index]?.checked),
            })),
            humanHelp: AUTONOMY_ITEMS.map((name, index) => ({
              name,
              checked: Boolean(entry?.humanHelp?.[index]?.checked),
            })),
          }));
        const primary = normalizedOccupants[0];
        const checklist = primary?.autonomy || AUTONOMY_ITEMS.map((name) => ({ name, checked: false }));
        return {
          done: Boolean(primary?.autonomyDone) || checklist.some((item) => item.checked),
          checklist,
          occupants: normalizedOccupants,
        };
      }
    } catch {
      // Ignore malformed legacy payloads and fall back to column-based parsing.
    }
  }

  const values = {
    'Déplacements/transferts': toBool(field(contextRecord, 'aide_technique_deplacement')) || toBool(field(contextRecord, 'utilise_fauteuil')) || toBool(field(contextRecord, 'utilise_canne')) || toBool(field(contextRecord, 'utilise_deambulateur')),
    'Escaliers': Boolean(field(contextRecord, 'difficultes_escalier')),
    'Conduite automobile': Boolean(field(contextRecord, 'restrictions_conduite')),
    'Transports en commun': false,
    'Toilette/habillage': Boolean(field(contextRecord, 'autonomie_toilette')),
    'Continence': false,
    'Repas (y compris courses)': Boolean(field(contextRecord, 'autonomie_repas')),
    'Tâches ménagères.domestiques': Boolean(field(contextRecord, 'autonomie_menage')),
    'Démarches admin': Boolean(field(contextRecord, 'autonomie_demarches_admin')),
    'Cognition': false,
    'Communication': false,
  };

  const checklist = AUTONOMY_ITEMS.map((name) => ({ name, checked: Boolean(values[name]) }));
  return { done: checklist.some((item) => item.checked), checklist, occupants: [] };
};

const safeSlug = (value, fallback = 'item') => {
  const normalized = String(value || '')
    .trim()
    .replace(/[^a-z0-9._-]+/gi, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .toLowerCase();
  return normalized || fallback;
};

const buildRetirementFundLogoDataUri = (name) => {
  const label = stringValue(name).trim() || 'Caisse';
  const initials = label
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase() || '')
    .join('') || 'CR';
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" width="240" height="160" viewBox="0 0 240 160" role="img" aria-label="${label}">
      <defs>
        <linearGradient id="g" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="#907CA1" />
          <stop offset="100%" stop-color="#554A63" />
        </linearGradient>
      </defs>
      <rect width="240" height="160" rx="28" fill="url(#g)" />
      <circle cx="198" cy="40" r="16" fill="rgba(255,255,255,0.18)" />
      <circle cx="42" cy="124" r="18" fill="rgba(255,255,255,0.12)" />
      <text x="120" y="96" text-anchor="middle" font-family="Arial, sans-serif" font-size="52" font-weight="700" fill="#ffffff">${initials}</text>
    </svg>
  `.trim();
  return `data:image/svg+xml;charset=UTF-8,${encodeURIComponent(svg)}`;
};

const normalizeRetirementFundPayload = (fund) => {
  const normalizedName = stringValue(fund?.name).trim();
  return {
    id: stringValue(fund?.id).trim() || `custom-${crypto.randomUUID()}`,
    name: normalizedName,
    phone: stringValue(fund?.phone).trim(),
    audience: stringValue(fund?.audience).trim(),
    requestMethod: stringValue(fund?.requestMethod).trim(),
    requestDelay: stringValue(fund?.requestDelay).trim(),
    aidAmount: stringValue(fund?.aidAmount).trim(),
    therapistNote: stringValue(fund?.therapistNote).trim(),
    website: stringValue(fund?.website).trim(),
    logoUrl: stringValue(fund?.logoUrl).trim(),
    lastEditedAt: fund?.lastEditedAt || null,
    lastEditedBy: stringValue(fund?.lastEditedBy).trim(),
  };
};

const buildRetirementFundResponse = (fund) => {
  const meta = getRetirementFundMeta(fund?.name || '');
  const normalized = normalizeRetirementFundPayload(fund);
  return {
    ...normalized,
    name: normalized.name || meta?.displayName || '',
    phone: normalized.phone || meta?.contactPhone || '',
    audience: normalized.audience || meta?.audience || '',
    requestMethod: normalized.requestMethod || meta?.requestMethod || 'Procédure à confirmer auprès de l’organisme.',
    requestDelay: normalized.requestDelay || meta?.requestDelay || 'Délai à confirmer.',
    aidAmount: normalized.aidAmount || meta?.aidAmount || '',
    therapistNote: normalized.therapistNote || meta?.therapistNote || '',
    website: normalized.website || meta?.website || '',
    logoUrl: normalized.logoUrl || meta?.logoUrl || buildRetirementFundLogoDataUri(normalized.name || meta?.displayName || 'Caisse'),
  };
};

const safeFileName = (value, fallback = 'document.bin') => {
  const normalized = String(value || '')
    .trim()
    .replace(/[/\\?%*:|"<>]+/g, '-')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
  return normalized || fallback;
};

const inferExtensionFromMimeType = (mimeType) => ({
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'application/pdf': 'pdf',
})[String(mimeType || '').trim().toLowerCase()] || 'bin';

const decodeBase64FilePayload = ({ contentBase64, mimeType }) => {
  const rawValue = String(contentBase64 || '').trim();
  if (!rawValue) {
    throw new Error('Contenu fichier manquant');
  }

  const dataUrlMatch = rawValue.match(/^data:([^;]+);base64,(.+)$/);
  const resolvedMimeType = dataUrlMatch?.[1]?.toLowerCase() || String(mimeType || '').trim().toLowerCase() || 'application/octet-stream';
  const base64Payload = dataUrlMatch?.[2] || rawValue;
  const buffer = Buffer.from(base64Payload, 'base64');

  if (buffer.length === 0) {
    throw new Error('Contenu fichier invalide');
  }

  return {
    mimeType: resolvedMimeType,
    buffer,
  };
};

const mapMedicalContext = (contextRecord) => {
  if (!contextRecord) return undefined;

  const pathology = [field(contextRecord, 'nom_pathologie'), field(contextRecord, 'pathologie_maladie'), field(contextRecord, 'maladie_evolutive')].filter(Boolean).join(' • ');
  const followUp = [field(contextRecord, 'suivi_medical'), field(contextRecord, 'frequence_suivi_medical')].filter(Boolean).join(' • ');
  const sensory = [field(contextRecord, 'deficience_auditive_visuelle'), field(contextRecord, 'deficience_auditive'), field(contextRecord, 'deficience_visuelle')].filter(Boolean).join(' • ');
  const heightCm = stringValue(field(contextRecord, 'taille_approximative')).replace(/[^\d.,]/g, '').replace(',', '.');
  const weightKg = stringValue(field(contextRecord, 'poids_exact')).replace(/[^\d.,]/g, '').replace(',', '.');
  const sizeWeight = [
    heightCm ? `${heightCm} cm` : '',
    weightKg ? `${weightKg} kg` : '',
    field(contextRecord, 'surcharge_pondérale'),
  ].filter(Boolean).join(' • ');

  if (!pathology && !followUp && !sensory && !sizeWeight) {
    return undefined;
  }

  return {
    pathology,
    followUp,
    sensory,
    heightCm,
    weightKg,
    sizeWeight,
  };
};

const AUTH_STORE_KEY = 'auth-store.json';

// Prefer a stable `JWT_SECRET` env var over the per-instance random one. On
// Vercel serverless (without Blob storage) the auth-store lives in /tmp,
// which is ephemeral and per-cold-start — so every new function instance
// would otherwise regenerate `secret` and invalidate every JWT the previous
// instance signed (→ random 401s on the clients). Setting JWT_SECRET in
// the project's env vars pins it across cold starts.
const STATIC_JWT_SECRET = stringValue(process.env.JWT_SECRET).trim();

const readAuthStore = async () => {
  const parsed = await getJson(AUTH_STORE_KEY, null);
  if (!parsed) {
    return {
      version: 1,
      secret: STATIC_JWT_SECRET || randomSecret(),
      users: {},
      pendingCredentials: {},
    };
  }
  const users = Object.fromEntries(
    Object.entries(parsed.users || {}).map(([email, user]) => [
      email,
      {
        ...user,
        profilePhotoUrl: stringValue(user?.profilePhotoUrl),
      },
    ]),
  );
  return {
    version: 1,
    secret: STATIC_JWT_SECRET || parsed.secret || randomSecret(),
    users,
    pendingCredentials: parsed.pendingCredentials || {},
  };
};

const writeAuthStore = async (store) => {
  await putJson(AUTH_STORE_KEY, store);
};

const readJsonStore = async (storeUrl, fallbackValue) => {
  try {
    const raw = await fs.readFile(storeUrl, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') {
      return fallbackValue;
    }
    return parsed;
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
    return fallbackValue;
  }
};

const writeJsonStore = async (storeUrl, payload) => {
  await fs.mkdir(DATA_DIR_URL, { recursive: true });
  await fs.writeFile(storeUrl, JSON.stringify(payload, null, 2));
};

const readDocumentStore = async () => {
  const store = await readJsonStore(DOCUMENT_STORE_URL, { version: 1, documents: [] });
  return {
    version: 1,
    documents: asArray(store.documents),
  };
};

const writeDocumentStore = async (store) => {
  await writeJsonStore(DOCUMENT_STORE_URL, {
    version: 1,
    documents: asArray(store.documents),
  });
};

const readNotePagesStore = async () => {
  const store = await readJsonStore(NOTE_PAGES_STORE_URL, { version: 1, notePages: [] });
  return {
    version: 1,
    notePages: asArray(store.notePages),
  };
};

const writeNotePagesStore = async (store) => {
  await writeJsonStore(NOTE_PAGES_STORE_URL, {
    version: 1,
    notePages: asArray(store.notePages),
  });
};

const readRetirementFundsStore = async () => {
  const store = await readJsonStore(RETIREMENT_FUNDS_STORE_URL, { version: 1, funds: {}, customFunds: [] });
  return {
    version: 1,
    funds: store.funds && typeof store.funds === 'object' ? store.funds : {},
    customFunds: asArray(store.customFunds).map((fund) => normalizeRetirementFundPayload(fund)).filter((fund) => fund.name),
  };
};

const writeRetirementFundsStore = async (store) => {
  await writeJsonStore(RETIREMENT_FUNDS_STORE_URL, {
    version: 1,
    funds: store.funds || {},
    customFunds: asArray(store.customFunds).map((fund) => normalizeRetirementFundPayload(fund)),
  });
};

const normalizeVisitRecommendationItem = (item, wikiMap = new Map()) => {
  const wikiItem = resolveRecommendationWikiItem(item, wikiMap);
  const now = new Date().toISOString();

  return {
    id: stringValue(item?.id).trim() || crypto.randomUUID(),
    wikiItemId: stringValue(wikiItem?.id || item?.wikiItemId).trim(),
    wikiTitle: stringValue(wikiItem?.title || item?.wikiTitle).trim(),
    wikiImageUrl: stringValue(wikiItem?.imageUrl || absoluteUrl(item?.wikiImageUrl)).trim(),
    wikiTag: stringValue(wikiItem?.tags?.[0] || item?.wikiTag).trim(),
    note: stringValue(item?.note),
    createdAt: item?.createdAt || now,
    updatedAt: now,
  };
};

const readVisitRecommendationsStore = async () => {
  const store = await readJsonStore(VISIT_RECOMMENDATIONS_STORE_URL, { version: 1, dossiers: {} });
  return {
    version: 1,
    dossiers: store.dossiers && typeof store.dossiers === 'object' ? store.dossiers : {},
  };
};

const writeVisitRecommendationsStore = async (store) => {
  await writeJsonStore(VISIT_RECOMMENDATIONS_STORE_URL, {
    version: 1,
    dossiers: store.dossiers && typeof store.dossiers === 'object' ? store.dossiers : {},
  });
};

const loadBundledWikiItems = async () => {
  if (Array.isArray(bundledWikiItemsCache)) return bundledWikiItemsCache;
  try {
    const raw = await fs.readFile(BUNDLED_WIKI_LIBRARY_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    bundledWikiItemsCache = asArray(parsed?.items);
  } catch {
    bundledWikiItemsCache = [];
  }
  return bundledWikiItemsCache;
};

const readWikiLibraryStore = async () => {
  const store = await readJsonStore(WIKI_LIBRARY_STORE_URL, { version: 1, items: [] });
  const bundledItems = await loadBundledWikiItems();
  const storedItems = asArray(store.items);
  const hasModernStoredImages = storedItems.some((item) => {
    const imageUrl = stringValue(item?.imageUrl);
    return imageUrl.includes('/wiki-offline/') || imageUrl.includes('/uploads/wiki-library/');
  });
  const seededItems = bundledItems.length > 0 ? bundledItems : WIKI_LIBRARY_SEED;
  const items = storedItems.length > 0 && hasModernStoredImages ? storedItems : seededItems;
  const normalized = {
    version: 1,
    items: items.map((item) => normalizeWikiItemPayload({
      id: String(item.id),
      title: stringValue(item.title),
      description: stringValue(item.description),
      imageUrl: stringValue(item.imageUrl),
      tags: asArray(item.tags).map((tag) => String(tag)),
      category: stringValue(item.category) || 'Autre',
      createdAt: item.createdAt || new Date().toISOString(),
      updatedAt: item.updatedAt || item.createdAt || new Date().toISOString(),
    })),
  };

  if (asArray(store.items).length === 0) {
    await writeJsonStore(WIKI_LIBRARY_STORE_URL, normalized);
  }

  return normalized;
};

const writeWikiLibraryStore = async (store) => {
  await writeJsonStore(WIKI_LIBRARY_STORE_URL, {
    version: 1,
    items: asArray(store.items),
  });
};

const resolveWikiPrimaryTag = ({ title, description, category, tags }) => {
  const explicitAllowed = asArray(tags).find((tag) => WIKI_FILTER_TAGS.includes(String(tag)));
  if (explicitAllowed) return String(explicitAllowed);

  const haystack = `${stringValue(title)} ${stringValue(description)} ${stringValue(category)} ${asArray(tags).join(' ')}`.toLowerCase();
  if (haystack.includes('wc') || haystack.includes('toilette')) return 'WC';
  if (haystack.includes('barre') || haystack.includes('main courante') || haystack.includes('accoudoir') || haystack.includes('relevage') || haystack.includes('redressement')) return "Barres d'appui";
  if (haystack.includes('douche') || haystack.includes('baignoire') || haystack.includes('lavabo') || haystack.includes('mitigeur') || haystack.includes('salle de bain')) return 'Salle de bain';
  if (haystack.includes('cuisine') || haystack.includes('evier') || haystack.includes('plan de travail') || haystack.includes('tiroir')) return 'Cuisine';
  if (haystack.includes('chambre') || haystack.includes('lit')) return 'Chambre';
  if (haystack.includes('monte') || haystack.includes('escalier') || haystack.includes('ascenseur') || haystack.includes('plateforme') || haystack.includes('reperage contrastant')) return 'Escaliers & ascenseur';
  if (haystack.includes('seuil surbaisse') || haystack.includes('seuil plat') || haystack.includes('porte') || haystack.includes('fenetre') || haystack.includes('volet') || haystack.includes('garage') || haystack.includes('portail')) return 'Ouvertures';
  if (haystack.includes('revetement antiderapant')) return 'Accès extérieurs';
  if (haystack.includes('rampe') || haystack.includes('pente') || haystack.includes('acces') || haystack.includes('passerelle') || haystack.includes('exterieur')) return 'Accès extérieurs';
  if (haystack.includes('revetement') || haystack.includes('sol ') || haystack.includes('sol-') || haystack.includes('parquet') || haystack.includes('doublage') || haystack.includes('isole')) return 'Equipements';
  if (haystack.includes('eclairage') || haystack.includes('lumineux') || haystack.includes('detection') || haystack.includes('vmc') || haystack.includes('poele') || haystack.includes('television') || haystack.includes('penderie')) return 'Equipements';
  return 'Equipements';
};

const normalizeWikiItemPayload = (item) => ({
  ...item,
  title: stringValue(item.title),
  description: stringValue(item.description),
  imageUrl: stringValue(item.imageUrl),
  category: stringValue(item.category) || 'Autre',
  tags: [resolveWikiPrimaryTag(item)],
});

const normalizeLookupKey = (value) => stringValue(value)
  .normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, ' ')
  .trim();

const mediaFileNameKey = (value) => {
  const raw = stringValue(value).trim();
  if (!raw) return '';

  try {
    const parsed = /^https?:\/\//i.test(raw)
      ? new URL(raw)
      : new URL(raw, APP_PUBLIC_BASE_URL || `http://127.0.0.1:${port}`);
    const fileName = parsed.pathname.split('/').filter(Boolean).at(-1) || '';
    return normalizeLookupKey(decodeURIComponent(fileName));
  } catch {
    const fileName = raw.split(/[/?#]/).filter(Boolean).at(-1) || '';
    return normalizeLookupKey(fileName);
  }
};

const buildWikiRecommendationLookup = (wikiItems = []) => {
  const byId = new Map();
  const byTitle = new Map();
  const byImageFile = new Map();

  for (const wikiItem of wikiItems) {
    const id = stringValue(wikiItem?.id).trim();
    const titleKey = normalizeLookupKey(wikiItem?.title);
    const imageKey = mediaFileNameKey(wikiItem?.imageUrl);
    if (id && !byId.has(id)) byId.set(id, wikiItem);
    if (titleKey && !byTitle.has(titleKey)) byTitle.set(titleKey, wikiItem);
    if (imageKey && !byImageFile.has(imageKey)) byImageFile.set(imageKey, wikiItem);
  }

  return { byId, byTitle, byImageFile, items: wikiItems };
};

const fuzzyMatchWikiItem = (title, wikiItems = []) => {
  const normalizedTitle = normalizeLookupKey(title);
  if (!normalizedTitle || wikiItems.length === 0) return null;
  const sourceTokens = normalizedTitle.split(' ').filter(Boolean);
  if (sourceTokens.length === 0) return null;

  let best = null;
  let bestScore = 0;

  for (const wikiItem of wikiItems) {
    const candidateKey = normalizeLookupKey(wikiItem?.title);
    if (!candidateKey) continue;
    const candidateTokens = candidateKey.split(' ').filter(Boolean);
    if (candidateTokens.length === 0) continue;

    const overlapCount = sourceTokens.filter((token) => candidateTokens.includes(token)).length;
    const tokenScore = overlapCount / sourceTokens.length;
    const prefixBonus = candidateKey.startsWith(sourceTokens[0]) ? 0.1 : 0;
    const score = tokenScore + prefixBonus;
    if (score > bestScore) {
      best = wikiItem;
      bestScore = score;
    }
  }

  return bestScore >= 0.45 ? best : null;
};

const resolveRecommendationWikiItem = (item, lookup) => {
  const byId = lookup?.byId || new Map();
  const byTitle = lookup?.byTitle || new Map();
  const byImageFile = lookup?.byImageFile || new Map();
  const wikiItems = Array.isArray(lookup?.items) ? lookup.items : [];
  const wikiItemId = stringValue(item?.wikiItemId).trim();
  const titleKey = normalizeLookupKey(item?.wikiTitle);
  const imageKey = mediaFileNameKey(item?.wikiImageUrl);

  return byId.get(wikiItemId)
    || byTitle.get(titleKey)
    || byImageFile.get(imageKey)
    || fuzzyMatchWikiItem(item?.wikiTitle, wikiItems)
    || null;
};

const parseWikiContent = (value) => {
  const raw = stringValue(value).trim();
  if (!raw) {
    return { description: '', category: 'Autre', tags: [] };
  }

  try {
    const parsed = JSON.parse(raw);
    return {
      description: stringValue(parsed?.description),
      category: stringValue(parsed?.category) || 'Autre',
      tags: asArray(parsed?.tags).map((tag) => String(tag)),
    };
  } catch {
    return { description: raw, category: 'Autre', tags: [] };
  }
};

const serializeWikiContent = ({ description, category, tags }) => JSON.stringify({
  description: stringValue(description),
  category: stringValue(category) || 'Autre',
  tags: asArray(tags).slice(0, 1).map((tag) => String(tag)),
});

const parseJsonArrayField = (value) => {
  const raw = stringValue(value).trim();
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
};

const buildLegacyBathroomInstances = (payload) => {
  const hasLegacyBathroomData = [
    payload?.sdbBaignoire,
    payload?.sdbBacDouche,
    payload?.sdbVasqueSuspendue,
    payload?.sdbVasqueColonne,
    payload?.sdbMeubleVasque,
    payload?.sdbBidet,
    payload?.sdbParoiDouche,
    payload?.sdbSolGlissant,
    payload?.sdbMachineALaver,
    payload?.porteSdbLargeurSuffisante,
    payload?.porteSdbDimension,
    payload?.porteSdbSensAdapte,
  ].some((value) => value !== null && value !== undefined && value !== false && value !== '');

  if (!hasLegacyBathroomData) return [];

  return [{
    id: 'sdb-legacy',
    levelField: payload?.sdbNiveauPiecesVie ? 'rdc' : 'floor',
    levelLabel: payload?.sdbNiveauPiecesVie ? 'RDC' : '1er étage',
    sdbBaignoire: Boolean(payload?.sdbBaignoire),
    sdbBaignoireHauteur: payload?.sdbBaignoireHauteur ?? null,
    sdbBacDouche: Boolean(payload?.sdbBacDouche),
    sdbBacDoucheHauteur: payload?.sdbBacDoucheHauteur ?? null,
    sdbVasqueSuspendue: Boolean(payload?.sdbVasqueSuspendue),
    sdbVasqueSuspendueHauteur: payload?.sdbVasqueSuspendueHauteur ?? null,
    sdbVasqueColonne: Boolean(payload?.sdbVasqueColonne),
    sdbVasqueColonneHauteur: payload?.sdbVasqueColonneHauteur ?? null,
    sdbMeubleVasque: Boolean(payload?.sdbMeubleVasque),
    sdbMeubleVasqueHauteur: payload?.sdbMeubleVasqueHauteur ?? null,
    sdbBidet: Boolean(payload?.sdbBidet),
    sdbBidetHauteur: payload?.sdbBidetHauteur ?? null,
    sdbParoiDouche: Boolean(payload?.sdbParoiDouche),
    sdbParoiDoucheHauteur: payload?.sdbParoiDoucheHauteur ?? null,
    sdbSolGlissant: Boolean(payload?.sdbSolGlissant),
    sdbMachineALaver: Boolean(payload?.sdbMachineALaver),
    sdbMachineALaverHauteur: payload?.sdbMachineALaverHauteur ?? null,
    porteSdbLargeurSuffisante: Boolean(payload?.porteSdbLargeurSuffisante),
    porteSdbDimension: payload?.porteSdbDimension ?? null,
    porteSdbSensAdapte: Boolean(payload?.porteSdbSensAdapte),
  }];
};

const buildLegacyWcInstances = (payload) => {
  const hasLegacyWcData = [
    payload?.wcCuvetteBonneHauteur,
    payload?.wcCuvetteTropBasse,
    payload?.wcCuvetteHauteur,
    payload?.wcBarreRelevement,
    payload?.porteWcLargeurSuffisante,
    payload?.porteWcDimension,
    payload?.porteWcSensAdapte,
    payload?.observationEquipementsUtilisation,
  ].some((value) => value !== null && value !== undefined && value !== false && value !== '');

  if (!hasLegacyWcData) return [];

  return [{
    id: 'wc-legacy',
    levelField: payload?.wcNiveau ? 'rdc' : 'floor',
    levelLabel: payload?.wcNiveau ? 'RDC' : '1er étage',
    wcCuvetteBonneHauteur: Boolean(payload?.wcCuvetteBonneHauteur),
    wcCuvetteTropBasse: Boolean(payload?.wcCuvetteTropBasse),
    wcCuvetteHauteur: payload?.wcCuvetteHauteur ?? null,
    wcBarreRelevement: Boolean(payload?.wcBarreRelevement),
    porteWcLargeurSuffisante: Boolean(payload?.porteWcLargeurSuffisante),
    porteWcDimension: payload?.porteWcDimension ?? null,
    porteWcSensAdapte: Boolean(payload?.porteWcSensAdapte),
    observationEquipementsUtilisation: stringValue(payload?.observationEquipementsUtilisation),
  }];
};

const mapWikiLibraryItem = (item) => ({
  id: String(item.id),
  title: stringValue(item.title),
  description: stringValue(item.description),
  imageUrl: String(item.imageUrl || '').startsWith('/wiki-') ? String(item.imageUrl) : absoluteUrl(item.imageUrl),
  tags: normalizeWikiItemPayload(item).tags,
  category: stringValue(item.category) || 'Autre',
  createdAt: item.createdAt,
  updatedAt: item.updatedAt,
});

const mapWikiRecordToItem = (record) => {
  const metadata = parseWikiContent(field(record, 'contenu'));
  const linkedTag = stringValue(field(record, 'wiki_tags')?.fields?.tags);
  const tags = metadata.tags.length > 0
    ? metadata.tags
    : linkedTag ? [linkedTag] : [];

  return mapWikiLibraryItem({
    id: field(record, 'uuid_source') || `wiki-record-${record.id}`,
    title: stringValue(field(record, 'titre')),
    description: metadata.description,
    imageUrl: stringValue(field(record, 'photos')),
    tags,
    category: metadata.category,
    createdAt: field(record, 'CreatedAt') || new Date().toISOString(),
    updatedAt: field(record, 'UpdatedAt') || field(record, 'CreatedAt') || new Date().toISOString(),
  });
};

const ensureWikiTagsInNocodb = async (tagNames, existingTagRecords = null) => {
  const records = existingTagRecords || await queryAll(TABLES.wikiTags, { fields: FIELD_SETS.wikiTags });
  const normalizedMap = new Map(
    records.map((record) => [stringValue(field(record, 'tags')).trim().toLowerCase(), record]),
  );

  for (const tagName of tagNames) {
    const normalized = stringValue(tagName).trim().toLowerCase();
    if (!normalized || normalizedMap.has(normalized)) continue;
    const created = await createRecord(TABLES.wikiTags, {
      uuid_source: crypto.randomUUID(),
      tags: stringValue(tagName).trim(),
    });
    records.push(created);
    normalizedMap.set(normalized, created);
  }

  return { records, normalizedMap };
};

const cleanupWikiTagsInNocodb = async (tagRecords, wikiRecords) => {
  const allowed = new Set(WIKI_FILTER_TAGS.map((tag) => tag.toLowerCase()));
  const wikiTagIdsInUse = new Set(
    wikiRecords.map((record) => String(field(record, 'wiki_tags_id') || '').trim()).filter(Boolean),
  );

  const deletions = tagRecords
    .filter((record) => !allowed.has(stringValue(field(record, 'tags')).trim().toLowerCase()))
    .filter((record) => !wikiTagIdsInUse.has(String(record.id)))
    .map((record) => ({ id: String(record.id) }));

  if (deletions.length > 0) {
    await callNocoTool('deleteRecords', {
      tableId: TABLES.wikiTags,
      records: deletions,
    });
  }
};

const syncLocalWikiStoreToNocodb = async () => {
  const localStore = await readWikiLibraryStore();
  const localItems = localStore.items.map((item) => normalizeWikiItemPayload(item));
  await writeWikiLibraryStore({ version: 1, items: localItems });
  const [wikiRecords, initialTagRecords] = await Promise.all([
    queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki }),
    queryAll(TABLES.wikiTags, { fields: FIELD_SETS.wikiTags }),
  ]);

  const { records: tagRecords, normalizedMap } = await ensureWikiTagsInNocodb(WIKI_FILTER_TAGS, initialTagRecords);
  const wikiByUuid = new Map(
    wikiRecords.map((record) => [stringValue(field(record, 'uuid_source')).trim(), record]),
  );

  for (const item of localItems) {
    const primaryTag = stringValue(asArray(item.tags)[0]).trim();
    const primaryTagRecord = primaryTag ? normalizedMap.get(primaryTag.toLowerCase()) : undefined;
    const payload = {
      uuid_source: stringValue(item.id),
      titre: stringValue(item.title),
      photos: stringValue(item.imageUrl),
      contenu: serializeWikiContent({
        description: item.description,
        category: item.category,
        tags: item.tags,
      }),
      wiki_tags_id: primaryTagRecord ? Number(primaryTagRecord.id) : null,
    };

    const existing = wikiByUuid.get(stringValue(item.id));
    if (!existing) {
      const created = await createRecord(TABLES.wiki, payload);
      wikiRecords.push(created);
      wikiByUuid.set(stringValue(item.id), created);
      continue;
    }

    const existingMetadata = parseWikiContent(field(existing, 'contenu'));
    const existingPrimaryTagId = field(existing, 'wiki_tags_id');
    const shouldUpdate =
      stringValue(field(existing, 'titre')) !== payload.titre
      || stringValue(field(existing, 'photos')) !== payload.photos
      || stringValue(existingMetadata.description) !== stringValue(item.description)
      || stringValue(existingMetadata.category) !== stringValue(item.category)
      || JSON.stringify(asArray(existingMetadata.tags)) !== JSON.stringify(asArray(item.tags))
      || String(existingPrimaryTagId ?? '') !== String(payload.wiki_tags_id ?? '');

    if (shouldUpdate) {
      await updateRecord(TABLES.wiki, existing.id, payload);
    }
  }

  const localIds = new Set(localItems.map((item) => stringValue(item.id).trim()));
  const wikiRecordsToDelete = wikiRecords.filter((record) => !localIds.has(stringValue(field(record, 'uuid_source')).trim()));
  if (wikiRecordsToDelete.length > 0) {
    await callNocoTool('deleteRecords', {
      tableId: TABLES.wiki,
      records: wikiRecordsToDelete.map((record) => ({ id: String(record.id) })),
    });
  }
  const activeWikiRecords = wikiRecords.filter((record) => localIds.has(stringValue(field(record, 'uuid_source')).trim()));

  for (const record of activeWikiRecords) {
    const normalizedItem = normalizeWikiItemPayload(mapWikiRecordToItem(record));
    const primaryTag = stringValue(asArray(normalizedItem.tags)[0]).trim();
    const primaryTagRecord = primaryTag ? normalizedMap.get(primaryTag.toLowerCase()) : undefined;
    const normalizedContent = serializeWikiContent({
      description: normalizedItem.description,
      category: normalizedItem.category,
      tags: normalizedItem.tags,
    });
    const existingMetadata = parseWikiContent(field(record, 'contenu'));
    const currentPrimaryTagId = String(field(record, 'wiki_tags_id') ?? '').trim();
    const desiredPrimaryTagId = String(primaryTagRecord?.id ?? '').trim();
    const currentContent = serializeWikiContent({
      description: existingMetadata.description,
      category: existingMetadata.category,
      tags: existingMetadata.tags,
    });

    if (currentPrimaryTagId === desiredPrimaryTagId && currentContent === normalizedContent) {
      continue;
    }

    await updateRecord(TABLES.wiki, record.id, {
      contenu: normalizedContent,
      wiki_tags_id: primaryTagRecord ? Number(primaryTagRecord.id) : null,
    });
    syncRecordFieldsLocally(record, {
      contenu: normalizedContent,
      wiki_tags_id: primaryTagRecord ? Number(primaryTagRecord.id) : null,
    });
  }

  const refreshedWikiRecords = await queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki });
  await cleanupWikiTagsInNocodb(tagRecords, refreshedWikiRecords);

  return { wikiRecords: refreshedWikiRecords, tagRecords };
};

const loadWikiLibrary = async () => {
  const localStore = await readWikiLibraryStore();

  try {
    await syncLocalWikiStoreToNocodb();
  } catch (error) {
    console.error('Wiki sync failed, serving local library', error);
  }

  return localStore.items.map(mapWikiLibraryItem).sort((a, b) => a.title.localeCompare(b.title));
};

const readAnahStatus = async ({ forceRefresh = false } = {}) => {
  if (!forceRefresh && anahStatusCache && anahStatusCache.expiresAt > Date.now()) {
    return anahStatusCache.value;
  }

  const evaluateUrl = async (url) => {
    try {
      const response = await withTimeout((signal) => fetch(url, {
        method: 'GET',
        redirect: 'follow',
        signal,
        headers: {
          'user-agent': 'AidHabitatManager/1.0',
          accept: 'text/html,application/xhtml+xml',
        },
      }));

      const xFrameOptions = String(response.headers.get('x-frame-options') || '').toUpperCase();
      const csp = String(response.headers.get('content-security-policy') || '');
      const frameAncestorsBlocked = /frame-ancestors\s+('none'|'self')/i.test(csp);

      return {
        ok: response.ok,
        status: response.status,
        canEmbed: !(xFrameOptions === 'DENY' || xFrameOptions === 'SAMEORIGIN' || frameAncestorsBlocked),
        reason: response.ok ? '' : `HTTP ${response.status}`,
      };
    } catch (error) {
      return {
        ok: false,
        status: 0,
        canEmbed: false,
        reason: error?.name === 'AbortError' ? 'Délai dépassé' : 'Site indisponible',
      };
    }
  };

  const [registrationStatus, publicStatus] = await Promise.all([
    evaluateUrl(ANAH_REGISTRATION_URL),
    evaluateUrl(ANAH_PUBLIC_URL),
  ]);

  const available = registrationStatus.ok;
  const value = {
    available,
    checkedAt: new Date().toISOString(),
    registrationUrl: ANAH_REGISTRATION_URL,
    publicUrl: ANAH_PUBLIC_URL,
    canEmbed: registrationStatus.canEmbed && publicStatus.canEmbed,
    reason: available ? '' : registrationStatus.reason || 'Site indisponible',
  };

  anahStatusCache = {
    value,
    expiresAt: Date.now() + ANAH_STATUS_TTL_MS,
  };

  return value;
};

const syncRecordFieldsLocally = (record, updates) => {
  if (!record?.fields) return;
  record.fields = { ...record.fields, ...updates };
};

const backfillChildDossierLinks = async ({ tableId, records, dossiers, beneficiaryField = 'beneficiaires_id' }) => {
  const updates = [];

  for (const record of records) {
    const beneficiaryRowId = field(record, beneficiaryField);
    if (!beneficiaryRowId) continue;

    const dossierRecord = latestByFieldValue(dossiers, 'beneficiaires_id', beneficiaryRowId);
    if (!dossierRecord) continue;

    const desiredDossierUuid = field(dossierRecord, 'uuid_source');
    const desiredDossierRowId = Number(dossierRecord.id);
    const patch = {};

    if (field(record, 'dossier_id') !== desiredDossierUuid) {
      patch.dossier_id = desiredDossierUuid;
    }

    if (String(field(record, 'dossiers_id') ?? '') !== String(desiredDossierRowId)) {
      patch.dossiers_id = desiredDossierRowId;
    }

    if (Object.keys(patch).length === 0) continue;

    updates.push({ id: String(record.id), fields: patch });
    syncRecordFieldsLocally(record, patch);
  }

  if (updates.length === 0) return;

  for (let index = 0; index < updates.length; index += 10) {
    await callNocoTool('updateRecords', {
      tableId,
      records: updates.slice(index, index + 10),
    });
  }
};

const createBlankDossierForBeneficiary = async ({ beneficiaryRecord, dossiers, logements, contextes, infosAdmin }) => {
  const beneficiaryRowId = String(beneficiaryRecord.id);
  const existing = latestByFieldValue(dossiers, 'beneficiaires_id', beneficiaryRowId);
  if (existing) return existing;

  const beneficiaryHousings = logements.filter((record) => String(field(record, 'beneficiaires_id') ?? '') === beneficiaryRowId);
  const beneficiaryContexts = contextes.filter((record) => String(field(record, 'beneficiaires_id') ?? '') === beneficiaryRowId);
  const beneficiaryInfos = infosAdmin.filter((record) => String(field(record, 'beneficiaires_id') ?? '') === beneficiaryRowId);
  const patientId = deriveBeneficiaryAppId({
    beneficiaryRecord,
    dossierRecords: [],
    housingRecords: beneficiaryHousings,
    contextRecords: beneficiaryContexts,
    infoRecords: beneficiaryInfos,
  });

  const created = await createRecord(TABLES.dossiers, {
    uuid_source: crypto.randomUUID(),
    patient_id: patientId,
    beneficiaires_id: Number(beneficiaryRecord.id),
    status: 'À visiter',
    ergo_id: specialMemberProfile(DEFAULT_LEGACY_ERGO_EMAIL)?.displayName || 'Coralie',
    created_at: new Date().toISOString(),
  });

  dossiers.push(created);
  return created;
};

const ensureDossiersForBeneficiaries = async ({ beneficiaires, dossiers, logements, contextes, infosAdmin }) => {
  for (const beneficiaryRecord of beneficiaires) {
    await createBlankDossierForBeneficiary({
      beneficiaryRecord,
      dossiers,
      logements,
      contextes,
      infosAdmin,
    });
  }
};

const mapHousing = (housingRecord) => {
  if (!housingRecord) {
    return {
      basement: false,
      rdc: false,
      floor: false,
      garage: false,
      veranda: false,
      balcon: false,
      terrasse: false,
      jardin: false,
      heatingMain: false,
      heatingDetails: {
        electric: false,
        gas: false,
        oil: false,
        heatPump: false,
        collective: false,
        wood: false,
        pellet: false,
        other: false,
      },
      easyAccess: false,
    };
  }

  return {
    id: field(housingRecord, 'uuid_source') || `nocodb-housing-${housingRecord.id}`,
    yearConstruction: stringValue(field(housingRecord, 'annee_construction')),
    yearHabitation: stringValue(field(housingRecord, 'annee_habitation')),
    surface: stringValue(field(housingRecord, 'surface_habitable')),
    levels: toNumber(field(housingRecord, 'nombre_niveaux')),
    typology: refLabel(field(housingRecord, 'type_de_logement')) || 'Maison',
    basement: toBool(field(housingRecord, 'sous_sol')),
    basementDesc: stringValue(field(housingRecord, 'description_sous_sol')),
    rdc: toBool(field(housingRecord, 'rdc')),
    rdcDesc: stringValue(field(housingRecord, 'description_rdc')),
    floor: toBool(field(housingRecord, 'etage')),
    secondFloor: toBool(field(housingRecord, 'second_etage')),
    thirdFloor: toBool(field(housingRecord, 'third_etage')),
    floorDesc: stringValue(field(housingRecord, 'description_etage')),
    garage: toBool(field(housingRecord, 'garage')),
    veranda: toBool(field(housingRecord, 'veranda')),
    balcon: toBool(field(housingRecord, 'balcon')),
    terrasse: toBool(field(housingRecord, 'terrasse')),
    jardin: toBool(field(housingRecord, 'jardin')),
    heatingMain: toBool(field(housingRecord, 'chauffage')),
    heatingDetails: {
      electric: toBool(field(housingRecord, 'radiateurs_electrique')),
      gas: toBool(field(housingRecord, 'chaudiere_gaz')),
      oil: toBool(field(housingRecord, 'chaudiere_fioul')),
      heatPump: toBool(field(housingRecord, 'pompe_a_chaleur')),
      collective: toBool(field(housingRecord, 'chaudiere_collective')),
      wood: toBool(field(housingRecord, 'cheminee_pole_bois')),
      pellet: toBool(field(housingRecord, 'poele_granules')),
      other: toBool(field(housingRecord, 'autre_chauffage')),
    },
    voletsRoulantsManuelsLocalisation: stringValue(field(housingRecord, 'volets_roulants_manuels_localisation')),
    voletsRoulantsManuelsEntier: toBool(field(housingRecord, 'volets_roulants_manuels_entier')),
    voletsRoulantsElectriquesLocalisation: stringValue(field(housingRecord, 'volets_roulants_electriques_localisation')),
    voletsRoulantsElectriquesEntier: toBool(field(housingRecord, 'volets_roulants_electriques_entier')),
    voletsPersiennesLocalisation: stringValue(field(housingRecord, 'volets_persiennes_localisation')),
    voletsPersiennesEntier: toBool(field(housingRecord, 'volets_persiennes_entier')),
    cheminementEscalierExterieur: toBool(field(housingRecord, 'cheminement_escalier_exterieur')),
    cheminementEscalierInterieur: toBool(field(housingRecord, 'cheminement_escalier_interieur')),
    cheminementPenteDouce: toBool(field(housingRecord, 'cheminement_pente_douce')),
    cheminementPlat: toBool(field(housingRecord, 'cheminement_plat')),
    cheminementQuelquesMarches: toBool(field(housingRecord, 'cheminement_quelques_marches')),
    cheminementParArriere: toBool(field(housingRecord, 'cheminement_par_arriere')),
    cheminementSeuilPorte: toBool(field(housingRecord, 'cheminement_seuil_porte')),
    difficultesCirculationInterieure: toBool(field(housingRecord, 'difficultes_circulation_interieure')),
    porteGarageId: field(housingRecord, 'porte_de_garage')?.id ? String(field(housingRecord, 'porte_de_garage').id) : '',
    portailId: field(housingRecord, 'portail')?.id ? String(field(housingRecord, 'portail').id) : '',
    motorisationPorteGarage: refLabel(field(housingRecord, 'porte_de_garage')),
    motorisationPortail: refLabel(field(housingRecord, 'portail')),
    easyAccess: toBool(field(housingRecord, 'acces_facile_rue')),
    comments: stringValue(field(housingRecord, 'commentaire')),
    accessObservation: stringValue(field(housingRecord, 'observation_accessibilite')),
  };
};

const mapPatient = (beneficiaryRecord, appBeneficiaryId) => ({
  id: String(appBeneficiaryId),
  firstName: stringValue(field(beneficiaryRecord, 'prenom')),
  lastName: stringValue(field(beneficiaryRecord, 'nom')),
  secondFirstName: stringValue(field(beneficiaryRecord, 'prenom_occupant_2')),
  secondLastName: stringValue(field(beneficiaryRecord, 'nom_occupant_2')),
  occupants: (() => {
    const parsed = parseOccupantsJson(field(beneficiaryRecord, 'occupants_json'));
    if (parsed.length > 0) return parsed;
    return [
      {
        firstName: stringValue(field(beneficiaryRecord, 'prenom')),
        lastName: stringValue(field(beneficiaryRecord, 'nom')),
        birthDate: stringValue(field(beneficiaryRecord, 'date_naissance_monsieur')),
        apa: Boolean(field(beneficiaryRecord, 'beneficiaire_apa')),
        invalidity: Boolean(field(beneficiaryRecord, 'reconnaissance_invalidite_mdph')),
        invalidityTxt: stringValue(field(beneficiaryRecord, 'reconnaissance_invalidité_mdph_txt')),
        homeHelp: Boolean(field(beneficiaryRecord, 'aide_a_domicile')),
        homeHelpTxt: stringValue(field(beneficiaryRecord, 'aide_a_domicile_txt')),
        dependenceTxt: refLabel(field(beneficiaryRecord, 'dependance_particuliere')) || stringValue(field(beneficiaryRecord, 'dependance_particuliere_txt')),
        numeroSecuriteSociale: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_monsieur')),
        caisseRetraitePrincipale: refLabel(field(beneficiaryRecord, 'caisse_retraite_principale')),
        caissesRetraiteComplementaires: refLabel(field(beneficiaryRecord, 'caisse_retraite_secondaire')),
      },
      ...((field(beneficiaryRecord, 'prenom_occupant_2') || field(beneficiaryRecord, 'nom_occupant_2') || field(beneficiaryRecord, 'date_naissance_madame')) ? [{
        firstName: stringValue(field(beneficiaryRecord, 'prenom_occupant_2')),
        lastName: stringValue(field(beneficiaryRecord, 'nom_occupant_2')),
        birthDate: stringValue(field(beneficiaryRecord, 'date_naissance_madame')),
        numeroSecuriteSociale: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_madame')),
      }] : []),
    ];
  })(),
  address: stringValue(field(beneficiaryRecord, 'adresse_logement')),
  city: stringValue(field(beneficiaryRecord, 'ville_libre')) || refLabel(field(beneficiaryRecord, 'commune')),
  cityId: field(beneficiaryRecord, 'communes_id') ? String(field(beneficiaryRecord, 'communes_id')) : '',
  zipCode: stringValue(field(beneficiaryRecord, 'code_postal_libre')) || stringValue(field(beneficiaryRecord, 'code_postal')),
  phone: stringValue(field(beneficiaryRecord, 'telephone')),
  email: stringValue(field(beneficiaryRecord, 'mail')),
  birthDate: field(beneficiaryRecord, 'date_naissance_monsieur') || field(beneficiaryRecord, 'date_naissance_madame') || undefined,
  birthDateMr: field(beneficiaryRecord, 'date_naissance_monsieur') || undefined,
  birthDateMme: field(beneficiaryRecord, 'date_naissance_madame') || undefined,
  occupant1BirthDate: field(beneficiaryRecord, 'date_naissance_monsieur') || undefined,
  occupant2BirthDate: field(beneficiaryRecord, 'date_naissance_madame') || undefined,
  familySituation: refLabel(field(beneficiaryRecord, 'situation_proprietaire')),
  occupationStatus: normalizeOccupation(refLabel(field(beneficiaryRecord, 'statut_occupation'))),
  numberPeople: toNumber(field(beneficiaryRecord, 'nombre_personnes')),
  incomeCategory: stringValue(field(beneficiaryRecord, 'categorie_revenu_calculee')) || 'Modeste',
  fiscalRevenue: toNumber(field(beneficiaryRecord, 'revenu_fiscal_reference')),
  apa: Boolean(field(beneficiaryRecord, 'beneficiaire_apa')),
  invalidity: Boolean(field(beneficiaryRecord, 'reconnaissance_invalidite_mdph')),
  invalidityTxt: stringValue(field(beneficiaryRecord, 'reconnaissance_invalidité_mdph_txt')),
  homeHelp: Boolean(field(beneficiaryRecord, 'aide_a_domicile')),
  homeHelpTxt: stringValue(field(beneficiaryRecord, 'aide_a_domicile_txt')),
  dependenceTxt: refLabel(field(beneficiaryRecord, 'dependance_particuliere')) || stringValue(field(beneficiaryRecord, 'dependance_particuliere_txt')),
  trustedPerson: {
    name: stringValue(field(beneficiaryRecord, 'personne_confiance')),
    phone: stringValue(field(beneficiaryRecord, 'telephone_personne_confiance')),
    email: stringValue(field(beneficiaryRecord, 'mail_personne_confiance')),
  },
  numeroSecuriteSocialeMonsieur: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_monsieur')),
  numeroSecuriteSocialeMadame: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_madame')),
  occupant1SocialSecurityNumber: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_monsieur')),
  occupant2SocialSecurityNumber: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_madame')),
  caisseRetraitePrincipale: refLabel(field(beneficiaryRecord, 'caisse_retraite_principale')),
  caissesRetraiteComplementaires: refLabel(field(beneficiaryRecord, 'caisse_retraite_secondaire')),
});

const createVirtualDossier = (beneficiaryRecord, appBeneficiaryId, housingRecord, contextRecord, dossierRecord, infoRecord) => ({
  id: `temp-${appBeneficiaryId}`,
  patient: mapPatient(beneficiaryRecord, appBeneficiaryId),
  status: 'À visiter',
  ergoId: stringValue(field(dossierRecord, 'ergo_id')) || 'user',
  visitDate: field(dossierRecord, 'visit_date') || field(beneficiaryRecord, 'date_visite') || field(infoRecord, 'date_visite') || undefined,
  housing: mapHousing(housingRecord),
  medicalContext: mapMedicalContext(contextRecord),
  autonomy: parseChecklistDone(contextRecord),
  compteAnah: stringValue(field(dossierRecord, 'compte_anah')),
  natureAccompagnement: stringValue(field(dossierRecord, 'nature_accompagnement')),
  envoiRapport: stringValue(field(dossierRecord, 'envoi_rapport')),
  personnesPresentesVisite: stringValue(field(dossierRecord, 'personnes_presentes_visite') || field(infoRecord, 'personnes_presentes')),
  autonomyNotes: '',
  plans: {
    PF1: { id: 'PF1', works: [], grants: [] },
    PF2: { id: 'PF2', works: [], grants: [] },
    PF3: { id: 'PF3', works: [], grants: [] },
  },
  createdAt: field(beneficiaryRecord, 'CreatedAt') || new Date().toISOString(),
});

const createDossier = (beneficiaryRecord, appBeneficiaryId, dossierRecord, housingRecord, contextRecord, infoRecord) => ({
  id: field(dossierRecord, 'uuid_source'),
  patient: mapPatient(beneficiaryRecord, appBeneficiaryId),
  status: stringValue(field(dossierRecord, 'status')) || 'À visiter',
  ergoId: stringValue(field(dossierRecord, 'ergo_id')) || 'E1',
  visitDate: field(dossierRecord, 'visit_date') || field(beneficiaryRecord, 'date_visite') || field(infoRecord, 'date_visite') || undefined,
  housing: mapHousing(housingRecord),
  medicalContext: mapMedicalContext(contextRecord),
  autonomy: parseChecklistDone(contextRecord),
  compteAnah: stringValue(field(dossierRecord, 'compte_anah')),
  natureAccompagnement: stringValue(field(dossierRecord, 'nature_accompagnement')),
  envoiRapport: stringValue(field(dossierRecord, 'envoi_rapport')),
  personnesPresentesVisite: stringValue(field(dossierRecord, 'personnes_presentes_visite') || field(infoRecord, 'personnes_presentes')),
  autonomyNotes: '',
  plans: {
    PF1: { id: 'PF1', works: [], grants: [] },
    PF2: { id: 'PF2', works: [], grants: [] },
    PF3: { id: 'PF3', works: [], grants: [] },
  },
  createdAt: field(dossierRecord, 'created_at') || field(dossierRecord, 'CreatedAt') || new Date().toISOString(),
});

const queryAll = async (tableId, options = {}) => {
  const records = [];
  let page = 1;

  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId,
      page,
      pageSize: 100,
      ...options,
    });

    const batch = asArray(payload?.records);
    records.push(...batch);

    if (!payload?.next || batch.length === 0) {
      break;
    }

    page += 1;
  }

  return records;
};

const updateRecord = async (tableId, id, fields) => {
  await callNocoTool('updateRecords', {
    tableId,
    records: [{ id: String(id), fields }],
  });
};

const createRecord = async (tableId, fields) => {
  const payload = await callNocoTool('createRecords', {
    tableId,
    records: [{ fields }],
  });

  const created = asArray(payload).at(0) || asArray(payload?.records).at(0);
  return created;
};

let visitRecommendationsTableIdCache = null;

const discoverTableIdByTitle = async (tableTitle) => {
  const payload = await callNocoTool('getTablesList');
  const tables = asArray(payload);
  const match = tables.find((table) => String(table.title).trim().toLowerCase() === String(tableTitle).trim().toLowerCase());
  return match ? String(match.id) : null;
};

const getVisitRecommendationsTableId = async () => {
  if (visitRecommendationsTableIdCache) {
    return visitRecommendationsTableIdCache;
  }

  const tableId = await discoverTableIdByTitle(VISIT_RECOMMENDATIONS_TABLE_NAME);
  if (tableId) {
    visitRecommendationsTableIdCache = tableId;
  }
  return tableId;
};

const buildVisitRecommendationMetadata = async (dossierRecord) => {
  const beneficiaires = await queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires });
  const beneficiaryRecord = findByRecordId(beneficiaires, field(dossierRecord, 'beneficiaires_id'));
  const patientFirstName = stringValue(field(beneficiaryRecord, 'prenom')).trim();
  const patientLastName = stringValue(field(beneficiaryRecord, 'nom')).trim();
  const patientDisplayName = [patientFirstName, patientLastName].filter(Boolean).join(' ').trim();

  return {
    dossierId: stringValue(field(dossierRecord, 'uuid_source')),
    patientId: stringValue(field(dossierRecord, 'patient_id')),
    patientFirstName,
    patientLastName,
    patientDisplayName,
    dossierLabel: patientDisplayName || stringValue(field(dossierRecord, 'uuid_source')).trim(),
  };
};

const mapVisitRecommendationRecord = (record) => ({
  id: stringValue(field(record, 'uuid_source')) || String(record.id || ''),
  wikiItemId: stringValue(field(record, 'wiki_item_id')),
  wikiTitle: stringValue(field(record, 'wiki_title')),
  wikiImageUrl: absoluteUrl(field(record, 'wiki_image_url')),
  wikiTag: stringValue(field(record, 'wiki_tag')),
  customTitle: stringValue(field(record, 'custom_title')),
  note: stringValue(field(record, 'note')),
  createdAt: field(record, 'created_at') || field(record, 'updated_at') || new Date().toISOString(),
  updatedAt: field(record, 'updated_at') || field(record, 'created_at') || new Date().toISOString(),
});

const buildMemberFromErgoRecord = (record) => {
  const email = normalizeEmail(field(record, 'email') || asArray(field(record, 'User')).at(0)?.email);
  if (!email) return null;
  const special = specialMemberProfile(email);
  const derivedName = special?.displayName || refLabel(record) || email;
  const nocoPassword = stringValue(field(record, 'mot_de_passe')).trim() || null;
  return {
    email,
    displayName: derivedName,
    role: special?.role || 'ERGO',
    selectable: special?.selectable ?? true,
    profilePhotoUrl: resolveClientMediaUrl(field(record, 'nom_etablissement_id')),
    establishmentId: field(record, 'etablissements_id') ? String(field(record, 'etablissements_id')) : '',
    establishmentLabel: refLabel(field(record, 'etablissement')) || special?.establishmentLabel || '',
    ergoRecordId: String(record.id),
    ergoLabel: special?.role === 'ADMIN' ? '' : derivedName,
    // Mot de passe défini directement dans NocoDB — prioritaire sur l'auth-store.
    nocoPassword,
  };
};

const buildFallbackMemberFromProfile = ([email, profile]) => ({
  email,
  displayName: profile.displayName,
  role: profile.role,
  selectable: profile.selectable,
  profilePhotoUrl: '',
  establishmentId: profile.establishmentId ? String(profile.establishmentId) : '',
  establishmentLabel: profile.establishmentLabel || '',
  ergoRecordId: '',
  ergoLabel: profile.role === 'ADMIN' ? '' : profile.displayName,
});

const buildFallbackMembers = () => (
  Object.entries(MEMBER_PROFILES)
    .map(buildFallbackMemberFromProfile)
    .sort((a, b) => a.displayName.localeCompare(b.displayName))
);

const resolveStoredProfilePhotoUrl = (store, email) => {
  const rawValue = stringValue(store?.users?.[email]?.profilePhotoUrl).trim();
  return rawValue ? resolveClientMediaUrl(rawValue) : '';
};

const parseImageDataUrl = (dataUrl) => {
  const match = String(dataUrl || '').match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (!match) {
    throw new Error('Format d’image invalide');
  }

  const mimeType = match[1].toLowerCase();
  const extension = ({
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
    'image/gif': 'gif',
  })[mimeType];

  if (!extension) {
    throw new Error('Format d’image non supporté');
  }

  return {
    mimeType,
    extension,
    buffer: Buffer.from(match[2], 'base64'),
  };
};

const getVisitPlanRelativeUrl = (dossierId) => {
  const folderName = safeSlug(dossierId, 'dossier');
  return `/uploads/visit-plans/${folderName}/plan_logement.png`;
};

const getVisitPlanFileUrl = (dossierId) => {
  const folderName = safeSlug(dossierId, 'dossier');
  return new URL(`${folderName}/plan_logement.png`, VISIT_PLANS_DIR_URL);
};

const readVisitPlanMeta = async (dossierId) => {
  const folderName = safeSlug(dossierId, 'dossier');
  const key = `visit-plans/${folderName}/plan_logement.png`;
  const { url, updatedAt } = await statObject(key);
  return { publicUrl: url, updatedAt };
};

const syncPresetMembersInErgos = async () => {
  const records = await queryAll(TABLES.ergotherapeutes, { fields: FIELD_SETS.ergotherapeutes });
  for (const [email, profile] of Object.entries(MEMBER_PROFILES)) {
    const existing = records.find((record) => normalizeEmail(field(record, 'email')) === email);
    const { prenom, nom } = splitDisplayName(profile.displayName);
    const patch = sanitizeUndefined({
      prenom,
      nom,
      email,
      etablissements_id: profile.establishmentId ?? undefined,
    });

    if (existing && Number(existing.id) > 0) {
      await updateRecord(TABLES.ergotherapeutes, existing.id, patch);
      syncRecordFieldsLocally(existing, patch);
      continue;
    }

    const created = await createRecord(TABLES.ergotherapeutes, {
      uuid_source: crypto.randomUUID(),
      ...patch,
      created_at: new Date().toISOString(),
    });
    records.push(created);
  }

  return records;
};

const loadMemberRegistry = async ({ forceRefresh = false } = {}) => {
  if (!forceRefresh && memberRegistryCache && memberRegistryCache.expiresAt > Date.now()) {
    return memberRegistryCache.value;
  }

  let members;
  try {
    const ergos = await syncPresetMembersInErgos();
    members = ergos
      .map(buildMemberFromErgoRecord)
      .filter(Boolean)
      .sort((a, b) => a.displayName.localeCompare(b.displayName));
  } catch (error) {
    console.warn('[auth] NocoDB indisponible, utilisation du registre local.', error);
    members = Object.entries(MEMBER_PROFILES)
      .map(buildFallbackMemberFromProfile)
      .sort((a, b) => a.displayName.localeCompare(b.displayName));
  }

  const store = await readAuthStore();
  let storeMutated = false;

  for (const member of members) {
    if (store.users[member.email]) continue;
    const password = generatePassword(member.displayName);
    const salt = randomSecret(16);
    store.users[member.email] = {
      salt,
      passwordHash: hashPassword(password, salt),
      createdAt: new Date().toISOString(),
      profilePhotoUrl: '',
    };
    store.pendingCredentials[member.email] = {
      displayName: member.displayName,
      password,
      role: member.role,
      createdAt: new Date().toISOString(),
    };
    storeMutated = true;
  }

  for (const member of members) {
    const storedUser = store.users[member.email];
    const currentPhotoPath = stringValue(storedUser?.profilePhotoUrl).trim();
    const memberPhotoPath = stringValue(member.profilePhotoUrl).trim();
    if (storedUser && memberPhotoPath && memberPhotoPath !== currentPhotoPath) {
      store.users[member.email] = {
        ...storedUser,
        profilePhotoUrl: memberPhotoPath,
      };
      storeMutated = true;
    }
  }

  // Synchronise le mot de passe NocoDB avec l'auth-store :
  //  - Si mot_de_passe est renseigné → on hache avec scrypt et on stocke le hash.
  //    Un checksum sha256 du texte brut permet de détecter les changements sans
  //    stocker le mot de passe lui-même côté serveur.
  //  - Si mot_de_passe est vide → on supprime les champs noco* de l'auth-store
  //    (retour au mot de passe auto-généré).
  // Dans tous les cas, nocoPassword est effacé de l'objet membre en mémoire.
  for (const member of members) {
    const plain = member.nocoPassword;
    member.nocoPassword = null; // jamais conservé en clair en mémoire

    if (plain) {
      const checksum = crypto.createHash('sha256').update(plain).digest('hex');
      const stored = store.users[member.email];
      if (stored?.nocoPasswordChecksum !== checksum) {
        const salt = randomSecret(16);
        store.users[member.email] = {
          ...(stored || { createdAt: new Date().toISOString(), profilePhotoUrl: '' }),
          nocoPasswordHash: hashPassword(plain, salt),
          nocoPasswordSalt: salt,
          nocoPasswordChecksum: checksum,
        };
        storeMutated = true;
      }
    } else {
      // Mot de passe NocoDB effacé → retirer les champs noco* de l'auth-store
      const stored = store.users[member.email];
      if (stored?.nocoPasswordHash) {
        const { nocoPasswordHash: _h, nocoPasswordSalt: _s, nocoPasswordChecksum: _c, ...rest } = stored;
        store.users[member.email] = rest;
        storeMutated = true;
      }
    }
  }

  if (storeMutated) {
    await writeAuthStore(store);
  }

  members = members.map((member) => ({
    ...member,
    profilePhotoUrl: resolveStoredProfilePhotoUrl(store, member.email) || member.profilePhotoUrl || '',
  }));

  const value = { members, store };
  memberRegistryCache = { value, expiresAt: Date.now() + AUTH_CACHE_TTL_MS };
  return value;
};

const loadMemberRegistryForAuth = async () => {
  // Force un rechargement NocoDB à chaque tentative de connexion pour que
  // le champ mot_de_passe soit toujours la valeur actuelle — pas de risque
  // de valider un ancien mot de passe depuis le cache.
  return loadMemberRegistry({ forceRefresh: true });
};

const signSessionToken = async (email) => {
  const { store } = await loadMemberRegistryForAuth();
  const payload = {
    email,
    exp: Date.now() + SESSION_TTL_MS,
  };
  const encodedPayload = encodeBase64Url(payload);
  const signature = crypto.createHmac('sha256', store.secret).update(encodedPayload).digest('base64url');
  return `${encodedPayload}.${signature}`;
};

const resolveSessionUser = async (req) => {
  const token = getTokenFromRequest(req);
  if (!token) return null;
  const localAuthEmail = decodeLocalAuthEmail(token);
  if (localAuthEmail) {
    const { members } = await loadMemberRegistryForAuth();
    return members.find((member) => member.email === normalizeEmail(localAuthEmail)) || null;
  }
  const [encodedPayload, signature] = token.split('.');
  if (!encodedPayload || !signature) return null;

  const { store, members } = await loadMemberRegistryForAuth();
  const expectedSignature = crypto.createHmac('sha256', store.secret).update(encodedPayload).digest('base64url');
  if (signature !== expectedSignature) return null;

  const payload = decodeBase64Url(encodedPayload);
  if (!payload?.email || Number(payload.exp) < Date.now()) return null;

  return members.find((member) => member.email === normalizeEmail(payload.email)) || null;
};

const requireAuth = async (req, res, next) => {
  try {
    const user = await resolveSessionUser(req);
    if (!user) {
      res.status(401).json({ success: false, error: 'Session invalide ou expirée' });
      return;
    }
    // Ne jamais exposer nocoPassword vers le client via req.appUser.
    const { nocoPassword: _omit, ...safeUser } = user;
    req.appUser = safeUser;
    next();
  } catch (error) {
    next(error);
  }
};

const requireAdmin = async (req, res, next) => {
  try {
    const user = await resolveSessionUser(req);
    if (!user) {
      res.status(401).json({ success: false, error: 'Session invalide ou expirée' });
      return;
    }
    if (user.role !== 'ADMIN') {
      res.status(403).json({ success: false, error: 'Accès administrateur requis' });
      return;
    }
    const { nocoPassword: _omit, ...safeUser } = user;
    req.appUser = safeUser;
    next();
  } catch (error) {
    next(error);
  }
};

const getAdminAccessMembers = async () => {
  const { members, store } = await loadMemberRegistry({ forceRefresh: true });
  return members.map((member) => ({
    email: member.email,
    displayName: member.displayName,
    role: member.role,
    selectable: member.selectable,
    establishmentLabel: member.establishmentLabel,
    ergoLabel: member.ergoLabel,
    hasPassword: Boolean(store.users[member.email]),
    generatedPassword: store.pendingCredentials[member.email]?.password || '',
    createdAt: store.users[member.email]?.createdAt || null,
  }));
};

const buildLocalAccessScopes = (member) => {
  if (!member) return [];
  if (member.role === 'ADMIN') {
    return [{ type: 'dossier_access', value: '*' }];
  }

  const scopes = [];
  if (member.establishmentId) {
    scopes.push({ type: 'establishment_id', value: String(member.establishmentId) });
  }
  if (member.ergoLabel) {
    scopes.push({ type: 'ergo_label', value: String(member.ergoLabel) });
    scopes.push({ type: 'dossier_ergo', value: String(member.ergoLabel) });
  }
  return scopes;
};

const buildLocalAuthUserPayload = (member) => ({
  email: member.email,
  displayName: member.displayName,
  role: member.role,
  establishmentId: member.establishmentId ? String(member.establishmentId) : '',
  ergoLabel: member.ergoLabel || '',
  isActive: true,
  scopes: buildLocalAccessScopes(member),
  // `profilePhotoUrl` exposé pour que `mergeRemoteUsers` côté Flutter
  // (auth_service.dart) puisse persister la photo de chaque membre dans
  // le SQLite local. Sans ça, un device qui n'a JAMAIS uploadé la
  // photo de l'utilisateur courant (typiquement : on s'est inscrit
  // sur l'iPad puis on se connecte sur macOS web) restait avec un
  // `profile_photo_url` vide en local, et l'avatar du sidebar
  // affichait les initiales au lieu de la photo. Bug signalé
  // 2026-04-29 : « la photo de profil que j'ai mis à Coralie sur Ipad
  // marche bien mais sur la version macOs même si je me login de
  // nouveau la photo de profil n'apparait pas ».
  profilePhotoUrl: member.profilePhotoUrl || '',
});

const resolveRequestedErgoLabel = async (appUser, requestedErgoLabel) => {
  const normalizedRequested = stringValue(requestedErgoLabel).trim();
  if (appUser.role !== 'ADMIN') {
    return appUser.ergoLabel;
  }

  if (!normalizedRequested) {
    throw new Error('Un ergothérapeute doit être sélectionné');
  }

  const { members } = await loadMemberRegistry();
  const match = members.find((member) => member.selectable && member.displayName === normalizedRequested);
  if (!match) {
    throw new Error('Ergothérapeute sélectionné invalide');
  }
  return match.displayName;
};

const canAccessDossierRecord = (appUser, dossierRecord) => {
  if (appUser?.role === 'ADMIN') return true;
  return stringValue(field(dossierRecord, 'ergo_id')).trim() === stringValue(appUser?.ergoLabel).trim();
};

const resolveBeneficiaryAccess = async (appUser, patientId) => {
  const [beneficiaires, dossiers, logements, contextes, infosAdmin] = await Promise.all([
    queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires }),
    queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers }),
    queryAll(TABLES.logements, { fields: FIELD_SETS.logements }),
    queryAll(TABLES.contexteDeVie, { fields: FIELD_SETS.contexteDeVie }),
    queryAll(TABLES.informationsAdministratives, { fields: FIELD_SETS.informationsAdministratives }),
  ]);

  const beneficiaryRecord = resolveBeneficiaryRecord({
    beneficiaires,
    dossiers,
    logements,
    contextes,
    infosAdmin,
    appBeneficiaryId: patientId,
  });

  if (!beneficiaryRecord) {
    throw httpError(404, `Bénéficiaire ${patientId} introuvable`);
  }

  const dossierRecord = latestByFieldValue(dossiers, 'beneficiaires_id', beneficiaryRecord.id);
  if (dossierRecord && !canAccessDossierRecord(appUser, dossierRecord)) {
    // Avant de rejeter en 403, on retente avec un refresh FORCÉ du
    // memberRegistry. Le cache (TTL ~30s) peut avoir une version stale
    // du `ergoLabel` quelques secondes après un login ou un changement
    // de rôle côté NocoDB → 1er finalize en 403, retry réussit.
    // Demande utilisateur 2026-04-29 : « la génération de mon document
    // met plus de 3 minutes, j'ai eu ce problème puis la generation a
    // été validée » — ce ré-essai côté serveur évite le dialog
    // "Opération en échec" cosmétique.
    try {
      const { members } = await loadMemberRegistry({ forceRefresh: true });
      const refreshed = members.find((m) => m.email === appUser?.email);
      if (refreshed) {
        const refreshedAppUser = { ...appUser, ergoLabel: refreshed.ergoLabel };
        if (canAccessDossierRecord(refreshedAppUser, dossierRecord)) {
          // Refresh du cache a résolu le mismatch — on laisse passer.
          return { beneficiaryRecord, dossierRecord };
        }
      }
    } catch (_) {
      // Refresh échoué : on tombe sur le 403 d'origine.
    }
    throw httpError(403, 'Accès interdit à ce bénéficiaire');
  }

  return {
    beneficiaryRecord,
    dossierRecord,
  };
};

const mapStoredDocument = (document) => ({
  id: document.id,
  patientId: document.patientId,
  dossierId: document.dossierId || null,
  patientFirstName: stringValue(document.patientFirstName),
  patientLastName: stringValue(document.patientLastName),
  patientDisplayName: stringValue(document.patientDisplayName),
  dossierLabel: stringValue(document.dossierLabel),
  title: document.title,
  fileName: document.fileName,
  mimeType: document.mimeType,
  tags: asArray(document.tags).map((tag) => String(tag)),
  createdAt: document.createdAt,
  updatedAt: document.updatedAt,
  remotePath: document.remotePath || document.relativeUrl || '',
  publicUrl: document.publicUrl || (document.relativeUrl ? absoluteUrl(document.relativeUrl) : ''),
});

const buildBeneficiaryDocumentContext = ({ beneficiaryRecord, dossierRecord, patientId }) => {
  const patientFirstName = stringValue(field(beneficiaryRecord, 'prenom')).trim();
  const patientLastName = stringValue(field(beneficiaryRecord, 'nom')).trim();
  const patientDisplayName = [patientFirstName, patientLastName].filter(Boolean).join(' ').trim()
    || patientId;
  const dossierLabel = patientDisplayName;

  return {
    patientFirstName,
    patientLastName,
    patientDisplayName,
    dossierLabel,
  };
};

const mapStoredNotePage = (notePage) => ({
  id: notePage.id,
  patientId: notePage.patientId,
  dossierId: notePage.dossierId || null,
  patientFirstName: stringValue(notePage.patientFirstName),
  patientLastName: stringValue(notePage.patientLastName),
  patientDisplayName: stringValue(notePage.patientDisplayName),
  dossierLabel: stringValue(notePage.dossierLabel),
  scopeType: notePage.scopeType || 'legacy',
  scopeId: notePage.scopeId || notePage.dossierId || notePage.patientId,
  tabKey: notePage.tabKey,
  subTabKey: stringValue(notePage.subTabKey),
  pageNumber: Number(notePage.pageNumber) || 0,
  textContent: stringValue(notePage.textContent),
  drawingJson: stringValue(notePage.drawingJson),
  previewDataUrl: stringValue(notePage.previewDataUrl),
  previewUrl: absoluteUrl(`/public/note-pages/${encodeURIComponent(notePage.id)}/preview`),
  layoutKind: stringValue(notePage.layoutKind) || 'freeform',
  updatedAt: notePage.updatedAt,
  remotePath: `note-pages/${notePage.patientId}/${notePage.scopeType || 'legacy'}/${notePage.scopeId || notePage.dossierId || notePage.patientId}/${notePage.tabKey}/${stringValue(notePage.subTabKey) || 'general'}/${Number(notePage.pageNumber) || 0}`,
  remoteUrl: absoluteUrl(`/api/note-pages/${encodeURIComponent(notePage.patientId)}?scopeType=${encodeURIComponent(notePage.scopeType || 'legacy')}&scopeId=${encodeURIComponent(notePage.scopeId || notePage.dossierId || notePage.patientId)}&tabKey=${encodeURIComponent(notePage.tabKey)}&subTabKey=${encodeURIComponent(stringValue(notePage.subTabKey) || 'general')}&pageNumber=${Number(notePage.pageNumber) || 0}`),
});

const escapeHtml = (value) => String(value || '')
  .replace(/&/g, '&amp;')
  .replace(/</g, '&lt;')
  .replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;')
  .replace(/'/g, '&#39;');

const formatBeneficiaryDisplayName = (beneficiaryRecord) => {
  const firstName = stringValue(field(beneficiaryRecord, 'prenom')).trim();
  const lastName = stringValue(field(beneficiaryRecord, 'nom')).trim();
  return [firstName, lastName].filter(Boolean).join(' ').trim();
};

const backfillLegacyDossierAssignments = async (dossiers) => {
  const fallbackLabel = specialMemberProfile(DEFAULT_LEGACY_ERGO_EMAIL)?.displayName || 'Coralie';
  const updates = dossiers
    .filter((record) => {
      const current = stringValue(field(record, 'ergo_id')).trim();
      return current === '' || current === 'E1' || current === 'user';
    })
    .map((record) => ({ id: String(record.id), fields: { ergo_id: fallbackLabel } }));

  if (updates.length === 0) return;

  for (let index = 0; index < updates.length; index += 10) {
    await callNocoTool('updateRecords', {
      tableId: TABLES.dossiers,
      records: updates.slice(index, index + 10),
    });
  }

  for (const update of updates) {
    const target = dossiers.find((record) => String(record.id) === update.id);
    syncRecordFieldsLocally(target, update.fields);
  }
};

const getReferences = async (appUser) => {
  const [situations, dependances, porteGarage, portail, baremesAnah, ergos, etablissements, communes, epcis] = await Promise.all([
    queryAll(TABLES.situationProprietaire, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.dependancesParticulieres, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.porteDeGarage, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.portail, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.baremesAnah, { fields: ['libelle', 'nombre_personnes', 'revenu_tres_modeste', 'revenu_modeste', 'revenu_intermediaire', 'revenu_haut', 'annee_plafond'] }),
    queryAll(TABLES.ergotherapeutes, { fields: FIELD_SETS.ergotherapeutes }),
    queryAll(TABLES.etablissements, { fields: FIELD_SETS.referencesNom }),
    queryAll(TABLES.communes, { fields: FIELD_SETS.communes }),
    queryAll(TABLES.epci, { fields: FIELD_SETS.referencesNom }),
  ]);

  return {
    situations: situations.map((record) => ({ id: String(record.id), label: refLabel(record) })),
    dependances: dependances.map((record) => ({ id: String(record.id), label: refLabel(record) })),
    porteGarage: porteGarage.map((record) => ({ id: String(record.id), label: refLabel(record) })),
    portail: portail.map((record) => ({ id: String(record.id), label: refLabel(record) })),
    baremesAnah: baremesAnah.map((record) => ({
      id: String(record.id),
      label: refLabel(record),
      householdSize: Number(field(record, 'nombre_personnes')) || 0,
      revenueTresModeste: toNumber(field(record, 'revenu_tres_modeste')),
      revenueModeste: toNumber(field(record, 'revenu_modeste')),
      revenueIntermediaire: toNumber(field(record, 'revenu_intermediaire')),
      revenueHaut: toNumber(field(record, 'revenu_haut')),
      plafondYear: toNumber(field(record, 'annee_plafond')),
    })),
    ergos: ergos
      .map(buildMemberFromErgoRecord)
      .filter((member) => member && member.selectable)
      .filter((member) => appUser?.role === 'ADMIN' || member.email === appUser?.email)
      .map((member) => ({
        id: member.ergoRecordId,
        label: member.displayName,
        establishmentId: member.establishmentId,
        establishmentLabel: member.establishmentLabel,
      })),
    etablissements: etablissements.map((record) => ({ id: String(record.id), label: refLabel(record) })),
    communes: communes
      .map((record) => ({
        id: String(record.id),
        label: refLabel(record),
        zipCode: stringValue(field(record, 'code_postal')),
        epciId: field(record, 'epci_id1') ? String(field(record, 'epci_id1')) : '',
        epciLabel: refLabel(field(record, 'epci')),
      }))
      .sort((a, b) => a.label.localeCompare(b.label) || a.zipCode.localeCompare(b.zipCode)),
    epcis: epcis.map((record) => ({ id: String(record.id), label: refLabel(record) })),
  };
};

const getDossiersForApp = async (appUser) => {
  const [beneficiaires, dossiers, logements, contextes, infosAdmin] = await Promise.all([
    queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires }),
    queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers }),
    queryAll(TABLES.logements, { fields: FIELD_SETS.logements }),
    queryAll(TABLES.contexteDeVie, { fields: FIELD_SETS.contexteDeVie }),
    queryAll(TABLES.informationsAdministratives, { fields: FIELD_SETS.informationsAdministratives }),
  ]);

  await ensureDossiersForBeneficiaries({ beneficiaires, dossiers, logements, contextes, infosAdmin });
  await backfillLegacyDossierAssignments(dossiers);
  await Promise.all([
    backfillChildDossierLinks({ tableId: TABLES.contexteDeVie, records: contextes, dossiers }),
    backfillChildDossierLinks({ tableId: TABLES.informationsAdministratives, records: infosAdmin, dossiers }),
  ]);

  const dossiersByBeneficiary = groupBy(dossiers, 'beneficiaires_id');
  const logementsByBeneficiary = groupBy(logements, 'beneficiaires_id');
  const contextByBeneficiaryRowId = groupBy(contextes, 'beneficiaires_id');
  const infoByBeneficiaryRowId = groupBy(infosAdmin, 'beneficiaires_id');
  const contextByDossier = groupBy(contextes, 'dossier_id');
  const infoByDossier = groupBy(infosAdmin, 'dossier_id');

  const mapped = beneficiaires.map((beneficiaryRecord) => {
    const beneficiaryRowId = String(beneficiaryRecord.id);
    const beneficiaryDossiers = dossiersByBeneficiary.get(beneficiaryRowId) || [];
    const beneficiaryHousings = logementsByBeneficiary.get(beneficiaryRowId) || [];
    const beneficiaryContexts = contextByBeneficiaryRowId.get(beneficiaryRowId) || [];
    const beneficiaryInfos = infoByBeneficiaryRowId.get(beneficiaryRowId) || [];
    const appBeneficiaryId = deriveBeneficiaryAppId({
      beneficiaryRecord,
      dossierRecords: beneficiaryDossiers,
      housingRecords: beneficiaryHousings,
      contextRecords: beneficiaryContexts,
      infoRecords: beneficiaryInfos,
    });
    const dossierRecord = latestRecord(beneficiaryDossiers);
    const dossierSourceId = field(dossierRecord, 'uuid_source');
    const housingRecord = latestRecord(beneficiaryHousings);
    const contextRecord = latestRecord((dossierSourceId && contextByDossier.get(String(dossierSourceId))) || beneficiaryContexts || []);
    const infoRecord = latestRecord((dossierSourceId && infoByDossier.get(String(dossierSourceId))) || beneficiaryInfos || []);

    if (!dossierRecord) {
      return createVirtualDossier(beneficiaryRecord, appBeneficiaryId, housingRecord, contextRecord, null, infoRecord);
    }

    return createDossier(beneficiaryRecord, appBeneficiaryId, dossierRecord, housingRecord, contextRecord, infoRecord);
  });

  const filtered = appUser?.role === 'ADMIN'
    ? mapped
    : mapped.filter((dossier) => stringValue(dossier.ergoId).trim() === stringValue(appUser?.ergoLabel).trim());

  return filtered.sort((a, b) => a.patient.lastName.localeCompare(b.patient.lastName) || a.patient.firstName.localeCompare(b.patient.firstName));
};

const ensureDossierRecord = async (dossierIdOrTemp) => {
  const dossiers = await queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers });

  if (!dossierIdOrTemp.startsWith('temp-')) {
    const dossierRecord = findByUuidSource(dossiers, dossierIdOrTemp);
    if (!dossierRecord) {
      throw new Error(`Dossier ${dossierIdOrTemp} introuvable dans la base métier`);
    }
    return dossierRecord;
  }

  const patientId = dossierIdOrTemp.replace(/^temp-/, '');
  const existing = latestByFieldValue(dossiers, 'patient_id', patientId);
  if (existing) return existing;

  const [beneficiaires, logements, contextes, infosAdmin] = await Promise.all([
    queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires }),
    queryAll(TABLES.logements, { fields: FIELD_SETS.logements }),
    queryAll(TABLES.contexteDeVie, { fields: FIELD_SETS.contexteDeVie }),
    queryAll(TABLES.informationsAdministratives, { fields: FIELD_SETS.informationsAdministratives }),
  ]);
  const beneficiaryRecord = resolveBeneficiaryRecord({
    beneficiaires,
    dossiers,
    logements,
    contextes,
    infosAdmin,
    appBeneficiaryId: patientId,
  });
  if (!beneficiaryRecord) {
    throw new Error(`Bénéficiaire ${patientId} introuvable pour créer un dossier`);
  }

  const newUuid = crypto.randomUUID();
  const created = await createRecord(TABLES.dossiers, {
    uuid_source: newUuid,
    patient_id: patientId,
    beneficiaires_id: Number(beneficiaryRecord.id),
    status: 'À visiter',
    created_at: new Date().toISOString(),
  });

  return created;
};

const upsertContexte = async (
  dossierUuid,
  beneficiaryUuid,
  medicalContext,
  autonomy,
  options = {},
) => {
  const contextes = await queryAll(TABLES.contexteDeVie, { fields: FIELD_SETS.contexteDeVie });
  const existing = latestByFieldValue(contextes, 'dossier_id', dossierUuid)
    || latestByFieldValue(contextes, 'beneficiaire_id', beneficiaryUuid);
  const dossierRecord = options.dossierRecord || null;
  const beneficiaryRecordId = options.beneficiaryRecordId ?? null;

  const checklistMap = new Map((autonomy?.checklist || []).map((item) => [item.name, item.checked]));
  const normalizedOccupants = Array.isArray(autonomy?.occupants)
    ? autonomy.occupants
      .filter((entry) => entry && typeof entry === 'object')
      .map((entry) => ({
        medical: {
          pathology: stringValue(entry?.medical?.pathology).trim(),
          followUp: stringValue(entry?.medical?.followUp).trim(),
          sensory: stringValue(entry?.medical?.sensory).trim(),
          heightCm: stringValue(entry?.medical?.heightCm).trim(),
          weightKg: stringValue(entry?.medical?.weightKg).trim(),
        },
        autonomyDone: Boolean(entry?.autonomyDone),
        autonomy: AUTONOMY_ITEMS.map((name, index) => ({
          name,
          checked: Boolean(entry?.autonomy?.[index]?.checked),
        })),
        humanHelp: AUTONOMY_ITEMS.map((name, index) => ({
          name,
          checked: Boolean(entry?.humanHelp?.[index]?.checked),
        })),
      }))
    : [];
  const legacySizeWeight = stringValue(medicalContext?.sizeWeight).replace(',', '.');
  const legacyHeightMatch = legacySizeWeight.match(/(\d+(?:\.\d+)?)\s*cm/i);
  const legacyWeightMatch = legacySizeWeight.match(/(\d+(?:\.\d+)?)\s*kg/i);
  const heightCm = stringValue(medicalContext?.heightCm).trim() || legacyHeightMatch?.[1] || '';
  const weightKg = stringValue(medicalContext?.weightKg).trim() || legacyWeightMatch?.[1] || '';
  const fields = {
    dossier_id: dossierUuid,
    beneficiaire_id: beneficiaryUuid,
    dossiers_id: dossierRecord ? Number(dossierRecord.id) : undefined,
    beneficiaires_id: beneficiaryRecordId != null ? Number(beneficiaryRecordId) : undefined,
    nom_pathologie: nullableString(medicalContext?.pathology),
    suivi_medical: nullableString(medicalContext?.followUp),
    deficience_auditive_visuelle: nullableString(medicalContext?.sensory),
    taille_approximative: nullableString(heightCm),
    poids_exact: nullableString(weightKg),
    aide_technique_deplacement: checklistMap.get('Déplacements/transferts') ? true : false,
    difficultes_escalier: checklistMap.get('Escaliers') ? 'Oui' : '',
    restrictions_conduite: checklistMap.get('Conduite automobile') ? 'Oui' : '',
    autonomie_toilette: checklistMap.get('Toilette/habillage') ? 'Oui' : '',
    autonomie_repas: checklistMap.get('Repas (y compris courses)') ? 'Oui' : '',
    autonomie_menage: checklistMap.get('Tâches ménagères.domestiques') ? 'Oui' : '',
    autonomie_demarches_admin: checklistMap.get('Démarches admin') ? 'Oui' : '',
    occupants_json: normalizedOccupants.length > 0 ? JSON.stringify(normalizedOccupants) : null,
  };

  if (existing) {
    await updateRecord(TABLES.contexteDeVie, existing.id, fields);
  } else {
    await createRecord(TABLES.contexteDeVie, {
      uuid_source: crypto.randomUUID(),
      ...fields,
    });
  }
};

const sanitizeUndefined = (fields) => Object.fromEntries(
  Object.entries(fields).filter(([, value]) => value !== undefined)
);

let beneficiaryReferenceSetsCache = null;
let beneficiaryReferenceSetsCachedAt = 0;
const BENEFICIARY_REFERENCE_CACHE_TTL_MS = 5 * 60 * 1000;

const loadBeneficiaryReferenceSets = async () => {
  if (
    beneficiaryReferenceSetsCache
    && (Date.now() - beneficiaryReferenceSetsCachedAt) < BENEFICIARY_REFERENCE_CACHE_TTL_MS
  ) {
    return beneficiaryReferenceSetsCache;
  }

  const [communes, situations, statuts, dependances, caisses, caissesComp, baremesAnah] = await Promise.all([
    queryAll(TABLES.communes, { fields: FIELD_SETS.communes }),
    queryAll(TABLES.situationProprietaire, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.statutOccupation, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.dependancesParticulieres, { fields: FIELD_SETS.referencesLibelle }),
    queryAll(TABLES.caissesRetraite, { fields: FIELD_SETS.referencesNom }),
    queryAll(TABLES.caissesRetraiteComplementaires, { fields: FIELD_SETS.referencesNom }),
    queryAll(TABLES.baremesAnah, { fields: FIELD_SETS.baremesAnah }),
  ]);

  beneficiaryReferenceSetsCache = { communes, situations, statuts, dependances, caisses, caissesComp, baremesAnah };
  beneficiaryReferenceSetsCachedAt = Date.now();
  return beneficiaryReferenceSetsCache;
};

const selectBaremeAnah = (records, householdSize) => {
  const size = Number(householdSize);
  if (!Number.isFinite(size) || size <= 0) return undefined;

  const exactMatches = records.filter((record) => Number(field(record, 'nombre_personnes')) === size);
  const candidates = exactMatches.length > 0
    ? exactMatches
    : records.filter((record) => Number(field(record, 'nombre_personnes')) <= size);

  if (candidates.length === 0) return undefined;

  return [...candidates].sort((a, b) => {
    const yearDiff = Number(field(b, 'annee_plafond') || 0) - Number(field(a, 'annee_plafond') || 0);
    if (yearDiff !== 0) return yearDiff;
    return Number(field(b, 'nombre_personnes') || 0) - Number(field(a, 'nombre_personnes') || 0);
  })[0];
};

const mapBeneficiaryUpdatesToFields = (updates, references) => {
  const has = (key) => Object.prototype.hasOwnProperty.call(updates, key);
  const hasTrustedPerson = has('trustedPerson') && updates.trustedPerson && typeof updates.trustedPerson === 'object';
  const trustedPersonPayload = hasTrustedPerson ? updates.trustedPerson : {};
  const trustedPersonNameValue = hasTrustedPerson && Object.prototype.hasOwnProperty.call(trustedPersonPayload, 'name')
    ? trustedPersonPayload?.name
    : (has('trustedName') ? updates.trustedName : undefined);
  const trustedPersonPhoneValue = hasTrustedPerson && Object.prototype.hasOwnProperty.call(trustedPersonPayload, 'phone')
    ? trustedPersonPayload?.phone
    : (has('trustedPhone') ? updates.trustedPhone : undefined);
  const trustedPersonEmailValue = hasTrustedPerson && Object.prototype.hasOwnProperty.call(trustedPersonPayload, 'email')
    ? trustedPersonPayload?.email
    : (has('trustedEmail') ? updates.trustedEmail : undefined);
  const situationMatch = findByLabel(references.situations, updates.familySituation);
  const normalizedOccupation = normalizeLabelForMatch(updates.occupationStatus);
  const occupationMatch = findByLabel(references.statuts, updates.occupationStatus === 'Usufruitier' ? 'Usufruitier(e)' : updates.occupationStatus)
    || (normalizedOccupation.startsWith('usufruitier')
      ? findByLabel(references.statuts, 'Usufruitier')
      : undefined);
  const dependenceMatch = findByLabel(references.dependances, updates.dependenceTxt);
  const caisseMatch = findByLabel(references.caisses, updates.caisseRetraitePrincipale);
  const caisseCompMatch = findByLabel(references.caissesComp, updates.caissesRetraiteComplementaires);
  const hasCommuneInput = has('city') || has('cityId') || has('zipCode');
  const communeMatch = has('cityId')
    ? references.communes.find((record) => String(record.id) === String(updates.cityId))
    : (hasCommuneInput ? findCommuneMatch(references.communes, updates.city, updates.zipCode) : undefined);
  const resolvedCommuneLabel = communeMatch ? stringValue(field(communeMatch, 'nom')) : stringValue(updates.city);
  const resolvedZipCode = communeMatch ? stringValue(field(communeMatch, 'code_postal')) : stringValue(updates.zipCode);
  const baremeMatch = has('numberPeople') ? selectBaremeAnah(references.baremesAnah, updates.numberPeople) : undefined;
  const normalizedOccupantsBase = Array.isArray(updates.occupants)
    ? updates.occupants
      .filter((entry) => entry && typeof entry === 'object')
      .map((entry) => ({
        firstName: stringValue(entry.firstName).trim(),
        lastName: stringValue(entry.lastName).trim(),
        birthDate: stringValue(entry.birthDate).trim(),
        apa: Boolean(entry.apa),
        // GIR (Groupe Iso-Ressources) — préservé pour le rapport PDF.
        // Sans cette ligne, le serveur dépouille `apaGir` lors du
        // round-trip Flutter→NocoDB et la valeur n'arrive jamais au
        // générateur (bug 2026-04-29).
        apaGir: stringValue(entry.apaGir).trim(),
        invalidity: Boolean(entry.invalidity),
        invalidityTxt: stringValue(entry.invalidityTxt).trim(),
        homeHelp: Boolean(entry.homeHelp),
        homeHelpTxt: stringValue(entry.homeHelpTxt).trim(),
        dependenceTxt: stringValue(entry.dependenceTxt).trim(),
        numeroSecuriteSociale: stringValue(entry.numeroSecuriteSociale).trim(),
        caisseRetraitePrincipale: stringValue(entry.caisseRetraitePrincipale).trim(),
        caissesRetraiteComplementaires: stringValue(entry.caissesRetraiteComplementaires).trim(),
      }))
    : null;
  const normalizedOccupants = normalizedOccupantsBase ? [...normalizedOccupantsBase] : null;

  if (normalizedOccupants?.[0]) {
    normalizedOccupants[0] = {
      ...normalizedOccupants[0],
      firstName: has('firstName') ? stringValue(updates.firstName).trim() : normalizedOccupants[0].firstName,
      lastName: has('lastName') ? stringValue(updates.lastName).trim() : normalizedOccupants[0].lastName,
      birthDate: has('occupant1BirthDate')
        ? stringValue(updates.occupant1BirthDate).trim()
        : (has('birthDateMr') ? stringValue(updates.birthDateMr).trim() : normalizedOccupants[0].birthDate),
      apa: has('apa') ? Boolean(updates.apa) : normalizedOccupants[0].apa,
      invalidity: has('invalidity') ? Boolean(updates.invalidity) : normalizedOccupants[0].invalidity,
      invalidityTxt: has('invalidityTxt') ? stringValue(updates.invalidityTxt).trim() : normalizedOccupants[0].invalidityTxt,
      homeHelp: has('homeHelp') ? Boolean(updates.homeHelp) : normalizedOccupants[0].homeHelp,
      homeHelpTxt: has('homeHelpTxt') ? stringValue(updates.homeHelpTxt).trim() : normalizedOccupants[0].homeHelpTxt,
      dependenceTxt: has('dependenceTxt') ? stringValue(updates.dependenceTxt).trim() : normalizedOccupants[0].dependenceTxt,
      numeroSecuriteSociale: has('occupant1SocialSecurityNumber')
        ? stringValue(updates.occupant1SocialSecurityNumber).trim()
        : (has('numeroSecuriteSocialeMonsieur')
          ? stringValue(updates.numeroSecuriteSocialeMonsieur).trim()
          : normalizedOccupants[0].numeroSecuriteSociale),
      caisseRetraitePrincipale: has('caisseRetraitePrincipale')
        ? stringValue(updates.caisseRetraitePrincipale).trim()
        : normalizedOccupants[0].caisseRetraitePrincipale,
      caissesRetraiteComplementaires: has('caissesRetraiteComplementaires')
        ? stringValue(updates.caissesRetraiteComplementaires).trim()
        : normalizedOccupants[0].caissesRetraiteComplementaires,
    };
  }

  if (normalizedOccupants?.[1]) {
    normalizedOccupants[1] = {
      ...normalizedOccupants[1],
      firstName: has('secondFirstName') ? stringValue(updates.secondFirstName).trim() : normalizedOccupants[1].firstName,
      lastName: has('secondLastName') ? stringValue(updates.secondLastName).trim() : normalizedOccupants[1].lastName,
      birthDate: has('occupant2BirthDate')
        ? stringValue(updates.occupant2BirthDate).trim()
        : (has('birthDateMme') ? stringValue(updates.birthDateMme).trim() : normalizedOccupants[1].birthDate),
      numeroSecuriteSociale: has('occupant2SocialSecurityNumber')
        ? stringValue(updates.occupant2SocialSecurityNumber).trim()
        : (has('numeroSecuriteSocialeMadame')
          ? stringValue(updates.numeroSecuriteSocialeMadame).trim()
          : normalizedOccupants[1].numeroSecuriteSociale),
    };
  }

  const primaryOccupant = normalizedOccupants?.[0];
  const secondaryOccupant = normalizedOccupants?.[1];

  return sanitizeUndefined({
    prenom: normalizedOccupants ? nullableString(primaryOccupant?.firstName) : (has('firstName') ? nullableString(updates.firstName) : undefined),
    nom: normalizedOccupants ? nullableString(primaryOccupant?.lastName) : (has('lastName') ? nullableString(updates.lastName) : undefined),
    prenom_occupant_2: normalizedOccupants ? nullableString(secondaryOccupant?.firstName) : (has('secondFirstName') ? nullableString(updates.secondFirstName) : undefined),
    nom_occupant_2: normalizedOccupants ? nullableString(secondaryOccupant?.lastName) : (has('secondLastName') ? nullableString(updates.secondLastName) : undefined),
    occupants_json: normalizedOccupants ? JSON.stringify(normalizedOccupants) : undefined,
    mail: has('email') ? nullableString(updates.email) : undefined,
    telephone: has('phone') ? nullableString(updates.phone) : undefined,
    adresse_logement: has('address') ? nullableString(updates.address) : undefined,
    ville_libre: hasCommuneInput ? nullableString(resolvedCommuneLabel) : undefined,
    code_postal_libre: hasCommuneInput ? nullableString(resolvedZipCode) : undefined,
    communes_id: hasCommuneInput ? (communeMatch ? Number(communeMatch.id) : null) : undefined,
    date_naissance_monsieur: normalizedOccupants
      ? nullableString(primaryOccupant?.birthDate)
      : (has('occupant1BirthDate')
        ? nullableString(updates.occupant1BirthDate)
        : (has('birthDateMr') ? nullableString(updates.birthDateMr) : undefined)),
    date_naissance_madame: normalizedOccupants
      ? nullableString(secondaryOccupant?.birthDate)
      : (has('occupant2BirthDate')
        ? nullableString(updates.occupant2BirthDate)
        : (has('birthDateMme') ? nullableString(updates.birthDateMme) : undefined)),
    // Si l'utilisateur envoie une étiquette non vide mais que
    // `findByLabel` ne matche AUCUNE entrée de la table de référence,
    // on `undefined` (= ne touche pas la colonne NocoDB) plutôt que
    // d'écrire `null` (= efface la sélection). Avant ce garde-fou,
    // un label légèrement différent de la valeur stockée dans NocoDB
    // (typo, accent, parenthèse…) provoquait l'EFFACEMENT silencieux
    // du statut d'occupation côté serveur, qui revenait ensuite vide
    // au prochain pull workspace. Symptôme reporté : "le statut se
    // ré-initialise tout seul quand je quitte/reviens sur le relevé".
    //
    // Cas vraiment "user veut vider" : on l'attrape par `updates.X === ''`
    // — chaîne explicitement vide → `null`. Sinon (pas matché ET non
    // vide), on log et on no-op.
    situation_proprietaire_id1: (() => {
      if (!has('familySituation')) return undefined;
      const v = updates.familySituation;
      if (v === '' || v == null) return null;
      if (situationMatch) return Number(situationMatch.id);
      console.warn(`[patient] familySituation "${v}" ne matche aucune ref. statut → no-op`);
      return undefined;
    })(),
    statut_occupation_id1: (() => {
      if (!has('occupationStatus')) return undefined;
      const v = updates.occupationStatus;
      if (v === '' || v == null) return null;
      if (occupationMatch) return Number(occupationMatch.id);
      console.warn(`[patient] occupationStatus "${v}" ne matche aucune ref. statut_occupation → no-op`);
      return undefined;
    })(),
    nombre_personnes: has('numberPeople') ? updates.numberPeople : undefined,
    // Catégorie de revenu : dérivée serveur du nombre d'occupants via
    // les barèmes ANAH. Si `selectBaremeAnah` ne trouve aucun barème
    // applicable (rare, ex. valeur extrême), on `undefined` plutôt que
    // `null` pour ne pas effacer la catégorie déjà calculée. Le pull
    // workspace ne réinitialisera plus à "Modeste" (fallback hardcodé
    // côté lecture).
    categorie_revenu_id1: (() => {
      if (!has('numberPeople')) return undefined;
      if (baremeMatch) return Number(baremeMatch.id);
      console.warn(`[patient] aucun bareme ANAH applicable pour numberPeople="${updates.numberPeople}" → no-op`);
      return undefined;
    })(),
    revenu_fiscal_reference: has('fiscalRevenue') ? updates.fiscalRevenue : undefined,
    beneficiaire_apa: has('apa') ? updates.apa : undefined,
    reconnaissance_invalidite_mdph: has('invalidity') ? updates.invalidity : undefined,
    reconnaissance_invalidité_mdph_txt: has('invalidityTxt') ? nullableString(updates.invalidityTxt) : undefined,
    aide_a_domicile: has('homeHelp') ? updates.homeHelp : undefined,
    aide_a_domicile_txt: has('homeHelpTxt') ? nullableString(updates.homeHelpTxt) : undefined,
    dependance_particuliere_txt: has('dependenceTxt') ? nullableString(updates.dependenceTxt) : undefined,
    // Dépendance particulière : la table de réf NocoDB `dependances`
    // est limitée (Canne / Déambulateur / Fauteuil…). Le `_txt` au-
    // dessus garantit que la valeur saisie est préservée même si la
    // ref ne matche pas → on suit la même règle protective.
    dependances_particulieres_id: (() => {
      if (!has('dependenceTxt')) return undefined;
      const v = updates.dependenceTxt;
      if (v === '' || v == null) return null;
      if (dependenceMatch) return Number(dependenceMatch.id);
      console.warn(`[patient] dependenceTxt "${v}" ne matche aucune ref. dependances → no-op (fallback _txt préservé)`);
      return undefined;
    })(),
    personne_confiance: trustedPersonNameValue === undefined ? undefined : nullableString(trustedPersonNameValue),
    telephone_personne_confiance: trustedPersonPhoneValue === undefined ? undefined : nullableString(trustedPersonPhoneValue),
    mail_personne_confiance: trustedPersonEmailValue === undefined ? undefined : nullableString(trustedPersonEmailValue),
    numero_securite_sociale_monsieur: has('occupant1SocialSecurityNumber')
      ? nullableString(updates.occupant1SocialSecurityNumber)
      : (has('numeroSecuriteSocialeMonsieur') ? nullableString(updates.numeroSecuriteSocialeMonsieur) : undefined),
    numero_securite_sociale_madame: has('occupant2SocialSecurityNumber')
      ? nullableString(updates.occupant2SocialSecurityNumber)
      : (has('numeroSecuriteSocialeMadame') ? nullableString(updates.numeroSecuriteSocialeMadame) : undefined),
    // Caisses de retraite : ces deux colonnes n'ont PAS de fallback
    // texte côté NocoDB — si la ref ne matche pas et qu'on écrit
    // null, la sélection ergo est définitivement perdue côté serveur
    // (même symptôme que occupationStatus). On applique le même garde-
    // fou : non-vide non-matché → `undefined` (no-op), '' explicite →
    // `null` (vidage volontaire).
    caisses_de_retraite_id: (() => {
      if (!has('caisseRetraitePrincipale')) return undefined;
      const v = updates.caisseRetraitePrincipale;
      if (v === '' || v == null) return null;
      if (caisseMatch) return Number(caisseMatch.id);
      console.warn(`[patient] caisseRetraitePrincipale "${v}" ne matche aucune ref. caisses_retraite → no-op`);
      return undefined;
    })(),
    caisses_de_retraite_complementaires_id: (() => {
      if (!has('caissesRetraiteComplementaires')) return undefined;
      const v = updates.caissesRetraiteComplementaires;
      if (v === '' || v == null) return null;
      if (caisseCompMatch) return Number(caisseCompMatch.id);
      console.warn(`[patient] caissesRetraiteComplementaires "${v}" ne matche aucune ref. caisses_retraite_comp → no-op`);
      return undefined;
    })(),
  });
};

app.post('/api/auth/login', async (req, res, next) => {
  try {
    const email = normalizeEmail(req.body?.email);
    const password = String(req.body?.password || '');
    const { members, store } = await loadMemberRegistryForAuth();
    const member = members.find((entry) => entry.email === email);

    if (!member) {
      res.status(401).json({ success: false, error: 'Adresse mail non autorisée' });
      return;
    }

    const credentials = store.users[email];
    if (!credentials) {
      res.status(401).json({ success: false, error: 'Aucun mot de passe généré pour ce membre' });
      return;
    }

    let isValid = false;
    if (credentials.nocoPasswordHash) {
      // Priorité 1 : hash du mot de passe NocoDB (scrypt, jamais stocké en clair).
      isValid = credentials.nocoPasswordHash === hashPassword(password, credentials.nocoPasswordSalt);
    } else {
      // Priorité 2 : fallback sur le mot de passe auto-généré (comportement historique).
      isValid = credentials.passwordHash === hashPassword(password, credentials.salt);
    }

    if (!isValid) {
      res.status(401).json({ success: false, error: 'Mot de passe incorrect' });
      return;
    }

    const token = await signSessionToken(email);
    res.json({
      success: true,
      error: null,
      data: {
        token,
        user: member,
      },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/auth/session', requireAuth, async (req, res) => {
  res.json({
    success: true,
    error: null,
    data: { user: req.appUser },
  });
});

app.get('/api/auth/local-state', requireAuth, async (req, res, next) => {
  try {
    const { members } = await loadMemberRegistryForAuth();
    const currentUser = req.appUser;
    const visibleMembers = currentUser?.role === 'ADMIN'
      ? members
      : members.filter((member) => member.email === currentUser?.email);

    res.json({
      success: true,
      error: null,
      data: {
        users: visibleMembers.map(buildLocalAuthUserPayload),
        syncedAt: new Date().toISOString(),
      },
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/auth/logout', requireAuth, async (_req, res) => {
  res.json({ success: true, error: null });
});

app.post('/api/profile/photo', requireAuth, async (req, res, next) => {
  try {
    const imageDataUrl = String(req.body?.imageDataUrl || '').trim();
    if (!imageDataUrl) {
      res.status(400).json({ success: false, error: 'Image manquante' });
      return;
    }

    const currentUser = req.appUser;
    if (!currentUser?.email) {
      res.status(400).json({ success: false, error: 'Utilisateur introuvable' });
      return;
    }

    const { extension, buffer } = parseImageDataUrl(imageDataUrl);
    if (buffer.length > 5 * 1024 * 1024) {
      res.status(400).json({ success: false, error: 'Image trop volumineuse' });
      return;
    }

    const safeEmail = currentUser.email.replace(/[^a-z0-9]+/gi, '-').toLowerCase();
    const fileName = `${safeEmail}-${Date.now()}.${extension}`;
    const { url: photoUrl } = await putObject({
      key: `profile-photos/${fileName}`,
      buffer,
      contentType: `image/${extension === 'jpg' ? 'jpeg' : extension}`,
    });

    const store = await readAuthStore();
    const credentials = store.users[currentUser.email];
    if (credentials) {
      store.users[currentUser.email] = {
        ...credentials,
        profilePhotoUrl: photoUrl,
      };
      await writeAuthStore(store);
    }

    if (currentUser.ergoRecordId) {
      try {
        await updateRecord(TABLES.ergotherapeutes, currentUser.ergoRecordId, {
          nom_etablissement_id: photoUrl,
        });
      } catch (error) {
        console.warn('[profile-photo] sync NocoDB impossible, photo conservée localement.', error);
      }
    }

    memberRegistryCache = null;
    const { members } = await loadMemberRegistry({ forceRefresh: true });
    const refreshedUser = members.find((member) => member.email === currentUser.email) || currentUser;

    res.json({
      success: true,
      error: null,
      data: {
        user: refreshedUser,
        photoUrl: resolveClientMediaUrl(photoUrl),
      },
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/auth/provision', requireAdmin, async (req, res, next) => {
  try {
    const requestedEmail = normalizeEmail(req.body?.email);
    const forceReset = Boolean(req.body?.forceReset);
    const { members } = await loadMemberRegistry({ forceRefresh: true });
    const store = await readAuthStore();
    const targets = requestedEmail
      ? members.filter((member) => member.email === requestedEmail)
      : members;

    if (targets.length === 0) {
      throw new Error('Aucun membre correspondant');
    }

    const generated = [];

    for (const member of targets) {
      if (!forceReset && store.users[member.email]) continue;
      const password = generatePassword(member.displayName);
      const salt = randomSecret(16);
      store.users[member.email] = {
        salt,
        passwordHash: hashPassword(password, salt),
        createdAt: new Date().toISOString(),
      };
      store.pendingCredentials[member.email] = {
        displayName: member.displayName,
        password,
        role: member.role,
        createdAt: new Date().toISOString(),
      };
      generated.push({
        email: member.email,
        displayName: member.displayName,
        role: member.role,
        password,
      });
    }

    await writeAuthStore(store);
    memberRegistryCache = null;
    res.json({ success: true, error: null, data: { generated } });
  } catch (error) {
    next(error);
  }
});

app.get('/api/admin/access-members', requireAdmin, async (_req, res, next) => {
  try {
    const members = await getAdminAccessMembers();
    res.json({
      success: true,
      error: null,
      data: { members },
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/admin/access-members', requireAdmin, async (req, res, next) => {
  try {
    const { email, displayName, role, establishmentId, password } = req.body || {};
    if (!email || !displayName) {
      return res.status(400).json({ success: false, error: 'email et displayName requis' });
    }
    const normalizedEmail = normalizeEmail(email);
    const { prenom, nom } = splitDisplayName(displayName);
    const created = await createRecord(TABLES.ergotherapeutes, sanitizeUndefined({
      uuid_source: crypto.randomUUID(),
      prenom,
      nom,
      email: normalizedEmail,
      etablissements_id: establishmentId ? Number(establishmentId) : undefined,
      created_at: new Date().toISOString(),
    }));
    // Provision credentials in auth store
    const store = await readAuthStore();
    if (!store.users[normalizedEmail]) {
      const chosenPassword = (password && password.trim()) ? password.trim() : generatePassword(displayName);
      const salt = randomSecret(16);
      store.users[normalizedEmail] = {
        salt,
        passwordHash: hashPassword(chosenPassword, salt),
        createdAt: new Date().toISOString(),
        profilePhotoUrl: '',
      };
      store.pendingCredentials[normalizedEmail] = {
        displayName,
        password: chosenPassword,
        role: role === 'ADMIN' ? 'ADMIN' : 'ERGO',
        createdAt: new Date().toISOString(),
      };
      await writeAuthStore(store);
    }
    memberRegistryCache = null;
    const members = await getAdminAccessMembers();
    const member = members.find((m) => m.email === normalizedEmail) || {
      email: normalizedEmail,
      displayName,
      role: role === 'ADMIN' ? 'ADMIN' : 'ERGO',
      selectable: true,
      establishmentLabel: '',
      ergoLabel: displayName,
      hasPassword: Boolean(store.users[normalizedEmail]),
      generatedPassword: store.pendingCredentials[normalizedEmail]?.password || '',
      createdAt: store.users[normalizedEmail]?.createdAt || null,
    };
    res.status(201).json({ success: true, error: null, data: { member } });
  } catch (error) {
    next(error);
  }
});

app.patch('/api/admin/access-members/:email', requireAdmin, async (req, res, next) => {
  try {
    const targetEmail = normalizeEmail(decodeURIComponent(req.params.email));
    const { displayName, establishmentId } = req.body || {};
    const records = await queryAll(TABLES.ergotherapeutes, { fields: FIELD_SETS.ergotherapeutes });
    const existing = records.find((r) => normalizeEmail(field(r, 'email') || asArray(field(r, 'User')).at(0)?.email) === targetEmail);
    if (!existing) {
      return res.status(404).json({ success: false, error: 'Membre introuvable' });
    }
    const patch = sanitizeUndefined({
      ...(displayName ? splitDisplayName(displayName) : {}),
      ...(establishmentId !== undefined ? { etablissements_id: establishmentId ? Number(establishmentId) : null } : {}),
    });
    await updateRecord(TABLES.ergotherapeutes, existing.id, patch);
    memberRegistryCache = null;
    const members = await getAdminAccessMembers();
    const member = members.find((m) => m.email === targetEmail);
    if (!member) {
      return res.status(404).json({ success: false, error: 'Membre introuvable après mise à jour' });
    }
    res.json({ success: true, error: null, data: { member } });
  } catch (error) {
    next(error);
  }
});

app.delete('/api/admin/access-members/:email', requireAdmin, async (req, res, next) => {
  try {
    const targetEmail = normalizeEmail(decodeURIComponent(req.params.email));
    const records = await queryAll(TABLES.ergotherapeutes, { fields: FIELD_SETS.ergotherapeutes });
    const existing = records.find((r) => normalizeEmail(field(r, 'email') || asArray(field(r, 'User')).at(0)?.email) === targetEmail);
    if (!existing) {
      return res.status(404).json({ success: false, error: 'Membre introuvable' });
    }
    await callNocoTool('deleteRecords', { tableId: TABLES.ergotherapeutes, recordIds: [String(existing.id)] });
    // Remove from auth store
    const store = await readAuthStore();
    if (store.users[targetEmail] || store.pendingCredentials[targetEmail]) {
      delete store.users[targetEmail];
      delete store.pendingCredentials[targetEmail];
      await writeAuthStore(store);
    }
    memberRegistryCache = null;
    res.json({ success: true, error: null, data: {} });
  } catch (error) {
    next(error);
  }
});

app.get('/api/health', async (_req, res, next) => {
  try {
    const beneficiaires = await queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires });
    res.json({
      success: true,
      message: 'Connexion active à la base métier',
      count: beneficiaires.length,
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/references', requireAuth, async (req, res, next) => {
  try {
    res.json(await getReferences(req.appUser));
  } catch (error) {
    next(error);
  }
});

app.get('/api/retirement-funds', requireAuth, async (_req, res, next) => {
  try {
    const records = await queryAll(TABLES.caissesRetraiteComplementaires, { fields: FIELD_SETS.caissesRetraiteComplementaires });
    const store = await readRetirementFundsStore();
    const remoteFunds = records
      .filter((record) => normalizeEmail(field(record, 'nom')).replace(/\s+/g, ' ') !== 'humanis')
      .map((record) => {
      const name = field(record, 'nom') || '';
      const override = store.funds[String(record.id)] || {};
      return buildRetirementFundResponse({
        id: String(record.id),
        name: override.name || name,
        phone: override.phone || field(record, 'numero_telephone_contact') || '',
        audience: override.audience || '',
        requestMethod: override.requestMethod || '',
        requestDelay: override.requestDelay || '',
        aidAmount: override.aidAmount || '',
        therapistNote: override.therapistNote || field(record, 'aide_complementaire') || '',
        website: override.website || '',
        logoUrl: override.logoUrl || '',
        lastEditedAt: override.lastEditedAt || field(record, 'UpdatedAt') || field(record, 'CreatedAt') || null,
      });
      })
      .sort((a, b) => a.name.localeCompare(b.name));
    const customFunds = store.customFunds
      .map((fund) => buildRetirementFundResponse(fund))
      .sort((a, b) => a.name.localeCompare(b.name));
    const funds = [...remoteFunds, ...customFunds].sort((a, b) => a.name.localeCompare(b.name));

    res.json({ success: true, error: null, data: { funds } });
  } catch (error) {
    next(error);
  }
});

app.get('/api/retirement-funds-principal', requireAuth, async (_req, res, next) => {
  try {
    const records = await queryAll(TABLES.caissesRetraite, { fields: ['nom', 'numero_telephone_contact'] });
    const funds = records
      .map((record) => ({
        id: String(record.id),
        name: String(field(record, 'nom') || '').trim(),
        phone: String(field(record, 'numero_telephone_contact') || '').trim(),
      }))
      .filter((fund) => fund.name)
      .sort((a, b) => a.name.localeCompare(b.name));

    res.json({ success: true, error: null, data: { funds } });
  } catch (error) {
    next(error);
  }
});

app.get('/api/anah-status', requireAuth, async (_req, res, next) => {
  try {
    const status = await readAnahStatus();
    res.json({
      success: true,
      error: null,
      data: {
        status,
      },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/wiki-library', requireAuth, async (_req, res, next) => {
  try {
    const items = await loadWikiLibrary();
    res.json({
      success: true,
      error: null,
      data: {
        items,
      },
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/wiki-library', requireAuth, async (req, res, next) => {
  try {
    const now = new Date().toISOString();
    const store = await readWikiLibraryStore();
    const title = stringValue(req.body?.title).trim();
    const description = stringValue(req.body?.description).trim();
    const category = stringValue(req.body?.category).trim() || 'Autre';
    const tags = asArray(req.body?.tags).map((tag) => String(tag).trim()).filter(Boolean);

    if (!title) {
      res.status(400).json({ success: false, error: 'Titre obligatoire' });
      return;
    }

    let imageUrl = stringValue(req.body?.imageUrl).trim() || '/wiki-access.svg';
    const imageDataUrl = stringValue(req.body?.imageDataUrl).trim();
    if (imageDataUrl) {
      const imagePayload = parseImageDataUrl(imageDataUrl);
      const fileName = `${safeSlug(title, 'wiki-item')}-${Date.now()}.${imagePayload.extension}`;
      const { url: uploadedUrl } = await putObject({
        key: `wiki-library/${fileName}`,
        buffer: imagePayload.buffer,
        contentType: `image/${imagePayload.extension === 'jpg' ? 'jpeg' : imagePayload.extension}`,
      });
      imageUrl = uploadedUrl;
    }

    const item = normalizeWikiItemPayload({
      id: crypto.randomUUID(),
      title,
      description,
      imageUrl,
      tags,
      category,
      createdAt: now,
      updatedAt: now,
    });

    store.items.unshift(item);
    await writeWikiLibraryStore(store);

    try {
      const [wikiRecords, initialTagRecords] = await Promise.all([
        queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki }),
        queryAll(TABLES.wikiTags, { fields: FIELD_SETS.wikiTags }),
      ]);
      const { normalizedMap } = await ensureWikiTagsInNocodb(WIKI_FILTER_TAGS, initialTagRecords);
      const primaryTag = stringValue(item.tags[0]).trim();
      const primaryTagRecord = primaryTag ? normalizedMap.get(primaryTag.toLowerCase()) : undefined;
      const existing = wikiRecords.find((record) => stringValue(field(record, 'uuid_source')).trim() === item.id);
      const payload = {
        uuid_source: item.id,
        titre: item.title,
        photos: item.imageUrl,
        contenu: serializeWikiContent(item),
        wiki_tags_id: primaryTagRecord ? Number(primaryTagRecord.id) : null,
      };
      if (existing) {
        await updateRecord(TABLES.wiki, existing.id, payload);
      } else {
        await createRecord(TABLES.wiki, payload);
      }
    } catch (syncError) {
      console.error('Wiki Noco sync failed on create', syncError);
    }

    res.json({
      success: true,
      error: null,
      data: {
        item: mapWikiLibraryItem(item),
      },
    });
  } catch (error) {
    next(error);
  }
});

app.put('/api/wiki-library/:itemId', requireAuth, async (req, res, next) => {
  try {
    const store = await readWikiLibraryStore();
    const index = store.items.findIndex((item) => String(item.id) === String(req.params.itemId));
    if (index === -1) {
      res.status(404).json({ success: false, error: 'Element introuvable' });
      return;
    }

    const current = store.items[index];
    const title = Object.prototype.hasOwnProperty.call(req.body || {}, 'title') ? stringValue(req.body?.title).trim() : current.title;
    if (!title) {
      res.status(400).json({ success: false, error: 'Titre obligatoire' });
      return;
    }

    let imageUrl = current.imageUrl;
    const imageDataUrl = stringValue(req.body?.imageDataUrl).trim();
    if (imageDataUrl) {
      const imagePayload = parseImageDataUrl(imageDataUrl);
      const fileName = `${safeSlug(title, 'wiki-item')}-${Date.now()}.${imagePayload.extension}`;
      const { url: uploadedUrl } = await putObject({
        key: `wiki-library/${fileName}`,
        buffer: imagePayload.buffer,
        contentType: `image/${imagePayload.extension === 'jpg' ? 'jpeg' : imagePayload.extension}`,
      });
      imageUrl = uploadedUrl;
    }

    const updated = normalizeWikiItemPayload({
      ...current,
      title,
      description: Object.prototype.hasOwnProperty.call(req.body || {}, 'description') ? stringValue(req.body?.description).trim() : current.description,
      category: Object.prototype.hasOwnProperty.call(req.body || {}, 'category') ? stringValue(req.body?.category).trim() || 'Autre' : current.category,
      tags: Object.prototype.hasOwnProperty.call(req.body || {}, 'tags') ? asArray(req.body?.tags).map((tag) => String(tag).trim()).filter(Boolean) : current.tags,
      imageUrl,
      updatedAt: new Date().toISOString(),
    });

    store.items[index] = updated;
    await writeWikiLibraryStore(store);

    try {
      const [wikiRecords, initialTagRecords] = await Promise.all([
        queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki }),
        queryAll(TABLES.wikiTags, { fields: FIELD_SETS.wikiTags }),
      ]);
      const { normalizedMap } = await ensureWikiTagsInNocodb(WIKI_FILTER_TAGS, initialTagRecords);
      const primaryTag = stringValue(updated.tags[0]).trim();
      const primaryTagRecord = primaryTag ? normalizedMap.get(primaryTag.toLowerCase()) : undefined;
      const existing = wikiRecords.find((record) => stringValue(field(record, 'uuid_source')).trim() === updated.id);
      const payload = {
        uuid_source: updated.id,
        titre: updated.title,
        photos: updated.imageUrl,
        contenu: serializeWikiContent(updated),
        wiki_tags_id: primaryTagRecord ? Number(primaryTagRecord.id) : null,
      };
      if (existing) {
        await updateRecord(TABLES.wiki, existing.id, payload);
      } else {
        await createRecord(TABLES.wiki, payload);
      }
    } catch (syncError) {
      console.error('Wiki Noco sync failed on update', syncError);
    }

    res.json({
      success: true,
      error: null,
      data: {
        item: mapWikiLibraryItem(updated),
      },
    });
  } catch (error) {
    next(error);
  }
});

app.delete('/api/wiki-library/:itemId', requireAuth, async (req, res, next) => {
  try {
    const store = await readWikiLibraryStore();
    const nextItems = store.items.filter((item) => String(item.id) !== String(req.params.itemId));
    if (nextItems.length === store.items.length) {
      res.status(404).json({ success: false, error: 'Element introuvable' });
      return;
    }
    store.items = nextItems;
    await writeWikiLibraryStore(store);

    try {
      const wikiRecords = await queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki });
      const existing = wikiRecords.find((record) => stringValue(field(record, 'uuid_source')).trim() === String(req.params.itemId));
      if (existing) {
        await callNocoTool('deleteRecords', {
          tableId: TABLES.wiki,
          records: [{ id: String(existing.id) }],
        });
      }
    } catch (syncError) {
      console.error('Wiki Noco sync failed on delete', syncError);
    }

    res.status(204).end();
  } catch (error) {
    next(error);
  }
});

app.post('/api/retirement-funds', requireAuth, async (req, res, next) => {
  try {
    const name = stringValue(req.body?.name).trim();
    const phone = stringValue(req.body?.phone).trim();
    const audience = stringValue(req.body?.audience).trim();
    const requestMethod = stringValue(req.body?.requestMethod).trim();
    const requestDelay = stringValue(req.body?.requestDelay).trim();
    const aidAmount = stringValue(req.body?.aidAmount).trim();
    const therapistNote = stringValue(req.body?.therapistNote).trim();
    const website = stringValue(req.body?.website).trim();
    const logoUrl = stringValue(req.body?.logoUrl).trim();

    if (!name) {
      res.status(400).json({ success: false, error: 'Nom obligatoire' });
      return;
    }

    const store = await readRetirementFundsStore();
    const lastEditedAt = new Date().toISOString();
    const storePayload = {
      name,
      phone,
      audience,
      requestMethod,
      requestDelay,
      aidAmount,
      therapistNote,
      website,
      logoUrl,
      lastEditedAt,
      lastEditedBy: req.appUser?.displayName || req.appUser?.email || '',
    };

    let createdId = null;
    try {
      const created = await createRecord(TABLES.caissesRetraiteComplementaires, {
        nom: nullableString(name),
        numero_telephone_contact: nullableString(phone),
        aide_complementaire: nullableString(therapistNote),
      });
      createdId = String(created?.id || '').trim() || null;
    } catch (createError) {
      console.error('Retirement fund Noco sync failed on create', createError);
    }

    if (createdId) {
      store.funds[createdId] = {
        ...(store.funds[createdId] || {}),
        ...storePayload,
      };
    } else {
      store.customFunds.unshift(normalizeRetirementFundPayload({
        id: `custom-${crypto.randomUUID()}`,
        ...storePayload,
      }));
    }
    await writeRetirementFundsStore(store);

    const createdFund = createdId
      ? buildRetirementFundResponse({ id: createdId, ...storePayload })
      : buildRetirementFundResponse(store.customFunds[0]);

    res.json({
      success: true,
      error: null,
      data: {
        fund: createdFund,
      },
    });
  } catch (error) {
    next(error);
  }
});

app.put('/api/retirement-funds/:fundId', requireAuth, async (req, res, next) => {
  try {
    const fundId = String(req.params.fundId || '').trim();
    if (!fundId) {
      res.status(400).json({ success: false, error: 'Identifiant de caisse manquant' });
      return;
    }

    const updates = req.body || {};
    const store = await readRetirementFundsStore();

    if (fundId.startsWith('custom-')) {
      const customIndex = store.customFunds.findIndex((fund) => fund.id === fundId);
      if (customIndex === -1) {
        res.status(404).json({ success: false, error: 'Caisse introuvable' });
        return;
      }

      const current = store.customFunds[customIndex];
      const updatedFund = normalizeRetirementFundPayload({
        ...current,
        name: stringValue(updates.name ?? current.name).trim(),
        phone: stringValue(updates.phone ?? current.phone).trim(),
        audience: stringValue(updates.audience ?? current.audience).trim(),
        requestMethod: stringValue(updates.requestMethod ?? current.requestMethod).trim(),
        requestDelay: stringValue(updates.requestDelay ?? current.requestDelay).trim(),
        aidAmount: stringValue(updates.aidAmount ?? current.aidAmount).trim(),
        therapistNote: stringValue(updates.therapistNote ?? current.therapistNote).trim(),
        website: stringValue(updates.website ?? current.website).trim(),
        logoUrl: stringValue(updates.logoUrl ?? current.logoUrl).trim(),
        lastEditedAt: new Date().toISOString(),
        lastEditedBy: req.appUser?.displayName || req.appUser?.email || '',
      });

      store.customFunds[customIndex] = updatedFund;
      await writeRetirementFundsStore(store);

      res.json({
        success: true,
        error: null,
        data: {
          fund: buildRetirementFundResponse(updatedFund),
        },
      });
      return;
    }

    const records = await queryAll(TABLES.caissesRetraiteComplementaires, { fields: FIELD_SETS.caissesRetraiteComplementaires });
    const record = records.find((entry) => String(entry.id) === fundId);
    if (!record) {
      res.status(404).json({ success: false, error: 'Caisse introuvable' });
      return;
    }

    if (normalizeEmail(field(record, 'nom')).replace(/\s+/g, ' ') === 'humanis') {
      res.status(410).json({ success: false, error: 'Cette caisse a été retirée' });
      return;
    }

    const meta = getRetirementFundMeta(field(record, 'nom') || '');
    const nextName = String(updates.name || meta?.displayName || field(record, 'nom') || '').trim();
    const nextPhone = String(updates.phone || '').trim();
    const nextAudience = String(updates.audience || '').trim();
    const nextRequestMethod = String(updates.requestMethod || '').trim();
    const nextRequestDelay = String(updates.requestDelay || '').trim();
    const nextAidAmount = String(updates.aidAmount || '').trim();
    const nextTherapistNote = String(updates.therapistNote || '').trim();
    const nextWebsite = String(updates.website || '').trim();
    const nextLogoUrl = String(updates.logoUrl || '').trim();
    const lastEditedAt = new Date().toISOString();

    await updateRecord(TABLES.caissesRetraiteComplementaires, fundId, {
      nom: nullableString(nextName),
      numero_telephone_contact: nullableString(nextPhone),
      aide_complementaire: nullableString(nextTherapistNote),
    });

    store.funds[fundId] = {
      ...(store.funds[fundId] || {}),
      name: nextName,
      phone: nextPhone,
      audience: nextAudience,
      requestMethod: nextRequestMethod,
      requestDelay: nextRequestDelay,
      aidAmount: nextAidAmount,
      therapistNote: nextTherapistNote,
      website: nextWebsite,
      logoUrl: nextLogoUrl,
      lastEditedAt,
      lastEditedBy: req.appUser?.displayName || req.appUser?.email || '',
    };
    await writeRetirementFundsStore(store);

    res.json({
      success: true,
      error: null,
      data: {
        fund: {
          id: fundId,
          name: nextName,
          phone: nextPhone,
          audience: nextAudience,
          requestMethod: nextRequestMethod,
          requestDelay: nextRequestDelay,
          aidAmount: nextAidAmount,
          therapistNote: nextTherapistNote,
          website: nextWebsite,
          logoUrl: nextLogoUrl || meta?.logoUrl || '',
          lastEditedAt,
        },
      },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/mobile-sync/schema', requireAuth, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: {
        mode: await mobileSyncStore.getMode(),
        schema: mobileSyncStore.schemaSpec,
      },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/mobile-sync/migration-status', requireAuth, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: await mobileSyncStore.getMigrationStatus(),
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/mobile-sync/schema-check', requireAuth, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: await mobileSyncStore.getSchemaCheck(),
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/mobile-sync/migrate', requireAuth, async (_req, res, next) => {
  try {
    res.json({
      success: true,
      error: null,
      data: await mobileSyncStore.migrateLocalToNocodb(),
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/dossiers', requireAuth, async (req, res, next) => {
  try {
    res.json(await getDossiersForApp(req.appUser));
  } catch (error) {
    next(error);
  }
});

/// Génère le rapport de visite PDF pour un dossier donné. Retourne
/// directement les bytes du PDF en `application/pdf` avec un
/// `Content-Disposition: attachment` — le client n'a qu'à streamer
/// la réponse vers un téléchargement / un upload Drive / un attach
/// NocoDB selon ses besoins (voir Chunk 5).
///
/// Filtrage d'accès : `getDossiersForApp(req.appUser)` applique déjà
/// les scopes de l'utilisateur. On cherche le dossier dans cette
/// liste — un appel à un dossierId hors scope renvoie 404 plutôt que
/// 403 pour ne pas leak l'existence de dossiers d'autres ergos.
///
/// L'header `X-Report-Stats` est joint à la réponse en debug — le
/// client peut le lire pour afficher "X champs remplis, Y absents
/// du template" et détecter une dérive de mapping.
/**
 * Lecture (sans middleware HTTP) des sanitaires pour un dossierId.
 * Réutilisable depuis le générateur de rapport. Renvoie `null` si
 * aucune ligne n'existe pour ce dossier — le PDF aura simplement
 * page 6 vide, ce qui est OK.
 */
const fetchSanitairesForDossier = async (dossierId) => {
  const records = await queryAll(TABLES.diagnosticSanitaires, {
    fields: FIELD_SETS.diagnosticSanitaires,
  });
  const record = latestByFieldValue(records, 'dossier_id', dossierId);
  if (!record) return null;
  const sdbFromJson = parseJsonArrayField(field(record, 'sdb_instances_json'));
  const wcFromJson = parseJsonArrayField(field(record, 'wc_instances_json'));
  return {
    id: field(record, 'uuid_source') || String(record.id),
    dossierId: field(record, 'dossier_id'),
    sdbInstances: sdbFromJson.length > 0
      ? sdbFromJson
      : buildLegacyBathroomInstances({
        sdbNiveauPiecesVie: toBool(field(record, 'sdb_niveau_pieces_vie')),
        sdbBaignoire: toBool(field(record, 'sdb_baignoire')),
        sdbBaignoireHauteur: toNumber(field(record, 'sdb_baignoire_hauteur')),
        sdbBacDouche: toBool(field(record, 'sdb_bac_douche')),
        sdbBacDoucheHauteur: toNumber(field(record, 'sdb_bac_douche_hauteur')),
        sdbVasqueSuspendue: toBool(field(record, 'sdb_vasque_suspendue')),
        sdbVasqueSuspendueHauteur: toNumber(field(record, 'sdb_vasque_suspendue_hauteur')),
        sdbVasqueColonne: toBool(field(record, 'sdb_vasque_colonne')),
        sdbVasqueColonneHauteur: toNumber(field(record, 'sdb_vasque_colonne_hauteur')),
        sdbMeubleVasque: toBool(field(record, 'sdb_meuble_vasque')),
        sdbMeubleVasqueHauteur: toNumber(field(record, 'sdb_meuble_vasque_hauteur')),
        sdbBidet: toBool(field(record, 'sdb_bidet')),
        sdbBidetHauteur: toNumber(field(record, 'sdb_bidet_hauteur')),
        sdbParoiDouche: toBool(field(record, 'sdb_paroi_douche')),
        sdbParoiDoucheHauteur: toNumber(field(record, 'sdb_paroi_douche_hauteur')),
        sdbSolGlissant: toBool(field(record, 'sdb_sol_glissant')),
        sdbMachineALaver: toBool(field(record, 'sdb_machine_a_laver')),
        sdbMachineALaverHauteur: toNumber(field(record, 'sdb_machine_a_laver_hauteur')),
        porteSdbLargeurSuffisante: toBool(field(record, 'porte_sdb_largeur_suffisante')),
        porteSdbDimension: toNumber(field(record, 'porte_sdb_dimension')),
        porteSdbSensAdapte: toBool(field(record, 'porte_sdb_sens_adapte')),
      }),
    wcInstances: wcFromJson.length > 0
      ? wcFromJson
      : buildLegacyWcInstances({
        wcNiveau: toBool(field(record, 'wc_niveau')),
        wcCuvetteBonneHauteur: toBool(field(record, 'wc_cuvette_bonne_hauteur')),
        wcCuvetteTropBasse: toBool(field(record, 'wc_cuvette_trop_basse')),
        wcCuvetteHauteur: toNumber(field(record, 'wc_cuvette_hauteur')),
        wcBarreRelevement: toBool(field(record, 'wc_barre_relevement')),
        porteWcLargeurSuffisante: toBool(field(record, 'porte_wc_largeur_suffisante')),
        porteWcDimension: toNumber(field(record, 'porte_wc_dimension')),
        porteWcSensAdapte: toBool(field(record, 'porte_wc_sens_adapte')),
        observationEquipementsUtilisation: stringValue(field(record, 'observation_equipements_utilisation')),
      }),
  };
};

/**
 * Vérifie si une caisse complémentaire donnée ouvre droit à une aide
 * (drapeau `a_une_aide_specifique` coché dans la table de référence).
 * Renvoie le libellé canonique de la caisse en cas de match, sinon
 * `null`. Sépare la lecture du drapeau de la mise en forme finale du
 * label, pour pouvoir agréger plusieurs occupants côté
 * `resolveCaisseComplementaireLabel`.
 *
 * @param {string} caisseName  Nom saisi côté patient (peut différer un
 *   poil du libellé canonique — `findByLabel` tolère accents/casse).
 * @param {Array}  records     Records pré-chargés de la table de
 *   référence pour éviter un round-trip par occupant.
 * @returns {string|null}      Nom canonique si aide active, sinon null.
 */
const resolveCaisseAideName = (caisseName, records) => {
  const trimmed = String(caisseName || '').trim();
  if (!trimmed) return null;
  const match = findByLabel(records, trimmed);
  if (!match) {
    // Caisse libellée côté patient mais absente de la table de
    // référence (donnée historique ou typo) → on préfère ignorer
    // plutôt que d'écrire un nom qui ne correspond à rien.
    return null;
  }
  // NocoDB renvoie les Checkbox comme booléens natifs (true/false)
  // mais on tolère aussi les variantes string ('1', 'true', 'yes')
  // qu'on rencontre via certaines surfaces (REST sans cast).
  const flag = field(match, 'a_une_aide_specifique');
  const hasAide = flag === true
    || flag === 1
    || /^(1|true|yes|oui|on)$/i.test(String(flag || '').trim());
  if (!hasAide) return null;
  // On retourne le libellé tel que saisi (`trimmed`) pour rester fidèle
  // à la donnée patient ; les libellés canoniques de la table NocoDB
  // sont normalement identiques au caractère près.
  return trimmed;
};

/**
 * Joint une liste de noms de caisses à la française :
 *   - 1 nom        → "Nom"
 *   - 2 noms       → "Nom1 et Nom2"
 *   - 3 noms et +  → "Nom1, Nom2 et Nom3" (virgules + dernier `et`,
 *                    pas de virgule d'Oxford).
 */
const joinCaisseNames = (names) => {
  if (names.length === 0) return '';
  if (names.length === 1) return names[0];
  if (names.length === 2) return `${names[0]} et ${names[1]}`;
  const last = names[names.length - 1];
  const head = names.slice(0, -1).join(', ');
  return `${head} et ${last}`;
};

/**
 * Résout le libellé à afficher dans le champ PDF
 * « Caisse de retraite complémentaire » selon la règle métier (demande
 * utilisateur 2026-04-29 / 2026-04-30).
 *
 * Accepte soit un nom unique (string) — compat avec les anciens
 * appelants — soit un tableau de noms quand le dossier a plusieurs
 * occupants. Règles :
 *
 *   - Toutes les caisses résolvent à `null` (aucune aide / vide /
 *     hors-table) → `'/'`.
 *   - Au moins une caisse ouvre droit à une aide :
 *       • 1 nom unique          → `'<Nom> sous conditions*'`
 *       • 2 noms uniques        → `'<Nom1> et <Nom2> sous conditions*'`
 *       • 3+ noms uniques       → `'<Nom1>, <Nom2> et <Nom3> sous conditions*'`
 *     (les caisses qui ne donnent pas droit à une aide sont
 *     silencieusement filtrées — cas mixte : choix utilisateur 2026-04-30,
 *     option A : on ignore les occupants qui n'ouvrent pas de droit).
 *
 * Pourquoi un drapeau dédié et pas un parsing du champ libre
 * `aide_complementaire` : ce dernier sert de NOTE INFORMATIVE pour
 * l'écran « Caisses de retraite » de l'app. On garde donc les deux
 * champs séparés : `aide_complementaire` = note libre,
 * `a_une_aide_specifique` = drapeau pour le PDF.
 */
const resolveCaisseComplementaireLabel = async (caisseInput) => {
  // Normalise l'entrée en tableau de noms.
  const list = Array.isArray(caisseInput) ? caisseInput : [caisseInput];
  const trimmedList = list
    .map((name) => String(name || '').trim())
    .filter((name) => name.length > 0);
  if (trimmedList.length === 0) return '/';

  let records;
  try {
    records = await queryAll(TABLES.caissesRetraiteComplementaires, {
      fields: FIELD_SETS.caissesRetraiteComplementaires,
    });
  } catch (error) {
    console.warn(
      '[report] échec chargement table caisses_retraite_complementaires :',
      error?.message || error,
    );
    return '/';
  }

  // Dédup tout en préservant l'ordre d'apparition (occupant 0 d'abord).
  const seen = new Set();
  const aides = [];
  for (const name of trimmedList) {
    const canonical = resolveCaisseAideName(name, records);
    if (!canonical) continue;
    const key = canonical.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    aides.push(canonical);
  }

  if (aides.length === 0) return '/';
  return `${joinCaisseNames(aides)} sous conditions*`;
};

/**
 * Mapping `categorie` (colonne NocoDB de mobile_visit_photos) → tag
 * canonique attendu par le générateur PDF (`generateVisitReport.mjs`
 * branche les photos par tag pour les slots de la page 8 et 9-10).
 *
 * Inverse de `TAG_TO_CAT` du script de migration. Doit rester aligné
 * avec `kVisitPhotoTags` côté Flutter (`models/visit_report_categories.dart`).
 */
const VISIT_PHOTO_CAT_TO_TAG = {
  logement: 'Visite - Logement',
  accessibilite: 'Visite - Accessibilité',
  sanitaires: 'Visite - Sanitaires',
  plan_avant: 'Visite - Plan avant',
  plan_apres: 'Visite - Plan après',
  autres: 'Visite - Autres',
};

/**
 * Liste les photos visite d'un patient. Source primaire :
 * `mobile_visit_photos` (table dédiée depuis 2026-04-30). Fallback
 * legacy : `mobile_documents` filtré par tags `Visite - *` pour les
 * dossiers ayant encore des photos avant migration complète côté
 * Flutter (transition).
 *
 * Format de retour uniforme — chaque entry a `id`, `tags`, `mimeType`,
 * + un champ `_source` ('visit_photo' | 'document') consommé par
 * `fetchImageBytesForReport` pour router vers la bonne table.
 */
const fetchVisitPhotosForPatient = async (patientId) => {
  const photos = [];

  // 1) Nouvelle source : mobile_visit_photos
  try {
    const records = await queryAll(TABLES.visitPhotos, {
      fields: [
        'uuid_source',
        'beneficiaire_id',
        'client_document_id',
        'titre',
        'nom_fichier',
        'mime_type',
        'categorie',
        'category_order',
        'created_at1',
        'updated_at1',
      ],
    });
    const matching = records.filter(
      (r) => String(field(r, 'beneficiaire_id') || '') === String(patientId),
    );
    for (const r of matching) {
      const cat = String(field(r, 'categorie') || '').trim().toLowerCase();
      const tag = VISIT_PHOTO_CAT_TO_TAG[cat] || 'Visite - Autres';
      photos.push({
        id: field(r, 'uuid_source') || String(r.id),
        clientDocumentId: field(r, 'client_document_id') || '',
        title: field(r, 'titre') || '',
        fileName: field(r, 'nom_fichier') || '',
        mimeType: field(r, 'mime_type') || 'image/jpeg',
        tags: [tag],
        categoryOrder: Number(field(r, 'category_order') || 0),
        updatedAt:
            field(r, 'updated_at1') || field(r, 'UpdatedAt') || null,
        // Marqueur consommé par fetchImageBytesForReport pour router
        // vers la table mobile_visit_photos (au lieu de mobile_documents).
        _source: 'visit_photo',
      });
    }
  } catch (error) {
    console.warn(
      '[report] échec query mobile_visit_photos :',
      error?.message || error,
    );
  }

  // 2) Fallback legacy : mobile_documents filtré par tag visite (pour
  //    les rows pas encore migrées — le client Flutter peut encore
  //    poster ici tant que le refactor Flutter n'est pas fini).
  try {
    const docs = await mobileSyncStore.listDocumentsByPatient(patientId, {});
    const normalizeTag = (s) => String(s || '')
      .toLowerCase()
      .normalize('NFD')
      .replace(/[̀-ͯ]/g, '')
      .replace(/\s+/g, ' ')
      .trim();
    const visitTagsNormalized = new Set([
      'visite - logement',
      'visite - accessibilite',
      'visite - sanitaires',
      'visite - plan avant',
      'visite - plan apres',
      'visite - autres',
    ]);
    for (const doc of asArray(docs)) {
      const mime = String(doc?.mimeType || '');
      if (!mime.startsWith('image/')) continue;
      const hasVisitTag = asArray(doc?.tags).some((tag) =>
        visitTagsNormalized.has(normalizeTag(tag)),
      );
      if (!hasVisitTag) continue;
      // Évite le doublon si un row legacy a la même `client_document_id`
      // qu'un row déjà migré dans mobile_visit_photos (les ids cross-table
      // doivent rester uniques après migration, mais on est défensif).
      const cid = String(doc?.clientDocumentId || '');
      if (cid && photos.some((p) => p.clientDocumentId === cid)) continue;
      photos.push({
        ...doc,
        _source: 'document',
      });
    }
  } catch (error) {
    console.warn(
      '[report] échec listDocumentsByPatient (fallback) :',
      error?.message || error,
    );
  }

  return photos;
};

/**
 * Liste les notes-pages de l'onglet Plans pour un patient/dossier.
 * Filtre côté API par `tabKey='Plans'`. Renvoie celles avec un
 * `planPhase` défini ('avant' ou 'apres'). Trie par pageNumber.
 */
const fetchPlanNotePagesForPatient = async (patientId, dossierId) => {
  try {
    const pages = await mobileSyncStore.listNotePagesByPatient(patientId, {
      tabKey: 'Plans',
    });
    return asArray(pages)
      .filter((pg) => pg && (pg.planPhase === 'avant' || pg.planPhase === 'apres'))
      // Optionnel : restreindre au scope du dossier passé. Utile si
      // l'ergo a plusieurs dossiers pour le même patient (rare).
      .filter((pg) => !dossierId || !pg?.scopeId || String(pg.scopeId) === String(dossierId))
      .sort((a, b) => Number(a.pageNumber) - Number(b.pageNumber));
  } catch (error) {
    console.warn('[report] échec listNotePagesByPatient :', error?.message || error);
    return [];
  }
};

/**
 * Liste les notes de la section « Contexte de vie » (sous-onglets
 * Médical + Autonomie) pour ce patient/dossier. Le générateur de
 * rapport utilise leur `textContent` pour remplir « Environnement »
 * (Médical) et « Habitudes de vie » (Autonomie) du PDF — on
 * privilégie la note manuscrite/saisie de l'ergo plutôt que les
 * données structurées du formulaire (demande utilisateur, plus
 * proche du libellé attendu dans le rapport).
 *
 * Le tabKey côté Flutter est `"Contexte de vie-Médical"` ou
 * `"Contexte de vie-Autonomie"` (cf. `notesWidget` qui concatène
 * `$tab-$section`). On retourne donc toutes les notes commençant par
 * `Contexte de vie` ; le caller filtre ensuite par sous-section.
 */
const fetchContexteNotePagesForPatient = async (patientId, dossierId) => {
  try {
    const allTabs = await Promise.all([
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Contexte de vie-Médical',
      }),
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Contexte de vie-Autonomie',
      }),
    ]);
    return allTabs
      .flat()
      .filter((pg) => !!pg)
      // Filtre scope tolérant : dossierId match OU patientId match OU
      // scopeId vide (cf. fetchVadOverlayNotesForReport pour le rationale).
      // Sans ce relâchement, les notes Contexte de vie étaient
      // rejetées car `saveDrawingJson` ne push pas de dossierId, donc
      // le sync_service fallback `scopeId = patientId` ≠ dossierId.
      .filter((pg) => {
        if (!dossierId) return true;
        const scopeId = pg?.scopeId;
        if (!scopeId) return true;
        const s = String(scopeId);
        if (s === String(dossierId)) return true;
        if (patientId && s === String(patientId)) return true;
        return false;
      })
      .sort((a, b) => Number(a.pageNumber) - Number(b.pageNumber));
  } catch (error) {
    console.warn('[report] échec contexte notes :', error?.message || error);
    return [];
  }
};

/**
 * Récupère les NotesWidget VAD qui ont remplacé l'ancien onglet
 * « Observations » (cf. demande utilisateur 2026-04-28). tabKeys
 * sources :
 *   - `Préconisations-Projet`     → page 7 PDF, champ « Projet ou souhait
 *                                   de l'usager »
 *   - `Préconisations-Résumé`     → page 7 PDF, champ « Résumé des
 *                                   préconisations »
 *   - `Accessibilité-Notes`       → page 5 PDF, champ `Observations1`
 *                                   (« Observations sur l'accessibilité »).
 *                                   Note unique partagée entre TOUTES les
 *                                   sous-sections de l'onglet Accessibilité
 *                                   (Général / Niveaux / Équipements /
 *                                   Extérieur), comme la note Sanitaires
 *                                   est partagée entre SDB et WC.
 *                                   Demande utilisateur 2026-04-29 :
 *                                   « la note ecrite (comme sanitaire avec
 *                                    wc et salle de bain) doit être associé
 *                                    entre chaque page de accessibilité ».
 *                                   Fallback legacy sur les anciens tabKeys
 *                                   par sous-section pour les dossiers déjà
 *                                   saisis avant cette unification.
 *
 * Concatène les `textContent` de toutes les pages d'un même tabKey
 * (séparateur double-newline) si l'ergo a fait défiler plusieurs
 * pages dans le NotesWidget. Renvoie un objet plat avec :
 *   - `projet` : page 7 PDF
 *   - `resume` : page 7 PDF
 *   - `accessibilite` : page 5 PDF (Observations1)
 * Si aucune note n'existe pour un tabKey, le champ correspondant
 * est `null`.
 */
const fetchVadOverlayNotesForReport = async (patientId, dossierId) => {
  if (!patientId) {
    return {
      projet: null,
      resume: null,
      accessibilite: null,
      sanitaires: null,
    };
  }
  try {
    const [
      projetPages,
      resumePages,
      accSharedPages,
      accGeneralPages,
      accExterieurPages,
      legacyEquipPages,
      sanitairesUnifiedPages,
      sdbPages,
      wcPages,
    ] = await Promise.all([
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Préconisations-Projet',
      }),
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Préconisations-Résumé',
      }),
      // NOUVEAU (2026-04-29) : tabKey unique partagé entre toutes les
      // sous-sections Accessibilité. Cf. visit_report_screen
      // _kSharedAccessibiliteNotesTabKey.
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Accessibilité-Notes',
      }),
      // Legacy : anciennes notes par sous-section, conservées pour
      // les dossiers saisis avant l'unification.
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Accessibilité-Général',
      }),
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Accessibilité-Extérieur',
      }),
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Accessibilité-Équipements',
      }),
      // NOUVEAU (2026-04-29 v2) : note unifiée SDB+WC sous le tabKey
      // partagé `Sanitaires-Notes`. Avant : 2 tabKeys séparés (`Salle
      // de bain-Équipements` + `WC-Config. & équipements`) — purgés
      // depuis (cf. `purgeLegacySanitairesNotes`). Désormais SDB et
      // WC partagent la même note dans l'app, qui alimente le champ
      // `obs` page 6 PDF (« Observations sur les équipements et
      // utilisation »).
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Sanitaires-Notes',
      }),
      // Fallback legacy : pour les rares dossiers où l'admin n'aurait
      // pas encore re-saisi la note sous le nouveau tabKey unifié,
      // on lit aussi les anciens — au cas où une ligne aurait été
      // restaurée depuis un backup. Inoffensif si vide.
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'Salle de bain-Équipements',
      }),
      mobileSyncStore.listNotePagesByPatient(patientId, {
        tabKey: 'WC-Config. & équipements',
      }),
    ]);
    // Le texte saisi par l'ergo dans NotesWidget est bundle DANS
    // `drawing_json` (champ JSON `{"text": "…", "strokes": [...]}`),
    // pas dans la colonne SQL `text_content` qui reste vide en
    // pratique (cf. components/notes_widget.dart `_currentDrawingJson`).
    // On parse donc le JSON pour extraire le texte.
    const extractTextFromDrawingJson = (raw) => {
      const s = stringValue(raw);
      if (!s) return '';
      try {
        const decoded = JSON.parse(s);
        if (decoded && typeof decoded === 'object' && typeof decoded.text === 'string') {
          return decoded.text;
        }
      } catch {
        // drawing_json non-JSON (data legacy ou tronqué) → on ignore.
      }
      return '';
    };
    const joinPages = (pages) => {
      const filtered = asArray(pages)
        .filter((pg) => !!pg)
        // Filtre scope : on accepte les notes dont le scopeId est :
        //  • absent (note legacy ou patient-level)
        //  • égal au dossierId (note vraiment scoped au dossier)
        //  • égal au patientId (cas réel : Flutter `saveDrawingJson` ne
        //    push PAS de dossierId dans le payload, donc le sync_service
        //    fallback `scopeId = patientId`. Sans ce 3ème cas, TOUTES
        //    les notes Préconisations / Contexte / SDB / WC se voyaient
        //    rejetées et le PDF restait vide — bug reporté 2026-04-29).
        .filter((pg) => {
          if (!dossierId) return true;
          const scopeId = pg?.scopeId;
          if (!scopeId) return true;
          const s = String(scopeId);
          if (s === String(dossierId)) return true;
          if (patientId && s === String(patientId)) return true;
          return false;
        })
        .sort((a, b) => Number(a.pageNumber) - Number(b.pageNumber));
      const text = filtered
        .map((pg) => {
          // Priorité au texte JSON dans drawing_json (NotesWidget).
          // Fallback sur textContent au cas où certaines pages legacy
          // utiliseraient cette colonne directement.
          const fromJson = extractTextFromDrawingJson(pg?.drawingJson).trim();
          if (fromJson) return fromJson;
          return stringValue(pg?.textContent).trim();
        })
        .filter(Boolean)
        .join('\n\n');
      return text || null;
    };
    // `accessibilite` du PDF (page 5 / champ `Observations1` =
    // « Observations sur l'accessibilité ») : priorité au tabKey
    // unifié `Accessibilité-Notes` (note partagée entre toutes les
    // sous-sections). Fallback : on assemble les anciens tabKeys par
    // sous-section pour les dossiers historiques (Général + Extérieur
    // + Équipements). Une fois le déploiement passé, la note unifiée
    // gagne automatiquement.
    const accSharedText = joinPages(accSharedPages);
    const accGeneralText = joinPages(accGeneralPages);
    const accExterieurText = joinPages(accExterieurPages);
    const legacyEquipText = joinPages(legacyEquipPages);
    const accessibilite = (() => {
      if (accSharedText && accSharedText.trim()) return accSharedText;
      const mergedLegacy = [accGeneralText, accExterieurText, legacyEquipText]
        .filter((s) => typeof s === 'string' && s.trim())
        .join('\n\n');
      return mergedLegacy.trim() ? mergedLegacy : null;
    })();
    // `sanitaires` du PDF (page 6 / champ `obs` = « Observations sur
    // les équipements et utilisation ») : priorité au tabKey unifié
    // `Sanitaires-Notes` (note partagée SDB+WC depuis 2026-04-29).
    // Fallback : concat des anciens tabKeys séparés au cas où un
    // dossier historique aurait encore des lignes legacy après le
    // déploiement de la migration.
    const sanitairesUnifiedText = joinPages(sanitairesUnifiedPages);
    const sdbText = joinPages(sdbPages);
    const wcText = joinPages(wcPages);
    const sanitaires = (() => {
      if (sanitairesUnifiedText && sanitairesUnifiedText.trim()) {
        return sanitairesUnifiedText;
      }
      const merged = [sdbText, wcText]
        .filter((s) => typeof s === 'string' && s.trim())
        .join('\n\n');
      return merged.trim() ? merged : null;
    })();
    // Diagnostic verbose (à retirer une fois le bug "obs vide" tracé)
    // — montre combien de pages NocoDB ont été remontées par tabKey,
    // et si le scopeId filter rejette quelque chose. Affiché dans les
    // Vercel Functions Logs côté backend.
    // eslint-disable-next-line no-console
    console.log('[fetchVadOverlayNotes] patient=%s dossier=%s | ' +
      'projet=%d resume=%d accNotes=%d accGen=%d accExt=%d accLegEq=%d ' +
      'sanUnified=%d sdbLegacy=%d wcLegacy=%d | ' +
      'extracted lengths : projet=%d resume=%d accessibilite=%d sanitaires=%d',
      patientId, dossierId,
      asArray(projetPages).length,
      asArray(resumePages).length,
      asArray(accSharedPages).length,
      asArray(accGeneralPages).length,
      asArray(accExterieurPages).length,
      asArray(legacyEquipPages).length,
      asArray(sanitairesUnifiedPages).length,
      asArray(sdbPages).length,
      asArray(wcPages).length,
      (joinPages(projetPages) || '').length,
      (joinPages(resumePages) || '').length,
      (accessibilite || '').length,
      (sanitaires || '').length,
    );
    return {
      projet: joinPages(projetPages),
      resume: joinPages(resumePages),
      accessibilite,
      sanitaires,
    };
  } catch (error) {
    console.warn('[report] échec fetchVadOverlayNotes :', error?.message || error);
    return {
      projet: null,
      resume: null,
      accessibilite: null,
      sanitaires: null,
    };
  }
};

/**
 * Liste les recommandations d'un dossier — réutilise la logique
 * de l'endpoint /api/visit-recommendations/:dossierId.
 */
const fetchVisitRecommendationsForDossier = async (dossierId) => {
  try {
    const tableId = await getVisitRecommendationsTableId();
    let items = [];
    if (tableId) {
      const records = await queryAll(tableId, {
        fields: VISIT_RECOMMENDATION_FIELDS,
        where: `(dossier_id,eq,${JSON.stringify(String(dossierId))})`,
      });
      items = records
        .map(mapVisitRecommendationRecord)
        .sort((left, right) => new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime());
    } else {
      const store = await readVisitRecommendationsStore();
      const payload = store.dossiers?.[dossierId];
      items = asArray(payload?.items);
    }
    return items;
  } catch (error) {
    console.warn('[report] échec fetch recos :', error?.message || error);
    return [];
  }
};

/**
 * Récupère les bytes d'une image (document, URL HTTP, data URL) sous
 * forme de Buffer + mimeType. Renvoie `null` si l'image n'est pas
 * accessible / le format ne convient pas. Appelé par le générateur
 * via le callback `fetchImageBytes`.
 */
const fetchImageBytesForReport = async (descriptor) => {
  try {
    if (!descriptor) return null;
    // `note_page` est un kind virtuel introduit pour le routing inline
    // (cf. buildInlineFirstFetcher). Si on arrive ici sans wrapper, ça
    // veut dire qu'il n'y a pas d'inline pour ce plan → on retourne
    // null et le générateur enchaîne sur previewDataUrl/previewUrl.
    if (descriptor.kind === 'note_page') return null;
    // Idem pour `inline_resolved` : descriptor factice utilisé quand
    // les bytes sont déjà résolus en amont (cf. générateur, étape 0
    // des plans). Le fetcher passé est inline, ce wrapper n'est pas
    // appelé — mais par sûreté on no-op.
    if (descriptor.kind === 'inline_resolved') return null;
    if (descriptor.kind === 'document' && descriptor.id) {
      // 1) Cas legacy : doc dans mobile_documents — go through the
      //    standard mobileSyncStore.getDocumentContent path.
      const content = await mobileSyncStore.getDocumentContent(descriptor.id);
      if (content?.buffer && content.buffer.length > 0) {
        return {
          buffer: content.buffer,
          mimeType: content.mimeType || 'image/jpeg',
        };
      }
      // 2) Cas nouveau : photo visite dans mobile_visit_photos (id =
      //    `uuid_source`). On lit directement le row + sa colonne
      //    `contenu_base64`. Ce path se déclenche pour les photos que
      //    `fetchVisitPhotosForPatient` a marquées `_source: 'visit_photo'`.
      try {
        const records = await queryAll(TABLES.visitPhotos, {
          fields: ['uuid_source', 'mime_type', 'contenu_base64'],
        });
        const match = records.find(
          (r) => String(field(r, 'uuid_source') || '') === String(descriptor.id),
        );
        if (match) {
          const base64 = String(field(match, 'contenu_base64') || '').trim();
          if (base64) {
            return {
              buffer: Buffer.from(base64, 'base64'),
              mimeType: field(match, 'mime_type') || 'image/jpeg',
            };
          }
        }
      } catch (error) {
        console.warn(
          '[report] échec query mobile_visit_photos :',
          error?.message || error,
        );
      }
      return null;
    }
    if (descriptor.kind === 'dataurl' && descriptor.dataUrl) {
      const m = String(descriptor.dataUrl).match(/^data:([^;]+);base64,(.+)$/);
      if (!m) return null;
      return {
        buffer: Buffer.from(m[2], 'base64'),
        mimeType: m[1] || 'image/png',
      };
    }
    if (descriptor.kind === 'url' && descriptor.url) {
      const res = await fetch(descriptor.url);
      if (!res.ok) return null;
      const arrayBuffer = await res.arrayBuffer();
      return {
        buffer: Buffer.from(arrayBuffer),
        mimeType: res.headers.get('content-type') || 'image/jpeg',
      };
    }
    return null;
  } catch (error) {
    console.warn('[report] échec fetchImageBytesForReport :', descriptor?.kind, error?.message || error);
    return null;
  }
};

/**
 * Lecture (sans middleware HTTP) des observations de synthèse pour
 * un dossier. Renvoie `null` si pas de ligne — page 7 du rapport
 * reste vide.
 */
const fetchObservationsForDossier = async (dossierId) => {
  const records = await queryAll(TABLES.observations, {
    fields: FIELD_SETS.observations,
  });
  const record = latestByFieldValue(records, 'dossier_id', dossierId);
  if (!record) return null;
  return {
    id: field(record, 'uuid_source') || String(record.id),
    dossierId: field(record, 'dossier_id'),
    observationEquipements: stringValue(field(record, 'observation_equipements')),
    projetSouhaitUsage: stringValue(field(record, 'projet_souhait_usage')),
    resumePreconisations: stringValue(field(record, 'resume_preconisations')),
  };
};

/**
 * Parse les assets inline (multipart) envoyés par le client Flutter
 * avec la requête de génération PDF. Permet au client d'embarquer les
 * bytes des images locales (photos VAD non-encore-syncées, plans PNG
 * rasterisés) directement dans la requête, garantissant que le PDF
 * reflète l'état SQLite local même quand la sync NocoDB est en retard
 * ou intermittente. Cf. discussion edge case « réseau intermittent ».
 *
 * Convention de fieldname multipart :
 *   - `inline_doc_<localId>` : binary blob d'une photo
 *   - `inline_doc_<localId>_meta` : champ texte JSON `{fileName, mimeType, tags, dossierId, title}`
 *   - `inline_plan_<localId>` : binary blob PNG d'un plan rasterisé
 *   - `inline_plan_<localId>_meta` : JSON `{planPhase, pageNumber, scopeId}`
 *
 * Retourne :
 *   { documents: Map<localId, doc>, plans: Map<localId, plan> }
 */
const parseInlineReportAssets = (req) => {
  const documents = new Map();
  const plans = new Map();
  const files = Array.isArray(req?.files) ? req.files : [];
  const body = req?.body || {};

  for (const file of files) {
    const fname = String(file?.fieldname || '');
    let match = fname.match(/^inline_doc_(.+)$/);
    if (match) {
      const localId = match[1];
      let meta = {};
      const rawMeta = body[`inline_doc_${localId}_meta`];
      if (typeof rawMeta === 'string' && rawMeta.length > 0) {
        try { meta = JSON.parse(rawMeta); } catch { /* meta invalide, on continue */ }
      }
      const tags = Array.isArray(meta.tags) ? meta.tags.map(String) : [];
      documents.set(localId, {
        id: localId,
        fileName: String(meta.fileName || file.originalname || `${localId}.bin`),
        mimeType: String(meta.mimeType || file.mimetype || 'application/octet-stream'),
        tags,
        title: typeof meta.title === 'string' ? meta.title : '',
        dossierId: typeof meta.dossierId === 'string' ? meta.dossierId : null,
        buffer: file.buffer,
      });
      continue;
    }
    match = fname.match(/^inline_plan_(.+)$/);
    if (match) {
      const localId = match[1];
      let meta = {};
      const rawMeta = body[`inline_plan_${localId}_meta`];
      if (typeof rawMeta === 'string' && rawMeta.length > 0) {
        try { meta = JSON.parse(rawMeta); } catch { /* meta invalide */ }
      }
      plans.set(localId, {
        id: localId,
        planPhase: typeof meta.planPhase === 'string' ? meta.planPhase : null,
        pageNumber: Number.isFinite(Number(meta.pageNumber)) ? Number(meta.pageNumber) : 0,
        scopeId: typeof meta.scopeId === 'string' ? meta.scopeId : null,
        mimeType: String(meta.mimeType || file.mimetype || 'image/png'),
        buffer: file.buffer,
      });
    }
  }

  return { documents, plans };
};

/**
 * Construit un wrapper de `fetchImageBytesForReport` qui privilégie le
 * cache inline. Si le descriptor cible un document/plan que le client
 * a embarqué dans la requête multipart, on lit les bytes directement
 * depuis le buffer en mémoire (zéro round-trip NocoDB). Sinon fallback
 * sur le fetcher d'origine (lecture NocoDB ou data URL ou URL HTTP).
 *
 * Effet : la génération PDF n'est plus sensible au délai de sync. Si
 * l'ergo ferme un VAD au moment où une partie des photos viennent
 * d'être uploadées et l'autre pas encore, le PDF a quand même toutes
 * les images parce qu'elles sont dans la requête.
 */
const buildInlineFirstFetcher = (inlineAssets) => async (descriptor) => {
  // Documents (photos page 8) embarqués inline.
  if (descriptor && descriptor.kind === 'document' && descriptor.id) {
    const inline = inlineAssets.documents.get(String(descriptor.id));
    if (inline?.buffer && inline.buffer.length > 0) {
      return { buffer: inline.buffer, mimeType: inline.mimeType || 'image/jpeg' };
    }
  }
  // Plans (pages 9-10) embarqués inline. Le générateur appelle avec
  // `{kind: 'note_page', id}` AVANT d'essayer previewDataUrl, donc on
  // intercepte ici. Si pas en cache → null → le générateur enchaîne
  // sur le fallback NocoDB (previewDataUrl persisté côté serveur).
  if (descriptor && descriptor.kind === 'note_page' && descriptor.id) {
    const inline = inlineAssets.plans.get(String(descriptor.id));
    if (inline?.buffer && inline.buffer.length > 0) {
      return { buffer: inline.buffer, mimeType: inline.mimeType || 'image/png' };
    }
    return null; // pas d'inline pour ce plan → fallback dans le générateur
  }
  return fetchImageBytesForReport(descriptor);
};

/**
 * Fusionne la liste de photos remontée par NocoDB avec les documents
 * inline embarqués par le client. Les inline gagnent sur les remote en
 * cas de doublon d'id (plus à jour côté local). Les inline absents de
 * NocoDB sont ajoutés à la liste — c'est le cas de l'edge case réseau
 * intermittent : photo non-encore-uploadée mais présente côté SQLite.
 *
 * On filtre quand même par tags VAD pour cohérence avec la sémantique
 * de fetchVisitPhotosForPatient (page 8 = uniquement les photos taggées
 * Visite-*).
 */
const mergeInlineDocuments = (remoteDocs, inlineMap) => {
  const visitTagsNormalized = new Set([
    'visite - logement',
    'visite - accessibilite',
    'visite - sanitaires',
  ]);
  const normalizeTag = (s) => String(s || '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  const hasVisitTag = (tags) =>
    Array.isArray(tags) && tags.some((tag) => visitTagsNormalized.has(normalizeTag(tag)));

  const merged = [];
  const seenIds = new Set();
  // 1) inline d'abord (priorité), filtrés par tag visite
  for (const inline of inlineMap.values()) {
    if (!hasVisitTag(inline.tags)) continue;
    merged.push({
      id: inline.id,
      title: inline.title || '',
      fileName: inline.fileName,
      mimeType: inline.mimeType,
      tags: inline.tags,
      dossierId: inline.dossierId,
    });
    seenIds.add(String(inline.id));
  }
  // 2) puis les remotes pas en doublon
  for (const doc of Array.isArray(remoteDocs) ? remoteDocs : []) {
    if (!doc) continue;
    if (seenIds.has(String(doc.id))) continue;
    merged.push(doc);
  }
  return merged;
};

/**
 * Fusionne les plans NocoDB avec les plans inline. Critère d'identité :
 * `localId` (id côté client). Si NocoDB a un plan avec un autre id mais
 * la même phase/page, on garde les deux côte à côte ; le générateur
 * PDF déduplique par slot s'il y a saturation (4 slots seulement).
 */
const mergeInlineNotePages = (remotePages, inlineMap) => {
  const merged = [];
  const seenIds = new Set();
  for (const inline of inlineMap.values()) {
    if (!inline.planPhase) continue;
    merged.push({
      id: inline.id,
      planPhase: inline.planPhase,
      pageNumber: inline.pageNumber || 0,
      scopeId: inline.scopeId,
      // Pas de `previewDataUrl` côté server-side ; le générateur passera
      // par fetchImageBytes(notePageId) → cache inline → buffer direct.
      previewDataUrl: null,
      _inline: true,
    });
    seenIds.add(String(inline.id));
  }
  for (const page of Array.isArray(remotePages) ? remotePages : []) {
    if (!page) continue;
    if (seenIds.has(String(page.id))) continue;
    merged.push(page);
  }
  // Tri par phase puis pageNumber pour un ordre stable.
  return merged.sort((a, b) => {
    if (a.planPhase !== b.planPhase) {
      return String(a.planPhase || '').localeCompare(String(b.planPhase || ''));
    }
    return Number(a.pageNumber) - Number(b.pageNumber);
  });
};

app.post(
  '/api/reports/visit/:dossierId',
  requireAuth,
  conditionalReportMultipart,
  async (req, res, next) => {
  try {
    const dossierId = String(req.params.dossierId || '').trim();
    if (!dossierId) {
      throw httpError(400, 'dossierId manquant');
    }

    // 0) Parse les assets inline (multipart). Si la requête est en JSON
    // ou sans body, `inlineAssets.documents` et `.plans` sont vides → le
    // comportement est strictement identique à l'ancien endpoint.
    const inlineAssets = parseInlineReportAssets(req);
    if (inlineAssets.documents.size > 0 || inlineAssets.plans.size > 0) {
      console.log(
        `[report] inline assets reçus pour ${dossierId} : ` +
        `${inlineAssets.documents.size} doc(s) + ${inlineAssets.plans.size} plan(s)`
      );
    }

    // 1) Dossier (avec scope d'accès appliqué via getDossiersForApp).
    const dossiers = await getDossiersForApp(req.appUser);
    const dossier = dossiers.find((d) => String(d.id) === dossierId);
    if (!dossier) {
      throw httpError(404, `Dossier ${dossierId} introuvable ou hors scope`);
    }

    const patientId = String(dossier?.patient?.id || '').trim();

    // 2) Tout en parallèle. Tout est optionnel — si l'ergo n'a pas
    // rempli telle ou telle section, le PDF a juste les zones vides.
    const [
      sanitaires,
      legacyObservations,
      remoteDocuments,
      remoteNotePages,
      contexteNotes,
      recommendations,
      vadOverlayNotes,
      caisseComplementaireResolved,
    ] = await Promise.all([
      fetchSanitairesForDossier(dossierId).catch((err) => {
        console.warn(`[report] échec fetch sanitaires pour ${dossierId}:`, err?.message || err);
        return null;
      }),
      fetchObservationsForDossier(dossierId).catch((err) => {
        console.warn(`[report] échec fetch observations pour ${dossierId}:`, err?.message || err);
        return null;
      }),
      patientId ? fetchVisitPhotosForPatient(patientId) : Promise.resolve([]),
      patientId ? fetchPlanNotePagesForPatient(patientId, dossierId) : Promise.resolve([]),
      patientId ? fetchContexteNotePagesForPatient(patientId, dossierId) : Promise.resolve([]),
      fetchVisitRecommendationsForDossier(dossierId),
      // NEW (2026-04-28) : les 3 textes VAD sont maintenant dans des
      // NotesWidget (Préconisations-Projet, Préconisations-Résumé,
      // Accessibilité-Équipements) au lieu de la table
      // `observations_synthese`. On lit les 2 sources et on merge —
      // les notes gagnent en priorité, observations_synthese reste un
      // fallback pour les dossiers historiques.
      patientId
        ? fetchVadOverlayNotesForReport(patientId, dossierId)
        : Promise.resolve({ projet: null, resume: null, observation: null }),
      // NEW (2026-04-29 / mis à jour 2026-04-30) : résolution de la
      // caisse de retraite complémentaire en `'/'` ou
      // `'<caisse> sous conditions*'`. Quand le dossier a plusieurs
      // occupants, on agrège leurs caisses respectives — voir la
      // règle complète dans `resolveCaisseComplementaireLabel`.
      // On lit `caissesRetraiteComplementaires` de chaque occupant ;
      // le top-level `patient.caissesRetraiteComplementaires` reste un
      // fallback pour les dossiers historiques sans `occupants_json`.
      resolveCaisseComplementaireLabel(
        Array.isArray(dossier?.patient?.occupants)
          && dossier.patient.occupants.length > 0
          ? dossier.patient.occupants.map(
              (occ) => occ?.caissesRetraiteComplementaires || '',
            )
          : [dossier?.patient?.caissesRetraiteComplementaires || ''],
      ),
    ]);

    // 3) Merge inline + remote. Inline gagne en cas de doublon (state
    // local plus récent que NocoDB pendant la fenêtre intermittente).
    const documents = mergeInlineDocuments(remoteDocuments, inlineAssets.documents);
    const notePages = mergeInlineNotePages(remoteNotePages, inlineAssets.plans);

    // 3b) Merge VAD overlay notes (nouvelle source) avec
    // `observations_synthese` (ancienne source). Notes gagnent.
    //
    // Champ `accessibiliteObservation` ajouté en avril 2026 — alimente
    // « Observations sur l'accessibilité » page 5 du PDF
    // (`Observations1`) à partir de la note PARTAGÉE entre toutes les
    // sous-sections de l'onglet Accessibilité (cf.
    // `_kSharedAccessibiliteNotesTabKey` côté Flutter et
    // `fetchVadOverlayNotesForReport.accessibilite` côté serveur).
    const observations = (() => {
      const base = legacyObservations || {
        id: null,
        dossierId,
        observationEquipements: '',
        projetSouhaitUsage: '',
        resumePreconisations: '',
      };
      return {
        ...base,
        projetSouhaitUsage:
          (vadOverlayNotes.projet && vadOverlayNotes.projet.trim()) ||
          base.projetSouhaitUsage,
        resumePreconisations:
          (vadOverlayNotes.resume && vadOverlayNotes.resume.trim()) ||
          base.resumePreconisations,
        // `observationEquipements` alimente `obs` page 6 PDF
        // (« Observations sur les équipements et utilisation »).
        // Source 2026-04-29 : concat des notes panneau Salle de bain
        // + WC (cf. fetchVadOverlayNotesForReport.sanitaires).
        // Fallback : observation legacy de `observations_synthese` pour
        // les dossiers historiques.
        observationEquipements: (() => {
          const fromNotes =
            (vadOverlayNotes.sanitaires &&
              vadOverlayNotes.sanitaires.trim()) || '';
          const fromLegacy = String(base.observationEquipements || '').trim();
          const final = fromNotes || fromLegacy;
          // Diagnostic verbose pour le bug "obs vide" reporté
          // 2026-04-29. À retirer une fois le bug confirmé fixé.
          // eslint-disable-next-line no-console
          console.log(
            '[observations.merge] dossier=%s | sanitairesNotes=%d legacyObs=%d → final=%d',
            dossierId,
            fromNotes.length,
            fromLegacy.length,
            final.length,
          );
          return final;
        })(),
        accessibiliteObservation:
          (vadOverlayNotes.accessibilite &&
              vadOverlayNotes.accessibilite.trim()) ||
          null,
      };
    })();

    const { bytes, stats } = await generateVisitReport({
      dossier,
      sanitaires,
      observations,
      documents,
      notePages,
      // Notes Contexte de vie (sous-onglets Médical + Autonomie). Le
      // générateur extrait leur `textContent` pour remplir
      // « Environnement » et « Habitudes de vie » du PDF (demande
      // utilisateur).
      contexteNotes,
      recommendations,
      // Libellé pré-résolu pour la cellule « Caisse de retraite
      // complémentaire » de la page descriptif des aides
      // prévisionnelles. La règle métier (lookup
      // `aide_complementaire`) vit dans `resolveCaisseComplementaireLabel`
      // côté `index.mjs` car le générateur n'accède pas directement à
      // NocoDB.
      caisseComplementaireResolved,
      // Wrapper inline-first : si le descriptor cible un asset embarqué
      // dans la requête multipart, on lit le buffer en mémoire (zéro
      // round-trip). Fallback sur le fetcher d'origine (NocoDB / URL).
      fetchImageBytes: buildInlineFirstFetcher(inlineAssets),
    });
    const fileName = buildReportFileName(dossier);

    // Sauvegarde IMMÉDIATE du PDF dans NocoDB côté serveur.
    //
    // Pourquoi : Vercel Hobby a une limite de body de ~4.5 MB qui faisait
    // échouer en 413 le re-upload Flutter→serveur du PDF rapport.
    // Symptôme reporté 2026-04-29 : « Rapport - DENA Paul » apparaît en
    // local sur les 2 devices mais jamais en NocoDB → divergence entre
    // macOS web et iPad PWA. En sauvant directement ici (no HTTP body
    // limit, on est dans la même fonction serverless qui a déjà chargé
    // le PDF en mémoire), on contourne complètement le 413.
    //
    // L'UUID du doc créé est retourné via le header `X-Saved-Doc-Uuid`
    // pour que Flutter puisse l'insérer directement comme `synced`
    // localement (sans queuer un upload qui ferait 413).
    //
    // Best-effort : si la sauvegarde NocoDB échoue (rare — cf. limite
    // 5 MB interne ou erreur réseau NocoDB), on log un warning mais on
    // retourne quand même les bytes au Flutter qui retombera sur son
    // ancien chemin (upload via /api/documents → fail 413 → marqué
    // failed, l'utilisateur regénère).
    let savedDocUuid = '';
    try {
      const patientId = stringValue(dossier?.patient?.id);
      if (patientId && bytes && bytes.length > 0) {
        const contentBase64 = Buffer.from(bytes).toString('base64');
        const documentLocalId = `doc_report_${dossierId}_${Date.now()}`;
        const titleNoExt = fileName.replace(/\.pdf$/i, '');
        const savedDoc = await mobileSyncStore.upsertDocument({
          patientId,
          dossierId,
          documentLocalId,
          title: titleNoExt,
          fileName,
          mimeType: 'application/pdf',
          tags: ['Rapport'],
          contentBase64,
          patientFirstName: dossier?.patient?.firstName || '',
          patientLastName: dossier?.patient?.lastName || '',
          patientDisplayName:
            [dossier?.patient?.firstName, dossier?.patient?.lastName]
              .filter(Boolean)
              .join(' ')
              .trim(),
          dossierLabel:
            [dossier?.patient?.firstName, dossier?.patient?.lastName]
              .filter(Boolean)
              .join(' ')
              .trim(),
        });
        savedDocUuid = stringValue(savedDoc?.id || savedDoc?.uuid_source);
        console.log(
          `[report] PDF sauvegardé directement dans NocoDB ` +
          `(dossier=${dossierId}, uuid=${savedDocUuid.slice(0, 8)}…, ` +
          `${bytes.length} bytes)`,
        );
      }
    } catch (saveErr) {
      console.warn(
        `[report] échec sauvegarde directe NocoDB (dossier=${dossierId}) :`,
        saveErr?.message || saveErr,
      );
      // Fallback silencieux : Flutter retombera sur l'upload classique.
    }

    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader(
      'Content-Disposition',
      `attachment; filename="${encodeURIComponent(fileName)}"`,
    );
    res.setHeader('X-Report-Stats', JSON.stringify(stats));
    if (savedDocUuid) {
      res.setHeader('X-Saved-Doc-Uuid', savedDocUuid);
    }
    // Bytes Uint8Array → Buffer pour Express.
    res.send(Buffer.from(bytes));
  } catch (error) {
    next(error);
  }
  },
);

app.post('/api/beneficiaires', requireAuth, async (req, res, next) => {
  try {
    const updates = req.body || {};
    const assignedErgoLabel = await resolveRequestedErgoLabel(req.appUser, updates.ergoId);
    const references = await loadBeneficiaryReferenceSets();
    const fields = mapBeneficiaryUpdatesToFields(updates, references);
    const relationFieldNames = [
      'situation_proprietaire_id1',
      'statut_occupation_id1',
      'dependances_particulieres_id',
      'caisses_de_retraite_id',
      'caisses_de_retraite_complementaires_id',
      'categorie_revenu_id1',
    ];
    const relationFields = Object.fromEntries(
      Object.entries(fields).filter(([key]) => relationFieldNames.includes(key))
    );
    const baseFields = Object.fromEntries(
      Object.entries(fields).filter(([key]) => !relationFieldNames.includes(key))
    );

    if (!fields.nom) {
      throw new Error('Le nom du bénéficiaire est obligatoire');
    }

    // Clé d'idempotence — Flutter envoie son `local_id` (ex:
    // `patient_<timestamp>`) comme `clientLocalId`. On le réutilise
    // comme `uuid_source` du dossier (champ existant côté NocoDB, pas
    // de migration de schéma nécessaire). Si un dossier avec ce
    // `uuid_source` existe déjà → la création précédente a abouti
    // côté NocoDB mais la réponse n'est pas arrivée au client (timeout
    // Wi-Fi, lambda Vercel coupée…) ; le client a rejoué l'op, et
    // sans cette garde on créerait un duplicate. On renvoie les IDs
    // existants au lieu de re-créer.
    const clientLocalId = stringValue(updates.clientLocalId).trim();
    if (clientLocalId) {
      try {
        const existingDossiers = await queryAll(TABLES.dossiers, {
          fields: ['uuid_source', 'patient_id', 'beneficiaires_id'],
          where: `(uuid_source,eq,${JSON.stringify(clientLocalId)})`,
        });
        if (existingDossiers.length > 0) {
          const existing = existingDossiers[0];
          const beneficiaireRecordId = field(existing, 'beneficiaires_id');
          const existingPatientSyntheticId = beneficiaireRecordId
            ? syntheticBeneficiaryId(beneficiaireRecordId)
            : stringValue(field(existing, 'patient_id'));
          // ignore: avoid_print
          console.log(
            `[POST /beneficiaires] idempotent skip — dossier déjà créé (uuid_source=${clientLocalId})`,
          );
          res.status(200).json({
            success: true,
            error: null,
            data: {
              id: existingPatientSyntheticId,
              dossierId: clientLocalId,
              alreadyExisted: true,
            },
          });
          return;
        }
      } catch (err) {
        // Si la requête NocoDB échoue, on continue sur le chemin
        // normal de création (la garde côté Flutter reste un filet
        // de sécurité).
        console.warn('[POST /beneficiaires] idempotency check failed:', err?.message || err);
      }
    }

    const created = await createRecord(TABLES.beneficiaires, baseFields);
    if (Object.keys(relationFields).length > 0) {
      await updateRecord(TABLES.beneficiaires, created.id, relationFields);
    }
    const createdDossier = await createRecord(TABLES.dossiers, {
      // `uuid_source` : si le client a fourni `clientLocalId`, on
      // l'utilise tel quel (clé d'idempotence). Sinon fallback sur
      // un UUID random (ex. dossiers créés via une UI tierce).
      uuid_source: clientLocalId || crypto.randomUUID(),
      patient_id: syntheticBeneficiaryId(created.id),
      beneficiaires_id: Number(created.id),
      ergo_id: assignedErgoLabel,
      status: 'À visiter',
      created_at: new Date().toISOString(),
    });
    res.status(201).json({
      success: true,
      error: null,
      data: {
        id: syntheticBeneficiaryId(created.id),
        dossierId: field(createdDossier, 'uuid_source') || String(createdDossier.id),
      },
    });
  } catch (error) {
    next(error);
  }
});

app.patch('/api/beneficiaires/:patientId', requireAuth, async (req, res, next) => {
  try {
    const patientId = req.params.patientId;
    const updates = req.body || {};
    const syntheticId = parseSyntheticBeneficiaryId(patientId);
    const [beneficiaires, references, dossiers] = await Promise.all([
      queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires }),
      loadBeneficiaryReferenceSets(),
      queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers }),
    ]);

    const beneficiaryRecord = syntheticId != null
      ? findByRecordId(beneficiaires, syntheticId)
      : resolveBeneficiaryRecord({
          beneficiaires,
          dossiers,
          appBeneficiaryId: patientId,
        });
    if (!beneficiaryRecord) {
      throw new Error(`Bénéficiaire ${patientId} introuvable`);
    }

    const dossierRecord = latestByFieldValue(dossiers, 'beneficiaires_id', beneficiaryRecord.id);
    if (dossierRecord && !canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce bénéficiaire' });
      return;
    }

    if (sendConflictIfStale(req, res, beneficiaryRecord)) return;

    const fields = mapBeneficiaryUpdatesToFields(updates, references);

    await updateRecord(TABLES.beneficiaires, beneficiaryRecord.id, fields);
    const refreshedDossiers = await getDossiersForApp(req.appUser);
    const refreshedDossier = refreshedDossiers.find((dossier) => String(dossier?.patient?.id) === String(patientId));
    if (refreshedDossier?.patient) {
      await mobileSyncStore.syncNotePagesBeneficiaryMetadata(patientId, {
        patientFirstName: refreshedDossier.patient.firstName,
        patientLastName: refreshedDossier.patient.lastName,
        patientDisplayName: [refreshedDossier.patient.firstName, refreshedDossier.patient.lastName].filter(Boolean).join(' ').trim(),
        dossierLabel: refreshedDossier.label || [refreshedDossier.patient.firstName, refreshedDossier.patient.lastName].filter(Boolean).join(' ').trim(),
        dossierId: refreshedDossier.id,
      });

      // Resync des champs dénormalisés (`beneficiaire_prenom`,
      // `beneficiaire_nom`, `beneficiaire_nom_complet`, `dossier_libelle`)
      // dans les 4 tables `mobile_*` qui les snapshot à l'écriture
      // (mobile_documents, mobile_document_chunks, mobile_note_pages,
      // mobile_visit_recommendations). Sans ce hook, un renommage de
      // bénéficiaire laissait des libellés legacy stale dans NocoDB
      // (cf. checkup 2026-04-29 : « Paul SAKA » devenu Paul DENA, etc.).
      //
      // Idempotent — ne PATCHe que les lignes effectivement stale.
      // Best-effort : un échec ici ne fait pas échouer le PATCH du
      // bénéficiaire (qui a déjà réussi).
      try {
        const stats = await resyncBeneficiaireDenormalizedNames({
          beneficiaireUuid: patientId,
          prenom: refreshedDossier.patient.firstName,
          nom: refreshedDossier.patient.lastName,
          dossierLabel:
            refreshedDossier.label ||
            [refreshedDossier.patient.firstName, refreshedDossier.patient.lastName]
              .filter(Boolean)
              .join(' ')
              .trim(),
          apiUrl: process.env.NOCODB_API_URL?.replace(/\/$/, ''),
          baseId: process.env.NOCODB_BASE_ID,
          token: process.env.NOCODB_API_TOKEN,
        });
        if (stats.total > 0) {
          console.log(
            `[resync-legacy-names] beneficiaire ${patientId} : ${stats.total} ligne(s) re-synchronisée(s)`,
          );
        }
      } catch (resyncErr) {
        console.warn(
          `[resync-legacy-names] échec pour ${patientId} :`,
          resyncErr?.message || resyncErr,
        );
      }
    }
    res.json({
      success: true,
      error: null,
      data: {},
    });
  } catch (error) {
    next(error);
  }
});

app.patch('/api/dossiers/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const updates = req.body || {};
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    if (sendConflictIfStale(req, res, dossierRecord)) return;

    const dossierUuid = field(dossierRecord, 'uuid_source');
    const beneficiaryUuid = field(dossierRecord, 'patient_id');

    const fields = sanitizeUndefined({
      compte_anah: updates.compteAnah,
      nature_accompagnement: updates.natureAccompagnement,
      envoi_rapport: updates.envoiRapport,
      personnes_presentes_visite: updates.personnesPresentesVisite,
      status: updates.status,
      visit_date: nullableString(updates.visitDate),
      ergo_id: Object.prototype.hasOwnProperty.call(updates, 'ergoId')
        ? nullableString(await resolveRequestedErgoLabel(req.appUser, updates.ergoId))
        : undefined,
    });

    if (Object.keys(fields).length > 0) {
      await updateRecord(TABLES.dossiers, dossierRecord.id, fields);
    }

    if (updates.medicalContext || updates.autonomy) {
      await upsertContexte(dossierUuid, beneficiaryUuid, updates.medicalContext, updates.autonomy, {
        dossierRecord,
        beneficiaryRecordId: field(dossierRecord, 'beneficiaires_id'),
      });
    }

    res.json({
      success: true,
      error: null,
      data: { id: dossierUuid },
    });
  } catch (error) {
    next(error);
  }
});

app.patch('/api/logements/by-beneficiary/:beneficiaryId', requireAuth, async (req, res, next) => {
  try {
    const beneficiaryId = req.params.beneficiaryId;
    const updates = req.body || {};
    const syntheticId = parseSyntheticBeneficiaryId(beneficiaryId);
    const [beneficiaires, logements, typeLogements, porteGarageRefs, portailRefs, dossiers] = await Promise.all([
      queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires }),
      queryAll(TABLES.logements, { fields: FIELD_SETS.logements }),
      queryAll(TABLES.typeDeLogement, { fields: FIELD_SETS.referencesLibelle }),
      queryAll(TABLES.porteDeGarage, { fields: FIELD_SETS.referencesLibelle }),
      queryAll(TABLES.portail, { fields: FIELD_SETS.referencesLibelle }),
      queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers }),
    ]);

    const beneficiaryRecord = syntheticId != null
      ? findByRecordId(beneficiaires, syntheticId)
      : resolveBeneficiaryRecord({
          beneficiaires,
          dossiers,
          logements,
          appBeneficiaryId: beneficiaryId,
        });
    if (!beneficiaryRecord) {
      throw new Error(`Bénéficiaire ${beneficiaryId} introuvable pour le logement`);
    }

    const dossierRecord = latestByFieldValue(dossiers, 'beneficiaires_id', beneficiaryRecord.id);
    if (dossierRecord && !canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce logement' });
      return;
    }

    const existingHousing = latestRecord(
      logements.filter((record) => field(record, 'beneficiaire_id') === beneficiaryId || String(field(record, 'beneficiaires_id')) === String(beneficiaryRecord.id))
    );
    const typeLogement = findByLabel(typeLogements, updates.typology);
    const porteGarage = findByLabel(porteGarageRefs, updates.motorisationPorteGarage);
    const portail = findByLabel(portailRefs, updates.motorisationPortail);

    const fields = sanitizeUndefined({
      uuid_source: existingHousing ? undefined : crypto.randomUUID(),
      beneficiaire_id: beneficiaryId,
      beneficiaires_id: Number(beneficiaryRecord.id),
      annee_construction: nullableString(updates.yearConstruction),
      annee_habitation: nullableString(updates.yearHabitation),
      surface_habitable: nullableString(updates.surface),
      nombre_niveaux: updates.levels,
      sous_sol: boolText(updates.basement),
      description_sous_sol: nullableString(updates.basementDesc),
      rdc: boolText(updates.rdc),
      description_rdc: nullableString(updates.rdcDesc),
      etage: boolText(updates.floor),
      second_etage: boolText(updates.secondFloor),
      third_etage: boolText(updates.thirdFloor),
      description_etage: nullableString(updates.floorDesc),
      garage: boolText(updates.garage),
      veranda: boolText(updates.veranda),
      balcon: boolText(updates.balcon),
      terrasse: boolText(updates.terrasse),
      jardin: boolText(updates.jardin),
      chauffage: boolText(updates.heatingMain),
      radiateurs_electrique: boolText(updates.heatingDetails?.electric),
      chaudiere_gaz: boolText(updates.heatingDetails?.gas),
      chaudiere_fioul: boolText(updates.heatingDetails?.oil),
      pompe_a_chaleur: boolText(updates.heatingDetails?.heatPump),
      chaudiere_collective: boolText(updates.heatingDetails?.collective),
      cheminee_pole_bois: boolText(updates.heatingDetails?.wood),
      poele_granules: boolText(updates.heatingDetails?.pellet),
      autre_chauffage: boolText(updates.heatingDetails?.other),
      volets_roulants_manuels_localisation: nullableString(updates.voletsRoulantsManuelsLocalisation),
      volets_roulants_manuels_entier: boolText(updates.voletsRoulantsManuelsEntier),
      volets_roulants_electriques_localisation: nullableString(updates.voletsRoulantsElectriquesLocalisation),
      volets_roulants_electriques_entier: boolText(updates.voletsRoulantsElectriquesEntier),
      volets_persiennes_localisation: nullableString(updates.voletsPersiennesLocalisation),
      volets_persiennes_entier: boolText(updates.voletsPersiennesEntier),
      cheminement_escalier_exterieur: boolText(updates.cheminementEscalierExterieur),
      cheminement_escalier_interieur: boolText(updates.cheminementEscalierInterieur),
      cheminement_pente_douce: boolText(updates.cheminementPenteDouce),
      cheminement_plat: boolText(updates.cheminementPlat),
      cheminement_quelques_marches: boolText(updates.cheminementQuelquesMarches),
      cheminement_par_arriere: boolText(updates.cheminementParArriere),
      cheminement_seuil_porte: boolText(updates.cheminementSeuilPorte),
      difficultes_circulation_interieure: boolText(updates.difficultesCirculationInterieure),
      acces_facile_rue: boolText(updates.easyAccess),
      commentaire: nullableString(updates.comments),
      observation_accessibilite: nullableString(updates.accessObservation),
      type_de_logement_id: typeLogement ? Number(typeLogement.id) : undefined,
      porte_de_garage_id: porteGarage ? Number(porteGarage.id) : undefined,
      portail_id1: portail ? Number(portail.id) : undefined,
    });

    if (existingHousing) {
      if (sendConflictIfStale(req, res, existingHousing)) return;
      await updateRecord(TABLES.logements, existingHousing.id, fields);
      res.json({ success: true, error: null, data: { id: field(existingHousing, 'uuid_source') || `nocodb-housing-${existingHousing.id}` } });
      return;
    }

    const created = await createRecord(TABLES.logements, fields);
    res.json({ success: true, error: null, data: { id: field(created, 'uuid_source') || `nocodb-housing-${created.id}` } });
  } catch (error) {
    next(error);
  }
});

app.get('/api/documents/:patientId', requireAuth, async (req, res, next) => {
  try {
    const access = await resolveBeneficiaryAccess(req.appUser, req.params.patientId);
    const dossierId = stringValue(req.query?.dossierId).trim();
    const documents = await mobileSyncStore.listDocumentsByPatient(req.params.patientId, {
      dossierId: dossierId || undefined,
    });
    const documentContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId: req.params.patientId,
    });

    res.json({
      success: true,
      error: null,
      data: { documents: documents.map((document) => ({ ...documentContext, ...document })) },
    });
  } catch (error) {
    next(error);
  }
});

app.post(
  '/api/documents/upload',
  requireAuth,
  express.raw({ type: () => true, limit: '30mb' }),
  async (req, res, next) => {
    try {
      const patientId = stringValue(req.query?.patientId).trim();
      const documentLocalId = stringValue(req.query?.documentLocalId).trim();
      const title = stringValue(req.query?.title).trim() || 'Document';
      const requestedFileName = stringValue(req.query?.fileName).trim();
      const requestedDossierId = stringValue(req.query?.dossierId).trim();
      const tags = safeParseJsonArray(req.query?.tagsJson).map((tag) => String(tag).trim()).filter(Boolean);
      const mimeType = stringValue(req.get('content-type')).trim() || 'application/octet-stream';
      const bodyBuffer = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);

      if (!patientId) {
        throw httpError(400, 'patientId manquant');
      }

      if (bodyBuffer.length === 0) {
        throw httpError(400, 'Fichier manquant');
      }

      const access = await resolveBeneficiaryAccess(req.appUser, patientId);
      const documentContext = buildBeneficiaryDocumentContext({
        beneficiaryRecord: access.beneficiaryRecord,
        dossierRecord: access.dossierRecord,
        patientId,
      });
      const document = await mobileSyncStore.upsertDocument({
        patientId,
        dossierId: requestedDossierId || field(access.dossierRecord, 'uuid_source') || null,
        documentLocalId,
        title,
        fileName: requestedFileName || `${title}.bin`,
        mimeType,
        tags,
        contentBase64: bodyBuffer.toString('base64'),
        ...documentContext,
      });

      res.status(201).json({
        success: true,
        error: null,
        data: { document: mapStoredDocument(document) },
      });
    } catch (error) {
      next(error);
    }
  },
);

app.post('/api/documents', requireAuth, documentUpload.single('file'), async (req, res, next) => {
  try {
    const patientId = stringValue(req.body?.patientId).trim();
    const documentLocalId = stringValue(req.body?.documentLocalId).trim();
    const title = stringValue(req.body?.title).trim() || 'Document';
    const requestedFileName = stringValue(req.body?.fileName).trim();
    const requestedDossierId = stringValue(req.body?.dossierId).trim();

    // tags may arrive as JSON string (multipart) or array (JSON body)
    const rawTags = req.body?.tags;
    const parsedTags = typeof rawTags === 'string' ? (() => { try { const p = JSON.parse(rawTags); return Array.isArray(p) ? p : [rawTags]; } catch { return [rawTags]; } })() : rawTags;
    const tags = asArray(parsedTags).map((tag) => String(tag).trim()).filter(Boolean);

    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }

    // Multipart file upload: convert buffer to base64 for downstream compatibility
    let contentBase64 = req.body?.contentBase64;
    if (!contentBase64 && req.file?.buffer) {
      contentBase64 = req.file.buffer.toString('base64');
    }

    const access = await resolveBeneficiaryAccess(req.appUser, patientId);
    const documentContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId,
    });
    const document = await mobileSyncStore.upsertDocument({
      patientId,
      dossierId: requestedDossierId || field(access.dossierRecord, 'uuid_source') || null,
      documentLocalId,
      title,
      fileName: requestedFileName || `${title}.bin`,
      mimeType: stringValue(req.body?.mimeType).trim() || req.file?.mimetype || 'application/octet-stream',
      tags,
      contentBase64,
      ...documentContext,
    });

    res.status(201).json({
      success: true,
      error: null,
      data: { document: mapStoredDocument(document) },
    });
  } catch (error) {
    next(error);
  }
});

// ---------------------------------------------------------------------------
// Chunked upload — contourne le timeout 10s de Vercel Hobby pour les gros
// fichiers (PDF rapport, photos haute définition…).
//
// Pourquoi : sur Hobby, une fonction Vercel a 10s pour répondre. Pour un
// fichier de 5MB qui doit être base64-encodé puis poussé via NocoDB MCP
// (api request + ingestion DB), on dépasse facilement → 504 Gateway
// Timeout → l'app web voit "CORS missing header" car Vercel ne passe pas
// par notre middleware en cas de timeout.
//
// Solution : le client splitte le fichier en chunks de ~1MB, chaque
// chunk fait son propre POST (< 2s), puis un dernier appel `finalize`
// reassemble côté serveur et insère en NocoDB.
//
// Demande utilisateur 2026-04-29 : « ajoute un mécanisme de chunked
// upload pour contourner les timeouts ».
// ---------------------------------------------------------------------------

/**
 * POST /api/documents/upload/chunk — uploade UN chunk d'un fichier.
 * Le client envoie multipart avec :
 *   - chunk      : binaire du chunk
 *   - uploadId   : ID unique de la session d'upload (généré client-side)
 *   - chunkIndex : 0..totalChunks-1
 *   - totalChunks: nombre total attendu
 *
 * Le chunk est stocké dans Vercel Blob sous `_chunks/<uploadId>/<idx>.bin`.
 * Réponse 202 + `{uploadId, received, total}` pour permettre au client
 * d'afficher la progression.
 */
app.post(
  '/api/documents/upload/chunk',
  requireAuth,
  documentUpload.single('chunk'),
  async (req, res, next) => {
    try {
      const uploadId = stringValue(req.body?.uploadId).trim();
      const chunkIndex = Number(req.body?.chunkIndex);
      const totalChunks = Number(req.body?.totalChunks);
      if (!uploadId) throw httpError(400, 'uploadId manquant');
      if (!Number.isInteger(chunkIndex) || chunkIndex < 0) {
        throw httpError(400, 'chunkIndex invalide');
      }
      if (!Number.isInteger(totalChunks) || totalChunks <= 0) {
        throw httpError(400, 'totalChunks invalide');
      }
      if (!req.file?.buffer || req.file.buffer.length === 0) {
        throw httpError(400, 'Chunk vide');
      }
      // Limite de taille par chunk pour rester < 10s côté Vercel — un
      // chunk > 4MB en upload peut prendre > 5s sur 4G médiocre + le
      // round-trip Vercel→Blob ajoute encore. On limite à 2MB pour
      // garder de la marge.
      if (req.file.buffer.length > 2 * 1024 * 1024) {
        throw httpError(
          413,
          'Chunk trop volumineux (max 2 MB) — réduire la taille de chunk côté client',
        );
      }
      await putChunk({
        uploadId,
        chunkIndex,
        buffer: req.file.buffer,
      });
      // On ne compte pas les chunks reçus en base — le client connaît
      // le total et envoie séquentiellement. Si tu veux supporter le
      // resume après crash, ajoute ici un appel `listChunks(uploadId)`
      // pour retourner `received: existingChunks.length`.
      res.status(202).json({
        success: true,
        error: null,
        data: { uploadId, chunkIndex, totalChunks },
      });
    } catch (error) {
      next(error);
    }
  },
);

/**
 * POST /api/documents/upload/finalize — assemble les chunks d'un upload
 * en un fichier complet et le persiste comme un document normal
 * (équivalent du POST /api/documents classique mais avec le contenu
 * pris depuis Blob plutôt que multipart). Body JSON :
 *   - uploadId
 *   - patientId, dossierId, documentLocalId, title, fileName,
 *     mimeType, tags  (mêmes champs que /api/documents)
 *
 * Cleanup : les chunks sont supprimés de Blob APRÈS l'insertion
 * NocoDB réussie. En cas d'erreur, ils restent (purge cron).
 */
app.post(
  '/api/documents/upload/finalize',
  requireAuth,
  async (req, res, next) => {
    try {
      const uploadId = stringValue(req.body?.uploadId).trim();
      const patientId = stringValue(req.body?.patientId).trim();
      const documentLocalId = stringValue(req.body?.documentLocalId).trim();
      const title = stringValue(req.body?.title).trim() || 'Document';
      const requestedFileName = stringValue(req.body?.fileName).trim();
      const requestedDossierId = stringValue(req.body?.dossierId).trim();
      const rawTags = req.body?.tags;
      const parsedTags = typeof rawTags === 'string'
        ? (() => {
            try {
              const p = JSON.parse(rawTags);
              return Array.isArray(p) ? p : [rawTags];
            } catch {
              return [rawTags];
            }
          })()
        : rawTags;
      const tags = asArray(parsedTags).map((t) => String(t).trim()).filter(Boolean);

      if (!uploadId) throw httpError(400, 'uploadId manquant');
      if (!patientId) throw httpError(400, 'patientId manquant');

      // Reassemble — fail-fast si chunks manquants ou non contigus.
      const buffer = await reassembleChunks(uploadId);
      const contentBase64 = buffer.toString('base64');

      const access = await resolveBeneficiaryAccess(req.appUser, patientId);
      const documentContext = buildBeneficiaryDocumentContext({
        beneficiaryRecord: access.beneficiaryRecord,
        dossierRecord: access.dossierRecord,
        patientId,
      });
      const document = await mobileSyncStore.upsertDocument({
        patientId,
        dossierId:
            requestedDossierId
            || field(access.dossierRecord, 'uuid_source')
            || null,
        documentLocalId,
        title,
        fileName: requestedFileName || `${title}.bin`,
        mimeType: stringValue(req.body?.mimeType).trim()
            || 'application/octet-stream',
        tags,
        contentBase64,
        ...documentContext,
      });

      // Cleanup. Best-effort — un chunk orphelin n'est pas critique.
      await deleteChunks(uploadId);

      res.status(201).json({
        success: true,
        error: null,
        data: { document: mapStoredDocument(document) },
      });
    } catch (error) {
      next(error);
    }
  },
);

/**
 * GET /api/documents/upload/:uploadId/status — utilisé par le client
 * pour reprendre un upload après un crash (liste les chunks déjà reçus).
 */
app.get(
  '/api/documents/upload/:uploadId/status',
  requireAuth,
  async (req, res, next) => {
    try {
      const uploadId = stringValue(req.params.uploadId).trim();
      if (!uploadId) throw httpError(400, 'uploadId manquant');
      const chunks = await listChunks(uploadId);
      res.json({
        success: true,
        error: null,
        data: {
          uploadId,
          receivedChunks: chunks.map((c) => c.index),
        },
      });
    } catch (error) {
      next(error);
    }
  },
);

app.patch('/api/documents/:documentId', requireAuth, async (req, res, next) => {
  try {
    const document = await mobileSyncStore.getDocumentById(req.params.documentId);
    if (!document) {
      throw httpError(404, 'Document introuvable');
    }

    await resolveBeneficiaryAccess(req.appUser, document.patientId);
    const title = req.body?.title == null ? undefined : stringValue(req.body.title).trim();
    const tags = req.body?.tags == null
      ? undefined
      : asArray(req.body.tags).map((tag) => String(tag).trim()).filter(Boolean);

    const updated = await mobileSyncStore.updateDocument(req.params.documentId, {
      title,
      tags,
    });

    if (!updated) {
      throw httpError(404, 'Document introuvable');
    }

    res.json({
      success: true,
      error: null,
      data: { document: mapStoredDocument(updated) },
    });
  } catch (error) {
    next(error);
  }
});

app.delete('/api/documents/:documentId', requireAuth, async (req, res, next) => {
  try {
    const document = await mobileSyncStore.getDocumentById(req.params.documentId);
    if (!document) {
      throw httpError(404, 'Document introuvable');
    }

    await resolveBeneficiaryAccess(req.appUser, document.patientId);
    const deleted = await mobileSyncStore.deleteDocument(req.params.documentId);

    res.json({
      success: deleted,
      error: deleted ? null : 'Document introuvable',
      data: { deleted },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/mobile-documents/:documentId/content', requireAuth, async (req, res, next) => {
  try {
    const content = await mobileSyncStore.getDocumentContent(req.params.documentId);
    if (!content) {
      throw httpError(404, 'Document introuvable');
    }
    // Garde-fou : un record peut exister côté NocoDB sans contenu binaire
    // (upload échoué entre la création de la row et le push des chunks
    // base64). Avant ce filet, on renvoyait 200 + 0 bytes → côté Flutter
    // `webCachedFetch` retournait null → l'aperçu sortait en
    // « Aperçu indisponible » avec point vert (l'app voyait la row
    // synced mais ne pouvait rien afficher). On signale maintenant
    // explicitement par un 404 — le client peut alors afficher un
    // message diagnostic clair (fichier corrompu côté serveur).
    if (!content.buffer || content.buffer.length === 0) {
      throw httpError(404, 'Document sans contenu (corrompu côté serveur)');
    }

    await resolveBeneficiaryAccess(req.appUser, content.patientId);
    res.setHeader('Content-Type', content.mimeType || 'application/octet-stream');
    res.setHeader('Content-Disposition', 'inline');
    res.send(content.buffer);
  } catch (error) {
    next(error);
  }
});

app.get('/public/note-pages/:notePageId/preview', async (req, res, next) => {
  try {
    const notePage = await mobileSyncStore.getNotePageById(req.params.notePageId);
    if (!notePage) {
      throw httpError(404, 'Note introuvable');
    }

    const previewDataUrl = stringValue(notePage.previewDataUrl).trim();
    const noteTitle = [
      stringValue(notePage.patientFirstName).trim(),
      stringValue(notePage.patientLastName).trim(),
    ].filter(Boolean).join(' ').trim() || 'Note';
    const textPreview = stringValue(notePage.textContent).trim();

    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.send(`<!doctype html>
<html lang="fr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHtml(noteTitle)} - Prévisualisation note</title>
    <style>
      body { margin:0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:#f8fafc; color:#0f172a; }
      .shell { min-height:100vh; display:flex; align-items:center; justify-content:center; padding:32px 20px; }
      .card { width:min(820px, 100%); background:#fff; border:1px solid #e2e8f0; border-radius:24px; box-shadow:0 20px 40px rgba(15, 23, 42, 0.08); overflow:hidden; }
      .header { padding:20px 24px 12px; border-bottom:1px solid #e2e8f0; }
      .meta { color:#64748b; font-size:13px; font-weight:600; text-transform:uppercase; letter-spacing:.08em; }
      h1 { margin:8px 0 0; font-size:22px; }
      .body { padding:24px; display:grid; gap:20px; }
      .preview { border:1px solid #e2e8f0; border-radius:18px; background:#fff; overflow:hidden; }
      .preview img { display:block; width:100%; height:auto; }
      .empty { padding:48px 24px; color:#94a3b8; text-align:center; font-weight:600; }
      .text { white-space:pre-wrap; line-height:1.6; color:#334155; border:1px solid #e2e8f0; border-radius:18px; background:#f8fafc; padding:18px; }
    </style>
  </head>
  <body>
    <div class="shell">
      <article class="card">
        <header class="header">
          <div class="meta">${escapeHtml(notePage.tabKey)} · page ${Number(notePage.pageNumber) + 1}</div>
          <h1>${escapeHtml(noteTitle)}</h1>
        </header>
        <div class="body">
          <section class="preview">
            ${previewDataUrl ? `<img src="${escapeHtml(previewDataUrl)}" alt="Prévisualisation de la note" />` : '<div class="empty">Aucune miniature disponible</div>'}
          </section>
          ${textPreview ? `<section class="text">${escapeHtml(textPreview)}</section>` : ''}
        </div>
      </article>
    </div>
  </body>
</html>`);
  } catch (error) {
    next(error);
  }
});

app.get('/api/note-pages/:patientId', requireAuth, async (req, res, next) => {
  try {
    await resolveBeneficiaryAccess(req.appUser, req.params.patientId);
    const scopeType = stringValue(req.query?.scopeType).trim();
    const scopeId = stringValue(req.query?.scopeId).trim();
    const tabKey = stringValue(req.query?.tabKey).trim();
    const subTabKey = stringValue(req.query?.subTabKey).trim();
    const pageNumber = req.query?.pageNumber == null || req.query.pageNumber === ''
      ? null
      : Number(req.query.pageNumber);
    const notePages = await mobileSyncStore.listNotePagesByPatient(
      req.params.patientId,
      { scopeType, scopeId, tabKey, subTabKey, pageNumber },
    );

    res.json({
      success: true,
      error: null,
      data: { notePages },
    });
  } catch (error) {
    next(error);
  }
});

app.put('/api/note-pages', requireAuth, async (req, res, next) => {
  try {
    const notePageId = stringValue(req.body?.notePageId).trim();
    const patientId = stringValue(req.body?.patientId).trim();
    const scopeType = stringValue(req.body?.scopeType).trim();
    const scopeId = stringValue(req.body?.scopeId).trim();
    const tabKey = stringValue(req.body?.tabKey).trim();
    const subTabKey = stringValue(req.body?.subTabKey).trim();
    const pageNumber = Number(req.body?.pageNumber ?? 0);
    const textContent = typeof req.body?.textContent === 'string' ? req.body.textContent : '';
    const drawingJson = typeof req.body?.drawingJson === 'string' ? req.body.drawingJson : JSON.stringify(req.body?.drawingJson ?? '');
    const previewDataUrl = typeof req.body?.previewDataUrl === 'string' ? req.body.previewDataUrl : '';
    const layoutKind = stringValue(req.body?.layoutKind).trim() || 'freeform';
    // Phase d'un dessin Plans : 'avant' ou 'apres' (autres valeurs
    // → null). Permet au générateur de rapport PDF de placer le
    // dessin dans le bon emplacement (pages 9 vs 10 du template).
    const planPhaseRaw = stringValue(req.body?.planPhase).trim().toLowerCase();
    const planPhase = (planPhaseRaw === 'avant' || planPhaseRaw === 'apres')
      ? planPhaseRaw
      : null;

    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }
    if (!scopeType) {
      throw httpError(400, 'scopeType manquant');
    }
    if (!scopeId) {
      throw httpError(400, 'scopeId manquant');
    }
    if (!tabKey) {
      throw httpError(400, 'tabKey manquant');
    }
    if (!Number.isFinite(pageNumber) || pageNumber < 0) {
      throw httpError(400, 'pageNumber invalide');
    }

    const access = await resolveBeneficiaryAccess(req.appUser, patientId);
    const notePageContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId,
    });
    const notePage = await mobileSyncStore.upsertNotePage({
      notePageId: notePageId || null,
      patientId,
      dossierId: field(access.dossierRecord, 'uuid_source') || null,
      scopeType,
      scopeId,
      tabKey,
      subTabKey,
      pageNumber,
      textContent,
      drawingJson,
      previewDataUrl,
      layoutKind,
      planPhase,
      ...notePageContext,
    });

    res.json({
      success: true,
      error: null,
      data: { notePage: mapStoredNotePage(notePage) },
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/note-pages', requireAuth, async (req, res, next) => {
  try {
    const patientId = stringValue(req.body?.patientId).trim();
    const scopeType = stringValue(req.body?.scopeType).trim();
    const scopeId = stringValue(req.body?.scopeId).trim();
    const tabKey = stringValue(req.body?.tabKey).trim();
    const subTabKey = stringValue(req.body?.subTabKey).trim();
    const layoutKind = stringValue(req.body?.layoutKind).trim() || 'freeform';

    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }
    if (!scopeType) {
      throw httpError(400, 'scopeType manquant');
    }
    if (!scopeId) {
      throw httpError(400, 'scopeId manquant');
    }
    if (!tabKey) {
      throw httpError(400, 'tabKey manquant');
    }

    const access = await resolveBeneficiaryAccess(req.appUser, patientId);
    const notePageContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId,
    });
    const notePage = await mobileSyncStore.createNotePage({
      patientId,
      dossierId: field(access.dossierRecord, 'uuid_source') || null,
      scopeType,
      scopeId,
      tabKey,
      subTabKey,
      layoutKind,
      ...notePageContext,
    });

    res.json({
      success: true,
      error: null,
      data: { notePage: mapStoredNotePage(notePage) },
    });
  } catch (error) {
    next(error);
  }
});

app.delete('/api/note-pages/:notePageId', requireAuth, async (req, res, next) => {
  try {
    const patientId = stringValue(req.query?.patientId).trim();
    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }

    await resolveBeneficiaryAccess(req.appUser, patientId);
    const deleted = await mobileSyncStore.deleteNotePage(req.params.notePageId);
    if (!deleted) {
      throw httpError(404, 'Note introuvable');
    }

    res.json({
      success: true,
      error: null,
      data: { deleted: true },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/visit-plans/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }

    const visitPlan = await readVisitPlanMeta(field(dossierRecord, 'uuid_source') || req.params.dossierId);
    res.json({
      success: true,
      error: null,
      data: { visitPlan },
    });
  } catch (error) {
    next(error);
  }
});

app.put('/api/visit-plans/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }

    const contentBase64 = stringValue(req.body?.contentBase64).trim();
    if (!contentBase64) {
      throw httpError(400, 'Contenu du plan manquant');
    }

    const image = parseImageDataUrl(contentBase64);
    const dossierId = field(dossierRecord, 'uuid_source') || req.params.dossierId;
    const folderName = safeSlug(dossierId, 'dossier');
    const { url: planUrl, updatedAt: planUpdatedAt } = await putObject({
      key: `visit-plans/${folderName}/plan_logement.png`,
      buffer: image.buffer,
      contentType: 'image/png',
    });
    const visitPlan = { publicUrl: planUrl, updatedAt: planUpdatedAt };
    res.json({
      success: true,
      error: null,
      data: { visitPlan },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/diagnostic-sanitaires/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    const records = await queryAll(TABLES.diagnosticSanitaires, { fields: FIELD_SETS.diagnosticSanitaires });
    const record = latestByFieldValue(records, 'dossier_id', req.params.dossierId);
    res.json(record ? {
      id: field(record, 'uuid_source') || String(record.id),
      dossierId: field(record, 'dossier_id'),
      sdbInstances: (() => {
        const parsed = parseJsonArrayField(field(record, 'sdb_instances_json'));
        return parsed.length > 0 ? parsed : buildLegacyBathroomInstances({
          sdbNiveauPiecesVie: toBool(field(record, 'sdb_niveau_pieces_vie')),
          sdbBaignoire: toBool(field(record, 'sdb_baignoire')),
          sdbBaignoireHauteur: toNumber(field(record, 'sdb_baignoire_hauteur')),
          sdbBacDouche: toBool(field(record, 'sdb_bac_douche')),
          sdbBacDoucheHauteur: toNumber(field(record, 'sdb_bac_douche_hauteur')),
          sdbVasqueSuspendue: toBool(field(record, 'sdb_vasque_suspendue')),
          sdbVasqueSuspendueHauteur: toNumber(field(record, 'sdb_vasque_suspendue_hauteur')),
          sdbVasqueColonne: toBool(field(record, 'sdb_vasque_colonne')),
          sdbVasqueColonneHauteur: toNumber(field(record, 'sdb_vasque_colonne_hauteur')),
          sdbMeubleVasque: toBool(field(record, 'sdb_meuble_vasque')),
          sdbMeubleVasqueHauteur: toNumber(field(record, 'sdb_meuble_vasque_hauteur')),
          sdbBidet: toBool(field(record, 'sdb_bidet')),
          sdbBidetHauteur: toNumber(field(record, 'sdb_bidet_hauteur')),
          sdbParoiDouche: toBool(field(record, 'sdb_paroi_douche')),
          sdbParoiDoucheHauteur: toNumber(field(record, 'sdb_paroi_douche_hauteur')),
          sdbSolGlissant: toBool(field(record, 'sdb_sol_glissant')),
          sdbMachineALaver: toBool(field(record, 'sdb_machine_a_laver')),
          sdbMachineALaverHauteur: toNumber(field(record, 'sdb_machine_a_laver_hauteur')),
          porteSdbLargeurSuffisante: toBool(field(record, 'porte_sdb_largeur_suffisante')),
          porteSdbDimension: toNumber(field(record, 'porte_sdb_dimension')),
          porteSdbSensAdapte: toBool(field(record, 'porte_sdb_sens_adapte')),
        });
      })(),
      wcInstances: (() => {
        const parsed = parseJsonArrayField(field(record, 'wc_instances_json'));
        return parsed.length > 0 ? parsed : buildLegacyWcInstances({
          wcNiveau: toBool(field(record, 'wc_niveau')),
          wcCuvetteBonneHauteur: toBool(field(record, 'wc_cuvette_bonne_hauteur')),
          wcCuvetteTropBasse: toBool(field(record, 'wc_cuvette_trop_basse')),
          wcCuvetteHauteur: toNumber(field(record, 'wc_cuvette_hauteur')),
          wcBarreRelevement: toBool(field(record, 'wc_barre_relevement')),
          porteWcLargeurSuffisante: toBool(field(record, 'porte_wc_largeur_suffisante')),
          porteWcDimension: toNumber(field(record, 'porte_wc_dimension')),
          porteWcSensAdapte: toBool(field(record, 'porte_wc_sens_adapte')),
          observationEquipementsUtilisation: stringValue(field(record, 'observation_equipements_utilisation')),
        });
      })(),
      sdbNiveauPiecesVie: toBool(field(record, 'sdb_niveau_pieces_vie')),
      wcNiveau: toBool(field(record, 'wc_niveau')),
      wcEtage: toBool(field(record, 'wc_etage')),
      sdbBaignoire: toBool(field(record, 'sdb_baignoire')),
      sdbBaignoireHauteur: toNumber(field(record, 'sdb_baignoire_hauteur')),
      sdbBacDouche: toBool(field(record, 'sdb_bac_douche')),
      sdbBacDoucheHauteur: toNumber(field(record, 'sdb_bac_douche_hauteur')),
      sdbVasqueSuspendue: toBool(field(record, 'sdb_vasque_suspendue')),
      sdbVasqueSuspendueHauteur: toNumber(field(record, 'sdb_vasque_suspendue_hauteur')),
      sdbVasqueColonne: toBool(field(record, 'sdb_vasque_colonne')),
      sdbVasqueColonneHauteur: toNumber(field(record, 'sdb_vasque_colonne_hauteur')),
      sdbMeubleVasque: toBool(field(record, 'sdb_meuble_vasque')),
      sdbMeubleVasqueHauteur: toNumber(field(record, 'sdb_meuble_vasque_hauteur')),
      sdbBidet: toBool(field(record, 'sdb_bidet')),
      sdbBidetHauteur: toNumber(field(record, 'sdb_bidet_hauteur')),
      sdbParoiDouche: toBool(field(record, 'sdb_paroi_douche')),
      sdbParoiDoucheHauteur: toNumber(field(record, 'sdb_paroi_douche_hauteur')),
      sdbSolGlissant: toBool(field(record, 'sdb_sol_glissant')),
      sdbMachineALaver: toBool(field(record, 'sdb_machine_a_laver')),
      sdbMachineALaverHauteur: toNumber(field(record, 'sdb_machine_a_laver_hauteur')),
      wcCuvetteBonneHauteur: toBool(field(record, 'wc_cuvette_bonne_hauteur')),
      wcCuvetteTropBasse: toBool(field(record, 'wc_cuvette_trop_basse')),
      wcCuvetteHauteur: toNumber(field(record, 'wc_cuvette_hauteur')),
      wcBarreRelevement: toBool(field(record, 'wc_barre_relevement')),
      porteSdbLargeurSuffisante: toBool(field(record, 'porte_sdb_largeur_suffisante')),
      porteSdbDimension: toNumber(field(record, 'porte_sdb_dimension')),
      porteSdbSensAdapte: toBool(field(record, 'porte_sdb_sens_adapte')),
      porteWcLargeurSuffisante: toBool(field(record, 'porte_wc_largeur_suffisante')),
      porteWcDimension: toNumber(field(record, 'porte_wc_dimension')),
      porteWcSensAdapte: toBool(field(record, 'porte_wc_sens_adapte')),
      observationEquipementsUtilisation: stringValue(field(record, 'observation_equipements_utilisation')),
    } : null);
  } catch (error) {
    next(error);
  }
});

app.put('/api/diagnostic-sanitaires/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierId = req.params.dossierId;
    const payload = req.body || {};
    const records = await queryAll(TABLES.diagnosticSanitaires, { fields: FIELD_SETS.diagnosticSanitaires });
    const dossierRecord = await ensureDossierRecord(dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    const existing = latestByFieldValue(records, 'dossier_id', field(dossierRecord, 'uuid_source'));
    const sdbInstances = Array.isArray(payload.sdbInstances) ? payload.sdbInstances : [];
    const wcInstances = Array.isArray(payload.wcInstances) ? payload.wcInstances : [];
    const primaryBathroom = sdbInstances[0] || {};
    const primaryWc = wcInstances[0] || {};
    const fields = {
      dossier_id: field(dossierRecord, 'uuid_source'),
      dossiers_id: Number(dossierRecord.id),
      sdb_instances_json: nullableString(sdbInstances.length > 0 ? JSON.stringify(sdbInstances) : null),
      wc_instances_json: nullableString(wcInstances.length > 0 ? JSON.stringify(wcInstances) : null),
      sdb_niveau_pieces_vie: boolText(sdbInstances.length > 0 ? primaryBathroom.levelField === 'rdc' : payload.sdbNiveauPiecesVie),
      wc_niveau: boolText(wcInstances.length > 0 ? primaryWc.levelField === 'rdc' : payload.wcNiveau),
      wc_etage: boolText(wcInstances.length > 0 ? primaryWc.levelField !== 'rdc' : payload.wcEtage),
      sdb_baignoire: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbBaignoire : payload.sdbBaignoire),
      sdb_baignoire_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbBaignoireHauteur : payload.sdbBaignoireHauteur),
      sdb_bac_douche: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbBacDouche : payload.sdbBacDouche),
      sdb_bac_douche_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbBacDoucheHauteur : payload.sdbBacDoucheHauteur),
      sdb_vasque_suspendue: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueSuspendue : payload.sdbVasqueSuspendue),
      sdb_vasque_suspendue_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueSuspendueHauteur : payload.sdbVasqueSuspendueHauteur),
      sdb_vasque_colonne: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueColonne : payload.sdbVasqueColonne),
      sdb_vasque_colonne_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueColonneHauteur : payload.sdbVasqueColonneHauteur),
      sdb_meuble_vasque: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbMeubleVasque : payload.sdbMeubleVasque),
      sdb_meuble_vasque_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbMeubleVasqueHauteur : payload.sdbMeubleVasqueHauteur),
      sdb_bidet: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbBidet : payload.sdbBidet),
      sdb_bidet_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbBidetHauteur : payload.sdbBidetHauteur),
      sdb_paroi_douche: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbParoiDouche : payload.sdbParoiDouche),
      sdb_paroi_douche_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbParoiDoucheHauteur : payload.sdbParoiDoucheHauteur),
      sdb_sol_glissant: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbSolGlissant : payload.sdbSolGlissant),
      sdb_machine_a_laver: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbMachineALaver : payload.sdbMachineALaver),
      sdb_machine_a_laver_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbMachineALaverHauteur : payload.sdbMachineALaverHauteur),
      wc_cuvette_bonne_hauteur: boolText(wcInstances.length > 0 ? primaryWc.wcCuvetteBonneHauteur : payload.wcCuvetteBonneHauteur),
      wc_cuvette_trop_basse: boolText(wcInstances.length > 0 ? primaryWc.wcCuvetteTropBasse : payload.wcCuvetteTropBasse),
      wc_cuvette_hauteur: nullableString(wcInstances.length > 0 ? primaryWc.wcCuvetteHauteur : payload.wcCuvetteHauteur),
      wc_barre_relevement: boolText(wcInstances.length > 0 ? primaryWc.wcBarreRelevement : payload.wcBarreRelevement),
      porte_sdb_largeur_suffisante: boolText(sdbInstances.length > 0 ? primaryBathroom.porteSdbLargeurSuffisante : payload.porteSdbLargeurSuffisante),
      porte_sdb_dimension: nullableString(sdbInstances.length > 0 ? primaryBathroom.porteSdbDimension : payload.porteSdbDimension),
      porte_sdb_sens_adapte: boolText(sdbInstances.length > 0 ? primaryBathroom.porteSdbSensAdapte : payload.porteSdbSensAdapte),
      porte_wc_largeur_suffisante: boolText(wcInstances.length > 0 ? primaryWc.porteWcLargeurSuffisante : payload.porteWcLargeurSuffisante),
      porte_wc_dimension: nullableString(wcInstances.length > 0 ? primaryWc.porteWcDimension : payload.porteWcDimension),
      porte_wc_sens_adapte: boolText(wcInstances.length > 0 ? primaryWc.porteWcSensAdapte : payload.porteWcSensAdapte),
      observation_equipements_utilisation: nullableString(wcInstances.length > 0 ? primaryWc.observationEquipementsUtilisation : payload.observationEquipementsUtilisation),
      updated_at: new Date().toISOString(),
    };

    if (existing) {
      if (sendConflictIfStale(req, res, existing)) return;
      await updateRecord(TABLES.diagnosticSanitaires, existing.id, fields);
    } else {
      await createRecord(TABLES.diagnosticSanitaires, { uuid_source: crypto.randomUUID(), created_at: new Date().toISOString(), ...fields });
    }

    res.json({ success: true, error: null });
  } catch (error) {
    next(error);
  }
});

app.get('/api/mesures/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    const records = await queryAll(TABLES.mesuresAnthropometriques, { fields: FIELD_SETS.mesuresAnthropometriques });
    const record = latestByFieldValue(records, 'dossier_id', req.params.dossierId);
    res.json(record ? {
      id: field(record, 'uuid_source') || String(record.id),
      dossierId: field(record, 'dossier_id'),
      deboutHauteurCoude: toNumber(field(record, 'debout_hauteur_coude')),
      assisHauteurAssise: toNumber(field(record, 'assis_hauteur_assise')),
      assisProfondeurGenoux: toNumber(field(record, 'assis_profondeur_genoux')),
      assisHauteurCoudes: toNumber(field(record, 'assis_hauteur_coudes')),
      observations: stringValue(field(record, 'observations')),
    } : null);
  } catch (error) {
    next(error);
  }
});

app.put('/api/mesures/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierId = req.params.dossierId;
    const payload = req.body || {};
    const records = await queryAll(TABLES.mesuresAnthropometriques, { fields: FIELD_SETS.mesuresAnthropometriques });
    const dossierRecord = await ensureDossierRecord(dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    const existing = latestByFieldValue(records, 'dossier_id', field(dossierRecord, 'uuid_source'));
    const fields = {
      dossier_id: field(dossierRecord, 'uuid_source'),
      dossiers_id: Number(dossierRecord.id),
      debout_hauteur_coude: nullableString(payload.deboutHauteurCoude),
      assis_hauteur_assise: nullableString(payload.assisHauteurAssise),
      assis_profondeur_genoux: nullableString(payload.assisProfondeurGenoux),
      assis_hauteur_coudes: nullableString(payload.assisHauteurCoudes),
      observations: nullableString(payload.observations),
      updated_at: new Date().toISOString(),
    };

    if (existing) {
      if (sendConflictIfStale(req, res, existing)) return;
      await updateRecord(TABLES.mesuresAnthropometriques, existing.id, fields);
    } else {
      await createRecord(TABLES.mesuresAnthropometriques, { uuid_source: crypto.randomUUID(), created_at: new Date().toISOString(), ...fields });
    }

    res.json({ success: true, error: null });
  } catch (error) {
    next(error);
  }
});

app.get('/api/observations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    const records = await queryAll(TABLES.observations, { fields: FIELD_SETS.observations });
    const record = latestByFieldValue(records, 'dossier_id', req.params.dossierId);
    res.json(record ? {
      id: field(record, 'uuid_source') || String(record.id),
      dossierId: field(record, 'dossier_id'),
      observationEquipements: stringValue(field(record, 'observation_equipements')),
      projetSouhaitUsage: stringValue(field(record, 'projet_souhait_usage')),
      resumePreconisations: stringValue(field(record, 'resume_preconisations')),
    } : null);
  } catch (error) {
    next(error);
  }
});

app.put('/api/observations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierId = req.params.dossierId;
    const payload = req.body || {};
    const records = await queryAll(TABLES.observations, { fields: FIELD_SETS.observations });
    const dossierRecord = await ensureDossierRecord(dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    const existing = latestByFieldValue(records, 'dossier_id', field(dossierRecord, 'uuid_source'));
    const fields = {
      dossier_id: field(dossierRecord, 'uuid_source'),
      dossiers_id: Number(dossierRecord.id),
      observation_equipements: nullableString(payload.observationEquipements),
      projet_souhait_usage: nullableString(payload.projetSouhaitUsage),
      resume_preconisations: nullableString(payload.resumePreconisations),
    };

    if (existing) {
      if (sendConflictIfStale(req, res, existing)) return;
      await updateRecord(TABLES.observations, existing.id, fields);
    } else {
      await createRecord(TABLES.observations, { uuid_source: crypto.randomUUID(), ...fields });
    }

    res.json({ success: true, error: null });
  } catch (error) {
    next(error);
  }
});

app.get('/api/visit-recommendations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }

    const dossierId = field(dossierRecord, 'uuid_source');
    const tableId = await getVisitRecommendationsTableId();
    let items = [];

    if (tableId) {
      const records = await queryAll(tableId, {
        fields: VISIT_RECOMMENDATION_FIELDS,
        where: `(dossier_id,eq,${JSON.stringify(String(dossierId))})`,
      });
      items = records
        .map(mapVisitRecommendationRecord)
        .sort((left, right) => new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime());
    } else {
      const store = await readVisitRecommendationsStore();
      const payload = store.dossiers?.[dossierId];
      items = asArray(payload?.items).map((item) => ({
        ...item,
        wikiImageUrl: absoluteUrl(item?.wikiImageUrl),
      }));
    }

    const wikiItems = await loadWikiLibrary();
    const wikiLookup = buildWikiRecommendationLookup(wikiItems);
    items = items.map((item) => {
      const matchedWikiItem = resolveRecommendationWikiItem(item, wikiLookup);
      if (!matchedWikiItem) {
        return {
          ...item,
          wikiImageUrl: absoluteUrl(item?.wikiImageUrl),
        };
      }
      return {
        ...item,
        wikiItemId: stringValue(matchedWikiItem.id),
        wikiTitle: stringValue(matchedWikiItem.title),
        wikiImageUrl: stringValue(matchedWikiItem.imageUrl),
        wikiTag: stringValue(matchedWikiItem.tags?.[0] || item?.wikiTag),
      };
    });

    res.json({
      success: true,
      error: null,
      data: { items },
    });
  } catch (error) {
    next(error);
  }
});

app.put('/api/visit-recommendations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }

    const wikiItems = await loadWikiLibrary();
    const wikiLookup = buildWikiRecommendationLookup(wikiItems);
    const dossierId = field(dossierRecord, 'uuid_source');
    const rawItems = asArray(req.body?.items);

    const normalizedItems = rawItems.map((item) => {
      const normalized = normalizeVisitRecommendationItem(item, wikiLookup);
      if (!normalized.wikiItemId || !wikiLookup.byId.has(normalized.wikiItemId)) {
        throw new Error('Chaque préconisation doit être liée à une image de la bibliothèque');
      }
      return normalized;
    });

    const tableId = await getVisitRecommendationsTableId();

    if (tableId) {
      const metadata = await buildVisitRecommendationMetadata(dossierRecord);
      const existingRecords = await queryAll(tableId, {
        fields: ['uuid_source'],
        where: `(dossier_id,eq,${JSON.stringify(String(dossierId))})`,
      });

      for (const record of existingRecords) {
        await callNocoTool('deleteRecords', {
          tableId,
          records: [{ id: String(record.id) }],
        });
      }

      for (const item of normalizedItems) {
        await createRecord(tableId, {
          uuid_source: item.id,
          dossier_id: metadata.dossierId,
          beneficiaire_id: metadata.patientId,
          beneficiaire_prenom: metadata.patientFirstName || null,
          beneficiaire_nom: metadata.patientLastName || null,
          beneficiaire_nom_complet: metadata.patientDisplayName || null,
          dossier_libelle: metadata.dossierLabel || null,
          wiki_item_id: item.wikiItemId,
          wiki_title: item.wikiTitle || null,
          wiki_image_url: item.wikiImageUrl || null,
          wiki_tag: item.wikiTag || null,
          custom_title: item.customTitle || null,
          note: item.note || null,
          created_at: item.createdAt,
          updated_at: item.updatedAt,
        });
      }
    } else {
      const store = await readVisitRecommendationsStore();
      store.dossiers[dossierId] = {
        updatedAt: new Date().toISOString(),
        items: normalizedItems,
      };
      await writeVisitRecommendationsStore(store);
    }

    res.json({
      success: true,
      error: null,
      data: {
        items: normalizedItems.map((item) => ({
          ...item,
          wikiImageUrl: absoluteUrl(item.wikiImageUrl),
        })),
      },
    });
  } catch (error) {
    if (error instanceof Error && error.message.includes('bibliothèque')) {
      res.status(400).json({ success: false, error: error.message });
      return;
    }
    next(error);
  }
});

app.use((error, _req, res, _next) => {
  console.error('[nocodb-api]', error);
  res.status(Number(error?.statusCode) || 500).json({
    success: false,
    error: error instanceof Error ? error.message : 'Erreur serveur inconnue',
  });
});

app.use(express.static(DIST_DIR_PATH, {
  etag: false,
  lastModified: false,
  setHeaders: (res) => {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
  },
}));

app.use(async (req, res, next) => {
  if (req.path.startsWith('/api') || req.path.startsWith('/uploads')) {
    next();
    return;
  }

  try {
    const fs = await import('node:fs/promises');
    await fs.access(DIST_INDEX_PATH);
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');
    res.sendFile(DIST_INDEX_PATH);
  } catch (error) {
    next(error);
  }
});

const isDirectExecution = process.argv[1]
  ? path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
  : false;

const warmupRuntime = async () => {
  try {
    await loadMemberRegistry({ forceRefresh: true });
  } catch (error) {
    console.warn('[auth] Initialisation registre échouée au démarrage, fallback local actif.', error);
  }
};

await warmupRuntime();

if (isDirectExecution) {
  const server = app.listen(port, () => {
    console.log(`[nocodb-api] listening on http://127.0.0.1:${port}`);
  });

  const shutdown = async () => {
    server.close();
    await closeMcpClient();
    process.exit(0);
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

export default app;
