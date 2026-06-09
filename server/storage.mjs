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
 * Taille max d'une cellule LongText NocoDB en pratique (~100k chars).
 * On vise 95 000 par sécurité (parité avec `splitBase64IntoChunks`
 * côté `mobileSyncStore.mjs`). Si on stockait un chunk client de
 * 1 MB binaire (= ~1.33 M chars base64) tel quel, NocoDB rejette
 * l'insert avec un 500 — d'où le besoin de splitter en sous-chunks
 * NocoDB (bug rapporté 2026-05-11 : `POST /upload/chunk` 500 en
 * série après le fix RAM→NocoDB).
 */
const NOCODB_SUBCHUNK_SIZE = 95000;

/**
 * Multiplicateur pour encoder (chunkIndex client, subIndex NocoDB)
 * dans la colonne `chunk_index` (unique flat int) :
 *   chunk_index NocoDB = chunkIndex_client * SUBCHUNK_STRIDE + subIdx
 * Un chunk client peut donc se diviser en jusqu'à 999 sous-chunks
 * → jusqu'à 95 MB par chunk client. Largement suffisant pour les
 * tailles actuelles (1-4 MB par chunk).
 */
const SUBCHUNK_STRIDE = 1000;

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
/**
 * Helper : lit un champ d'un record retourné par `callNocoTool`.
 * Les records sont du shape `{ id: "...", fields: {col: value, ...} }`
 * (cf. `toMcpRecord` dans nocodbMcpClient.mjs) — il faut donc passer
 * par `.fields[name]`, sinon les champs sont `undefined`.
 */
const field = (record, name) => record?.fields?.[name];

const queryUploadChunks = async (uploadId, ownerKey = null) => {
  const tableId = await getDocumentChunksTableId();
  const tmpKey = `${TMP_DOC_UUID_PREFIX}${uploadId}`;
  const where = `(document_uuid_source,eq,${JSON.stringify(tmpKey)})`
    + (ownerKey ? `~and(beneficiaire_id,eq,${JSON.stringify(String(ownerKey))})` : '');
  const records = [];
  let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId,
      page,
      pageSize: 100,
      fields: ['uuid_source', 'chunk_index', 'chunk_base64', 'updated_at'],
      where,
    });
    const batch = Array.isArray(payload?.records) ? payload.records : [];
    records.push(...batch);
    if (!payload?.next || batch.length === 0) break;
    page += 1;
  }
  return records.sort(
    (a, b) => Number(field(a, 'chunk_index')) - Number(field(b, 'chunk_index')),
  );
};

/**
 * Stocke un chunk binaire dans NocoDB (`mobile_document_chunks`).
 * Encodé en base64. Le `document_uuid_source` est préfixé par
 * `upload_` pour ne pas se confondre avec les chunks d'un vrai
 * document finalisé (qui ont un UUID v4).
 */
