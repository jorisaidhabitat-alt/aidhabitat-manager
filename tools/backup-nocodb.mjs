#!/usr/bin/env node
// Backup quotidien de toutes les tables NocoDB du projet aid'habitat.
//
// Usage :
//   node tools/backup-nocodb.mjs                  (utilise NOCODB_API_URL + NOCODB_API_TOKEN + NOCODB_BASE_ID)
//   BACKUP_DIR=/var/backups/nocodb node tools/backup-nocodb.mjs
//   RETENTION_DAYS=30 node tools/backup-nocodb.mjs
//
// Variables d'environnement :
//   NOCODB_API_URL        (obligatoire) ex. https://apps-nocodb.z5avx1.easypanel.host
//   NOCODB_API_TOKEN      (obligatoire) token avec lecture sur toutes les tables
//   NOCODB_BASE_ID        (obligatoire) id de la base à backuper
//   BACKUP_DIR            (optionnel)   dossier de sortie (défaut: ./backups)
//   RETENTION_DAYS        (optionnel)   garde les N derniers jours (défaut: 30)
//   PAGE_SIZE             (optionnel)   taille des pages NocoDB (défaut: 200, max 1000)
//
// Sortie :
//   <BACKUP_DIR>/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
//     {
//       "version": 1,
//       "createdAt": "ISO-8601",
//       "baseId": "...",
//       "tables": [
//         { "id": "...", "name": "...", "fields": [...], "records": [...] },
//         ...
//       ]
//     }
//
// Rétention : à la fin, on supprime tout fichier `aidhabitat-*.json.gz`
// dans BACKUP_DIR dont la date dans le nom est antérieure à `now - N jours`.
//
// Exit codes :
//   0 = succès
//   1 = env manquante / réseau / I/O
//   2 = NocoDB a renvoyé une réponse inattendue
//
// Cron suggéré (EasyPanel host ou container dédié) :
//   0 3 * * * cd /opt/aidhabitat && node tools/backup-nocodb.mjs >> /var/log/nocodb-backup.log 2>&1
//
// Upload off-site : enchaîne avec rclone après le dump :
//   0 3 * * * /opt/aidhabitat/tools/backup-and-upload.sh

import { gzip } from 'node:zlib';
import { promisify } from 'node:util';
import { mkdir, writeFile, readdir, unlink } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const gzipAsync = promisify(gzip);

// ----- Config -----
const API_URL = (process.env.NOCODB_API_URL || '').trim().replace(/\/+$/, '');
const API_TOKEN = (process.env.NOCODB_API_TOKEN || '').trim();
const BASE_ID = (process.env.NOCODB_BASE_ID || '').trim();
const BACKUP_DIR = path.resolve(process.env.BACKUP_DIR || './backups');
const RETENTION_DAYS = Math.max(1, Number(process.env.RETENTION_DAYS) || 30);
const PAGE_SIZE = Math.min(1000, Math.max(25, Number(process.env.PAGE_SIZE) || 200));

if (!API_URL || !API_TOKEN || !BASE_ID) {
  console.error(
    '[backup] ERREUR: NOCODB_API_URL, NOCODB_API_TOKEN et NOCODB_BASE_ID sont requis.',
  );
  process.exit(1);
}

// ----- Helpers HTTP -----
const headers = {
  'xc-token': API_TOKEN,
  'Content-Type': 'application/json',
  Accept: 'application/json',
};

async function fetchJson(url, opts = {}) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const res = await fetch(url, { ...opts, headers: { ...headers, ...(opts.headers || {}) } });
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(`HTTP ${res.status} ${res.statusText} on ${url} :: ${text.slice(0, 200)}`);
      }
      return await res.json();
    } catch (err) {
      lastError = err;
      const backoff = 500 * Math.pow(2, attempt); // 500ms, 1s, 2s
      console.warn(`[backup] tentative ${attempt + 1}/3 échouée: ${err.message} (retry dans ${backoff}ms)`);
      await new Promise((r) => setTimeout(r, backoff));
    }
  }
  throw lastError;
}

// ----- Liste des tables -----
async function listTables() {
  const payload = await fetchJson(`${API_URL}/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`);
  const list = payload?.list || payload?.tables || [];
  if (!Array.isArray(list) || list.length === 0) {
    throw new Error(`Aucune table trouvée pour la base ${BASE_ID}`);
  }
  return list.map((t) => ({
    id: String(t.id),
    name: String(t.title || t.table_name || t.name || t.id),
  }));
}

// ----- Schema d'une table (colonnes/types) -----
async function fetchTableSchema(tableId) {
  try {
    const payload = await fetchJson(`${API_URL}/api/v2/meta/tables/${encodeURIComponent(tableId)}`);
    const cols = payload?.columns || payload?.fields || [];
    return cols.map((c) => ({
      id: c.id,
      name: c.title || c.column_name,
      type: c.uidt || c.type || null,
      required: Boolean(c.rqd),
    }));
  } catch (err) {
    console.warn(`[backup] impossible de lire le schema de ${tableId}: ${err.message}`);
    return [];
  }
}

