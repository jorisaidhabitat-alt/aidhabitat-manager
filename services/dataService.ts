import { AdminAccessMember, AnahStatus, AppDocument, AppUser, Dossier, DossierStatus, HousingType, HeatingMode, NotePage, OccupantIdentity, Patient, Visit, Housing, DiagnosticSanitaires, MesuresAnthropometriques, ObservationsSynthese, RetirementFund, VisitRecommendationItem, WikiLibraryItem } from '../types';
import { profilsAutorises, nocoDbTokensParEmail, LOCAL_SESSION_TOKEN_PREFIX } from '../shared/localAuthProfiles.js';
import { queueReleveForSync } from './releveSync';

// Simple debug logger
const debugLog = (msg: string) => {
  console.log(`[DataService] ${msg}`);
};

const APP_SESSION_TOKEN_KEY = 'aidhabitat.app_session';
const APP_LOCAL_USER_KEY = 'aidhabitat.app_user';
const NOCODB_TOKEN_STORAGE_KEY = 'aidhabitat.nocodb_token';
const RETIREMENT_FUNDS_CACHE_KEY = 'aidhabitat.retirement_funds_cache';
const BENEFICIARY_PATCHES_CACHE_KEY = 'aidhabitat.beneficiary_patches.v1';
const LOCAL_DOCUMENTS_CACHE_KEY = 'aidhabitat.documents.cache.v1';
const LOCAL_DOCUMENT_QUEUE_KEY = 'aidhabitat.documents.queue.v1';
const LOCAL_DOCUMENT_BLOB_CACHE_NAME = 'aidhabitat.documents.blobs.v1';
const NOTES_OFFLINE_DB_NAME = 'aidhabitat.notes.offline';
const NOTES_OFFLINE_DB_VERSION = 1;
const NOTES_PAGES_STORE_NAME = 'note_pages';
const NOTES_QUEUE_STORE_NAME = 'note_pages_sync_queue';

export const formatCityLabel = (value: unknown): string => {
  if (typeof value !== 'string') return 'Ville non renseignée';
  const trimmed = value.trim();
  if (!trimmed || trimmed === '[object Object]') return 'Ville non renseignée';
  return trimmed;
};

export const normalizeCityInput = (value: unknown): string => {
  if (typeof value !== 'string') return '';
  const trimmed = value.trim();
  if (!trimmed || trimmed === '[object Object]') return '';
  return trimmed;
};

const resolveApiUrl = (input: string): string => {
  if (!input.startsWith('/')) return input;
  if (typeof window === 'undefined') {
    return `http://127.0.0.1:3001${input}`;
  }

  const explicitBase = (import.meta as ImportMeta & { env?: Record<string, string | undefined> }).env?.VITE_API_BASE_URL?.trim();
  if (explicitBase) {
    return `${explicitBase.replace(/\/+$/, '')}${input}`;
  }
  return input;
};

const getSessionToken = (): string | null => {
  if (typeof window === 'undefined') return null;
  return window.localStorage.getItem(APP_SESSION_TOKEN_KEY);
};

const setSessionToken = (token: string) => {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(APP_SESSION_TOKEN_KEY, token);
};

const setLocalAppUser = (user: AppUser) => {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(APP_LOCAL_USER_KEY, JSON.stringify(user));
};

const getLocalAppUser = (): AppUser | null => {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(APP_LOCAL_USER_KEY);
    if (!raw) return null;
    return JSON.parse(raw) as AppUser;
  } catch {
    return null;
  }
};

const clearSessionToken = () => {
  if (typeof window === 'undefined') return;
  window.localStorage.removeItem(APP_SESSION_TOKEN_KEY);
};

const clearLocalAppUser = () => {
  if (typeof window === 'undefined') return;
  window.localStorage.removeItem(APP_LOCAL_USER_KEY);
  window.localStorage.removeItem(NOCODB_TOKEN_STORAGE_KEY);
};

const readLocalJsonCache = <T,>(key: string, fallbackValue: T): T => {
  if (typeof window === 'undefined') return fallbackValue;
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return fallbackValue;
    const parsed = JSON.parse(raw);
    return parsed ?? fallbackValue;
  } catch {
    return fallbackValue;
  }
};

const writeLocalJsonCache = (key: string, value: unknown) => {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Ignore quota/cache write issues.
  }
};

const readBeneficiaryPatchMap = (): Record<string, BeneficiaryPatchRecord> => (
  readLocalJsonCache<Record<string, BeneficiaryPatchRecord>>(BENEFICIARY_PATCHES_CACHE_KEY, {})
);

const writeBeneficiaryPatchMap = (value: Record<string, BeneficiaryPatchRecord>) => {
  writeLocalJsonCache(BENEFICIARY_PATCHES_CACHE_KEY, value);
};

const mergeBeneficiaryPatch = (patientId: string, updates: Partial<Patient>, lastError?: string): BeneficiaryPatchRecord => {
  const existing = readBeneficiaryPatchMap()[patientId];
  return {
    patientId,
    updates: {
      ...(existing?.updates || {}),
      ...updates,
    },
    updatedAt: new Date().toISOString(),
    lastError,
  };
};

const setBeneficiaryPatch = (patch: BeneficiaryPatchRecord) => {
  const next = readBeneficiaryPatchMap();
  next[patch.patientId] = patch;
  writeBeneficiaryPatchMap(next);
};

const clearBeneficiaryPatch = (patientId: string) => {
  const next = readBeneficiaryPatchMap();
  if (!next[patientId]) return;
  delete next[patientId];
  writeBeneficiaryPatchMap(next);
};

const normalizeOccupantIdentity = (value: unknown): OccupantIdentity | null => {
  if (!value || typeof value !== 'object') return null;
  const candidate = value as Partial<OccupantIdentity>;
  return {
    firstName: String(candidate.firstName || '').trim(),
    lastName: String(candidate.lastName || '').trim(),
    birthDate: String(candidate.birthDate || '').trim(),
    apa: Boolean(candidate.apa),
    invalidity: Boolean(candidate.invalidity),
    invalidityTxt: String(candidate.invalidityTxt || '').trim(),
    homeHelp: Boolean(candidate.homeHelp),
    homeHelpTxt: String(candidate.homeHelpTxt || '').trim(),
    dependenceTxt: String(candidate.dependenceTxt || '').trim(),
    numeroSecuriteSociale: String(candidate.numeroSecuriteSociale || '').trim(),
    caisseRetraitePrincipale: String(candidate.caisseRetraitePrincipale || '').trim(),
    caissesRetraiteComplementaires: String(candidate.caissesRetraiteComplementaires || '').trim(),
  };
};

const parseOccupantsJson = (raw: unknown): OccupantIdentity[] => {
  const source = String(raw || '').trim();
  if (!source) return [];
  try {
    const parsed = JSON.parse(source);
    if (!Array.isArray(parsed)) return [];
    return parsed.map(normalizeOccupantIdentity).filter(Boolean) as OccupantIdentity[];
  } catch {
    return [];
  }
};

const valuesMatch = (left: unknown, right: unknown): boolean => {
  if (left == null || left === '') {
    return right == null || right === '';
  }
  if (right == null || right === '') {
    return left == null || left === '';
  }
  if (typeof left === 'object' || typeof right === 'object') {
    return JSON.stringify(left) === JSON.stringify(right);
  }
  return left === right;
};

const applyPendingBeneficiaryUpdates = (dossiers: Dossier[]): Dossier[] => {
  const patches = readBeneficiaryPatchMap();
  if (Object.keys(patches).length === 0) return dossiers;

  return dossiers.map((dossier) => {
    const patch = patches[dossier.patient.id];
    if (!patch) return dossier;
    return {
      ...dossier,
      patient: {
        ...dossier.patient,
        ...patch.updates,
      },
    };
  });
};

const beneficiaryMatchesPatch = (patient: Patient, updates: Partial<Patient>): boolean => (
  Object.entries(updates).every(([key, value]) => {
    const patientValue = patient[key as keyof Patient];
    return valuesMatch(patientValue, value);
  })
);

const reconcileBeneficiaryPatchesWithDossiers = (dossiers: Dossier[]) => {
  const patches = readBeneficiaryPatchMap();
  if (Object.keys(patches).length === 0) return;

  let changed = false;
  const nextPatches = { ...patches };

  dossiers.forEach((dossier) => {
    const patch = nextPatches[dossier.patient.id];
    if (!patch) return;
    if (beneficiaryMatchesPatch(dossier.patient, patch.updates)) {
      delete nextPatches[dossier.patient.id];
      changed = true;
    }
  });

  if (changed) {
    writeBeneficiaryPatchMap(nextPatches);
  }
};

let beneficiaryFlushPromise: Promise<void> | null = null;
let beneficiaryOnlineListenerRegistered = false;
let beneficiaryFlushTimer: number | null = null;

const shouldAttemptBeneficiarySync = (): boolean => {
  if (typeof window === 'undefined') return false;
  if (!getSessionToken()) return false;
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return false;
  return true;
};

const supportsLocalDocumentBlobCache = (): boolean => (
  typeof window !== 'undefined' && typeof window.caches !== 'undefined'
);

const readLocalDocumentRecords = (): LocalDocumentRecord[] => (
  readLocalJsonCache<LocalDocumentRecord[]>(LOCAL_DOCUMENTS_CACHE_KEY, [])
);

const writeLocalDocumentRecords = (records: LocalDocumentRecord[]) => {
  writeLocalJsonCache(LOCAL_DOCUMENTS_CACHE_KEY, records);
};

const readLocalDocumentQueue = (): DocumentQueueRecord[] => (
  readLocalJsonCache<DocumentQueueRecord[]>(LOCAL_DOCUMENT_QUEUE_KEY, [])
);

const writeLocalDocumentQueue = (records: DocumentQueueRecord[]) => {
  writeLocalJsonCache(LOCAL_DOCUMENT_QUEUE_KEY, records);
};

const localDocumentCacheKey = (documentId: string) => `/local-documents/${encodeURIComponent(documentId)}`;

const putLocalDocumentBlob = async (documentId: string, blob: Blob): Promise<void> => {
  if (!supportsLocalDocumentBlobCache()) return;
  const cache = await window.caches.open(LOCAL_DOCUMENT_BLOB_CACHE_NAME);
  await cache.put(localDocumentCacheKey(documentId), new Response(blob));
  documentBlobCache.set(documentId, blob);
};

const getLocalDocumentBlob = async (documentId: string): Promise<Blob | null> => {
  if (!supportsLocalDocumentBlobCache()) return null;
  const cachedBlob = documentBlobCache.get(documentId);
  if (cachedBlob) {
    return cachedBlob;
  }
  const cache = await window.caches.open(LOCAL_DOCUMENT_BLOB_CACHE_NAME);
  const response = await cache.match(localDocumentCacheKey(documentId));
  if (!response) return null;
  const blob = await response.blob();
  documentBlobCache.set(documentId, blob);
  return blob;
};

