/**
 * Storage abstraction — Vercel Blob in production, local FS in development.
 *
 * Backend selection:
 *  - If BLOB_READ_WRITE_TOKEN is set → @vercel/blob (persistent across deploys)
 *  - Otherwise → local filesystem under server/data/ (dev only)
 *
 * Key format: '<folder>/<filename>'
 *   profile-photos/safeEmail-timestamp.jpg
 *   visit-plans/<dossier-slug>/plan_logement.png
 *   wiki-library/title-slug-timestamp.jpg
 *
 * Returned URL:
 *  - Blob mode  → absolute https:// URL (resolveClientMediaUrl already passes these through)
 *  - FS mode    → relative /uploads/<key>  (served by express.static)
 */

import { put, list, del } from '@vercel/blob';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import process from 'node:process';

// Mirror helpers.mjs DATA_DIR_PATH logic — kept here to avoid circular imports.
const _LOCAL_DATA_DIR_PATH = fileURLToPath(new URL('./data/', import.meta.url));
const _DATA_DIR_PATH = process.env.VERCEL
  ? path.join('/tmp', 'aidhabitat-data')
  : _LOCAL_DATA_DIR_PATH;

/** True when Vercel Blob credentials are present. */
export const USE_BLOB = Boolean(process.env.BLOB_READ_WRITE_TOKEN);

/**
 * Write a binary object to storage.
 *
 * @param {{ key: string, buffer: Buffer, contentType: string }} opts
 * @returns {{ url: string, updatedAt: string }}
 */
export const putObject = async ({ key, buffer, contentType }) => {
  if (USE_BLOB) {
    const blob = await put(key, buffer, {
      access: 'public',
      contentType,
      addRandomSuffix: false,
    });
    return {
      url: blob.url,
      updatedAt: blob.uploadedAt?.toISOString() ?? new Date().toISOString(),
    };
  }
  // FS fallback
  const filePath = path.join(_DATA_DIR_PATH, key);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, buffer);
  return { url: `/uploads/${key}`, updatedAt: new Date().toISOString() };
};

/**
 * Check whether an object exists and return its public URL + timestamp.
 * Returns { url: null, updatedAt: null } when the object is absent.
 *
 * @param {string} key
 * @returns {{ url: string|null, updatedAt: string|null }}
 */
export const statObject = async (key) => {
  if (USE_BLOB) {
    const result = await list({ prefix: key, limit: 1 });
    const blob = result.blobs[0];
    if (!blob) return { url: null, updatedAt: null };
    return {
      url: blob.url,
      updatedAt: blob.uploadedAt?.toISOString() ?? null,
    };
  }
  // FS fallback
  const filePath = path.join(_DATA_DIR_PATH, key);
  try {
    const stats = await fs.stat(filePath);
    return { url: `/uploads/${key}`, updatedAt: stats.mtime.toISOString() };
  } catch (error) {
    if (error?.code === 'ENOENT') return { url: null, updatedAt: null };
    throw error;
  }
};

/**
 * Read a JSON object from storage. Returns `fallback` when the key is absent.
 *
 * Blob mode: the blob is stored with `access: 'public'` (same as putObject)
 * and fetched via its public URL. In-memory caching is deliberately left to
 * the caller — auth-store.json is small and read at most once per request.
 *
 * @template T
 * @param {string} key
 * @param {T} fallback
 * @returns {Promise<T>}
 */
export const getJson = async (key, fallback) => {
  if (USE_BLOB) {
    const result = await list({ prefix: key, limit: 1 });
    const blob = result.blobs.find((b) => b.pathname === key);
    if (!blob) return fallback;
    const response = await fetch(blob.url, { cache: 'no-store' });
    if (!response.ok) {
      throw new Error(`getJson(${key}) HTTP ${response.status}`);
    }
    return await response.json();
  }
  const filePath = path.join(_DATA_DIR_PATH, key);
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    return JSON.parse(raw);
  } catch (error) {
    if (error?.code === 'ENOENT') return fallback;
    throw error;
  }
};

