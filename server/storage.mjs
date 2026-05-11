/**
 * Storage abstraction — version 2026-05-11 (post-fix Fluid Compute
 * multi-instance).
 *
 * Plus AUCUN stockage RAM côté serveur. Tous les chunks d'upload
 * transitent par NocoDB (`mobile_document_chunks` avec préfixe
 * `upload_${uploadId}` comme `document_uuid_source`).
 *
 * Pourquoi le changement (bug rapporté 2026-05-11) :
 *   La version précédente stockait les chunks en RAM via une Map
 *   `_inMemoryChunks` partagée au sein d'une seule instance Node.
 *   Avec Vercel Fluid Compute multi-instance, `POST /upload/chunk` et
 *   `POST /upload/finalize` peuvent tomber sur DEUX instances
 *   différentes (le load balancer scale dès que la charge augmente).
 *   L'instance qui reçoit `/finalize` n'a aucun chunk en RAM → throw
 *   « Aucun chunk trouvé » → 500. Symptôme côté utilisateur : doc
 *   modifié reste en « En attente » indéfiniment, console DevTools
 *   « POST /api/documents/upload/finalize 500 Internal Server Error ».
 *
 * Coût : ~3N opérations NocoDB par upload (chunk insert, finalize
 * read, cleanup delete) au lieu de N (chunk insert seul). Acceptable
 * pour des fichiers < 50 MB. NocoDB tient sans difficulté (testé
 * jusqu'à 100 requêtes parallèles).
 *
 * Lifecycle d'un chunk temporaire :
 *   1. `putChunk(uploadId, idx, buf)` → INSERT NocoDB avec
 *      `document_uuid_source = "upload_<uploadId>"`.
 *   2. `reassembleChunks(uploadId)` → SELECT NocoDB filtré sur ce
 *      préfixe, validation de contiguïté, concat en Buffer.
 *   3. `deleteChunks(uploadId)` → DELETE NocoDB (appelé après
 *      `finalize` succès OU après rejet pour corruption).
 *   4. `purgeStaleChunks` → DELETE des `upload_*` plus vieux que
 *      `olderThan` (uploads abandonnés par fermeture d'onglet).
 *
 * Limites :
 *   - Pas de stockage RAM = chaque chunk fait un round-trip réseau
 *     NocoDB. Pour un PDF de 5 MB en chunks 1 MB = 5 inserts + 1 read.
 *     Latence acceptable (~300 ms par insert NocoDB en parallèle via
 *     Promise.all côté serveur).
 *   - Une instance NocoDB partagée par tous les uploads : si NocoDB
 *     tombe, les uploads échouent. Mais c'était déjà le cas pour le
 *     reste de l'app.
 */

import { callNocoTool } from './nocodbMcpClient.mjs';

const TMP_DOC_UUID_PREFIX = 'upload_';

/**
 * Cache module-level de l'id NocoDB de `mobile_document_chunks`.
 * Récupéré une fois via `getTablesList` puis réutilisé pour la vie de
 * l'instance Node. Pas de problème en multi-instance Vercel : chaque
 * instance fait sa propre découverte au premier appel.
 */
let _documentChunksTableId = null;

const getDocumentChunksTableId = async () => {
  if (_documentChunksTableId) return _documentChunksTableId;
  const payload = await callNocoTool('getTablesList');
  const tables = Array.isArray(payload) ? payload : (payload?.records || []);
  const found = tables.find((t) =>
    String(t?.title || '').trim().toLowerCase() === 'mobile_document_chunks',
  );
  if (!found?.id) {
    throw new Error(
      'Table NocoDB `mobile_document_chunks` introuvable — '
      + 'vérifier la connexion NocoDB et le schéma.',
    );
  }
  _documentChunksTableId = String(found.id);
  return _documentChunksTableId;
};

/**
 * Lit tous les chunks NocoDB d'un upload donné, triés par
 * `chunk_index` croissant. Renvoie `[]` si aucun chunk trouvé.
 */
const queryUploadChunks = async (uploadId) => {
  const tableId = await getDocumentChunksTableId();
  const tmpKey = `${TMP_DOC_UUID_PREFIX}${uploadId}`;
  const records = [];
  let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId,
      page,
      pageSize: 100,
      fields: ['uuid_source', 'chunk_index', 'chunk_base64', 'updated_at'],
      where: `(document_uuid_source,eq,${JSON.stringify(tmpKey)})`,
    });
    const batch = Array.isArray(payload?.records) ? payload.records : [];
    records.push(...batch);
    if (!payload?.next || batch.length === 0) break;
    page += 1;
  }
  return records.sort((a, b) => Number(a.chunk_index) - Number(b.chunk_index));
};

/**
 * Stocke un chunk binaire dans NocoDB (`mobile_document_chunks`).
 * Encodé en base64. Le `document_uuid_source` est préfixé par
 * `upload_` pour ne pas se confondre avec les chunks d'un vrai
 * document finalisé (qui ont un UUID v4).
 */
