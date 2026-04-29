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
// Strategy : the client splits a file into ~1 MB chunks and POSTs each
// independently. Each chunk is small enough to upload in <2s. The final
// `/finalize` call assembles the chunks (download from Blob → concat →
// upload to NocoDB).
//
// Layout :
//   _chunks/<uploadId>/<chunkIndex>.bin   ← raw chunk data
//   _chunks/<uploadId>/manifest.json      ← {fileName, mimeType, total, …}
//
// Cleanup : after `/finalize` succeeds, all blobs under _chunks/<uploadId>/
// are deleted. Orphaned uploads (client crashed mid-upload) accumulate
// until manually purged. A daily cron could call `purgeStaleChunks()`.
// ---------------------------------------------------------------------------

/**
 * Stocke un chunk binaire d'un upload en cours. La clé est
 * `_chunks/<uploadId>/<chunkIndex>.bin`. Renvoie l'URL pour récupération
 * ultérieure.
 */
export const putChunk = async ({ uploadId, chunkIndex, buffer }) => {
  const key = `_chunks/${uploadId}/${String(chunkIndex).padStart(6, '0')}.bin`;
  return putObject({ key, buffer, contentType: 'application/octet-stream' });
};

/**
 * Liste tous les chunks d'un upload, triés par chunkIndex croissant.
 * Renvoie un tableau de `{ index, url, size }` ou `[]` si aucun chunk
 * trouvé (uploadId invalide, déjà finalisé/purgé).
 */
export const listChunks = async (uploadId) => {
  const prefix = `_chunks/${uploadId}/`;
  if (USE_BLOB) {
    const result = await list({ prefix });
    return result.blobs
      .filter((b) => b.pathname.endsWith('.bin'))
      .map((b) => ({
        url: b.url,
        size: b.size,
        index: extractChunkIndex(b.pathname),
      }))
      .sort((a, b) => a.index - b.index);
  }
  // FS fallback
  const dirPath = path.join(_DATA_DIR_PATH, prefix);
  try {
    const files = await fs.readdir(dirPath);
    const chunks = await Promise.all(
      files
        .filter((f) => f.endsWith('.bin'))
        .map(async (f) => {
          const fullPath = path.join(dirPath, f);
          const stats = await fs.stat(fullPath);
          return {
            url: `/uploads/${prefix}${f}`,
            size: stats.size,
            index: extractChunkIndex(f),
          };
        }),
    );
    return chunks.sort((a, b) => a.index - b.index);
  } catch (error) {
    if (error?.code === 'ENOENT') return [];
    throw error;
  }
};

/**
 * Télécharge tous les chunks d'un upload et les concatène dans un
 * Buffer unique. Bloquant — utiliser uniquement dans le handler
 * `/finalize` qui dispose du timeout complet de la fonction Vercel.
 */
export const reassembleChunks = async (uploadId) => {
  const chunks = await listChunks(uploadId);
  if (chunks.length === 0) {
    throw new Error(`Aucun chunk trouvé pour uploadId="${uploadId}"`);
  }
  // Sanity check : les indices doivent être contigus 0..n-1.
  for (let i = 0; i < chunks.length; i += 1) {
    if (chunks[i].index !== i) {
      throw new Error(
        `Chunks non contigus pour uploadId="${uploadId}" : `
        + `index ${i} attendu, trouvé ${chunks[i].index}`,
      );
    }
  }
  const buffers = await Promise.all(
    chunks.map(async (c) => {
      if (USE_BLOB) {
        const response = await fetch(c.url, { cache: 'no-store' });
        if (!response.ok) {
          throw new Error(`Chunk fetch HTTP ${response.status} : ${c.url}`);
        }
        const ab = await response.arrayBuffer();
        return Buffer.from(ab);
      }
      // FS fallback : lire le fichier local
      const filePath = path.join(_DATA_DIR_PATH, c.url.replace(/^\/uploads\//, ''));
      return fs.readFile(filePath);
    }),
  );
  return Buffer.concat(buffers);
};

/**
 * Supprime tous les blobs/fichiers liés à un uploadId — chunks +
 * manifest. Idempotent. Best-effort : les erreurs sont avalées (le
 * pire cas est un orphelin qui sera purgé par `purgeStaleChunks`).
 */
export const deleteChunks = async (uploadId) => {
  const prefix = `_chunks/${uploadId}/`;
  if (USE_BLOB) {
    try {
      const result = await list({ prefix });
      if (result.blobs.length === 0) return;
      await del(result.blobs.map((b) => b.url));
    } catch {
      // best-effort
    }
    return;
  }
  // FS fallback
  const dirPath = path.join(_DATA_DIR_PATH, prefix);
  try {
    await fs.rm(dirPath, { recursive: true, force: true });
  } catch {
    // best-effort
  }
};

/**
 * Purge les uploads chunked orphelins (clients qui ont commencé un
 * upload puis abandonné). À appeler depuis un cron quotidien — pas
 * critique pour le bon fonctionnement, juste pour limiter l'usage
 * stockage.
 */
export const purgeStaleChunks = async ({
  olderThan = 24 * 60 * 60 * 1000, // 24h
} = {}) => {
  const cutoff = Date.now() - olderThan;
  const prefix = '_chunks/';
  let purged = 0;
  if (USE_BLOB) {
    const result = await list({ prefix });
    const stale = result.blobs.filter((b) => {
      const uploadedAt = b.uploadedAt?.getTime() ?? 0;
      return uploadedAt < cutoff;
    });
    if (stale.length > 0) {
      await del(stale.map((b) => b.url));
      purged = stale.length;
    }
    return purged;
  }
  // FS fallback : skip (dev only, /tmp is wiped between runs anyway)
  return purged;
};

/**
 * Extrait l'index d'un nom de fichier chunk (ex. `000003.bin` → 3).
 * Tolère les chemins absolus (Blob renvoie `_chunks/<id>/000003.bin`).
 */
function extractChunkIndex(pathname) {
  const match = pathname.match(/(\d+)\.bin$/);
  return match ? parseInt(match[1], 10) : -1;
}