const deleteLocalDocumentBlob = async (documentId: string): Promise<void> => {
  if (!supportsLocalDocumentBlobCache()) {
    documentBlobCache.delete(documentId);
    return;
  }
  const cache = await window.caches.open(LOCAL_DOCUMENT_BLOB_CACHE_NAME);
  await cache.delete(localDocumentCacheKey(documentId));
  documentBlobCache.delete(documentId);
};

const sortLocalDocuments = (documents: AppDocument[]) => (
  [...documents].sort((left, right) => new Date(right.updatedAt || right.createdAt || 0).getTime() - new Date(left.updatedAt || left.createdAt || 0).getTime())
);

const listLocalDocuments = (patientId: string, dossierId?: string): AppDocument[] => sortLocalDocuments(
  readLocalDocumentRecords().filter((document) => (
    document.patientId === patientId && (!dossierId || document.dossierId === dossierId)
  )),
);

const upsertLocalDocumentRecord = (record: LocalDocumentRecord) => {
  const current = readLocalDocumentRecords();
  const next = current.filter((document) => document.id !== record.id);
  next.unshift(record);
  writeLocalDocumentRecords(next);
};

const removeLocalDocumentRecord = (documentId: string) => {
  const current = readLocalDocumentRecords();
  writeLocalDocumentRecords(current.filter((document) => document.id !== documentId));
};

const enqueueLocalDocumentOperation = (operation: DocumentQueueRecord) => {
  const current = readLocalDocumentQueue();
  const next = current.filter((entry) => entry.documentId !== operation.documentId);
  next.push(operation);
  writeLocalDocumentQueue(next);
};

const clearLocalDocumentOperation = (documentId: string) => {
  const current = readLocalDocumentQueue();
  writeLocalDocumentQueue(current.filter((entry) => entry.documentId !== documentId));
};

const getLocalDocumentRecord = (documentId: string): LocalDocumentRecord | null => (
  readLocalDocumentRecords().find((document) => document.id === documentId) || null
);

const apiFetch = async <T>(input: string, init?: RequestInit): Promise<T> => {
  const response = await fetch(resolveApiUrl(input), {
    headers: {
      'Content-Type': 'application/json',
      ...(getSessionToken() ? { 'X-App-Session': getSessionToken() as string } : {}),
      ...(init?.headers || {}),
    },
    ...init,
  });

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(body || `HTTP ${response.status}`);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return response.json() as Promise<T>;
};

const readBlobAsDataUrl = (blob: Blob): Promise<string> =>
  new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ''));
    reader.onerror = () => reject(new Error('Lecture du blob impossible'));
    reader.readAsDataURL(blob);
  });

const supportsIndexedDbNotes = (): boolean => (
  typeof window !== 'undefined' && typeof window.indexedDB !== 'undefined'
);

const buildNoteScopeKey = (patientId: string, options: NoteScopeOptions): string => (
  `${patientId}::${options.scopeType}::${options.scopeId}::${options.tabKey}`
);

const buildNoteIdentityKey = (
  patientId: string,
  options: NoteScopeOptions,
  pageNumber: number,
): string => `${buildNoteScopeKey(patientId, options)}::${Number(pageNumber) || 0}`;

