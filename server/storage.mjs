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

import { put, list } from '@vercel/blob';
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
