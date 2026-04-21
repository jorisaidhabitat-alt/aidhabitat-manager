#!/usr/bin/env node
/**
 * Seed auth-store.json to Vercel Blob (one-shot migration).
 *
 * Reads server/data/auth-store.json from the local filesystem and uploads it
 * to the Blob store under the same key. Run this once after configuring
 * BLOB_READ_WRITE_TOKEN so production can authenticate users.
 *
 * Usage:
 *   BLOB_READ_WRITE_TOKEN=vercel_blob_rw_... node scripts/seedAuthStoreToBlob.mjs
 *
 * The token can be fetched from `vercel env pull .env.local` or from the
 * Vercel dashboard (Storage → Blob → .env.local). Safe to re-run — uploads
 * with addRandomSuffix:false + allowOverwrite:true overwrite the existing key.
 */
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });
dotenv.config();

const AUTH_STORE_KEY = 'auth-store.json';
const LOCAL_PATH = fileURLToPath(new URL('../server/data/auth-store.json', import.meta.url));

if (!process.env.BLOB_READ_WRITE_TOKEN) {
  console.error('ERROR: BLOB_READ_WRITE_TOKEN is not set.');
  console.error('       Run `vercel env pull .env.local` or export the token in your shell.');
  process.exit(1);
}

const raw = await fs.readFile(LOCAL_PATH, 'utf8').catch((err) => {
  if (err?.code === 'ENOENT') {
    console.error(`ERROR: ${LOCAL_PATH} not found — nothing to seed.`);
    process.exit(1);
  }
  throw err;
});

// Sanity-check it parses before uploading.
const parsed = JSON.parse(raw);
const userCount = Object.keys(parsed.users || {}).length;
const pendingCount = Object.keys(parsed.pendingCredentials || {}).length;
console.log(`→ Uploading ${path.basename(LOCAL_PATH)} (${userCount} users, ${pendingCount} pending) to Vercel Blob key "${AUTH_STORE_KEY}"...`);

const { put } = await import('@vercel/blob');
const blob = await put(AUTH_STORE_KEY, raw, {
  access: 'public',
  contentType: 'application/json; charset=utf-8',
  addRandomSuffix: false,
  allowOverwrite: true,
});

console.log(`✓ Uploaded. URL: ${blob.url}`);
console.log(`✓ uploadedAt: ${blob.uploadedAt?.toISOString()}`);