export const putChunk = async ({ uploadId, chunkIndex, buffer }) => {
  const tableId = await getDocumentChunksTableId();
  const tmpKey = `${TMP_DOC_UUID_PREFIX}${uploadId}`;
  const now = new Date().toISOString();
  await callNocoTool('createRecords', {
    tableId,
    records: [{
      fields: {
        // Chaque chunk row a son propre UUID pour ne pas se cogner si
        // le client retry le même chunkIndex après échec réseau.
        uuid_source: `chunk_${uploadId}_${chunkIndex}_${Date.now()}`,
        document_uuid_source: tmpKey,
        chunk_index: chunkIndex,
        chunk_base64: buffer.toString('base64'),
        updated_at: now,
      },
    }],
  });
  return {
    url: `nocodb://chunks/${tmpKey}/${chunkIndex}`,
    updatedAt: now,
  };
};

/**
 * Liste les chunks d'un upload, triés par index croissant. Le champ
 * `size` est la longueur du base64 (= 4/3 × taille binaire).
 */
export const listChunks = async (uploadId) => {
  const records = await queryUploadChunks(uploadId);
  return records.map((r) => ({
    url: `nocodb://chunks/${TMP_DOC_UUID_PREFIX}${uploadId}/${Number(r.chunk_index)}`,
    size: String(r.chunk_base64 || '').length,
    index: Number(r.chunk_index),
  }));
};

/**
 * Concatène tous les chunks d'un upload en un Buffer unique.
 * Throw si aucun chunk trouvé OU indices non contigus.
 */
export const reassembleChunks = async (uploadId) => {
  const records = await queryUploadChunks(uploadId);
  if (records.length === 0) {
    throw new Error(
      `Aucun chunk trouvé pour uploadId="${uploadId}" — `
      + 'le client doit retry l\'upload (chunks expirés ou jamais reçus).',
    );
  }
  for (let i = 0; i < records.length; i += 1) {
    const idx = Number(records[i].chunk_index);
    if (idx !== i) {
      throw new Error(
        `Chunks non contigus pour uploadId="${uploadId}" : `
        + `index ${i} attendu, trouvé ${idx}.`,
      );
    }
  }
  return Buffer.concat(
    records.map((r) => Buffer.from(String(r.chunk_base64 || ''), 'base64')),
  );
};

/**
 * Supprime tous les chunks NocoDB d'un upload donné. Idempotent —
 * appelé après `finalize` succès ou après rejet pour corruption pour
 * libérer les rows temporaires.
 *
 * Delete par batch de 100 pour limiter la taille du payload NocoDB.
 */
export const deleteChunks = async (uploadId) => {
  const records = await queryUploadChunks(uploadId);
  if (records.length === 0) return;
  const tableId = await getDocumentChunksTableId();
  for (let i = 0; i < records.length; i += 100) {
    const slice = records.slice(i, i + 100);
    await callNocoTool('deleteRecords', {
      tableId,
      records: slice.map((r) => ({ id: String(r.id) })),
    });
  }
};

/**
 * Purge les chunks orphelins de uploads abandonnés. À appeler depuis
 * un cron périodique (cf. `vercel.json` crons / GitHub Actions
 * scheduled workflow). Sans purge, les chunks d'uploads abandonnés
 * (utilisateur ferme l'onglet avant finalize) restent indéfiniment.
 *
 * Implémentation : lit toutes les rows avec `document_uuid_source`
 * commençant par `upload_` ET `updated_at < cutoff`, puis bulk
 * delete par batch de 100.
 */
export const purgeStaleChunks = async ({
  olderThan = 60 * 60 * 1000, // 1h par défaut
} = {}) => {
  const tableId = await getDocumentChunksTableId();
  const cutoff = new Date(Date.now() - olderThan).toISOString();
  const records = [];
  let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId,
      page,
      pageSize: 100,
      fields: ['uuid_source', 'document_uuid_source', 'updated_at'],
      where:
        `(document_uuid_source,like,${JSON.stringify(`${TMP_DOC_UUID_PREFIX}%`)})`
        + `~and(updated_at,lt,${JSON.stringify(cutoff)})`,
    });
    const batch = Array.isArray(payload?.records) ? payload.records : [];
    records.push(...batch);
    if (!payload?.next || batch.length === 0) break;
    page += 1;
  }
  if (records.length === 0) return 0;
  for (let i = 0; i < records.length; i += 100) {
    const slice = records.slice(i, i + 100);
    await callNocoTool('deleteRecords', {
      tableId,
      records: slice.map((r) => ({ id: String(r.id) })),
    });
  }
  return records.length;
};

/**
 * Backward-compat — exporté à false (plus jamais de Vercel Blob actif).
 * Du code legacy peut encore référencer ce flag pour des branches
 * conditionnelles ; elles tomberont toutes dans le path NocoDB.
 */
export const USE_BLOB = false;
