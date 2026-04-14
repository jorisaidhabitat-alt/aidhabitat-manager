import { localDb, type ReleveEnAttente, type ReleveEnAttenteType, upsertReleveEnAttente } from './localDb';

const NOCODB_API_ROOT = 'https://apps-nocodb.z5avx1.easypanel.host';
const NOCODB_TOKEN_STORAGE_KEY = 'aidhabitat.nocodb_token';

const RELEVE_TABLES: Record<ReleveEnAttenteType, string> = {
  diagnostic_sanitaires: 'mdukulxcd18ae3o',
  mesures_anthropometriques: 'mbaj91z97utreco',
  observations_synthese: 'mbkuomk0aazes1c',
};

const stringValue = (value: unknown) => (value == null ? '' : String(value));
const nullableString = (value: unknown) => {
  const normalized = stringValue(value).trim();
  return normalized ? normalized : null;
};
const boolText = (value: unknown) => (Boolean(value) ? 'Oui' : 'Non');

const buildNocoDbHeaders = (token: string) => ({
  Accept: 'application/json',
  'Content-Type': 'application/json',
  'xc-token': token,
});

const normalizeRows = (payload: any): any[] => {
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.list)) return payload.list;
  if (Array.isArray(payload?.records)) return payload.records;
  return [];
};

const queryExistingRecord = async (type: ReleveEnAttenteType, dossierId: string, token: string) => {
  const where = encodeURIComponent(`(dossier_id,eq,${dossierId})`);
  const response = await fetch(
    `${NOCODB_API_ROOT}/api/v2/tables/${encodeURIComponent(RELEVE_TABLES[type])}/records?limit=1&where=${where}`,
    { headers: buildNocoDbHeaders(token) },
  );

  if (!response.ok) {
    throw new Error(`Impossible de lire la table ${type} (${response.status})`);
  }

  return normalizeRows(await response.json())[0] || null;
};

const buildDiagnosticPayload = (dossierId: string, payload: Record<string, unknown>) => {
  const sdbInstances = Array.isArray(payload.sdbInstances) ? payload.sdbInstances : [];
  const wcInstances = Array.isArray(payload.wcInstances) ? payload.wcInstances : [];
  const primaryBathroom = (sdbInstances[0] || {}) as Record<string, unknown>;
  const primaryWc = (wcInstances[0] || {}) as Record<string, unknown>;

  return {
    dossier_id: dossierId,
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
};

const buildMesuresPayload = (dossierId: string, payload: Record<string, unknown>) => ({
  dossier_id: dossierId,
  debout_hauteur_coude: nullableString(payload.deboutHauteurCoude),
  assis_hauteur_assise: nullableString(payload.assisHauteurAssise),
  assis_profondeur_genoux: nullableString(payload.assisProfondeurGenoux),
  assis_hauteur_coudes: nullableString(payload.assisHauteurCoudes),
  observations: nullableString(payload.observations),
  updated_at: new Date().toISOString(),
});

const buildObservationsPayload = (dossierId: string, payload: Record<string, unknown>) => ({
  dossier_id: dossierId,
  observation_equipements: nullableString(payload.observationEquipements),
  projet_souhait_usage: nullableString(payload.projetSouhaitUsage),
  resume_preconisations: nullableString(payload.resumePreconisations),
  updated_at: new Date().toISOString(),
});

const buildPayloadForType = (entry: ReleveEnAttente) => {
  switch (entry.type) {
    case 'diagnostic_sanitaires':
      return buildDiagnosticPayload(entry.dossierId, entry.payload);
    case 'mesures_anthropometriques':
      return buildMesuresPayload(entry.dossierId, entry.payload);
    case 'observations_synthese':
      return buildObservationsPayload(entry.dossierId, entry.payload);
    default:
      return { dossier_id: entry.dossierId, updated_at: new Date().toISOString() };
  }
};

const syncPendingEntry = async (entry: ReleveEnAttente, token: string) => {
  const tableId = RELEVE_TABLES[entry.type];
  const payload = buildPayloadForType(entry);
  const existing = await queryExistingRecord(entry.type, entry.dossierId, token);

  if (existing?.Id || existing?.id) {
    const response = await fetch(`${NOCODB_API_ROOT}/api/v2/tables/${encodeURIComponent(tableId)}/records`, {
      method: 'PATCH',
      headers: buildNocoDbHeaders(token),
      body: JSON.stringify([{ Id: Number(existing.Id || existing.id), ...payload }]),
    });
    if (!response.ok) {
      throw new Error(`Mise à jour NocoDB impossible pour ${entry.type} (${response.status})`);
    }
    return;
  }

  const response = await fetch(`${NOCODB_API_ROOT}/api/v2/tables/${encodeURIComponent(tableId)}/records`, {
    method: 'POST',
    headers: buildNocoDbHeaders(token),
    body: JSON.stringify({
      uuid_source: crypto.randomUUID(),
      created_at: new Date().toISOString(),
      ...payload,
    }),
  });

  if (!response.ok) {
    throw new Error(`Création NocoDB impossible pour ${entry.type} (${response.status})`);
  }
};

let onlineListenerRegistered = false;
let syncPromise: Promise<void> | null = null;

export const queueReleveForSync = async (
  type: ReleveEnAttenteType,
  dossierId: string,
  payload: Record<string, unknown>,
) => {
  await upsertReleveEnAttente(type, dossierId, payload);
};

export const flushPendingReleves = async () => {
  if (typeof window === 'undefined') return;
  if (navigator.onLine === false) return;
  if (syncPromise) return syncPromise;

  const token = window.localStorage.getItem(NOCODB_TOKEN_STORAGE_KEY);
  if (!token) return;

  syncPromise = (async () => {
    const entries = await localDb.releves_attente.orderBy('updatedAt').toArray();
    for (const entry of entries) {
      if (!entry.id) continue;
      await syncPendingEntry(entry, token);
      await localDb.releves_attente.delete(entry.id);
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
