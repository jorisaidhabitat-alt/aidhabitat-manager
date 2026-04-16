import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import dotenv from 'dotenv';
import { callNocoTool, closeMcpClient } from './nocodbMcpClient.mjs';
import { createMobileSyncStore } from './mobileSyncStore.mjs';
import { getRetirementFundMeta } from './retirementFundsCatalog.mjs';
import { WIKI_FILTER_TAGS, WIKI_LIBRARY_SEED } from './wikiLibraryCatalog.mjs';

export { callNocoTool, closeMcpClient, getRetirementFundMeta, WIKI_FILTER_TAGS };
import { LOCAL_SESSION_TOKEN_PREFIX } from '../shared/localAuthProfiles.js';

dotenv.config({ path: '.env.local' });
dotenv.config();

export const port = Number(process.env.API_PORT || 3001);
export const SERVER_DIR_PATH = path.dirname(fileURLToPath(import.meta.url));
export const DIST_DIR_PATH = path.resolve(SERVER_DIR_PATH, '../dist');
export const DIST_INDEX_PATH = path.join(DIST_DIR_PATH, 'index.html');
export const LOCAL_DATA_DIR_PATH = fileURLToPath(new URL('./data/', import.meta.url));
export const DATA_DIR_PATH = process.env.VERCEL
  ? path.join('/tmp', 'aidhabitat-data')
  : LOCAL_DATA_DIR_PATH;
export const DATA_DIR_URL = pathToFileURL(DATA_DIR_PATH.endsWith(path.sep) ? DATA_DIR_PATH : `${DATA_DIR_PATH}${path.sep}`);
export const dataFileUrl = (relativePath) => new URL(relativePath, DATA_DIR_URL);
export const AUTH_STORE_URL = dataFileUrl('auth-store.json');
export const PROFILE_PHOTOS_DIR_URL = dataFileUrl('profile-photos/');
export const DOCUMENTS_DIR_URL = dataFileUrl('documents/');
export const VISIT_PLANS_DIR_URL = dataFileUrl('visit-plans/');
export const WIKI_LIBRARY_DIR_URL = dataFileUrl('wiki-library/');
export const DOCUMENT_STORE_URL = dataFileUrl('documents-store.json');
export const NOTE_PAGES_STORE_URL = dataFileUrl('note-pages-store.json');
export const RETIREMENT_FUNDS_STORE_URL = dataFileUrl('retirement-funds.json');
export const VISIT_RECOMMENDATIONS_STORE_URL = dataFileUrl('visit-recommendations.json');
export const VISIT_RECOMMENDATIONS_TABLE_NAME = process.env.NOCODB_VISIT_RECOMMENDATIONS_TABLE_NAME || 'mobile_visit_recommendations';
export const WIKI_LIBRARY_STORE_URL = dataFileUrl('wikiLibraryStatic.json');
export const BUNDLED_WIKI_LIBRARY_PATH = path.resolve(SERVER_DIR_PATH, '../data/wikiLibraryStatic.json');
export const AUTH_CACHE_TTL_MS = 30_000;
export const SESSION_TTL_MS = 1000 * 60 * 60 * 24 * 7;
export const ANAH_STATUS_TTL_MS = 60_000;
export const ANAH_PUBLIC_URL = 'https://www.anah.gouv.fr/';
export const ANAH_REGISTRATION_URL = 'https://monprojet.anah.gouv.fr/';
export const APP_PUBLIC_BASE_URL = String(process.env.APP_PUBLIC_BASE_URL || '').trim().replace(/\/+$/, '')
  || (process.env.VERCEL_URL ? `https://${String(process.env.VERCEL_URL).trim()}` : '');
export const LOCALHOST_URL_PATTERN = /^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//i;
export const PROJECT_VERCEL_HOST_PATTERN = /^aid-habitat-manager(?:-[a-z0-9-]+)?\.vercel\.app$/i;
export let anahStatusCache = null;
export let bundledWikiItemsCache = null;

export const MEMBER_PROFILES = {
  'contact@aidhabitat.fr': { displayName: 'Renan', role: 'ADMIN', selectable: false, establishmentId: null, establishmentLabel: '' },
  'joris.aidhabitat@gmail.com': { displayName: 'Coralie', role: 'ERGO', selectable: true, establishmentId: 2, establishmentLabel: "Aid'habitat" },
  'joris.balluais@gmail.com': { displayName: 'Christelle', role: 'ERGO', selectable: true, establishmentId: 2, establishmentLabel: "Aid'habitat" },
};
export const BENEFICIARY_TRUSTED_EMAIL_FIELD_ID = 'c8s1kh1eqqx6xl6';
export const DEFAULT_LEGACY_ERGO_EMAIL = 'joris.aidhabitat@gmail.com';
export let memberRegistryCache = null;

