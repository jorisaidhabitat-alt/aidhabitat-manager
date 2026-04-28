// One-off : liste tous les documents présents dans `mobile_document_chunks`,
// groupés par document_uuid_source + count de chunks. Joint
// `mobile_documents` pour récupérer le nom de fichier et le bénéficiaire.
//
// Usage :
//   node tools/list-document-chunks.mjs
//
// Variables d'environnement (lues depuis .env.local) :
//   NOCODB_API_URL, NOCODB_API_TOKEN, NOCODB_BASE_ID

import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Charge .env.local si dotenv n'a pas trouvé un .env standard.
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

if (!API_URL || !API_TOKEN || !BASE_ID) {
  console.error('NOCODB_API_URL / NOCODB_API_TOKEN / NOCODB_BASE_ID requis (.env.local)');
  process.exit(1);
}

const nocoFetch = async (url) => {
  const res = await fetch(url, {
    headers: { 'xc-token': API_TOKEN, 'Content-Type': 'application/json' },
  });
  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText} on ${url} :: ${await res.text()}`);
  }
  return res.json();
};

// 1. Liste les tables de la base pour résoudre les IDs de tables.
const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = tablesResp.list || tablesResp;
const findTable = (name) =>
  tables.find((t) => String(t.title).toLowerCase() === name.toLowerCase());

const chunksTable = findTable('mobile_document_chunks');
const documentsTable = findTable('mobile_documents');

if (!chunksTable) {
  console.error("Table 'mobile_document_chunks' introuvable dans la base.");
  console.error('Tables disponibles :', tables.map((t) => t.title).join(', '));
  process.exit(1);
}

// 2. Lit tous les chunks (paginé).
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

console.log('🔍 Lecture de mobile_document_chunks…');
const chunks = await queryAllRecords(chunksTable.id, [
  'document_uuid_source',
  'chunk_index',
  'updated_at',
]);
console.log(`   ${chunks.length} chunks au total.\n`);

// 3. Groupe par document_uuid_source.
const byDoc = new Map();
for (const c of chunks) {
  const uuid = String(c.document_uuid_source || '').trim();
  if (!uuid) continue;
  const e = byDoc.get(uuid) || { uuid, chunkCount: 0, lastUpdate: '' };
  e.chunkCount += 1;
  const u = String(c.updated_at || '');
  if (u > e.lastUpdate) e.lastUpdate = u;
  byDoc.set(uuid, e);
}

// 4. Joint mobile_documents pour le nom de fichier.
let docMeta = new Map();
if (documentsTable) {
  const docs = await queryAllRecords(documentsTable.id, [
    'uuid_source',
    'nom_fichier',
    'titre',
    'beneficiaire_nom_complet',
    'mime_type',
    'updated_at',
  ]);
  for (const d of docs) {
    const u = String(d.uuid_source || '').trim();
    if (u) docMeta.set(u, d);
  }
}

// 5. Restitution.
const rows = Array.from(byDoc.values())
  .map((e) => ({
    ...e,
    meta: docMeta.get(e.uuid) || null,
  }))
  .sort((a, b) => (b.lastUpdate || '').localeCompare(a.lastUpdate || ''));

console.log(`📦 ${rows.length} document(s) distincts dans mobile_document_chunks :\n`);
for (const r of rows) {
  const m = r.meta;
  const name = m?.nom_fichier || m?.titre || '(metadata absente)';
  const who = m?.beneficiaire_nom_complet || '?';
  const mime = m?.mime_type || '?';
  console.log(
    `  • ${name}`.padEnd(60) +
    ` chunks=${String(r.chunkCount).padStart(3)} ` +
    `mime=${mime.padEnd(30)} ` +
    `bénéficiaire=${who}`
  );
  console.log(`      uuid=${r.uuid}    last_update=${r.lastUpdate}`);
}

// 6. Cherche les orphelins (chunks sans entrée correspondante dans mobile_documents).
const orphans = rows.filter((r) => !r.meta);
if (orphans.length > 0) {
  console.log(`\n⚠️  ${orphans.length} document(s) ORPHELIN(S) (chunks sans metadata dans mobile_documents) :`);
  for (const o of orphans) {
    console.log(`   - uuid=${o.uuid} chunks=${o.chunkCount} last_update=${o.lastUpdate}`);
  }
}