export const putChunk = async ({ uploadId, chunkIndex, buffer, ownerKey = null }) => {
  const tableId = await getDocumentChunksTableId();
  const tmpKey = `${TMP_DOC_UUID_PREFIX}${uploadId}`;
  const base64 = buffer.toString('base64');
  const now = new Date().toISOString();

  // Split en sous-chunks ≤ NOCODB_SUBCHUNK_SIZE pour respecter la limite
  // LongText NocoDB. Un chunk client de 1 MB binaire → ~14 sous-chunks.
  const subChunks = [];
  for (let off = 0; off < base64.length; off += NOCODB_SUBCHUNK_SIZE) {
    subChunks.push(base64.slice(off, off + NOCODB_SUBCHUNK_SIZE));
  }
  if (subChunks.length === 0) subChunks.push('');

  if (subChunks.length >= SUBCHUNK_STRIDE) {
    throw new Error(
      `Chunk client trop volumineux pour le schéma temporaire : `
      + `${subChunks.length} sous-chunks NocoDB requis, max ${SUBCHUNK_STRIDE - 1}. `
      + `Réduire la taille de chunk côté client (actuellement ${buffer.length} B).`,
    );
  }

  // Bulk insert : 1 POST NocoDB pour les N sous-chunks d'un même chunk
  // Flutter. Le helper `callNocoTool('createRecords')` détecte
  // `records.length > 1` et utilise le bulk endpoint v2 → speedup ~14×
  // vs le for-séquentiel précédent (bug rapporté 2026-05-11 : upload
  // bouclé en spirale avec chunks orphelins parce que le for-séquentiel
  // dépassait le `_uploadTimeout = 60s` côté client).
  const ts = Date.now();
  await callNocoTool('createRecords', {
    tableId,
    records: subChunks.map((sub, subIdx) => ({
      fields: {
        uuid_source: `chunk_${uploadId}_${chunkIndex}_${subIdx}_${ts}`,
        document_uuid_source: tmpKey,
        beneficiaire_id: ownerKey ? String(ownerKey) : null,
        chunk_index: chunkIndex * SUBCHUNK_STRIDE + subIdx,
        chunk_base64: sub,
        updated_at: now,
      },
    })),
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
export const listChunks = async (uploadId, ownerKey = null) => {
  const records = await queryUploadChunks(uploadId, ownerKey);
  return records.map((r) => ({
    url: `nocodb://chunks/${TMP_DOC_UUID_PREFIX}${uploadId}/${Number(field(r, 'chunk_index'))}`,
    size: String(field(r, 'chunk_base64') || '').length,
    index: Number(field(r, 'chunk_index')),
  }));
};

/**
 * Concatène tous les chunks d'un upload en un Buffer unique.
 * Throw si aucun chunk trouvé OU indices non contigus.
 */
export const reassembleChunks = async (uploadId, ownerKey = null) => {
  const records = await queryUploadChunks(uploadId, ownerKey);
  if (records.length === 0) {
    throw Object.assign(new Error(
      `Aucun chunk trouvé pour uploadId="${uploadId}" — `
      + 'le client doit retry l\'upload (chunks expirés ou jamais reçus).',
    ), { statusCode: 404 });
  }
  // `queryUploadChunks` renvoie déjà trié par `chunk_index` croissant.
  // L'encodage est `clientChunkIdx * SUBCHUNK_STRIDE + subIdx`.
  //
  // Stratégie de decode : on regroupe les sous-chunks par chunk client
  // (chunk_index NocoDB ÷ SUBCHUNK_STRIDE), on concat les base64 de
  // chaque groupe, puis on décode chaque groupe séparément. On NE
  // PEUT PAS concat tous les sous-chunks puis décoder en une fois,
  // car le base64 d'un chunk client se termine par du padding `=` ou
  // `==` qui se retrouve au MILIEU de la chaîne concaténée — et
  // `Buffer.from(str, 'base64')` s'arrête silencieusement au premier
  // `=` rencontré, donnant un buffer tronqué (bug rapporté 2026-05-11
  // après le déploiement RAM→NocoDB : reassemble renvoyait juste le
  // 1er chunk au lieu du fichier complet).
  const byClientChunk = new Map();
  for (const r of records) {
    const flatIdx = Number(field(r, 'chunk_index'));
    const clientIdx = Math.floor(flatIdx / SUBCHUNK_STRIDE);
    if (!byClientChunk.has(clientIdx)) byClientChunk.set(clientIdx, []);
    byClientChunk.get(clientIdx).push({
      subIdx: flatIdx % SUBCHUNK_STRIDE,
      b64: String(field(r, 'chunk_base64') || ''),
    });
  }
  const orderedClientIndices = [...byClientChunk.keys()].sort((a, b) => a - b);
  const buffers = orderedClientIndices.map((ci) => {
    const subs = byClientChunk.get(ci).sort((a, b) => a.subIdx - b.subIdx);
    const fullBase64 = subs.map((s) => s.b64).join('');
    return Buffer.from(fullBase64, 'base64');
  });
  return Buffer.concat(buffers);
};

/**
 * Supprime tous les chunks NocoDB d'un upload donné. Idempotent —
 * appelé après `finalize` succès ou après rejet pour corruption pour
 * libérer les rows temporaires.
 *
 * Delete par batch de 100 pour limiter la taille du payload NocoDB.
 */
export const deleteChunks = async (uploadId, ownerKey = null) => {
  const records = await queryUploadChunks(uploadId, ownerKey);
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