export const TABLES = {
  beneficiaires: 'muvp56d5i9z2qbe',
  logements: 'mgdpvdrnzyy6n4k',
  dossiers: 'mez74y7ndoej30p',
  observations: 'mbkuomk0aazes1c',
  diagnosticSanitaires: 'mdukulxcd18ae3o',
  mesuresAnthropometriques: 'mbaj91z97utreco',
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

export const FIELD_SETS = {
  beneficiaires: [
    'prenom', 'nom', 'prenom_occupant_2', 'nom_occupant_2', 'occupants_json', 'adresse_logement', 'ville_libre', 'code_postal_libre', 'commune', 'communes_id', 'code_postal',
    'telephone', 'mail', 'date_naissance_monsieur', 'date_naissance_madame', 'date_visite',
    'situation_proprietaire', 'statut_occupation', 'nombre_personnes', 'categorie_revenu_calculee',
    'revenu_fiscal_reference', 'beneficiaire_apa', 'reconnaissance_invalidite_mdph',
    'reconnaissance_invalidité_mdph_txt', 'aide_a_domicile', 'aide_a_domicile_txt',
    'dependance_particuliere', 'dependance_particuliere_txt', 'personne_confiance',
    'telephone_personne_confiance', 'mail_personne_confiance', BENEFICIARY_TRUSTED_EMAIL_FIELD_ID, 'numero_securite_sociale_monsieur',
    'numero_securite_sociale_madame', 'caisse_retraite_principale', 'caisse_retraite_secondaire',
    'CreatedAt',
  ],
  dossiers: [
    'uuid_source', 'patient_id', 'beneficiaires_id', 'status', 'ergo_id', 'visit_date', 'compte_anah',
    'nature_accompagnement', 'envoi_rapport', 'personnes_presentes_visite', 'created_at', 'CreatedAt',
  ],
  logements: [
    'uuid_source', 'beneficiaire_id', 'beneficiaires_id', 'type_de_logement', 'annee_construction', 'annee_habitation',
    'surface_habitable', 'nombre_niveaux', 'sous_sol', 'description_sous_sol', 'rdc', 'description_rdc',
    'etage', 'description_etage', 'garage', 'veranda', 'balcon', 'terrasse', 'jardin', 'chauffage',
    'radiateurs_electrique', 'chaudiere_gaz', 'chaudiere_fioul', 'pompe_a_chaleur', 'chaudiere_collective',
    'cheminee_pole_bois', 'poele_granules', 'autre_chauffage', 'volets_roulants_manuels_localisation',
    'volets_roulants_manuels_entier', 'volets_roulants_electriques_localisation',
    'volets_roulants_electriques_entier', 'volets_persiennes_localisation', 'volets_persiennes_entier',
    'cheminement_escalier_exterieur', 'cheminement_escalier_interieur', 'cheminement_pente_douce',
    'cheminement_plat', 'cheminement_quelques_marches', 'cheminement_par_arriere', 'cheminement_seuil_porte',
    'difficultes_circulation_interieure', 'porte_de_garage', 'portail', 'acces_facile_rue',
    'commentaire', 'observation_accessibilite',
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
    'observation_equipements_utilisation', 'sdb_instances_json', 'wc_instances_json',
  ],
  mesuresAnthropometriques: [
    'uuid_source', 'dossier_id', 'debout_hauteur_coude', 'assis_hauteur_assise', 'assis_profondeur_genoux',
    'assis_hauteur_coudes', 'observations',
  ],
  observations: ['uuid_source', 'dossier_id', 'observation_equipements', 'projet_souhait_usage', 'resume_preconisations'],
  referencesLibelle: ['libelle'],
  referencesNom: ['nom'],
  ergotherapeutes: ['uuid_source', 'nom', 'prenom', 'email', 'user_id', 'nom_etablissement_id', 'User', 'etablissements_id', 'etablissement'],
  communes: ['nom', 'code_postal', 'epci_id1', 'epci'],
  baremesAnah: ['libelle', 'nombre_personnes', 'annee_plafond'],
  caissesRetraiteComplementaires: ['nom', 'numero_telephone_contact', 'aide_complementaire'],
  wikiTags: ['uuid_source', 'tags'],
  wiki: ['uuid_source', 'titre', 'photos', 'contenu', 'wiki_tags_id', 'wiki_tags'],
};

export const AUTONOMY_ITEMS = [
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

export const VISIT_RECOMMENDATION_FIELDS = [
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
  'note',
  'created_at',
  'updated_at',
];

export const asArray = (value) => Array.isArray(value) ? value : [];
export const field = (record, name) => record?.fields?.[name];
export const firstDefined = (...values) => values.find((value) => value !== undefined);
export const stringValue = (value) => value == null ? '' : String(value);
export const safeParseJsonArray = (value) => {
  try {
    const parsed = JSON.parse(stringValue(value) || '[]');
    return asArray(parsed).map((entry) => String(entry));
  } catch {
    return [];
  }
};
export const normalizeEmail = (value) => String(value || '').trim().toLowerCase();
export const nullableString = (value) => value == null || value === '' ? null : String(value);
export const absoluteUrl = (value) => {
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
export const resolveClientMediaUrl = (value) => {
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
export const withTimeout = async (promiseFactory, timeoutMs = 5000) => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await promiseFactory(controller.signal);
  } finally {
    clearTimeout(timeout);
  }
};
export const toNumber = (value) => {
  if (value == null || value === '') return undefined;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
};
export const toBool = (value) => {
  if (typeof value === 'boolean') return value;
  if (value == null) return false;
  return ['true', '1', 'yes', 'oui', 'x'].includes(String(value).trim().toLowerCase());
};
export const boolText = (value) => String(Boolean(value));
export const httpError = (statusCode, message) => Object.assign(new Error(message), { statusCode });
export const latestRecord = (records) => {
  const sorted = [...records].sort((a, b) => {
    const aDate = new Date(field(a, 'UpdatedAt') || field(a, 'updated_at') || field(a, 'created_at') || 0).getTime();
    const bDate = new Date(field(b, 'UpdatedAt') || field(b, 'updated_at') || field(b, 'created_at') || 0).getTime();
    if (aDate !== bDate) return bDate - aDate;
    return Number(b.id) - Number(a.id);
  });
  return sorted[0];
};
export const normalizeOccupation = (label) => label?.startsWith('Usufruitier') ? 'Usufruitier' : (label || '');

export const parseOccupantsJson = (rawValue) => {
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
export const filterValue = (value) => `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
export const unwrapRecordFields = (record) => (
  record && typeof record === 'object' && record.fields && typeof record.fields === 'object'
    ? record.fields
    : record
);

export const refLabel = (record) => {
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

export const groupBy = (records, key) => {
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

export const findByUuidSource = (records, sourceId) => records.find((record) => field(record, 'uuid_source') === sourceId);
export const findByFieldValue = (records, fieldName, value) => records.find((record) => field(record, fieldName) === value);
export const findByRecordId = (records, recordId) => records.find((record) => String(record.id) === String(recordId));
export const latestByFieldValue = (records, fieldName, value) => latestRecord(
  records.filter((record) => String(field(record, fieldName) ?? '') === String(value ?? ''))
);
export const normalizeLabelForMatch = (value) => String(value || '')
  .normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/[''`()/-]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();
export const findByLabel = (records, value) => {
  if (!value) return undefined;
  const normalized = normalizeLabelForMatch(value);
  if (!normalized) return undefined;
  return records.find((record) => normalizeLabelForMatch(refLabel(record)) === normalized)
    || records.find((record) => normalizeLabelForMatch(refLabel(record)).startsWith(normalized));
};
export const normalizeCommuneKey = (value) => String(value || '')
  .normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/[''`-]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();
export const findCommuneMatch = (records, city, zipCode) => {
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
export const resolveCommuneMatch = async (city, zipCode, fallbackRecords = []) => {
  return findCommuneMatch(fallbackRecords, city, zipCode);
};
export const specialMemberProfile = (email) => MEMBER_PROFILES[normalizeEmail(email)];
export const splitDisplayName = (displayName) => {
  const parts = String(displayName || '').trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { prenom: '', nom: '' };
  if (parts.length === 1) return { prenom: parts[0], nom: '' };
  return { prenom: parts.slice(0, -1).join(' '), nom: parts.at(-1) };
};
export const randomSecret = (size = 48) => crypto.randomBytes(size).toString('base64url');
export const hashPassword = (password, salt) => crypto.scryptSync(String(password), salt, 64).toString('hex');
export const generatePassword = (displayName) => {
  const base = String(displayName || 'AidHabitat').replace(/[^a-z0-9]/gi, '').slice(0, 8) || 'AidHab';
  return `${base}-${crypto.randomBytes(4).toString('hex')}`;
};
export const encodeBase64Url = (payload) => Buffer.from(JSON.stringify(payload)).toString('base64url');
export const decodeBase64Url = (payload) => JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
export const decodeLocalAuthEmail = (token) => {
  if (!String(token || '').startsWith(LOCAL_SESSION_TOKEN_PREFIX)) return null;
  const rawPayload = String(token).slice(LOCAL_SESSION_TOKEN_PREFIX.length).trim();
  if (!rawPayload) return null;
  try {
    return Buffer.from(rawPayload, 'base64').toString('utf8');
  } catch {
    return rawPayload;
  }
};
export const getTokenFromRequest = (req) => {
  const header = req.get('authorization') || '';
  if (header.toLowerCase().startsWith('bearer ')) {
    return header.slice(7).trim();
  }
  return String(req.get('x-app-session') || '').trim();
};
export const syntheticBeneficiaryId = (recordId) => `nocodb-beneficiaire-${recordId}`;
export const parseSyntheticBeneficiaryId = (value) => {
  const match = String(value || '').match(/^nocodb-beneficiaire-(\d+)$/);
  return match ? Number(match[1]) : null;
};
export const mobileSyncStore = createMobileSyncStore({ absoluteUrl });
export const deriveBeneficiaryAppId = ({ beneficiaryRecord, dossierRecords = [], housingRecords = [], contextRecords = [], infoRecords = [] }) => {
  const relatedExternalId = [
    latestRecord(dossierRecords) ? field(latestRecord(dossierRecords), 'patient_id') : undefined,
    latestRecord(housingRecords) ? field(latestRecord(housingRecords), 'beneficiaire_id') : undefined,
    latestRecord(contextRecords) ? field(latestRecord(contextRecords), 'beneficiaire_id') : undefined,
    latestRecord(infoRecords) ? field(latestRecord(infoRecords), 'beneficiaire_id') : undefined,
  ].find(Boolean);

  return String(relatedExternalId || syntheticBeneficiaryId(beneficiaryRecord.id));
};
export const resolveBeneficiaryRecord = ({ beneficiaires, dossiers = [], logements = [], contextes = [], infosAdmin = [], appBeneficiaryId }) => {
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

export const parseChecklistDone = (contextRecord) => {
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

export const safeSlug = (value, fallback = 'item') => {
  const normalized = String(value || '')
    .trim()
    .replace(/[^a-z0-9._-]+/gi, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .toLowerCase();
  return normalized || fallback;
};

export const buildRetirementFundLogoDataUri = (name) => {
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

export const normalizeRetirementFundPayload = (fund) => {
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

export const buildRetirementFundResponse = (fund) => {
  const meta = getRetirementFundMeta(fund?.name || '');
  const normalized = normalizeRetirementFundPayload(fund);
  return {
    ...normalized,
    name: normalized.name || meta?.displayName || '',
    phone: normalized.phone || meta?.contactPhone || '',
    audience: normalized.audience || meta?.audience || '',
    requestMethod: normalized.requestMethod || meta?.requestMethod || 'Procédure à confirmer auprès de l\u2019organisme.',
    requestDelay: normalized.requestDelay || meta?.requestDelay || 'Délai à confirmer.',
    aidAmount: normalized.aidAmount || meta?.aidAmount || '',
    therapistNote: normalized.therapistNote || meta?.therapistNote || '',
    website: normalized.website || meta?.website || '',
    logoUrl: normalized.logoUrl || meta?.logoUrl || buildRetirementFundLogoDataUri(normalized.name || meta?.displayName || 'Caisse'),
  };
};

export const safeFileName = (value, fallback = 'document.bin') => {
  const normalized = String(value || '')
    .trim()
    .replace(/[/\\?%*:|"<>]+/g, '-')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
  return normalized || fallback;
};

export const inferExtensionFromMimeType = (mimeType) => ({
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'application/pdf': 'pdf',
})[String(mimeType || '').trim().toLowerCase()] || 'bin';

export const decodeBase64FilePayload = ({ contentBase64, mimeType }) => {
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

export const mapMedicalContext = (contextRecord) => {
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

export const readAuthStore = async () => {
  try {
    const raw = await fs.readFile(AUTH_STORE_URL, 'utf8');
    const parsed = JSON.parse(raw);
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
      secret: parsed.secret || randomSecret(),
      users,
      pendingCredentials: parsed.pendingCredentials || {},
    };
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
    return {
      version: 1,
      secret: randomSecret(),
      users: {},
      pendingCredentials: {},
    };
  }
};

export const writeAuthStore = async (store) => {
  await fs.mkdir(DATA_DIR_URL, { recursive: true });
  await fs.writeFile(AUTH_STORE_URL, JSON.stringify(store, null, 2));
};

export const readJsonStore = async (storeUrl, fallbackValue) => {
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

export const writeJsonStore = async (storeUrl, payload) => {
  await fs.mkdir(DATA_DIR_URL, { recursive: true });
  await fs.writeFile(storeUrl, JSON.stringify(payload, null, 2));
};

export const readDocumentStore = async () => {
  const store = await readJsonStore(DOCUMENT_STORE_URL, { version: 1, documents: [] });
  return {
    version: 1,
    documents: asArray(store.documents),
  };
};

export const writeDocumentStore = async (store) => {
  await writeJsonStore(DOCUMENT_STORE_URL, {
    version: 1,
    documents: asArray(store.documents),
  });
};

export const readNotePagesStore = async () => {
  const store = await readJsonStore(NOTE_PAGES_STORE_URL, { version: 1, notePages: [] });
  return {
    version: 1,
    notePages: asArray(store.notePages),
  };
};

export const writeNotePagesStore = async (store) => {
  await writeJsonStore(NOTE_PAGES_STORE_URL, {
    version: 1,
    notePages: asArray(store.notePages),
  });
};

export const readRetirementFundsStore = async () => {
  const store = await readJsonStore(RETIREMENT_FUNDS_STORE_URL, { version: 1, funds: {}, customFunds: [] });
  return {
    version: 1,
    funds: store.funds && typeof store.funds === 'object' ? store.funds : {},
    customFunds: asArray(store.customFunds).map((fund) => normalizeRetirementFundPayload(fund)).filter((fund) => fund.name),
  };
};

export const writeRetirementFundsStore = async (store) => {
  await writeJsonStore(RETIREMENT_FUNDS_STORE_URL, {
    version: 1,
    funds: store.funds || {},
    customFunds: asArray(store.customFunds).map((fund) => normalizeRetirementFundPayload(fund)),
  });
};

export const normalizeVisitRecommendationItem = (item, wikiMap = new Map()) => {
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

export const readVisitRecommendationsStore = async () => {
  const store = await readJsonStore(VISIT_RECOMMENDATIONS_STORE_URL, { version: 1, dossiers: {} });
  return {
    version: 1,
    dossiers: store.dossiers && typeof store.dossiers === 'object' ? store.dossiers : {},
  };
};

export const writeVisitRecommendationsStore = async (store) => {
  await writeJsonStore(VISIT_RECOMMENDATIONS_STORE_URL, {
    version: 1,
    dossiers: store.dossiers && typeof store.dossiers === 'object' ? store.dossiers : {},
  });
};

export const loadBundledWikiItems = async () => {
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

export const readWikiLibraryStore = async () => {
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

export const writeWikiLibraryStore = async (store) => {
  await writeJsonStore(WIKI_LIBRARY_STORE_URL, {
    version: 1,
    items: asArray(store.items),
  });
};

export const resolveWikiPrimaryTag = ({ title, description, category, tags }) => {
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

export const normalizeWikiItemPayload = (item) => ({
  ...item,
  title: stringValue(item.title),
  description: stringValue(item.description),
  imageUrl: stringValue(item.imageUrl),
  category: stringValue(item.category) || 'Autre',
  tags: [resolveWikiPrimaryTag(item)],
});

export const normalizeLookupKey = (value) => stringValue(value)
  .normalize('NFD')
  .replace(/[\u0300-\u036f]/g, '')
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, ' ')
  .trim();

export const mediaFileNameKey = (value) => {
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

export const buildWikiRecommendationLookup = (wikiItems = []) => {
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

export const fuzzyMatchWikiItem = (title, wikiItems = []) => {
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

export const resolveRecommendationWikiItem = (item, lookup) => {
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

export const parseWikiContent = (value) => {
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

export const serializeWikiContent = ({ description, category, tags }) => JSON.stringify({
  description: stringValue(description),
  category: stringValue(category) || 'Autre',
  tags: asArray(tags).slice(0, 1).map((tag) => String(tag)),
});

export const parseJsonArrayField = (value) => {
  const raw = stringValue(value).trim();
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
};

export const buildLegacyBathroomInstances = (payload) => {
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

export const buildLegacyWcInstances = (payload) => {
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

export const mapWikiLibraryItem = (item) => ({
  id: String(item.id),
  title: stringValue(item.title),
  description: stringValue(item.description),
  imageUrl: String(item.imageUrl || '').startsWith('/wiki-') ? String(item.imageUrl) : absoluteUrl(item.imageUrl),
  tags: normalizeWikiItemPayload(item).tags,
  category: stringValue(item.category) || 'Autre',
  createdAt: item.createdAt,
  updatedAt: item.updatedAt,
});

export const mapWikiRecordToItem = (record) => {
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

export const ensureWikiTagsInNocodb = async (tagNames, existingTagRecords = null) => {
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

export const cleanupWikiTagsInNocodb = async (tagRecords, wikiRecords) => {
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

export const syncLocalWikiStoreToNocodb = async () => {
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

export const loadWikiLibrary = async () => {
  const localStore = await readWikiLibraryStore();

  try {
    await syncLocalWikiStoreToNocodb();
  } catch (error) {
    console.error('Wiki sync failed, serving local library', error);
  }

  return localStore.items.map(mapWikiLibraryItem).sort((a, b) => a.title.localeCompare(b.title));
};

export const readAnahStatus = async ({ forceRefresh = false } = {}) => {
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

export const syncRecordFieldsLocally = (record, updates) => {
  if (!record?.fields) return;
  record.fields = { ...record.fields, ...updates };
};

export const backfillChildDossierLinks = async ({ tableId, records, dossiers, beneficiaryField = 'beneficiaires_id' }) => {
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

export const createBlankDossierForBeneficiary = async ({ beneficiaryRecord, dossiers, logements, contextes, infosAdmin }) => {
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

export const ensureDossiersForBeneficiaries = async ({ beneficiaires, dossiers, logements, contextes, infosAdmin }) => {
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

export const mapHousing = (housingRecord) => {
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

export const mapPatient = (beneficiaryRecord, appBeneficiaryId) => ({
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
    email: stringValue(firstDefined(
      field(beneficiaryRecord, 'mail_personne_confiance'),
      field(beneficiaryRecord, BENEFICIARY_TRUSTED_EMAIL_FIELD_ID),
    )),
  },
  numeroSecuriteSocialeMonsieur: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_monsieur')),
  numeroSecuriteSocialeMadame: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_madame')),
  occupant1SocialSecurityNumber: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_monsieur')),
  occupant2SocialSecurityNumber: stringValue(field(beneficiaryRecord, 'numero_securite_sociale_madame')),
  caisseRetraitePrincipale: refLabel(field(beneficiaryRecord, 'caisse_retraite_principale')),
  caissesRetraiteComplementaires: refLabel(field(beneficiaryRecord, 'caisse_retraite_secondaire')),
});

export const createVirtualDossier = (beneficiaryRecord, appBeneficiaryId, housingRecord, contextRecord, dossierRecord, infoRecord) => ({
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

export const createDossier = (beneficiaryRecord, appBeneficiaryId, dossierRecord, housingRecord, contextRecord, infoRecord) => ({
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

export const queryAll = async (tableId, options = {}) => {
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

export const updateRecord = async (tableId, id, fields) => {
  await callNocoTool('updateRecords', {
    tableId,
    records: [{ id: String(id), fields }],
  });
};

export const createRecord = async (tableId, fields) => {
  const payload = await callNocoTool('createRecords', {
    tableId,
    records: [{ fields }],
  });

  const created = asArray(payload).at(0) || asArray(payload?.records).at(0);
  return created;
};

export let visitRecommendationsTableIdCache = null;

export const discoverTableIdByTitle = async (tableTitle) => {
  const payload = await callNocoTool('getTablesList');
  const tables = asArray(payload);
  const match = tables.find((table) => String(table.title).trim().toLowerCase() === String(tableTitle).trim().toLowerCase());
  return match ? String(match.id) : null;
};

export const getVisitRecommendationsTableId = async () => {
  if (visitRecommendationsTableIdCache) {
    return visitRecommendationsTableIdCache;
  }

  const tableId = await discoverTableIdByTitle(VISIT_RECOMMENDATIONS_TABLE_NAME);
  if (tableId) {
    visitRecommendationsTableIdCache = tableId;
  }
  return tableId;
};

export const buildVisitRecommendationMetadata = async (dossierRecord) => {
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

export const mapVisitRecommendationRecord = (record) => ({
  id: stringValue(field(record, 'uuid_source')) || String(record.id || ''),
  wikiItemId: stringValue(field(record, 'wiki_item_id')),
  wikiTitle: stringValue(field(record, 'wiki_title')),
  wikiImageUrl: absoluteUrl(field(record, 'wiki_image_url')),
  wikiTag: stringValue(field(record, 'wiki_tag')),
  note: stringValue(field(record, 'note')),
  createdAt: field(record, 'created_at') || field(record, 'updated_at') || new Date().toISOString(),
  updatedAt: field(record, 'updated_at') || field(record, 'created_at') || new Date().toISOString(),
});

export const buildMemberFromErgoRecord = (record) => {
  const email = normalizeEmail(field(record, 'email') || asArray(field(record, 'User')).at(0)?.email);
  if (!email) return null;
  const special = specialMemberProfile(email);
  const derivedName = special?.displayName || refLabel(record) || email;
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
  };
};

export const buildFallbackMemberFromProfile = ([email, profile]) => ({
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

export const buildFallbackMembers = () => (
  Object.entries(MEMBER_PROFILES)
    .map(buildFallbackMemberFromProfile)
    .sort((a, b) => a.displayName.localeCompare(b.displayName))
);

export const resolveStoredProfilePhotoUrl = (store, email) => {
  const rawValue = stringValue(store?.users?.[email]?.profilePhotoUrl).trim();
  return rawValue ? resolveClientMediaUrl(rawValue) : '';
};

export const parseImageDataUrl = (dataUrl) => {
  const match = String(dataUrl || '').match(/^data:(image\/[a-zA-Z0-9.+-]+);base64,(.+)$/);
  if (!match) {
    throw new Error('Format d\u2019image invalide');
  }

  const mimeType = match[1].toLowerCase();
  const extension = ({
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
    'image/gif': 'gif',
  })[mimeType];

  if (!extension) {
    throw new Error('Format d\u2019image non supporté');
  }

  return {
    mimeType,
    extension,
    buffer: Buffer.from(match[2], 'base64'),
  };
};

export const getVisitPlanRelativeUrl = (dossierId) => {
  const folderName = safeSlug(dossierId, 'dossier');
  return `/uploads/visit-plans/${folderName}/plan_logement.png`;
};

export const getVisitPlanFileUrl = (dossierId) => {
  const folderName = safeSlug(dossierId, 'dossier');
  return new URL(`${folderName}/plan_logement.png`, VISIT_PLANS_DIR_URL);
};

export const readVisitPlanMeta = async (dossierId) => {
  const targetUrl = getVisitPlanFileUrl(dossierId);
  try {
    const stats = await fs.stat(targetUrl);
    return {
      publicUrl: getVisitPlanRelativeUrl(dossierId),
      updatedAt: stats.mtime.toISOString(),
    };
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return { publicUrl: null, updatedAt: null };
    }
    throw error;
  }
};

export const syncPresetMembersInErgos = async () => {
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

export const loadMemberRegistry = async ({ forceRefresh = false } = {}) => {
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

export const loadMemberRegistryForAuth = async () => {
  if (memberRegistryCache?.value) {
    return memberRegistryCache.value;
  }

  try {
    const store = await readAuthStore();
    const members = buildFallbackMembers().map((member) => ({
      ...member,
      profilePhotoUrl: resolveStoredProfilePhotoUrl(store, member.email) || member.profilePhotoUrl || '',
    }));
    return { members, store };
  } catch (error) {
    console.error('[auth] Impossible de charger le registre local, utilisation du fallback mémoire.', error);
    return {
      members: buildFallbackMembers(),
      store: {
        version: 1,
        secret: randomSecret(),
        users: {},
        pendingCredentials: {},
      },
    };
  }
};

export const signSessionToken = async (email) => {
  const { store } = await loadMemberRegistryForAuth();
  const payload = {
    email,
    exp: Date.now() + SESSION_TTL_MS,
  };
  const encodedPayload = encodeBase64Url(payload);
  const signature = crypto.createHmac('sha256', store.secret).update(encodedPayload).digest('base64url');
  return `${encodedPayload}.${signature}`;
};

export const resolveSessionUser = async (req) => {
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

export const getAdminAccessMembers = async () => {
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

export const buildLocalAccessScopes = (member) => {
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

export const buildLocalAuthUserPayload = (member) => ({
  email: member.email,
  displayName: member.displayName,
  role: member.role,
  establishmentId: member.establishmentId ? String(member.establishmentId) : '',
  ergoLabel: member.ergoLabel || '',
  isActive: true,
  scopes: buildLocalAccessScopes(member),
});

export const resolveRequestedErgoLabel = async (appUser, requestedErgoLabel) => {
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

export const canAccessDossierRecord = (appUser, dossierRecord) => {
  if (appUser?.role === 'ADMIN') return true;
  return stringValue(field(dossierRecord, 'ergo_id')).trim() === stringValue(appUser?.ergoLabel).trim();
};

export const resolveBeneficiaryAccess = async (appUser, patientId) => {
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
    throw httpError(403, 'Accès interdit à ce bénéficiaire');
  }

  return {
    beneficiaryRecord,
    dossierRecord,
  };
};

export const mapStoredDocument = (document) => ({
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

export const buildBeneficiaryDocumentContext = ({ beneficiaryRecord, dossierRecord, patientId }) => {
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

export const mapStoredNotePage = (notePage) => ({
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

export const escapeHtml = (value) => String(value || '')
  .replace(/&/g, '&amp;')
  .replace(/</g, '&lt;')
  .replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;')
  .replace(/'/g, '&#39;');

export const formatBeneficiaryDisplayName = (beneficiaryRecord) => {
  const firstName = stringValue(field(beneficiaryRecord, 'prenom')).trim();
  const lastName = stringValue(field(beneficiaryRecord, 'nom')).trim();
  return [firstName, lastName].filter(Boolean).join(' ').trim();
};

export const backfillLegacyDossierAssignments = async (dossiers) => {
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

export const getReferences = async (appUser) => {
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

export const getDossiersForApp = async (appUser) => {
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

export const ensureDossierRecord = async (dossierIdOrTemp) => {
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

export const upsertContexte = async (
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

export const sanitizeUndefined = (fields) => Object.fromEntries(
  Object.entries(fields).filter(([, value]) => value !== undefined)
);

export let beneficiaryReferenceSetsCache = null;
export let beneficiaryReferenceSetsCachedAt = 0;
export const BENEFICIARY_REFERENCE_CACHE_TTL_MS = 5 * 60 * 1000;

export const loadBeneficiaryReferenceSets = async () => {
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

export const selectBaremeAnah = (records, householdSize) => {
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

export const mapBeneficiaryUpdatesToFields = (updates, references) => {
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
    situation_proprietaire_id1: has('familySituation') ? (situationMatch ? Number(situationMatch.id) : null) : undefined,
    statut_occupation_id1: has('occupationStatus') ? (occupationMatch ? Number(occupationMatch.id) : null) : undefined,
    nombre_personnes: has('numberPeople') ? updates.numberPeople : undefined,
    categorie_revenu_id1: has('numberPeople') ? (baremeMatch ? Number(baremeMatch.id) : null) : undefined,
    revenu_fiscal_reference: has('fiscalRevenue') ? updates.fiscalRevenue : undefined,
    beneficiaire_apa: has('apa') ? updates.apa : undefined,
    reconnaissance_invalidite_mdph: has('invalidity') ? updates.invalidity : undefined,
    reconnaissance_invalidité_mdph_txt: has('invalidityTxt') ? nullableString(updates.invalidityTxt) : undefined,
    aide_a_domicile: has('homeHelp') ? updates.homeHelp : undefined,
    aide_a_domicile_txt: has('homeHelpTxt') ? nullableString(updates.homeHelpTxt) : undefined,
    dependance_particuliere_txt: has('dependenceTxt') ? nullableString(updates.dependenceTxt) : undefined,
    dependances_particulieres_id: has('dependenceTxt') ? (dependenceMatch ? Number(dependenceMatch.id) : null) : undefined,
    personne_confiance: trustedPersonNameValue === undefined ? undefined : nullableString(trustedPersonNameValue),
    telephone_personne_confiance: trustedPersonPhoneValue === undefined ? undefined : nullableString(trustedPersonPhoneValue),
    mail_personne_confiance: trustedPersonEmailValue === undefined ? undefined : nullableString(trustedPersonEmailValue),
    numero_securite_sociale_monsieur: has('occupant1SocialSecurityNumber')
      ? nullableString(updates.occupant1SocialSecurityNumber)
      : (has('numeroSecuriteSocialeMonsieur') ? nullableString(updates.numeroSecuriteSocialeMonsieur) : undefined),
    numero_securite_sociale_madame: has('occupant2SocialSecurityNumber')
      ? nullableString(updates.occupant2SocialSecurityNumber)
      : (has('numeroSecuriteSocialeMadame') ? nullableString(updates.numeroSecuriteSocialeMadame) : undefined),
    caisses_de_retraite_id: has('caisseRetraitePrincipale') ? (caisseMatch ? Number(caisseMatch.id) : null) : undefined,
    caisses_de_retraite_complementaires_id: has('caissesRetraiteComplementaires') ? (caisseCompMatch ? Number(caisseCompMatch.id) : null) : undefined,
  });
};

export const initializeRuntimeStores = async () => {
  await fs.mkdir(DATA_DIR_URL, { recursive: true });
  await fs.mkdir(PROFILE_PHOTOS_DIR_URL, { recursive: true });
  await fs.mkdir(DOCUMENTS_DIR_URL, { recursive: true });
  await fs.mkdir(VISIT_PLANS_DIR_URL, { recursive: true });
  await fs.mkdir(WIKI_LIBRARY_DIR_URL, { recursive: true });
};

export let bundledDataBootstrapPromise = null;

export const bootstrapBundledDataForRuntime = async () => {
  if (!process.env.VERCEL) {
    return;
  }

  const targetAuthStorePath = AUTH_STORE_URL.pathname;
  const bundledAuthStorePath = new URL('./data/auth-store.json', import.meta.url).pathname;

  try {
    await fs.access(targetAuthStorePath);
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      throw error;
    }

    try {
      await fs.cp(LOCAL_DATA_DIR_PATH, DATA_DIR_PATH, {
        recursive: true,
        force: false,
        errorOnExist: false,
      });
      return;
    } catch (copyError) {
      console.warn('[runtime] Copie initiale des données embarquées impossible.', copyError);
    }
  }

  try {
    await fs.access(targetAuthStorePath);
  } catch {
    try {
      await fs.copyFile(bundledAuthStorePath, targetAuthStorePath);
    } catch (copyError) {
      console.warn('[runtime] Copie du auth-store embarqué impossible.', copyError);
    }
  }

  const bundledProfilePhotosPath = new URL('./data/profile-photos/', import.meta.url).pathname;
  try {
    const currentPhotos = await fs.readdir(PROFILE_PHOTOS_DIR_URL);
    if (currentPhotos.length > 0) {
      return;
    }
  } catch {
    // Continue with copy attempt.
  }

  try {
    await fs.cp(bundledProfilePhotosPath, PROFILE_PHOTOS_DIR_URL.pathname, {
      recursive: true,
      force: false,
      errorOnExist: false,
    });
  } catch (copyError) {
    console.warn('[runtime] Copie des photos de profil embarquées impossible.', copyError);
  }
};

export const warmupRuntime = async () => {
  await initializeRuntimeStores();
  if (!bundledDataBootstrapPromise) {
    bundledDataBootstrapPromise = bootstrapBundledDataForRuntime().catch((error) => {
      console.warn('[runtime] Initialisation des données embarquées impossible.', error);
    });
  }
  await bundledDataBootstrapPromise;
  try {
    await loadMemberRegistry({ forceRefresh: true });
  } catch (error) {
    console.warn('[auth] Initialisation registre échouée au démarrage, fallback local actif.', error);
  }
};
