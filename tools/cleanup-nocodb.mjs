// Nettoyage ciblé NocoDB (suite au checkup) :
//
//   1. Purge des « uploads de test » sans bénéficiaire dans
//      `mobile_documents` (mars 2026, ~12 docs) + leurs chunks.
//
//   2. Dédoublonnage des `image.jpg` pour un même bénéficiaire :
//      garde le plus récent (par updated_at), supprime les autres
//      (et leurs chunks).
//
// Usage :
//   node tools/cleanup-nocodb.mjs           # dry-run
//   node tools/cleanup-nocodb.mjs --apply   # supprime réellement
//
// Sortie : tmp/cleanup-backup-<ts>.json (archive avant suppression)
//
// Lecture seule par défaut. Aucune modification sans --apply.

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
  console.error('NOCODB_API_URL / NOCODB_API_TOKEN / NOCODB_BASE_ID requis');
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
    throw new Error(`${res.status} on ${url} :: ${await res.text().catch(() => '')}`);
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
};

const queryAllRecords = async (tableId, fields = []) => {
  const all = [];
  let offset = 0;
  while (true) {
    const f = fields.length ? `&fields=${encodeURIComponent(fields.join(','))}` : '';
    const r = await nocoFetch(
      `${API_URL}/api/v2/tables/${tableId}/records?limit=1000&offset=${offset}${f}`,
    );
    const list = r.list || [];
    all.push(...list);
    if (list.length < 1000) break;
    offset += 1000;
  }
  return all;
};

const deleteBatch = async (tableId, ids) => {
  // NocoDB v2 batch DELETE : body = [{ Id }, …]
  const BATCH = 50;
  for (let i = 0; i < ids.length; i += BATCH) {
    await nocoFetch(`${API_URL}/api/v2/tables/${tableId}/records`, {
      method: 'DELETE',
      body: JSON.stringify(ids.slice(i, i + BATCH).map((id) => ({ Id: id }))),
    });
  }
};

const stringValue = (v) => (v == null || v === 'null' ? '' : String(v).trim());

// 1. Récupère les IDs des tables.
const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = (tablesResp.list || tablesResp).filter((t) => t && t.id);
const findTable = (n) => tables.find((t) => String(t.title).toLowerCase() === n.toLowerCase());
const documentsTable = findTable('mobile_documents');
const chunksTable = findTable('mobile_document_chunks');
if (!documentsTable || !chunksTable) {
  console.error('Tables mobile_documents ou mobile_document_chunks introuvables');
  process.exit(1);
}

// 2. Lecture des deux tables.
console.log('🔍 Lecture mobile_documents et mobile_document_chunks…');
const [docs, chunks] = await Promise.all([
  queryAllRecords(documentsTable.id, [
    'Id', 'uuid_source', 'beneficiaire_id', 'beneficiaire_nom_complet',
    'nom_fichier', 'titre', 'updated_at', 'CreatedAt',
  ]),
  queryAllRecords(chunksTable.id, [
    'Id', 'document_uuid_source', 'chunk_index',
  ]),
]);
console.log(`   ${docs.length} docs, ${chunks.length} chunks\n`);

const chunksByDoc = new Map();
for (const c of chunks) {
  const u = stringValue(c.document_uuid_source);
  if (!u) continue;
  (chunksByDoc.get(u) || chunksByDoc.set(u, []).get(u)).push(c.Id);
}

// =====================================================================
// ACTION 1 : docs sans bénéficiaire
// =====================================================================
const testDocs = docs.filter((d) =>
  !stringValue(d.beneficiaire_id) && !stringValue(d.beneficiaire_nom_complet),
);
console.log(`🧪 Action 1 : ${testDocs.length} doc(s) « test » sans bénéficiaire :`);
let testChunkCount = 0;
for (const d of testDocs) {
  const cIds = chunksByDoc.get(stringValue(d.uuid_source)) || [];
  testChunkCount += cIds.length;
  console.log(`   - ${stringValue(d.nom_fichier) || stringValue(d.titre) || '(sans nom)'}`.padEnd(58) +
    ` chunks=${cIds.length}  uuid=${d.uuid_source}`);
}
console.log(`   Total chunks à supprimer : ${testChunkCount}\n`);

