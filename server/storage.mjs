/**
 * Storage abstraction — version 2026-05-06 (post-migration Vercel Blob).
 *
 * Plus aucun appel @vercel/blob. Tout passe par NocoDB (base64 dans
 * `mobile_documents` / `mobile_visit_photos` / `ergotherapeutes` /
 * `wiki`) ou par la RAM serveur (auth-store, chunks d'upload).
 *
 * Ce fichier conserve uniquement le helper de chunking d'upload :
 * pendant qu'un client envoie un gros fichier en chunks de 1 MB,
 * on garde les chunks en mémoire le temps que tous arrivent puis
 * `reassembleChunks` concatène et le pipeline final écrit en base64
 * dans NocoDB via `mobileSyncStore.upsertDocument`.
 *
 * Pourquoi RAM et pas Blob :
 *   - free tier Vercel Blob = 2000 ops/mois (atteint en 1 jour avec
 *     les uploads chunked + auth reads).
 *   - les chunks sont éphémères (vie ~quelques secondes max), pas
 *     besoin d'un stockage persistant pour ça.
 *   - le résultat final est dans NocoDB de toute façon.
 *
 * Limites :
 *   - Si Fluid Compute redémarre l'instance entre chunk N et finalize
 *     (rare), les chunks précédents sont perdus → le client retry
 *     l'upload.
 *   - La RAM par instance Fluid est limitée — un PDF de 10 MB en
 *     chunks 1 MB consomme 10 MB le temps de l'upload. Acceptable.
 */

/**
 * Map<uploadId, Map<chunkIndex, Buffer>>.
 * Chaque uploadId a sa propre sous-map indexée par chunkIndex.
 * Le GC nettoie automatiquement après `deleteChunks`.
 */
const _inMemoryChunks = new Map();

/**
 * Timestamp de dernière activité par uploadId — utilisé par le GC
 * `purgeStaleChunks` pour détruire les uploads abandonnés.
 */
const _chunkLastActivity = new Map();

/**
 * Stocke un chunk binaire en RAM serveur. Le buffer est conservé tel
 * quel (pas de copy) — l'appelant ne doit pas le muter après.
 */
export const putChunk = async ({ uploadId, chunkIndex, buffer }) => {
  if (!_inMemoryChunks.has(uploadId)) {
    _inMemoryChunks.set(uploadId, new Map());
  }
  _inMemoryChunks.get(uploadId).set(chunkIndex, buffer);
  _chunkLastActivity.set(uploadId, Date.now());
  return {
    url: `memory://chunks/${uploadId}/${chunkIndex}`,
    updatedAt: new Date().toISOString(),
  };
};

/**
 * Liste tous les chunks d'un upload en RAM, triés par chunkIndex
 * croissant. Renvoie `[]` si aucun chunk trouvé.
 */
export const listChunks = async (uploadId) => {
  const subMap = _inMemoryChunks.get(uploadId);
  if (!subMap) return [];
  const indices = [...subMap.keys()].sort((a, b) => a - b);
  return indices.map((idx) => ({
    url: `memory://chunks/${uploadId}/${idx}`,
    size: subMap.get(idx)?.length || 0,
    index: idx,
  }));
};

/**
 * Concatène tous les chunks en RAM dans un Buffer unique.
 * Throw si aucun chunk trouvé ou indices non contigus.
 */
export const reassembleChunks = async (uploadId) => {
  const subMap = _inMemoryChunks.get(uploadId);
  if (!subMap || subMap.size === 0) {
    throw new Error(
      `Aucun chunk trouvé pour uploadId="${uploadId}" — `
      + `peut-être perdu suite à un redémarrage Function ; le client doit retry.`,
    );
  }
  const indices = [...subMap.keys()].sort((a, b) => a - b);
  for (let i = 0; i < indices.length; i += 1) {
    if (indices[i] !== i) {
      throw new Error(
        `Chunks non contigus pour uploadId="${uploadId}" : `
        + `index ${i} attendu, trouvé ${indices[i]}`,
      );
    }
  }
  return Buffer.concat(indices.map((idx) => subMap.get(idx)));
};

/**
 * Supprime tous les chunks d'un uploadId. Idempotent — appelé après
 * `/finalize` réussi pour libérer la RAM.
 */
export const deleteChunks = async (uploadId) => {
  _inMemoryChunks.delete(uploadId);
  _chunkLastActivity.delete(uploadId);
};

/**
 * Purge les uploads chunked orphelins en RAM. À appeler depuis un
 * cron périodique pour limiter la conso RAM.
 */
export const purgeStaleChunks = async ({
  olderThan = 60 * 60 * 1000, // 1h
} = {}) => {
  const cutoff = Date.now() - olderThan;
  let purged = 0;
  for (const [uploadId, lastActivity] of _chunkLastActivity.entries()) {
    if (lastActivity < cutoff) {
      _inMemoryChunks.delete(uploadId);
      _chunkLastActivity.delete(uploadId);
      purged += 1;
    }
  }
  return purged;
};

/**
 * Backward-compat — exporté à false (plus jamais de Blob actif).
 * Du code legacy peut encore référencer ce flag pour des branches
 * conditionnelles ; elles tomberont toutes dans le path NocoDB.
 */
export const USE_BLOB = false;