// ----- Pagination de tous les records d'une table -----
async function fetchAllRecords(tableId, tableName) {
  const records = [];
  let offset = 0;
  while (true) {
    const url = new URL(`${API_URL}/api/v2/tables/${encodeURIComponent(tableId)}/records`);
    url.searchParams.set('limit', String(PAGE_SIZE));
    url.searchParams.set('offset', String(offset));
    const payload = await fetchJson(url.toString());
    const list = payload?.list || [];
    if (!Array.isArray(list)) {
      throw Object.assign(
        new Error(`Réponse inattendue sur ${tableName} (pas de .list)`),
        { code: 2 },
      );
    }
    records.push(...list);
    const pageInfo = payload?.pageInfo || {};
    const isLast = Boolean(pageInfo.isLastPage) || list.length < PAGE_SIZE;
    if (isLast) break;
    offset += PAGE_SIZE;
    if (offset > 200_000) {
      throw new Error(`Garde-fou: >200k records sur ${tableName}, arrêt`);
    }
  }
  return records;
}

// ----- Dump complet -----
async function dumpBase() {
  console.log(`[backup] début dump base=${BASE_ID} url=${API_URL}`);
  const tables = await listTables();
  console.log(`[backup] ${tables.length} table(s) trouvée(s)`);

  const dump = {
    version: 1,
    createdAt: new Date().toISOString(),
    baseId: BASE_ID,
    apiUrl: API_URL,
    tables: [],
  };

  for (const t of tables) {
    const start = Date.now();
    const [fields, records] = await Promise.all([
      fetchTableSchema(t.id),
      fetchAllRecords(t.id, t.name),
    ]);
    const ms = Date.now() - start;
    console.log(`[backup]   ${t.name.padEnd(40)} ${String(records.length).padStart(6)} records (${ms}ms)`);
    dump.tables.push({
      id: t.id,
      name: t.name,
      fields,
      records,
    });
  }

  return dump;
}

// ----- Compression + écriture disque -----
async function writeDump(dump) {
  await mkdir(BACKUP_DIR, { recursive: true });
  const stamp = dump.createdAt.replace(/[:T]/g, '-').replace(/\.\d+Z$/, '').replace('-', '_');
  // Format final : aidhabitat-2026-05-13_18-42-30.json.gz
  const yyyy_mm_dd = dump.createdAt.slice(0, 10);
  const hh_mm_ss = dump.createdAt.slice(11, 19).replace(/:/g, '-');
  const filename = `aidhabitat-${yyyy_mm_dd}_${hh_mm_ss}.json.gz`;
  const filepath = path.join(BACKUP_DIR, filename);

  const json = JSON.stringify(dump);
  const buf = Buffer.from(json, 'utf8');
  const gz = await gzipAsync(buf, { level: 9 });

  await writeFile(filepath, gz);
  const ratio = ((1 - gz.length / buf.length) * 100).toFixed(1);
  console.log(
    `[backup] ✓ écrit ${filepath}` +
      ` (${(gz.length / 1024 / 1024).toFixed(2)} MB compressé, ratio ${ratio}%)`,
  );
  return filepath;
}

// ----- Purge rétention -----
const FILENAME_RE = /^aidhabitat-(\d{4}-\d{2}-\d{2})_/;
async function pruneOldBackups() {
  let entries = [];
  try {
    entries = await readdir(BACKUP_DIR);
  } catch {
    return;
  }
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - RETENTION_DAYS);
  let pruned = 0;
  for (const name of entries) {
    const m = FILENAME_RE.exec(name);
    if (!m) continue;
    const fileDate = new Date(`${m[1]}T00:00:00Z`);
    if (fileDate < cutoff) {
      try {
        await unlink(path.join(BACKUP_DIR, name));
        pruned += 1;
      } catch (err) {
        console.warn(`[backup] purge échouée pour ${name}: ${err.message}`);
      }
    }
  }
  if (pruned > 0) {
    console.log(`[backup] purgé ${pruned} backup(s) > ${RETENTION_DAYS} jours`);
  }
}

// ----- Main -----
(async () => {
  const t0 = Date.now();
  try {
    const dump = await dumpBase();
    const filepath = await writeDump(dump);
    await pruneOldBackups();
    const total = ((Date.now() - t0) / 1000).toFixed(1);
    console.log(`[backup] terminé en ${total}s — ${filepath}`);
    process.exit(0);
  } catch (err) {
    console.error(`[backup] ÉCHEC: ${err.message}`);
    if (err.stack) console.error(err.stack);
    process.exit(err.code === 2 ? 2 : 1);
  }
})();
