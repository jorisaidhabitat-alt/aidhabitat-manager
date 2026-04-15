import { localDb, type ReleveEnAttenteType, upsertReleveEnAttente } from './localDb';

const APP_SESSION_TOKEN_KEY = 'aidhabitat.app_session';

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

const getSessionToken = (): string => {
  if (typeof window === 'undefined') return '';
  return String(window.localStorage.getItem(APP_SESSION_TOKEN_KEY) || '');
};

const ENDPOINTS: Record<ReleveEnAttenteType, (dossierId: string) => string> = {
  diagnostic_sanitaires: (dossierId) => `/api/diagnostic-sanitaires/${encodeURIComponent(dossierId)}`,
  mesures_anthropometriques: (dossierId) => `/api/mesures/${encodeURIComponent(dossierId)}`,
  observations_synthese: (dossierId) => `/api/observations/${encodeURIComponent(dossierId)}`,
};

const syncEntryToBackend = async (entry: {
  type: ReleveEnAttenteType;
  dossierId: string;
  payload: Record<string, unknown>;
}) => {
  const sessionToken = getSessionToken();
  if (!sessionToken) {
    throw new Error('Session locale absente');
  }

  const endpointResolver = ENDPOINTS[entry.type];
  const endpoint = endpointResolver(entry.dossierId);
  const response = await fetch(resolveApiUrl(endpoint), {
    method: 'PUT',
    headers: {
      'Content-Type': 'application/json',
      'X-App-Session': sessionToken,
    },
    body: JSON.stringify(entry.payload),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(body || `HTTP ${response.status}`);
  }
};

let syncPromise: Promise<void> | null = null;
let onlineListenerRegistered = false;
let flushTimer: number | null = null;

const scheduleFlushSoon = () => {
  if (typeof window === 'undefined') return;
  if (flushTimer != null) {
    window.clearTimeout(flushTimer);
  }
  flushTimer = window.setTimeout(() => {
    flushTimer = null;
    void flushPendingReleves();
  }, 80);
};

export const queueReleveForSync = async (
  type: ReleveEnAttenteType,
  dossierId: string,
  payload: Record<string, unknown>,
) => {
  await upsertReleveEnAttente(type, dossierId, payload);
  if (typeof window !== 'undefined' && navigator.onLine) {
    scheduleFlushSoon();
  }
};

export const flushPendingReleves = async () => {
  if (typeof window === 'undefined') return;
  if (!navigator.onLine) return;
  if (syncPromise) return syncPromise;

  syncPromise = (async () => {
    const entries = await localDb.releves_attente.orderBy('updatedAt').toArray();
    for (const entry of entries) {
      if (!entry.id) continue;
      try {
        await syncEntryToBackend({
          type: entry.type,
          dossierId: entry.dossierId,
          payload: entry.payload,
        });
        await localDb.releves_attente.delete(entry.id);
      } catch (error) {
        console.error(`Sync relevé en attente impossible (${entry.type})`, error);
      }
    }
  })().finally(() => {
    syncPromise = null;
  });

  return syncPromise;
};

export const registerPendingRelevesSync = () => {
  if (typeof window === 'undefined') return () => undefined;

  const handleOnline = () => {
    void flushPendingReleves();
  };

  if (!onlineListenerRegistered) {
    window.addEventListener('online', handleOnline);
    onlineListenerRegistered = true;
  }

  return () => {
    window.removeEventListener('online', handleOnline);
    onlineListenerRegistered = false;
  };
};