/**
 * Write a JSON object to storage atomically (same key overwrites previous).
 *
 * @param {string} key
 * @param {unknown} data
 * @returns {Promise<{ url: string, updatedAt: string }>}
 */
export const putJson = async (key, data) => {
  const payload = JSON.stringify(data, null, 2);
  if (USE_BLOB) {
    const blob = await put(key, payload, {
      access: 'public',
      contentType: 'application/json; charset=utf-8',
      addRandomSuffix: false,
      allowOverwrite: true,
    });
    return {
      url: blob.url,
      updatedAt: blob.uploadedAt?.toISOString() ?? new Date().toISOString(),
    };
  }
  const filePath = path.join(_DATA_DIR_PATH, key);
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, payload);
  return { url: `/uploads/${key}`, updatedAt: new Date().toISOString() };
};

// ---------------------------------------------------------------------------
// Chunked upload helpers — used by /api/documents/chunk and /finalize for
// big files that would otherwise exceed Vercel's 10s function timeout.
//
// Strategy v2 (2026-05-06) : MIGRATION HORS DE VERCEL BLOB. Demande
// utilisateur : « tout doit fonctionner à 100 % entre NocoDB et
// l'application Flutter ». Les chunks sont désormais stockés en
// MÉMOIRE PURE côté serveur (Map JS), pas dans Blob.
//
// Pourquoi pas Blob :
//   - free tier Vercel Blob = 2000 ops/mois (atteint en 1 jour avec
//     le pull adaptatif + uploads chunked)
//   - le résultat final est de toute façon stocké dans NocoDB via
//     `mobileSyncStore.upsertDocument({contentBase64, ...})` — Blob
//     n'était qu'un buffer temporaire entre les chunks et le
//     reassemble.
//   - chunks séquentiels rapides → la même instance Fluid Compute
//     traite typiquement chunk N et finalize, donc la Map en RAM
//     suffit dans 99 % des cas.
//
// Limites :
//   - Si Fluid Compute redémarre l'instance entre chunk N et finalize
//     (rare mais possible), les chunks précédents sont perdus → le
//     client doit retry l'upload from scratch (même `uploadId`
//     régénéré). C'est OK pour un cas exceptionnel.
//   - La RAM par instance Fluid Compute est limitée — un PDF de 10 MB
//     en chunks d'1 MB consomme 10 MB de RAM le temps de l'upload.
//     Acceptable.
// ---------------------------------------------------------------------------

/**
 * Stockage in-memory des chunks en cours d'upload.
 * Map<uploadId, Map<chunkIndex, Buffer>>
 *
 * Chaque uploadId a sa propre sous-map indexée par chunkIndex. Le
 * GC nettoie automatiquement après `deleteChunks` (qui delete la
 * top-level entry).
 */
const _inMemoryChunks = new Map();

/**
 * Timestamp de dernière activité par uploadId — utilisé par le GC
 * `purgeStaleChunks` pour détruire les uploads abandonnés (ex. client
 * crashé en plein milieu).
 */
const _chunkLastActivity = new Map();

/**
 * Stocke un chunk binaire en mémoire serveur (plus de Vercel Blob).
 * Le buffer est conservé tel quel (pas de copy) — l'appelant ne doit
 * pas le muter après.
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
 * Liste tous les chunks d'un upload en mémoire, triés par chunkIndex
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
 * Concatène tous les chunks en mémoire dans un Buffer unique.
 * Throw si aucun chunk ou indices non contigus.
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
  const buffers = indices.map((idx) => subMap.get(idx));
  return Buffer.concat(buffers);
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
 * Purge les uploads chunked orphelins en RAM (clients qui ont
 * commencé un upload puis abandonné). À appeler depuis un cron
 * périodique pour limiter la conso RAM. Avec Fluid Compute, les
 * instances qui restent en vie peuvent accumuler des chunks
 * orphelins entre les redémarrages — ce GC les libère.
 */
export const purgeStaleChunks = async ({
  olderThan = 60 * 60 * 1000, // 1h (raccourci vs 24h Blob — RAM > stockage)
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
}