const createClientUuid = (): string => {
  if (typeof globalThis !== 'undefined' && globalThis.crypto?.randomUUID) {
    return globalThis.crypto.randomUUID();
  }
  return `local-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
};

let noteOfflineDbPromise: Promise<IDBDatabase | null> | null = null;
let noteSyncPromise: Promise<void> | null = null;
let noteSyncListenerRegistered = false;

const openNoteOfflineDb = async (): Promise<IDBDatabase | null> => {
  if (!supportsIndexedDbNotes()) {
    return null;
  }
  if (!noteOfflineDbPromise) {
    noteOfflineDbPromise = new Promise<IDBDatabase | null>((resolve, reject) => {
      const request = window.indexedDB.open(NOTES_OFFLINE_DB_NAME, NOTES_OFFLINE_DB_VERSION);

      request.onupgradeneeded = () => {
        const db = request.result;

        if (!db.objectStoreNames.contains(NOTES_PAGES_STORE_NAME)) {
          const pagesStore = db.createObjectStore(NOTES_PAGES_STORE_NAME, { keyPath: 'id' });
          pagesStore.createIndex('by_scope_key', 'scopeKey', { unique: false });
          pagesStore.createIndex('by_identity_key', 'identityKey', { unique: true });
        }

        if (!db.objectStoreNames.contains(NOTES_QUEUE_STORE_NAME)) {
          db.createObjectStore(NOTES_QUEUE_STORE_NAME, { keyPath: 'notePageId' });
        }
      };

      request.onsuccess = () => {
        const db = request.result;
        db.onversionchange = () => db.close();
        resolve(db);
      };
      request.onerror = () => reject(request.error || new Error('Impossible d’ouvrir IndexedDB'));
    }).catch((error): IDBDatabase | null => {
      console.error('Failed to open offline notes database', error);
      return null;
    });
  }
  return noteOfflineDbPromise;
};

const toLocalNotePageRecord = (
  notePage: NotePage,
  syncStatus: LocalNotePageRecord['syncStatus'] = 'synced',
): LocalNotePageRecord => ({
  ...notePage,
  scopeKey: buildNoteScopeKey(notePage.patientId, {
    scopeType: notePage.scopeType,
    scopeId: notePage.scopeId,
    tabKey: notePage.tabKey,
  }),
  identityKey: buildNoteIdentityKey(
    notePage.patientId,
    {
      scopeType: notePage.scopeType,
      scopeId: notePage.scopeId,
      tabKey: notePage.tabKey,
    },
    notePage.pageNumber,
  ),
  syncStatus,
  deleted: false,
});

const sortNotePages = (pages: NotePage[]): NotePage[] => (
  [...pages].sort((left, right) => left.pageNumber - right.pageNumber)
);

const listLocalNotePages = async (
  patientId: string,
  options: NoteScopeOptions,
): Promise<NotePage[]> => {
  const db = await openNoteOfflineDb();
  if (!db) return [];

  return new Promise((resolve, reject) => {
    const tx = db.transaction(NOTES_PAGES_STORE_NAME, 'readonly');
    const store = tx.objectStore(NOTES_PAGES_STORE_NAME);
    const index = store.index('by_scope_key');
    const request = index.getAll(buildNoteScopeKey(patientId, options));

    request.onsuccess = () => {
      const records = (request.result || []) as LocalNotePageRecord[];
      resolve(sortNotePages(records.filter((record) => !record.deleted)));
    };
    request.onerror = () => reject(request.error || new Error('Lecture locale des notes impossible'));
  });
};

const getLocalNotePageById = async (notePageId: string): Promise<LocalNotePageRecord | null> => {
  const db = await openNoteOfflineDb();
  if (!db) return null;

  return new Promise((resolve, reject) => {
    const tx = db.transaction(NOTES_PAGES_STORE_NAME, 'readonly');
    const store = tx.objectStore(NOTES_PAGES_STORE_NAME);
    const request = store.get(notePageId);
    request.onsuccess = () => resolve((request.result as LocalNotePageRecord | undefined) || null);
    request.onerror = () => reject(request.error || new Error('Lecture locale de la note impossible'));
  });
};

const getLocalNotePageByIdentity = async (
  patientId: string,
  options: NoteScopeOptions,
  pageNumber: number,
): Promise<LocalNotePageRecord | null> => {
  const db = await openNoteOfflineDb();
  if (!db) return null;

  return new Promise((resolve, reject) => {
    const tx = db.transaction(NOTES_PAGES_STORE_NAME, 'readonly');
    const store = tx.objectStore(NOTES_PAGES_STORE_NAME);
    const index = store.index('by_identity_key');
    const request = index.get(buildNoteIdentityKey(patientId, options, pageNumber));
    request.onsuccess = () => resolve((request.result as LocalNotePageRecord | undefined) || null);
    request.onerror = () => reject(request.error || new Error('Lecture locale de la note impossible'));
  });
};

const putLocalNotePage = async (record: LocalNotePageRecord): Promise<void> => {
  const db = await openNoteOfflineDb();
  if (!db) return;

  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(NOTES_PAGES_STORE_NAME, 'readwrite');
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error('Ecriture locale de la note impossible'));
    tx.objectStore(NOTES_PAGES_STORE_NAME).put(record);
  });
};

const bulkUpsertLocalNotePages = async (records: LocalNotePageRecord[]): Promise<void> => {
  const db = await openNoteOfflineDb();
  if (!db || records.length === 0) return;

  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(NOTES_PAGES_STORE_NAME, 'readwrite');
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error('Synchronisation locale des notes impossible'));
    const store = tx.objectStore(NOTES_PAGES_STORE_NAME);
    records.forEach((record) => store.put(record));
  });
};

const deleteLocalNotePageRecord = async (notePageId: string): Promise<void> => {
  const db = await openNoteOfflineDb();
  if (!db) return;

  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(NOTES_PAGES_STORE_NAME, 'readwrite');
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error('Suppression locale de la note impossible'));
    tx.objectStore(NOTES_PAGES_STORE_NAME).delete(notePageId);
  });
};

const listQueuedNoteOperations = async (): Promise<NoteQueueRecord[]> => {
  const db = await openNoteOfflineDb();
  if (!db) return [];

  return new Promise((resolve, reject) => {
    const tx = db.transaction(NOTES_QUEUE_STORE_NAME, 'readonly');
    const store = tx.objectStore(NOTES_QUEUE_STORE_NAME);
    const request = store.getAll();
    request.onsuccess = () => {
      const operations = ((request.result || []) as NoteQueueRecord[])
        .sort((left, right) => new Date(left.queuedAt).getTime() - new Date(right.queuedAt).getTime());
      resolve(operations);
    };
    request.onerror = () => reject(request.error || new Error('Lecture de la queue de notes impossible'));
  });
};

const getQueuedNoteOperation = async (notePageId: string): Promise<NoteQueueRecord | null> => {
  const db = await openNoteOfflineDb();
  if (!db) return null;

  return new Promise((resolve, reject) => {
    const tx = db.transaction(NOTES_QUEUE_STORE_NAME, 'readonly');
    const store = tx.objectStore(NOTES_QUEUE_STORE_NAME);
    const request = store.get(notePageId);
    request.onsuccess = () => resolve((request.result as NoteQueueRecord | undefined) || null);
    request.onerror = () => reject(request.error || new Error('Lecture de la queue de notes impossible'));
  });
};

const putQueuedNoteOperation = async (operation: NoteQueueRecord): Promise<void> => {
  const db = await openNoteOfflineDb();
  if (!db) return;

  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(NOTES_QUEUE_STORE_NAME, 'readwrite');
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error('Ecriture de la queue de notes impossible'));
    tx.objectStore(NOTES_QUEUE_STORE_NAME).put(operation);
  });
};

const deleteQueuedNoteOperation = async (notePageId: string): Promise<void> => {
  const db = await openNoteOfflineDb();
  if (!db) return;

  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction(NOTES_QUEUE_STORE_NAME, 'readwrite');
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error('Nettoyage de la queue de notes impossible'));
    tx.objectStore(NOTES_QUEUE_STORE_NAME).delete(notePageId);
  });
};

type MutationResult = { success: boolean; error: string | null; data?: { id?: string; dossierId?: string; patient?: Patient } };
type AuthResult = { success: boolean; error: string | null; data?: { token?: string; user?: AppUser } };
type AdminAccessMembersResult = { success: boolean; error: string | null; data?: { members: AdminAccessMember[]; generated?: Array<{ email: string; displayName: string; role: string; password: string }> } };
type ProfilePhotoResult = { success: boolean; error: string | null; data?: { user?: AppUser; photoUrl?: string } };
type RetirementFundsResult = { success: boolean; error: string | null; data?: { funds?: RetirementFund[] } };
type RetirementFundResult = { success: boolean; error: string | null; data?: { fund?: RetirementFund } };
type AnahStatusResult = { success: boolean; error: string | null; data?: { status?: AnahStatus } };
type NotePagesResult = { success: boolean; error: string | null; data?: { notePages?: NotePage[]; notePage?: NotePage; deleted?: boolean } };
type WikiLibraryResult = { success: boolean; error: string | null; data?: { items?: WikiLibraryItem[] } };
type WikiLibraryItemResult = { success: boolean; error: string | null; data?: { item?: WikiLibraryItem } };
type VisitRecommendationsResult = { success: boolean; error: string | null; data?: { items?: VisitRecommendationItem[] } };
type VisitPlanResult = { success: boolean; error: string | null; data?: { visitPlan?: { publicUrl?: string | null; updatedAt?: string | null } } };
type DocumentsResult = { success: boolean; error: string | null; data?: { documents?: ApiDocument[] } };
type DocumentResult = { success: boolean; error: string | null; data?: { document?: ApiDocument; deleted?: boolean } };
type MobileSyncStatusResult = {
  success: boolean;
  error: string | null;
  data?: {
    mode?: 'nocodb' | 'local';
    nocodbTablesReady?: boolean;
    localCounts?: { documents: number; notePages: number };
    remoteCounts?: { documents: number; notePages: number };
  };
};

type ApiDocument = {
  id: string;
  patientId: string;
  dossierId?: string | null;
  patientFirstName?: string;
  patientLastName?: string;
  patientDisplayName?: string;
  dossierLabel?: string;
  title: string;
  fileName: string;
  mimeType: string;
  tags?: string[];
  createdAt?: string;
  updatedAt?: string;
  publicUrl?: string;
  remotePath?: string;
};

type NoteScopeOptions = {
  scopeType: string;
  scopeId: string;
  tabKey: string;
};

type LocalNotePageRecord = NotePage & {
  scopeKey: string;
  identityKey: string;
  syncStatus: 'synced' | 'pending' | 'failed';
  deleted?: boolean;
};

type NoteQueueRecord = {
  notePageId: string;
  type: 'upsert' | 'delete';
  patientId: string;
  queuedAt: string;
  lastError?: string;
};

type BeneficiaryPatchRecord = {
  patientId: string;
  updates: Partial<Patient>;
  updatedAt: string;
  lastError?: string;
};

type LocalDocumentRecord = AppDocument & {
  remoteId?: string;
  syncStatus: 'synced' | 'pending' | 'failed';
  lastSyncedAt?: string | null;
};

type DocumentQueueRecord = {
  documentId: string;
  type: 'upload' | 'update' | 'delete';
  patientId: string;
  remoteId?: string;
  queuedAt: string;
  lastError?: string;
};

const documentBlobCache = new Map<string, Blob>();
const documentBlobPromiseCache = new Map<string, Promise<Blob>>();
const warmedImageUrls = new Set<string>();

const inferMimeTypeFromFileName = (fileName: string): string => {
  const extension = String(fileName || '').trim().split('.').pop()?.toLowerCase() || '';
  return ({
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    png: 'image/png',
    webp: 'image/webp',
    gif: 'image/gif',
    bmp: 'image/bmp',
    svg: 'image/svg+xml',
    pdf: 'application/pdf',
  })[extension] || 'application/octet-stream';
};

const normalizeDocumentMimeType = (fileName: string, mimeType: string): string => {
  const normalized = String(mimeType || '').trim().toLowerCase();
  if (!normalized || normalized === 'application/octet-stream') {
    return inferMimeTypeFromFileName(fileName);
  }
  return normalized;
};

export const preloadImageAssets = async (urls: string[]): Promise<void> => {
  if (typeof window === 'undefined') return;

  const pending = urls
    .map((url) => String(url || '').trim())
    .filter(Boolean)
    .filter((url) => !warmedImageUrls.has(url))
    .map((url) => new Promise<void>((resolve) => {
      const image = new Image();
      image.decoding = 'async';
      image.onload = () => {
        warmedImageUrls.add(url);
        resolve();
      };
      image.onerror = () => resolve();
      image.src = url;
    }));

  if (pending.length === 0) {
    return;
  }

  await Promise.allSettled(pending);
};

export interface ReferenceData {
  situations: Array<{ id: string; label: string }>;
  dependances: Array<{ id: string; label: string }>;
  porteGarage: Array<{ id: string; label: string }>;
  portail: Array<{ id: string; label: string }>;
  baremesAnah: Array<{
    id: string;
    label: string;
    householdSize: number;
    revenueTresModeste?: number;
    revenueModeste?: number;
    revenueIntermediaire?: number;
    revenueHaut?: number;
    plafondYear?: number;
  }>;
  ergos: Array<{ id: string; label: string; establishmentId?: string; establishmentLabel?: string }>;
  etablissements: Array<{ id: string; label: string }>;
  communes: Array<{ id: string; label: string; zipCode: string; epciId?: string; epciLabel?: string }>;
  epcis: Array<{ id: string; label: string }>;
}

let referenceDataCache: ReferenceData | null = null;
let referenceDataPromise: Promise<ReferenceData> | null = null;

export const getReferenceDataSnapshot = (): ReferenceData | null => referenceDataCache;

export const loginApp = async (email: string, password: string): Promise<{ success: boolean; error: string | null; user?: AppUser }> => {
  const normalizedEmail = String(email || '').trim().toLowerCase();
  const profile = profilsAutorises[normalizedEmail as keyof typeof profilsAutorises];

  if (!profile || profile.motDePasse !== password) {
    clearSessionToken();
    clearLocalAppUser();
    return { success: false, error: 'Adresse mail ou mot de passe incorrect' };
  }

  const role = profile.role === 'admin' ? 'ADMIN' : 'ERGO';
  const user: AppUser = {
    email: normalizedEmail,
    displayName: profile.nomDansNocoDb,
    role,
    selectable: role !== 'ADMIN',
    profilePhotoUrl: '',
    establishmentId: role === 'ADMIN' ? '' : '2',
    establishmentLabel: role === 'ADMIN' ? '' : "Aid'habitat",
    ergoRecordId: '',
    ergoLabel: role === 'ADMIN' ? '' : profile.nomDansNocoDb,
  };

  const encodedEmail = typeof window !== 'undefined' && typeof window.btoa === 'function'
    ? window.btoa(normalizedEmail)
    : normalizedEmail;
  const sessionToken = `${LOCAL_SESSION_TOKEN_PREFIX}${encodedEmail}`;
  const nocoDbToken = nocoDbTokensParEmail[normalizedEmail as keyof typeof nocoDbTokensParEmail] || '';

  setSessionToken(sessionToken);
  setLocalAppUser(user);
  if (typeof window !== 'undefined') {
    window.localStorage.setItem(NOCODB_TOKEN_STORAGE_KEY, nocoDbToken);
  }

  return { success: true, error: null, user };
};

export const fetchCurrentAppUser = async (): Promise<AppUser | null> => {
  const token = getSessionToken();
  const user = getLocalAppUser();
  if (!token || !user) return null;
  return user;
};

export const logoutApp = async (): Promise<void> => {
  clearSessionToken();
  clearLocalAppUser();
};

export const uploadProfilePhoto = async (imageDataUrl: string): Promise<{ success: boolean; error: string | null; user?: AppUser; photoUrl?: string }> => {
  try {
    const result = await apiFetch<ProfilePhotoResult>('/api/profile/photo', {
      method: 'POST',
      body: JSON.stringify({ imageDataUrl }),
    });
    return {
      success: result.success,
      error: result.error,
      user: result.data?.user,
      photoUrl: result.data?.photoUrl,
    };
  } catch (error: any) {
    return { success: false, error: error.message || 'Upload impossible' };
  }
};

export const fetchAdminAccessMembers = async (): Promise<AdminAccessMember[]> => {
  const result = await apiFetch<AdminAccessMembersResult>('/api/admin/access-members');
  return result.data?.members || [];
};

export const regenerateAccessPassword = async (email: string): Promise<{ success: boolean; error: string | null; password?: string }> => {
  try {
    const result = await apiFetch<AdminAccessMembersResult>('/api/auth/provision', {
      method: 'POST',
      body: JSON.stringify({ email, forceReset: true }),
    });
    const generated = result.data?.generated?.find((entry) => entry.email === email);
    return {
      success: result.success,
      error: result.error,
      password: generated?.password,
    };
  } catch (error: any) {
    return { success: false, error: error.message || 'Réinitialisation impossible' };
  }
};

export const fetchRetirementFunds = async (): Promise<RetirementFund[]> => {
  const result = await apiFetch<RetirementFundsResult>('/api/retirement-funds');
  const funds = result.data?.funds || [];
  writeLocalJsonCache(RETIREMENT_FUNDS_CACHE_KEY, funds);
  return funds;
};

export const getCachedRetirementFunds = (): RetirementFund[] =>
  readLocalJsonCache<RetirementFund[]>(RETIREMENT_FUNDS_CACHE_KEY, []);

export const updateRetirementFund = async (fundId: string, updates: Partial<RetirementFund>): Promise<RetirementFund> => {
  const result = await apiFetch<RetirementFundResult>(`/api/retirement-funds/${fundId}`, {
    method: 'PUT',
    body: JSON.stringify(updates),
  });
  if (!result.data?.fund) {
    throw new Error(result.error || 'Enregistrement impossible');
  }
  const cachedFunds = getCachedRetirementFunds();
  if (cachedFunds.length > 0) {
    writeLocalJsonCache(
      RETIREMENT_FUNDS_CACHE_KEY,
      cachedFunds.map((fund) => fund.id === fundId ? { ...fund, ...result.data!.fund } : fund),
    );
  }
  return result.data.fund;
};

export const createRetirementFund = async (payload: Partial<RetirementFund> & { name: string }): Promise<RetirementFund> => {
  const result = await apiFetch<RetirementFundResult>('/api/retirement-funds', {
    method: 'POST',
    body: JSON.stringify(payload),
  });
  if (!result.data?.fund) {
    throw new Error(result.error || 'Création impossible');
  }
  const cachedFunds = getCachedRetirementFunds();
  writeLocalJsonCache(
    RETIREMENT_FUNDS_CACHE_KEY,
    [result.data.fund, ...cachedFunds.filter((fund) => fund.id !== result.data!.fund!.id)],
  );
  return result.data.fund;
};

export const fetchAnahStatus = async (): Promise<AnahStatus> => {
  const result = await apiFetch<AnahStatusResult>('/api/anah-status');
  if (!result.data?.status) {
    throw new Error(result.error || 'Statut ANAH indisponible');
  }
  return result.data.status;
};

export const fetchVisitPlan = async (dossierId: string): Promise<{ publicUrl: string | null; updatedAt?: string | null }> => {
  const result = await apiFetch<VisitPlanResult>(`/api/visit-plans/${encodeURIComponent(dossierId)}`);
  return {
    publicUrl: result.data?.visitPlan?.publicUrl || null,
    updatedAt: result.data?.visitPlan?.updatedAt || null,
  };
};

export const saveVisitPlan = async (dossierId: string, blob: Blob): Promise<{ publicUrl: string; updatedAt?: string | null }> => {
  const contentBase64 = await readBlobAsDataUrl(blob);
  const result = await apiFetch<VisitPlanResult>(`/api/visit-plans/${encodeURIComponent(dossierId)}`, {
    method: 'PUT',
    body: JSON.stringify({ contentBase64 }),
  });
  const publicUrl = result.data?.visitPlan?.publicUrl;
  if (!publicUrl) {
    throw new Error(result.error || 'Sauvegarde du plan impossible');
  }
  return {
    publicUrl,
    updatedAt: result.data?.visitPlan?.updatedAt || null,
  };
};

export const fetchWikiLibrary = async (): Promise<WikiLibraryItem[]> => {
  const result = await apiFetch<WikiLibraryResult>('/api/wiki-library');
  return result.data?.items || [];
};

export const createWikiLibraryItem = async (payload: {
  title: string;
  description: string;
  category: string;
  tags: string[];
  imageDataUrl?: string;
}): Promise<WikiLibraryItem> => {
  const result = await apiFetch<WikiLibraryItemResult>('/api/wiki-library', {
    method: 'POST',
    body: JSON.stringify(payload),
  });
  if (!result.data?.item) {
    throw new Error(result.error || 'Creation impossible');
  }
  return result.data.item;
};

export const updateWikiLibraryItem = async (itemId: string, payload: Partial<WikiLibraryItem> & { imageDataUrl?: string }): Promise<WikiLibraryItem> => {
  const result = await apiFetch<WikiLibraryItemResult>(`/api/wiki-library/${encodeURIComponent(itemId)}`, {
    method: 'PUT',
    body: JSON.stringify(payload),
  });
  if (!result.data?.item) {
    throw new Error(result.error || 'Enregistrement impossible');
  }
  return result.data.item;
};

export const deleteWikiLibraryItem = async (itemId: string): Promise<void> => {
  await apiFetch<void>(`/api/wiki-library/${encodeURIComponent(itemId)}`, {
    method: 'DELETE',
  });
};

export const fetchVisitRecommendations = async (dossierId: string): Promise<VisitRecommendationItem[]> => {
  const result = await apiFetch<VisitRecommendationsResult>(`/api/visit-recommendations/${encodeURIComponent(dossierId)}`);
  return result.data?.items || [];
};

export const saveVisitRecommendations = async (
  dossierId: string,
  items: VisitRecommendationItem[],
): Promise<{ success: boolean; error: string | null }> => {
  try {
    const result = await apiFetch<MutationResult>(`/api/visit-recommendations/${encodeURIComponent(dossierId)}`, {
      method: 'PUT',
      body: JSON.stringify({ items }),
    });
    return { success: result.success, error: result.error };
  } catch (e: any) {
    return { success: false, error: e.message };
  }
};

// Helper to map a raw beneficiary (from 'beneficiaires' table) to a Patient object
export const mapPatient = (data: any): Patient => ({
  id: data.id || 'unknown',
  firstName: data.prenom || 'Inconnu',
  lastName: data.nom || 'Inconnu',
  secondFirstName: data.prenom_occupant_2 || '',
  secondLastName: data.nom_occupant_2 || '',
  occupants: (() => {
    const parsed = parseOccupantsJson(data.occupants_json);
    if (parsed.length > 0) return parsed;
    return [
      {
        firstName: data.prenom || '',
        lastName: data.nom || '',
        birthDate: data.date_naissance_monsieur || '',
        apa: data.beneficiaire_apa || false,
        invalidity: data.reconnaissance_invalidite_mdph || false,
        invalidityTxt: data.reconnaissance_invalidité_mdph_txt || '',
        homeHelp: data.aide_a_domicile || false,
        homeHelpTxt: data.aide_a_domicile_txt || '',
        dependenceTxt: data.dependance_particuliere_txt || '',
        numeroSecuriteSociale: data.numero_securite_sociale_monsieur || '',
        caisseRetraitePrincipale: data.caisse_retraite_principale || '',
        caissesRetraiteComplementaires: data.caisses_retraite_complementaires || '',
      },
      ...((data.prenom_occupant_2 || data.nom_occupant_2 || data.date_naissance_madame) ? [{
        firstName: data.prenom_occupant_2 || '',
        lastName: data.nom_occupant_2 || '',
        birthDate: data.date_naissance_madame || '',
        numeroSecuriteSociale: data.numero_securite_sociale_madame || '',
      }] : []),
    ];
  })(),

  // Coordonnées
  email: data.mail || '',
  phone: data.telephone || '',
  address: data.adresse_logement || '',
  city: normalizeCityInput(data.ville_libre ?? data.commune ?? data.nom_commune),
  zipCode: String((data.code_postal_libre ?? data.code_postal) || ''),
  cityId: data.commune_id || data.communes_id || '',

  // Situation
  birthDate: data.date_naissance_monsieur || data.date_naissance_madame || new Date().toISOString(), // Fallback main date
  birthDateMr: data.date_naissance_monsieur,
  birthDateMme: data.date_naissance_madame,
  familySituation: data.situation_proprietaire_libelle || '',
  occupationStatus: data.statut_occupation_libelle || '',
  numberPeople: data.nombre_personnes,

  // Revenus
  incomeCategory: data.categorie_revenu_nom || 'Modeste',
  fiscalRevenue: data.revenu_fiscal_reference,

  // Autonomie / Santé
  apa: data.beneficiaire_apa || false,
  invalidity: data.reconnaissance_invalidite_mdph || false,
  invalidityTxt: data.reconnaissance_invalidité_mdph_txt,
  homeHelp: data.aide_a_domicile || false,
  homeHelpTxt: data.aide_a_domicile_txt,
  dependenceTxt: data.dependance_particuliere_txt,

  // Personne de confiance
  trustedPerson: {
    name: data.personne_confiance || '',
    phone: data.telephone_personne_confiance || '',
    email: data.mail_personne_confiance || ''
  },

  numeroSecuriteSocialeMonsieur: data.numero_securite_sociale_monsieur || '',
  numeroSecuriteSocialeMadame: data.numero_securite_sociale_madame || '',
  caisseRetraitePrincipale: data.caisse_retraite_principale || '',
  caissesRetraiteComplementaires: data.caisses_retraite_complementaires || '',

  photoUrl: data.photo_logement_url
});

// Helper to map a raw logement (from 'logements' table) to Housing object
const mapHousingFromDB = (data: any): Housing => {
  if (!data) {
    // Return empty/default if no housing found
    return {
      id: undefined,
      yearConstruction: undefined,
      yearHabitation: undefined,
      surface: undefined,
      levels: undefined,
      basement: false, basementDesc: undefined,
      rdc: false, rdcDesc: undefined,
      floor: false, floorDesc: undefined,
      garage: false, veranda: false, balcon: false, terrasse: false, jardin: false,
      heatingMain: false,
      heatingDetails: { electric: false, gas: false, oil: false, heatPump: false, collective: false, wood: false, pellet: false, other: false },
      easyAccess: false,
      comments: undefined,
      accessObservation: undefined
    };
  }

  return {
    id: data.id,

    // General
    yearConstruction: data.annee_construction,
    yearHabitation: data.annee_habitation,
    surface: data.surface_habitable,
    levels: data.nombre_niveaux,
    // Infer type? Or leave undefined?

    // Floors
    basement: data.sous_sol || false,
    basementDesc: data.description_sous_sol,
    rdc: data.rdc || false,
    rdcDesc: data.description_rdc,
    floor: data.etage || false,
    floorDesc: data.description_etage,

    // Annexes
    garage: data.garage || false,
    veranda: data.veranda || false,
    balcon: data.balcon || false,
    terrasse: data.terrasse || false,
    jardin: data.jardin || false,

    // Heating
    heatingMain: data.chauffage || false,
    heatingDetails: {
      electric: data.radiateurs_electrique || false,
      gas: data.chaudiere_gaz || false,
      oil: data.chaudiere_fioul || false,
      heatPump: data.pompe_a_chaleur || false,
      collective: data.chaudiere_collective || false,
      wood: data.cheminee_pole_bois || false,
      pellet: data.poele_granules || false,
      other: data.autre_chauffage || false
    },

    // Access
    easyAccess: data.acces_facile_rue || false,
    comments: data.commentaire,
    accessObservation: data.observation_accessibilite,

    // Porte de garage et portail (FK IDs + libellés pour affichage)
    porteGarageId: data.porte_garage_id || '',
    portailId: data.portail_id || '',
    // On stocke aussi les libellés s'ils sont joints (pour les menus déroulants)
    motorisationPorteGarage: data.porte_de_garage?.libelle || '',
    motorisationPortail: data.portail?.libelle || ''
  };
};

// Mapper for existing dossiers (joined with beneficiaries)
const mapDossierFromDB = (data: any): Dossier => {
  const patientData = data.beneficiaires || {};
  const patient = mapPatient(patientData);

  // Link Housing from 'logements' table (via beneficiary)
  // We assume 'beneficiaires' has a nested 'logements' array from the query
  const housingDataArray = patientData.logements;
  const housingData = (housingDataArray && housingDataArray.length > 0) ? housingDataArray[0] : null;
  const housing = mapHousingFromDB(housingData);

  // Map Status safely
  let status = DossierStatus.TO_VISIT;
  if (Object.values(DossierStatus).includes(data.status)) {
    status = data.status as DossierStatus;
  }

  // Note: Legacy housing columns on dossiers table have been removed.
  // If a beneficiary has no associated logement record, housing defaults will be empty.

  const reportData = data.report_data || {};

  return {
    id: data.id,
    patient: patient,
    status: status,
    ergoId: data.ergo_id || 'E1',
    visitDate: data.visit_date,
    housing: housing,

    // New Fields mapped from JSONB 'report_data'
    // Note: Some of these modify Patient/Housing directly now, so these might be redundant 
    // but useful for 'medicalContext' and 'autonomy' which are not in the main tables yet 
    // (unless created).
    medicalContext: reportData.medicalContext,
    autonomy: reportData.autonomy,

    // Admin fields
    compteAnah: data.compte_anah,
    natureAccompagnement: data.nature_accompagnement,
    envoiRapport: data.envoi_rapport,
    personnesPresentesVisite: data.personnes_presentes_visite || '',

    autonomyNotes: data.autonomy_notes || '',
    plans: {
      PF1: { id: 'PF1', works: [], grants: [] },
      PF2: { id: 'PF2', works: [], grants: [] },
      PF3: { id: 'PF3', works: [], grants: [] }
    },
    createdAt: data.created_at || new Date().toISOString()
  };
};

// Mapper for beneficiaries who don't have a dossier yet (create a virtual dossier)
export const mapVirtualDossierFromBeneficiary = (beneficiaryData: any): Dossier => {
  const patient = mapPatient(beneficiaryData);

  // Try to find housing in local data (not passed here usually, but if provided)
  // For virtual, we define empty housing
  const housing = mapHousingFromDB(null);

  return {
    id: `temp-${patient.id}`, // Temporary ID
    patient: patient,
    status: DossierStatus.TO_VISIT, // Default status for new profiles
    ergoId: 'user',
    housing: housing,

    // Defaults
    medicalContext: { autonomyDone: false, autonomy: [] } as any,
    autonomyNotes: '',
    plans: {
      PF1: { id: 'PF1', works: [], grants: [] },
      PF2: { id: 'PF2', works: [], grants: [] },
      PF3: { id: 'PF3', works: [], grants: [] }
    },
    createdAt: beneficiaryData.created_at || new Date().toISOString()
  };
};



export const fetchLocalSnapshot = async (): Promise<Dossier[]> => {
  try {
    const response = await fetch('/snapshot.json');
    if (response.ok) {
      const snapshot = await response.json();
      console.log(`[DataService] Snapshot loaded. ${snapshot.beneficiaries?.length || 0} beneficiaries, ${snapshot.dossiers?.length || 0} dossiers.`);

      let finalDossiers: Dossier[] = [];

      // 1. Map dossiers already normalized from the shared API.
      if (snapshot.dossiers && snapshot.dossiers.length > 0 && snapshot.dossiers[0]?.patient) {
        return applyPendingBeneficiaryUpdates(snapshot.dossiers as Dossier[]);
      }

      // 2. Map raw dossiers from legacy snapshot format.
      if (snapshot.dossiers && snapshot.dossiers.length > 0) {
        finalDossiers = snapshot.dossiers.map(mapDossierFromDB);
      }

      // 3. Map beneficiaries without dossier only for legacy snapshots.
      const coveredIds = new Set(finalDossiers.map(d => d.patient.id));
      const orphans = (snapshot.beneficiaries || []).filter((b: any) => !coveredIds.has(b.id));
      const virtuals = orphans.map(mapVirtualDossierFromBeneficiary);

      return applyPendingBeneficiaryUpdates([...finalDossiers, ...virtuals]);
    }
  } catch (e: any) {
    console.error('[DataService] Snapshot fetch error:', e);
  }
  return [];
};

export const fetchDossiers = async (userId?: string): Promise<Dossier[]> => {
  debugLog(`fetchDossiers: loading via shared API for user ${userId || 'ALL'}`);
  const dossiers = await apiFetch<Dossier[]>('/api/dossiers');
  reconcileBeneficiaryPatchesWithDossiers(dossiers);
  return applyPendingBeneficiaryUpdates(dossiers);
};

export const updateDossier = async (
  dossierId: string,
  updates: Partial<Dossier>,
): Promise<{ success: boolean; error: string | null; data?: MutationResult['data'] }> => {
  try {
    const result = await apiFetch<MutationResult>(`/api/dossiers/${encodeURIComponent(dossierId)}`, {
      method: 'PATCH',
      body: JSON.stringify(updates),
    });
    return { success: result.success, error: result.error, data: result.data };
  } catch (error: any) {
    console.error('Unexpected error updating dossier:', error);
    return { success: false, error: error.message };
  }
};

export const checkSupabaseConnection = async (): Promise<{ success: boolean; message: string; count?: number }> => {
  try {
    return await apiFetch<{ success: boolean; message: string; count?: number }>('/api/health');
  } catch (err: any) {
    return { success: false, message: err.message || 'Erreur inconnue' };
  }
};

// Generate visits dynamically based on fetched dossiers
export const generateVisitsFromDossiers = (dossiers: Dossier[]): Visit[] => {
  return dossiers
    .filter(d => d.visitDate)
    .map(d => ({
      id: `V-${d.id}`,
      dossierId: d.id,
      patientName: `${d.patient.firstName} ${d.patient.lastName}`,
      date: d.visitDate!,
      location: formatCityLabel(d.patient.city),
      status: new Date(d.visitDate!) < new Date() ? 'Done' : 'Upcoming'
    }));
};

// --- Documents Service ---

const inferDocumentType = (fileName: string, mimeType: string): AppDocument['type'] => {
  const normalizedMimeType = normalizeDocumentMimeType(fileName, mimeType);
  if (normalizedMimeType.startsWith('image/')) return 'image';
  if (normalizedMimeType === 'application/pdf') return 'pdf';

  const extension = String(fileName || '').split('.').pop()?.toLowerCase() || '';
  if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg'].includes(extension)) return 'image';
  if (extension === 'pdf') return 'pdf';
  return 'doc';
};

const mapApiDocument = (document: ApiDocument): AppDocument => ({
  id: document.id,
  remoteId: document.id,
  patientId: document.patientId,
  dossierId: document.dossierId || null,
  patientFirstName: document.patientFirstName || '',
  patientLastName: document.patientLastName || '',
  patientDisplayName: document.patientDisplayName || '',
  dossierLabel: document.dossierLabel || '',
  title: document.title,
  fileName: document.fileName,
  mimeType: normalizeDocumentMimeType(document.fileName, document.mimeType),
  tags: Array.isArray(document.tags) ? document.tags : [],
  createdAt: document.createdAt || new Date().toISOString(),
  updatedAt: document.updatedAt || document.createdAt || new Date().toISOString(),
  lastSyncedAt: document.updatedAt || document.createdAt || new Date().toISOString(),
  syncStatus: 'synced',
  remotePath: document.remotePath,
  url: document.publicUrl || '',
  type: inferDocumentType(document.fileName, document.mimeType),
});

const buildDocumentFileName = (title: string, originalFileName: string): string => {
  const extension = String(originalFileName || '').split('.').pop()?.trim();
  return extension ? `${title}.${extension}` : title;
};

const uploadDocumentRemote = async (
  patientId: string,
  file: File,
  _patientName: string,
  customName: string,
  tags: string[],
  dossierId?: string,
  documentLocalId?: string,
): Promise<{ success: boolean; error: string | null; document?: AppDocument }> => {
  try {
    const title = customName.trim() || file.name.replace(/\.[^.]+$/, '') || 'Document';
    const fileName = buildDocumentFileName(title, file.name);
    const query = new URLSearchParams({
      patientId,
      title,
      fileName,
      tagsJson: JSON.stringify(tags),
    });
    if (documentLocalId) {
      query.set('documentLocalId', documentLocalId);
    }
    if (dossierId) {
      query.set('dossierId', dossierId);
    }

    const response = await fetch(resolveApiUrl(`/api/documents/upload?${query.toString()}`), {
      method: 'POST',
      headers: {
        'Content-Type': file.type || 'application/octet-stream',
        ...(getSessionToken() ? { 'X-App-Session': getSessionToken() as string } : {}),
      },
      body: file,
    });

    const result = await response.json() as DocumentResult;
    if (!response.ok) {
      return { success: false, error: result.error || `HTTP ${response.status}` };
    }

    return {
      success: result.success,
      error: result.error,
      document: result.data?.document ? mapApiDocument(result.data.document) : undefined,
    };
  } catch (error: any) {
    console.error('Unexpected error uploading document:', error);
    return { success: false, error: error.message || 'Unexpected error' };
  }
};

const updateDocumentRemote = async (
  documentId: string,
  updates: { title?: string; tags?: string[] },
): Promise<{ success: boolean; error: string | null; document?: AppDocument }> => {
  try {
    const result = await apiFetch<DocumentResult>(`/api/documents/${encodeURIComponent(documentId)}`, {
      method: 'PATCH',
      body: JSON.stringify(updates),
    });

    return {
      success: result.success,
      error: result.error,
      document: result.data?.document ? mapApiDocument(result.data.document) : undefined,
    };
  } catch (error: any) {
    console.error('Unexpected error updating document:', error);
    return { success: false, error: error.message || 'Unexpected error' };
  }
};

const deleteDocumentRemote = async (documentId: string): Promise<{ success: boolean; error: string | null }> => {
  try {
    const result = await apiFetch<DocumentResult>(`/api/documents/${encodeURIComponent(documentId)}`, {
      method: 'DELETE',
    });
    return { success: result.success, error: result.error };
  } catch (error: any) {
    console.error('Unexpected error deleting document:', error);
    return { success: false, error: error.message || 'Unexpected error' };
  }
};

const fetchRemoteDocumentBlob = async (document: Pick<AppDocument, 'id' | 'remoteId' | 'fileName' | 'mimeType'>): Promise<Blob> => {
  const cachedBlob = documentBlobCache.get(document.id);
  if (cachedBlob) {
    return cachedBlob;
  }

  const pendingBlob = documentBlobPromiseCache.get(document.id);
  if (pendingBlob) {
    return pendingBlob;
  }

  const blobPromise = (async () => {
    const response = await fetch(resolveApiUrl(`/api/mobile-documents/${encodeURIComponent(document.remoteId || document.id)}/content`), {
      headers: {
        ...(getSessionToken() ? { 'X-App-Session': getSessionToken() as string } : {}),
      },
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      throw new Error(body || `HTTP ${response.status}`);
    }

    const blob = await response.blob();
    const resolvedMimeType = normalizeDocumentMimeType(document.fileName, document.mimeType || blob.type);
    const normalizedBlob = blob.type === resolvedMimeType
      ? blob
      : new Blob([blob], { type: resolvedMimeType });
    documentBlobCache.set(document.id, normalizedBlob);
    return normalizedBlob;
  })().finally(() => {
    documentBlobPromiseCache.delete(document.id);
  });

  documentBlobPromiseCache.set(document.id, blobPromise);
  return blobPromise;
};

const shouldAttemptDocumentSync = (): boolean => {
  if (typeof window === 'undefined') return false;
  if (!getSessionToken()) return false;
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return false;
  return true;
};

let documentFlushPromise: Promise<void> | null = null;
let documentOnlineListenerRegistered = false;

const flushQueuedDocumentOperations = async (): Promise<void> => {
  if (!shouldAttemptDocumentSync()) {
    return;
  }
  if (documentFlushPromise) {
    return documentFlushPromise;
  }

  documentFlushPromise = (async () => {
    const operations = [...readLocalDocumentQueue()].sort((left, right) => new Date(left.queuedAt).getTime() - new Date(right.queuedAt).getTime());

    for (const operation of operations) {
      const localDocument = getLocalDocumentRecord(operation.documentId);

      try {
        if (operation.type === 'delete') {
          if (operation.remoteId) {
            await deleteDocumentRemote(operation.remoteId);
          }
          clearLocalDocumentOperation(operation.documentId);
          continue;
        }

        if (!localDocument) {
          clearLocalDocumentOperation(operation.documentId);
          continue;
        }

        if (operation.type === 'upload') {
          const blob = await getLocalDocumentBlob(localDocument.id);
          if (!blob) {
            throw new Error('Fichier local introuvable');
          }
          const file = new File([blob], localDocument.fileName, { type: localDocument.mimeType || blob.type || 'application/octet-stream' });
          const result = await uploadDocumentRemote(
            localDocument.patientId,
            file,
            localDocument.patientDisplayName || '',
            localDocument.title,
            localDocument.tags,
            localDocument.dossierId || undefined,
            localDocument.id,
          );
          if (!result.success || !result.document) {
            throw new Error(result.error || 'Upload impossible');
          }
          upsertLocalDocumentRecord({
            ...localDocument,
            remoteId: result.document.id,
            remotePath: result.document.remotePath,
            url: result.document.url,
            updatedAt: result.document.updatedAt,
            lastSyncedAt: result.document.updatedAt,
            syncStatus: 'synced',
          });
          clearLocalDocumentOperation(operation.documentId);
          continue;
        }

        if (!localDocument.remoteId) {
          enqueueLocalDocumentOperation({
            ...operation,
            type: 'upload',
            queuedAt: new Date().toISOString(),
          });
          continue;
        }

        const result = await updateDocumentRemote(localDocument.remoteId, {
          title: localDocument.title,
          tags: localDocument.tags,
        });
        if (!result.success) {
          throw new Error(result.error || 'Mise à jour impossible');
        }
        upsertLocalDocumentRecord({
          ...localDocument,
          updatedAt: result.document?.updatedAt || new Date().toISOString(),
          lastSyncedAt: result.document?.updatedAt || new Date().toISOString(),
          syncStatus: 'synced',
        });
        clearLocalDocumentOperation(operation.documentId);
      } catch (error: any) {
        if (localDocument) {
          upsertLocalDocumentRecord({
            ...localDocument,
            syncStatus: 'failed',
          });
        }
        enqueueLocalDocumentOperation({
          ...operation,
          lastError: error?.message || 'Erreur de synchronisation',
        });
        break;
      }
    }
  })().finally(() => {
    documentFlushPromise = null;
  });

  return documentFlushPromise;
};

const scheduleQueuedDocumentSync = () => {
  if (!documentOnlineListenerRegistered && typeof window !== 'undefined') {
    window.addEventListener('online', () => {
      void flushQueuedDocumentOperations();
    });
    documentOnlineListenerRegistered = true;
  }
  void flushQueuedDocumentOperations();
};

const mergeRemoteDocumentsIntoLocalCache = async (remoteDocuments: AppDocument[]) => {
  const queue = readLocalDocumentQueue();
  const pendingIds = new Set(queue.map((entry) => entry.documentId));

  remoteDocuments.forEach((document) => {
    const localDocument = readLocalDocumentRecords().find((entry) => entry.remoteId === document.id || entry.id === document.id);
    if (localDocument && pendingIds.has(localDocument.id)) {
      return;
    }
    upsertLocalDocumentRecord({
      ...(localDocument || document),
      ...document,
      id: localDocument?.id || document.id,
      remoteId: document.id,
      syncStatus: 'synced',
      lastSyncedAt: document.updatedAt,
    });
  });
};

const fetchRemoteDocuments = async (patientId: string, dossierId?: string): Promise<AppDocument[]> => {
  const query = new URLSearchParams();
  if (dossierId) {
    query.set('dossierId', dossierId);
  }
  const suffix = query.toString() ? `?${query.toString()}` : '';
  const result = await apiFetch<DocumentsResult>(`/api/documents/${encodeURIComponent(patientId)}${suffix}`);
  return (result.data?.documents || []).map(mapApiDocument);
};

export const uploadDocument = async (
  patientId: string,
  file: File,
  patientName: string,
  customName: string,
  tags: string[],
  dossierId?: string,
): Promise<{ success: boolean; error: string | null; document?: AppDocument }> => {
  const title = customName.trim() || file.name.replace(/\.[^.]+$/, '') || 'Document';
  const fileName = buildDocumentFileName(title, file.name);
  const localId = createClientUuid();
  const now = new Date().toISOString();
  const localDocument: LocalDocumentRecord = {
    id: localId,
    patientId,
    dossierId: dossierId || null,
    patientDisplayName: patientName,
    title,
    fileName,
    mimeType: normalizeDocumentMimeType(fileName, file.type || 'application/octet-stream'),
    tags: tags.length > 0 ? tags : ['Autre'],
    createdAt: now,
    updatedAt: now,
    lastSyncedAt: null,
    syncStatus: 'pending',
    remotePath: '',
    url: '',
    type: inferDocumentType(fileName, file.type || 'application/octet-stream'),
  };

  upsertLocalDocumentRecord(localDocument);
  await putLocalDocumentBlob(localId, file);
  enqueueLocalDocumentOperation({
    documentId: localId,
    type: 'upload',
    patientId,
    queuedAt: now,
  });
  scheduleQueuedDocumentSync();

  return {
    success: true,
    error: null,
    document: localDocument,
  };
};

export const updateDocument = async (
  documentId: string,
  updates: { title?: string; tags?: string[] },
): Promise<{ success: boolean; error: string | null; document?: AppDocument }> => {
  const localDocument = getLocalDocumentRecord(documentId);
  if (!localDocument) {
    return { success: false, error: 'Document introuvable' };
  }

  const updatedDocument: LocalDocumentRecord = {
    ...localDocument,
    title: updates.title ?? localDocument.title,
    tags: updates.tags ?? localDocument.tags,
    updatedAt: new Date().toISOString(),
    syncStatus: 'pending',
  };
  upsertLocalDocumentRecord(updatedDocument);
  enqueueLocalDocumentOperation({
    documentId,
    type: localDocument.remoteId ? 'update' : 'upload',
    patientId: localDocument.patientId,
    queuedAt: updatedDocument.updatedAt,
  });
  scheduleQueuedDocumentSync();

  return { success: true, error: null, document: updatedDocument };
};

export const renameDocument = async (documentId: string, newTitle: string): Promise<{ success: boolean; error: string | null; document?: AppDocument }> =>
  updateDocument(documentId, { title: newTitle });

export const deleteDocument = async (documentId: string): Promise<{ success: boolean; error: string | null }> => {
  const localDocument = getLocalDocumentRecord(documentId);
  if (!localDocument) {
    return { success: false, error: 'Document introuvable' };
  }

  removeLocalDocumentRecord(documentId);
  await deleteLocalDocumentBlob(documentId);

  if (localDocument.remoteId) {
    enqueueLocalDocumentOperation({
      documentId,
      type: 'delete',
      patientId: localDocument.patientId,
      remoteId: localDocument.remoteId,
      queuedAt: new Date().toISOString(),
    });
    scheduleQueuedDocumentSync();
  } else {
    clearLocalDocumentOperation(documentId);
  }

  return { success: true, error: null };
};

export const fetchDocumentBlob = async (document: Pick<AppDocument, 'id' | 'remoteId' | 'fileName' | 'mimeType'>): Promise<Blob> => {
  const localBlob = await getLocalDocumentBlob(document.id);
  if (localBlob) {
    return localBlob;
  }
  const remoteBlob = await fetchRemoteDocumentBlob(document);
  await putLocalDocumentBlob(document.id, remoteBlob);
  return remoteBlob;
};

// --- Notes Service ---
const fetchRemoteNotePages = async (
  patientId: string,
  options: NoteScopeOptions,
): Promise<NotePage[]> => {
  const query = new URLSearchParams({
    scopeType: options.scopeType,
    scopeId: options.scopeId,
    tabKey: options.tabKey,
  });
  const result = await apiFetch<NotePagesResult>(
    `/api/note-pages/${encodeURIComponent(patientId)}?${query.toString()}`,
  );
  return result.data?.notePages || [];
};

const saveRemoteNotePage = async ({
  notePageId,
  patientId,
  dossierId,
  scopeType,
  scopeId,
  tabKey,
  pageNumber,
  textContent,
  drawingJson,
  layoutKind = 'freeform',
}: {
  notePageId?: string;
  patientId: string;
  dossierId?: string;
  scopeType: string;
  scopeId: string;
  tabKey: string;
  pageNumber: number;
  textContent: string;
  drawingJson: string;
  layoutKind?: string;
}): Promise<NotePage> => {
  const result = await apiFetch<NotePagesResult>('/api/note-pages', {
    method: 'PUT',
    body: JSON.stringify({
      notePageId,
      patientId,
      dossierId,
      scopeType,
      scopeId,
      tabKey,
      pageNumber,
      textContent,
      drawingJson,
      layoutKind,
    }),
  });
  if (!result.data?.notePage) {
    throw new Error(result.error || 'Sauvegarde impossible');
  }
  return result.data.notePage;
};

const deleteRemoteNotePage = async (
  notePageId: string,
  patientId: string,
): Promise<boolean> => {
  const result = await apiFetch<NotePagesResult>(
    `/api/note-pages/${encodeURIComponent(notePageId)}?patientId=${encodeURIComponent(patientId)}`,
    { method: 'DELETE' },
  );
  return Boolean(result.data?.deleted);
};

const shouldAttemptNoteSync = (): boolean => {
  if (typeof window === 'undefined') return false;
  if (!getSessionToken()) return false;
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return false;
  return true;
};

const mergeRemoteNotesIntoLocalStore = async (remotePages: NotePage[]): Promise<void> => {
  if (!supportsIndexedDbNotes() || remotePages.length === 0) return;

  const recordsToWrite: LocalNotePageRecord[] = [];
  for (const remotePage of remotePages) {
    const pendingOperation = await getQueuedNoteOperation(remotePage.id);
    if (pendingOperation) {
      continue;
    }

    const localRecord = await getLocalNotePageById(remotePage.id);
    if (
      localRecord
      && new Date(localRecord.updatedAt || 0).getTime() > new Date(remotePage.updatedAt || 0).getTime()
      && localRecord.syncStatus !== 'synced'
    ) {
      continue;
    }

    recordsToWrite.push(toLocalNotePageRecord(remotePage, 'synced'));
  }

  await bulkUpsertLocalNotePages(recordsToWrite);
};

const flushQueuedNoteOperations = async (): Promise<void> => {
  if (!supportsIndexedDbNotes() || !shouldAttemptNoteSync()) {
    return;
  }
  if (noteSyncPromise) {
    return noteSyncPromise;
  }

  noteSyncPromise = (async () => {
    const operations = await listQueuedNoteOperations();

    for (const operation of operations) {
      try {
        if (operation.type === 'delete') {
          await deleteRemoteNotePage(operation.notePageId, operation.patientId);
          await deleteQueuedNoteOperation(operation.notePageId);
          continue;
        }

        const localRecord = await getLocalNotePageById(operation.notePageId);
        if (!localRecord || localRecord.deleted) {
          await deleteQueuedNoteOperation(operation.notePageId);
          continue;
        }

        const savedPage = await saveRemoteNotePage({
          notePageId: localRecord.id,
          patientId: localRecord.patientId,
          dossierId: localRecord.dossierId || undefined,
          scopeType: localRecord.scopeType,
          scopeId: localRecord.scopeId,
          tabKey: localRecord.tabKey,
          pageNumber: localRecord.pageNumber,
          textContent: localRecord.textContent,
          drawingJson: localRecord.drawingJson,
          layoutKind: localRecord.layoutKind || 'freeform',
        });

        await putLocalNotePage(toLocalNotePageRecord(savedPage, 'synced'));
        await deleteQueuedNoteOperation(operation.notePageId);
      } catch (error: any) {
        const localRecord = await getLocalNotePageById(operation.notePageId);
        if (localRecord) {
          await putLocalNotePage({
            ...localRecord,
            syncStatus: 'failed',
          });
        }
        await putQueuedNoteOperation({
          ...operation,
          lastError: error?.message || 'Erreur de synchronisation',
        });
        if (typeof navigator !== 'undefined' && navigator.onLine === false) {
          break;
        }
      }
    }
  })().finally(() => {
    noteSyncPromise = null;
  });

  return noteSyncPromise;
};

const scheduleQueuedNoteSync = () => {
  if (!noteSyncListenerRegistered && typeof window !== 'undefined') {
    window.addEventListener('online', () => {
      void flushQueuedNoteOperations();
    });
    noteSyncListenerRegistered = true;
  }
  void flushQueuedNoteOperations();
};

const refreshNoteScopeInBackground = (patientId: string, options: NoteScopeOptions) => {
  if (!shouldAttemptNoteSync()) {
    return;
  }

  void flushQueuedNoteOperations()
    .then(() => fetchRemoteNotePages(patientId, options))
    .then((remotePages) => mergeRemoteNotesIntoLocalStore(remotePages))
    .catch((error) => {
      console.error('Failed to refresh notes scope from remote', error);
    });
};

export const fetchNotePages = async (
  patientId: string,
  options: NoteScopeOptions,
): Promise<NotePage[]> => {
  if (!supportsIndexedDbNotes()) {
    return fetchRemoteNotePages(patientId, options);
  }

  const localPages = await listLocalNotePages(patientId, options);
  if (localPages.length > 0) {
    refreshNoteScopeInBackground(patientId, options);
    return localPages;
  }

  try {
    const remotePages = await fetchRemoteNotePages(patientId, options);
    await mergeRemoteNotesIntoLocalStore(remotePages);
    return listLocalNotePages(patientId, options);
  } catch (error) {
    console.error('Failed to fetch note pages from remote', error);
    return localPages;
  }
};

export const createNotePage = async (
  patientId: string,
  options: NoteScopeOptions & { layoutKind?: string },
): Promise<NotePage> => {
  const localPages = supportsIndexedDbNotes()
    ? await listLocalNotePages(patientId, options)
    : [];
  const nextPageNumber = localPages.length > 0
    ? Math.max(...localPages.map((page) => page.pageNumber)) + 1
    : 0;

  const savedPage = await saveRemoteNotePage({
    notePageId: undefined,
    patientId,
    dossierId: options.scopeId,
    scopeType: options.scopeType,
    scopeId: options.scopeId,
    tabKey: options.tabKey,
    pageNumber: nextPageNumber,
    textContent: '',
    drawingJson: '',
    layoutKind: options.layoutKind || 'freeform',
  });

  if (supportsIndexedDbNotes()) {
    await putLocalNotePage(toLocalNotePageRecord(savedPage, 'synced'));
    await deleteQueuedNoteOperation(savedPage.id).catch(() => undefined);
  }

  return savedPage;
};

export const saveNotePage = async ({
  notePageId,
  patientId,
  dossierId,
  scopeType,
  scopeId,
  tabKey,
  pageNumber,
  textContent,
  drawingJson,
  layoutKind = 'freeform',
}: {
  notePageId?: string;
  patientId: string;
  dossierId?: string;
  scopeType: string;
  scopeId: string;
  tabKey: string;
  pageNumber: number;
  textContent: string;
  drawingJson: string;
  layoutKind?: string;
}): Promise<NotePage> => {
  const savedPage = await saveRemoteNotePage({
    notePageId,
    patientId,
    dossierId,
    scopeType,
    scopeId,
    tabKey,
    pageNumber,
    textContent,
    drawingJson,
    layoutKind,
  });

  if (supportsIndexedDbNotes()) {
    await putLocalNotePage(toLocalNotePageRecord(savedPage, 'synced'));
    await deleteQueuedNoteOperation(savedPage.id).catch(() => undefined);
  }

  return savedPage;
};

export const deleteNotePage = async (
  notePageId: string,
  patientId: string,
): Promise<boolean> => {
  await deleteRemoteNotePage(notePageId, patientId);

  if (supportsIndexedDbNotes()) {
    await deleteLocalNotePageRecord(notePageId).catch(() => undefined);
    await deleteQueuedNoteOperation(notePageId).catch(() => undefined);
  }
  return true;
};

// --- Documents Service ---

export const fetchDocuments = async (patientId: string, dossierId?: string): Promise<AppDocument[]> => {
  const localDocuments = listLocalDocuments(patientId, dossierId);
  if (localDocuments.length > 0) {
    if (shouldAttemptDocumentSync()) {
      void flushQueuedDocumentOperations()
        .then(() => fetchRemoteDocuments(patientId, dossierId))
        .then((remoteDocuments) => mergeRemoteDocumentsIntoLocalCache(remoteDocuments))
        .catch((error) => console.error('Unexpected error refreshing documents:', error));
    }
    return localDocuments;
  }

  try {
    const remoteDocuments = await fetchRemoteDocuments(patientId, dossierId);
    await mergeRemoteDocumentsIntoLocalCache(remoteDocuments);
    return listLocalDocuments(patientId, dossierId);
  } catch (error) {
    console.error('Unexpected error fetching documents:', error);
    return localDocuments;
  }
};

export const fetchDocumentSyncStatus = async (): Promise<{
  mode: 'nocodb' | 'local';
  nocodbTablesReady: boolean;
  localCounts?: { documents: number; notePages: number };
  remoteCounts?: { documents: number; notePages: number };
}> => {
  const queue = readLocalDocumentQueue();
  const records = readLocalDocumentRecords();
  const pending = records.filter((record) => record.syncStatus !== 'synced').length;
  return {
    mode: pending > 0 || queue.length > 0 ? 'local' : 'nocodb',
    nocodbTablesReady: true,
    localCounts: {
      documents: records.length,
      notePages: 0,
    },
    remoteCounts: {
      documents: records.filter((record) => record.syncStatus === 'synced').length,
      notePages: 0,
    },
  };
};

export const getCachedDocumentBlob = (documentId: string): Blob | null => documentBlobCache.get(documentId) || null;

export const preloadDocumentsView = async (patientId: string, dossierId?: string): Promise<AppDocument[]> => {
  const documents = await fetchDocuments(patientId, dossierId);
  const previewableDocs = documents.filter((document) => document.type === 'image' || document.type === 'pdf');
  await Promise.allSettled(previewableDocs.map((document) => fetchDocumentBlob(document)));
  return documents;
};

export const updateBeneficiaryRemote = async (patientId: string, updates: Partial<Patient>): Promise<{ success: boolean; error: string | null; data?: { patient?: Patient } }> => {
  try {
    const result = await apiFetch<MutationResult>(`/api/beneficiaires/${encodeURIComponent(patientId)}`, {
      method: 'PATCH',
      body: JSON.stringify(updates),
    });
    return { success: result.success, error: result.error, data: result.data };
  } catch (error: any) {
    console.error('Unexpected error updating beneficiary:', error);
    return { success: false, error: error.message || 'Unexpected error' };
  }
};

const flushQueuedBeneficiaryUpdates = async (): Promise<void> => {
  if (!shouldAttemptBeneficiarySync()) {
    return;
  }
  if (beneficiaryFlushPromise) {
    return beneficiaryFlushPromise;
  }

  beneficiaryFlushPromise = (async () => {
    const patches = Object.values(readBeneficiaryPatchMap())
      .sort((left, right) => new Date(left.updatedAt).getTime() - new Date(right.updatedAt).getTime());

    for (const patch of patches) {
      const result = await updateBeneficiaryRemote(patch.patientId, patch.updates);
      if (result.success) {
        clearBeneficiaryPatch(patch.patientId);
        continue;
      }

      setBeneficiaryPatch({
        ...patch,
        lastError: result.error || 'Synchronisation bénéficiaire impossible',
      });
      break;
    }
  })().finally(() => {
    beneficiaryFlushPromise = null;
  });

  return beneficiaryFlushPromise;
};

const scheduleQueuedBeneficiarySync = () => {
  if (!beneficiaryOnlineListenerRegistered && typeof window !== 'undefined') {
    window.addEventListener('online', () => {
      void flushQueuedBeneficiaryUpdates();
    });
    beneficiaryOnlineListenerRegistered = true;
  }
  if (typeof window === 'undefined') {
    void flushQueuedBeneficiaryUpdates();
    return;
  }
  if (beneficiaryFlushTimer) {
    window.clearTimeout(beneficiaryFlushTimer);
  }
  beneficiaryFlushTimer = window.setTimeout(() => {
    beneficiaryFlushTimer = null;
    void flushQueuedBeneficiaryUpdates();
  }, 450);
};

export const updateBeneficiary = async (patientId: string, updates: Partial<Patient>): Promise<{ success: boolean; error: string | null; data?: { patient?: Patient } }> => {
  const normalizedUpdates = { ...updates };
  const patch = mergeBeneficiaryPatch(patientId, normalizedUpdates);
  setBeneficiaryPatch(patch);
  scheduleQueuedBeneficiarySync();

  return {
    success: true,
    error: null,
    data: {
      patient: {
        ...(normalizedUpdates as Patient),
      },
    },
  };
};

export const createBeneficiary = async (
  updates: Partial<Patient>,
): Promise<{ success: boolean; error: string | null; data?: { id?: string; dossierId?: string } }> => {
  try {
    const result = await apiFetch<MutationResult>('/api/beneficiaires', {
      method: 'POST',
      body: JSON.stringify(updates),
    });
    return { success: result.success, error: result.error, data: result.data };
  } catch (error: any) {
    console.error('Unexpected error creating beneficiary:', error);
    return { success: false, error: error.message || 'Unexpected error' };
  }
};

export const updateHousing = async (
  beneficiaryId: string,
  housingId: string | undefined,
  updates: Partial<Housing>,
): Promise<{ success: boolean; error: string | null; data?: { id?: string } }> => {
  try {
    const result = await apiFetch<MutationResult>(`/api/logements/by-beneficiary/${encodeURIComponent(beneficiaryId)}`, {
      method: 'PATCH',
      body: JSON.stringify({ ...updates, housingId }),
    });
    return { success: result.success, error: result.error, data: result.data };
  } catch (error: any) {
    console.error('Unexpected error updating housing:', error);
    return { success: false, error: error.message };
  }
};

export const fetchReferenceData = async (): Promise<ReferenceData> => {
  if (referenceDataCache) {
    return referenceDataCache;
  }

  if (!referenceDataPromise) {
    referenceDataPromise = apiFetch<ReferenceData>('/api/references')
      .then((data) => {
        referenceDataCache = data;
        return data;
      })
      .finally(() => {
        referenceDataPromise = null;
      });
  }

  return referenceDataPromise;
};

export const createDossier = async (beneficiaryId: string, ergoId: string): Promise<{ success: boolean; data?: Dossier; error?: string }> => {
  try {
    const result = await updateDossier(`temp-${beneficiaryId}`, {
      ergoId,
      status: DossierStatus.TO_VISIT,
    });
    if (!result.success || !result.data?.id) {
      return { success: false, error: result.error || 'Création du dossier impossible' };
    }

    const dossiers = await fetchDossiers();
    const created = dossiers.find((dossier) => dossier.id === result.data?.id || dossier.patient.id === beneficiaryId);
    if (!created) {
      return { success: false, error: 'Dossier créé mais non retrouvé dans la liste' };
    }
    return { success: true, data: created };
  } catch (err: any) {
    console.error("Unexpected error creating dossier:", err);
    return { success: false, error: err.message };
  }
};

export const createBeneficiaryWithDossier = async (
  beneficiary: Partial<Patient>,
  ergoId = ''
): Promise<{ success: boolean; data?: Dossier; error?: string }> => {
  try {
    const createdBeneficiary = await createBeneficiary(beneficiary);
    if (!createdBeneficiary.success || !createdBeneficiary.data?.id) {
      return { success: false, error: createdBeneficiary.error || 'Création du bénéficiaire impossible' };
    }

    if (ergoId) {
      return createDossier(createdBeneficiary.data.id, ergoId);
    }

    const dossiers = await fetchDossiers();
    const created = dossiers.find((dossier) =>
      dossier.id === createdBeneficiary.data?.dossierId
      || dossier.patient.id === createdBeneficiary.data?.id
    );
    if (!created) {
      return { success: false, error: 'Dossier créé mais non retrouvé dans la liste' };
    }

    return { success: true, data: created };
  } catch (error: any) {
    console.error('Unexpected error creating beneficiary with dossier:', error);
    return { success: false, error: error.message || 'Unexpected error' };
  }
};

// =============================================================
// --- Diagnostic Sanitaires Service ---
// =============================================================

const mapSanitairesFromDB = (data: any): DiagnosticSanitaires => ({
  id: data.id,
  dossierId: data.dossier_id,
  sdbInstances: (() => {
    const raw = data.sdb_instances_json;
    if (!raw) return undefined;
    if (Array.isArray(raw)) return raw;
    try { return JSON.parse(raw); } catch { return undefined; }
  })(),
  wcInstances: (() => {
    const raw = data.wc_instances_json;
    if (!raw) return undefined;
    if (Array.isArray(raw)) return raw;
    try { return JSON.parse(raw); } catch { return undefined; }
  })(),
  sdbNiveauPiecesVie: data.sdb_niveau_pieces_vie,
  wcNiveau: data.wc_niveau,
  wcEtage: data.wc_etage,
  sdbBaignoire: data.sdb_baignoire,
  sdbBaignoireHauteur: data.sdb_baignoire_hauteur,
  sdbBacDouche: data.sdb_bac_douche,
  sdbBacDoucheHauteur: data.sdb_bac_douche_hauteur,
  sdbVasqueSuspendue: data.sdb_vasque_suspendue,
  sdbVasqueSuspendueHauteur: data.sdb_vasque_suspendue_hauteur,
  sdbVasqueColonne: data.sdb_vasque_colonne,
  sdbVasqueColonneHauteur: data.sdb_vasque_colonne_hauteur,
  sdbMeubleVasque: data.sdb_meuble_vasque,
  sdbMeubleVasqueHauteur: data.sdb_meuble_vasque_hauteur,
  sdbBidet: data.sdb_bidet,
  sdbBidetHauteur: data.sdb_bidet_hauteur,
  sdbParoiDouche: data.sdb_paroi_douche,
  sdbParoiDoucheHauteur: data.sdb_paroi_douche_hauteur,
  sdbSolGlissant: data.sdb_sol_glissant,
  sdbMachineALaver: data.sdb_machine_a_laver,
  sdbMachineALaverHauteur: data.sdb_machine_a_laver_hauteur,
  wcCuvetteBonneHauteur: data.wc_cuvette_bonne_hauteur,
  wcCuvetteTropBasse: data.wc_cuvette_trop_basse,
  wcCuvetteHauteur: data.wc_cuvette_hauteur,
  wcBarreRelevement: data.wc_barre_relevement,
  porteSdbLargeurSuffisante: data.porte_sdb_largeur_suffisante,
  porteSdbDimension: data.porte_sdb_dimension,
  porteSdbSensAdapte: data.porte_sdb_sens_adapte,
  porteWcLargeurSuffisante: data.porte_wc_largeur_suffisante,
  porteWcDimension: data.porte_wc_dimension,
  porteWcSensAdapte: data.porte_wc_sens_adapte,
  observationEquipementsUtilisation: data.observation_equipements_utilisation,
});

export const fetchDiagnosticSanitaires = async (dossierId: string): Promise<DiagnosticSanitaires | null> => {
  try {
    return await apiFetch<DiagnosticSanitaires | null>(`/api/diagnostic-sanitaires/${encodeURIComponent(dossierId)}`);
  } catch (e) { console.error('Unexpected error fetching sanitaires:', e); return null; }
};

export const upsertDiagnosticSanitaires = async (dossierId: string, updates: Partial<DiagnosticSanitaires>): Promise<{ success: boolean; error: string | null }> => {
  try {
    await queueReleveForSync('diagnostic_sanitaires', dossierId, updates as Record<string, unknown>);
    return { success: true, error: null };
  } catch (e: any) { return { success: false, error: e.message }; }
};

// =============================================================
// --- Mesures Anthropométriques Service ---
// =============================================================

const mapMesuresFromDB = (data: any): MesuresAnthropometriques => ({
  id: data.id,
  dossierId: data.dossier_id,
  deboutHauteurCoude: data.debout_hauteur_coude,
  assisHauteurAssise: data.assis_hauteur_assise,
  assisProfondeurGenoux: data.assis_profondeur_genoux,
  assisHauteurCoudes: data.assis_hauteur_coudes,
  observations: data.observations,
});

export const fetchMesuresAnthropometriques = async (dossierId: string): Promise<MesuresAnthropometriques | null> => {
  try {
    return await apiFetch<MesuresAnthropometriques | null>(`/api/mesures/${encodeURIComponent(dossierId)}`);
  } catch (e) { console.error('Unexpected error fetching mesures:', e); return null; }
};

export const upsertMesuresAnthropometriques = async (dossierId: string, updates: Partial<MesuresAnthropometriques>): Promise<{ success: boolean; error: string | null }> => {
  try {
    await queueReleveForSync('mesures_anthropometriques', dossierId, updates as Record<string, unknown>);
    return { success: true, error: null };
  } catch (e: any) { return { success: false, error: e.message }; }
};

// =============================================================
// --- Observations / Synthèse Service ---
// =============================================================

const mapObservationsFromDB = (data: any): ObservationsSynthese => ({
  id: data.id,
  dossierId: data.dossier_id,
  beneficiaireId: data.beneficiaire_id,
  observationEquipements: data.observation_equipements,
  projetSouhaitUsage: data.projet_souhait_usage,
  resumePreconisations: data.resume_preconisations,
});

export const fetchObservationsSynthese = async (dossierId: string, beneficiaireId: string): Promise<ObservationsSynthese | null> => {
  try {
    void beneficiaireId;
    return await apiFetch<ObservationsSynthese | null>(`/api/observations/${encodeURIComponent(dossierId)}`);
  } catch (e) { console.error('Unexpected error fetching observations:', e); return null; }
};

export const upsertObservationsSynthese = async (dossierId: string, beneficiaireId: string, updates: Partial<ObservationsSynthese>): Promise<{ success: boolean; error: string | null }> => {
  try {
    void beneficiaireId;
    await queueReleveForSync('observations_synthese', dossierId, updates as Record<string, unknown>);
    return { success: true, error: null };
  } catch (e: any) { return { success: false, error: e.message }; }
};