// =====================================================================
// ACTION 2 : doublons par bénéficiaire (même nom_fichier)
// =====================================================================
//
// On scope aux docs AVEC bénéficiaire (sinon ils sont déjà couverts
// par l'action 1). Pour chaque (beneficiaire_id, nom_fichier), on garde
// la version la plus récente (par updated_at desc) et on marque les
// autres pour suppression.
const docsWithBenef = docs.filter((d) => stringValue(d.beneficiaire_id));
const dupGroups = new Map();
for (const d of docsWithBenef) {
  const fn = stringValue(d.nom_fichier);
  if (!fn) continue;
  const key = `${stringValue(d.beneficiaire_id)}|${fn.toLowerCase()}`;
  (dupGroups.get(key) || dupGroups.set(key, []).get(key)).push(d);
}
const dupsToPurge = [];
console.log(`🪞 Action 2 : doublons par bénéficiaire :`);
for (const [, group] of dupGroups) {
  if (group.length <= 1) continue;
  // Tri par updated_at desc (le plus récent en premier).
  group.sort((a, b) => stringValue(b.updated_at).localeCompare(stringValue(a.updated_at)));
  const keep = group[0];
  const drop = group.slice(1);
  console.log(`   • "${keep.nom_fichier}" pour ${keep.beneficiaire_nom_complet || '?'} (${group.length} copies)`);
  console.log(`       garde   : uuid=${keep.uuid_source} updated=${keep.updated_at}`);
  for (const d of drop) {
    const cIds = chunksByDoc.get(stringValue(d.uuid_source)) || [];
    console.log(`       supprime: uuid=${d.uuid_source} updated=${d.updated_at} chunks=${cIds.length}`);
    dupsToPurge.push(d);
  }
}
const dupsChunkCount = dupsToPurge.reduce(
  (n, d) => n + (chunksByDoc.get(stringValue(d.uuid_source)) || []).length,
  0,
);
console.log(`   Total doublons à supprimer : ${dupsToPurge.length} doc(s), ${dupsChunkCount} chunks\n`);

// Récap.
const allDocsToDelete = [...testDocs, ...dupsToPurge];
const allChunkIds = [];
for (const d of allDocsToDelete) {
  const cIds = chunksByDoc.get(stringValue(d.uuid_source)) || [];
  allChunkIds.push(...cIds);
}

console.log('━'.repeat(60));
console.log(`🗒  Résumé total : ${allDocsToDelete.length} doc(s), ${allChunkIds.length} chunks à supprimer.`);
console.log('━'.repeat(60));

if (allDocsToDelete.length === 0) {
  console.log('\n✅ Rien à nettoyer.');
  process.exit(0);
}

// Archive avant suppression.
const ts = new Date().toISOString().replace(/[:.]/g, '-');
const backupPath = path.resolve(__dirname, `../tmp/cleanup-backup-${ts}.json`);
fs.mkdirSync(path.dirname(backupPath), { recursive: true });
fs.writeFileSync(
  backupPath,
  JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      action1_testDocs: testDocs.map((d) => ({
        Id: d.Id,
        uuid_source: d.uuid_source,
        nom_fichier: d.nom_fichier,
        chunkIds: chunksByDoc.get(stringValue(d.uuid_source)) || [],
      })),
      action2_duplicates: dupsToPurge.map((d) => ({
        Id: d.Id,
        uuid_source: d.uuid_source,
        nom_fichier: d.nom_fichier,
        beneficiaire_nom_complet: d.beneficiaire_nom_complet,
        chunkIds: chunksByDoc.get(stringValue(d.uuid_source)) || [],
      })),
    },
    null,
    2,
  ),
);
console.log(`\n💾 Archive : ${backupPath}`);

if (!APPLY) {
  console.log('\n🚧 Dry-run : aucune suppression effectuée.');
  console.log('   Relance avec  --apply  pour exécuter.');
  process.exit(0);
}

// 3. Exécution : on supprime les chunks d'abord, les docs après.
console.log(`\n🗑  Suppression des chunks (${allChunkIds.length})…`);
await deleteBatch(chunksTable.id, allChunkIds);
console.log(`   ✓ ${allChunkIds.length} chunk(s) supprimé(s)`);

console.log(`🗑  Suppression des documents (${allDocsToDelete.length})…`);
await deleteBatch(documentsTable.id, allDocsToDelete.map((d) => d.Id));
console.log(`   ✓ ${allDocsToDelete.length} document(s) supprimé(s)\n`);

console.log('✅ Nettoyage terminé.');
