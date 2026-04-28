// Purge des chunks orphelins dans `mobile_document_chunks` :
// chunks dont le `document_uuid_source` ne pointe plus sur aucune
// entrée dans `mobile_documents`. Ces chunks correspondent soit à des
// docs supprimées sans cleanup des chunks, soit à des uploads
// abandonnés en cours.
//
// Usage :
//   node tools/purge-orphan-chunks.mjs           # dry-run (lecture seule)
//   node tools/purge-orphan-chunks.mjs --apply   # supprime réellement
//
// Sortie :
//   tmp/orphan-chunks-backup-<timestamp>.json    # archive avant suppression

import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const envLocalPath = path.resolve(__dirname, '../.env.local');
if (fs.existsSync(envLocalPath) && !process.env.NOCODB_API_URL) {
  for (const line of fs.readFileSync(envLocalPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m) process.env[m[1]] = m[2].trim();
  }
}

const API_URL = process.env.NOCODB_API_URL?.replace(/\/$/, '');
const API_TOKEN = process.env.NOCODB_API_TOKEN;
const BASE_ID = process.env.NOCODB_BASE_ID;
const APPLY = process.argv.includes('--apply');

if (!API_URL || !API_TOKEN || !BASE_ID) {
  console.error('NOCODB_API_URL / NOCODB_API_TOKEN / NOCODB_BASE_ID requis (.env.local)');
  process.exit(1);
}

const nocoFetch = async (url, init = {}) => {
  const res = await fetch(url, {
    ...init,
    headers: {
      'xc-token': API_TOKEN,
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText} on ${url} :: ${await res.text()}`);
  }
  // DELETE renvoie parfois un body vide.
  const text = await res.text();
  return text ? JSON.parse(text) : null;
};

const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = tablesResp.list || tablesResp;
const findTable = (name) =>
  tables.find((t) => String(t.title).toLowerCase() === name.toLowerCase());

const chunksTable = findTable('mobile_document_chunks');
const documentsTable = findTable('mobile_documents');
if (!chunksTable || !documentsTable) {
  console.error('Tables manquantes : mobile_document_chunks ou mobile_documents');
  process.exit(1);
}

const queryAllRecords = async (tableId, fields = []) => {
  const all = [];
  let offset = 0;
  const pageSize = 1000;
  while (true) {
    const fieldsParam = fields.length ? `&fields=${encodeURIComponent(fields.join(','))}` : '';
    const url = `${API_URL}/api/v2/tables/${tableId}/records?limit=${pageSize}&offset=${offset}${fieldsParam}`;
    const r = await nocoFetch(url);
    const list = r.list || [];
    all.push(...list);
    if (list.length < pageSize) break;
    offset += pageSize;
  }
  return all;
};

console.log(`🔍 Lecture de mobile_documents et mobile_document_chunks…`);
const [allDocs, allChunks] = await Promise.all([
  queryAllRecords(documentsTable.id, ['Id', 'uuid_source', 'nom_fichier']),
  queryAllRecords(chunksTable.id, ['Id', 'document_uuid_source', 'chunk_index', 'updated_at']),
]);

const validUuids = new Set(
  allDocs.map((d) => String(d.uuid_source || '').trim()).filter(Boolean),
);
console.log(`   ${allDocs.length} document(s) parent(s) valides`);
console.log(`   ${allChunks.length} chunk(s) au total\n`);

// Identifie les chunks orphelins.
const orphanChunks = allChunks.filter((c) => {
  const u = String(c.document_uuid_source || '').trim();
  return !u || !validUuids.has(u);
});

// Groupe par document_uuid_source pour le résumé.
const byDoc = new Map();
for (const c of orphanChunks) {
  const u = String(c.document_uuid_source || '').trim() || '(empty-uuid)';
  const e = byDoc.get(u) || { uuid: u, chunkIds: [], lastUpdate: '' };
  e.chunkIds.push(c.Id);
  const up = String(c.updated_at || '');
  if (up > e.lastUpdate) e.lastUpdate = up;
  byDoc.set(u, e);
}

const orphanSummary = Array.from(byDoc.values()).sort((a, b) =>
  (b.lastUpdate || '').localeCompare(a.lastUpdate || ''),
);

console.log(`📦 ${orphanChunks.length} chunk(s) orphelin(s) répartis sur ${orphanSummary.length} document(s) :\n`);
for (const o of orphanSummary) {
  console.log(`  • uuid=${o.uuid}  chunks=${o.chunkIds.length}  last_update=${o.lastUpdate}`);
}

if (orphanChunks.length === 0) {
  console.log('\n✅ Rien à purger.');
  process.exit(0);
}

// Archive avant suppression (chunkIds + uuids — pas le contenu base64,
// qui ferait exploser la taille du fichier inutilement).
const backupDir = path.resolve(__dirname, '../tmp');
fs.mkdirSync(backupDir, { recursive: true });
const ts = new Date().toISOString().replace(/[:.]/g, '-');
const backupPath = path.resolve(backupDir, `orphan-chunks-backup-${ts}.json`);
fs.writeFileSync(
  backupPath,
  JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      tableName: 'mobile_document_chunks',
      tableId: chunksTable.id,
      orphanCount: orphanChunks.length,
      groupCount: orphanSummary.length,
      groups: orphanSummary,
    },
    null,
    2,
  ),
);
console.log(`\n💾 Archive avant suppression : ${backupPath}`);

if (!APPLY) {
  console.log('\n🚧 Dry-run : aucune suppression effectuée.');
  console.log('   Relance avec  --apply  pour supprimer.');
  process.exit(0);
}

console.log(`\n🗑  Suppression de ${orphanChunks.length} chunk(s) orphelin(s)…`);

// NocoDB v2 DELETE batch via body avec liste d'IDs.
const deleteBatch = async (ids) => {
  await nocoFetch(`${API_URL}/api/v2/tables/${chunksTable.id}/records`, {
    method: 'DELETE',
    body: JSON.stringify(ids.map((id) => ({ Id: id }))),
  });
};

const idsToDelete = orphanChunks.map((c) => c.Id).filter(Boolean);
const BATCH_SIZE = 50;
let deleted = 0;
for (let i = 0; i < idsToDelete.length; i += BATCH_SIZE) {
  const batch = idsToDelete.slice(i, i + BATCH_SIZE);
  await deleteBatch(batch);
  deleted += batch.length;
  process.stdout.write(`\r   ${deleted} / ${idsToDelete.length}`);
}
console.log(`\n✅ ${deleted} chunk(s) supprimé(s).`);
