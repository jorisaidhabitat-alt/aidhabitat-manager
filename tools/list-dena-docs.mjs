// Liste TOUS les documents (mobile_documents + mobile_document_chunks)
// rattachés à Paul DENA — source de vérité NocoDB. Sert à comparer
// avec ce que l'iPad et le macOS web montrent à l'écran.

import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const envP = path.resolve(__dirname, '../.env.local');
if (fs.existsSync(envP) && !process.env.NOCODB_API_URL) {
  for (const line of fs.readFileSync(envP, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m) process.env[m[1]] = m[2].trim();
  }
}
const URL = process.env.NOCODB_API_URL?.replace(/\/$/, '');
const TOK = process.env.NOCODB_API_TOKEN;
const BASE = process.env.NOCODB_BASE_ID;
const f = async (u) => (await fetch(u, { headers: { 'xc-token': TOK } })).json();
const sv = (v) => (v == null || v === 'null' ? '' : String(v).trim());

const queryAll = async (tableId, where = '') => {
  const all = [];
  let offset = 0;
  while (true) {
    const w = where ? `&where=${encodeURIComponent(where)}` : '';
    const r = await f(`${URL}/api/v2/tables/${tableId}/records?limit=1000&offset=${offset}${w}`);
    const list = r.list || [];
    all.push(...list);
    if (list.length < 1000) break;
    offset += 1000;
  }
  return all;
};

const meta = await f(`${URL}/api/v2/meta/bases/${BASE}/tables`);
const tables = meta.list || meta;
const docsTbl = tables.find((t) => t.title === 'mobile_documents');
const chunksTbl = tables.find((t) => t.title === 'mobile_document_chunks');
const benefTbl = tables.find((t) => t.title === 'beneficiaires');
const dossiersTbl = tables.find((t) => t.title === 'dossiers');

// 1. Trouver Paul DENA et son UUID
const benefs = await queryAll(benefTbl.id);
const paul = benefs.find(
  (b) =>
    sv(b.prenom).toLowerCase() === 'paul' &&
    sv(b.nom).toLowerCase() === 'dena',
);
if (!paul) {
  console.error('Paul DENA introuvable dans beneficiaires.');
  process.exit(1);
}
console.log(`✅ Paul DENA : Id=${paul.Id}`);

// 2. Trouver le dossier de Paul (pour récupérer patient_id UUID)
const dossiers = await queryAll(dossiersTbl.id);
const paulDossier = dossiers.find((d) => {
  const link = d.beneficiaires_id;
  if (Array.isArray(link)) return link[0]?.Id == paul.Id || link[0] == paul.Id;
  if (typeof link === 'object' && link) return link.Id == paul.Id;
  return link == paul.Id;
});
const paulUuid = sv(paulDossier?.patient_id);
console.log(`   patient_id UUID : ${paulUuid}`);
console.log(`   dossier uuid    : ${sv(paulDossier?.uuid_source)}\n`);

// 3. Documents pour Paul DENA
const docs = await queryAll(docsTbl.id, `(beneficiaire_id,eq,${paulUuid})`);
console.log(`📄 ${docs.length} document(s) dans mobile_documents pour Paul DENA :\n`);
const sorted = docs.sort((a, b) =>
  sv(b.updated_at).localeCompare(sv(a.updated_at)),
);
for (const d of sorted) {
  const name = sv(d.nom_fichier) || sv(d.titre) || '(sans nom)';
  console.log(
    `  • ${name.padEnd(50)} ` +
    `${sv(d.mime_type).padEnd(28)} ` +
    `${sv(d.updated_at).slice(0, 19)} ` +
    `uuid=${sv(d.uuid_source).slice(0, 13)}…`,
  );
}

// 4. Chunks pour Paul DENA (dénormalisés via beneficiaire_id)
const chunks = await queryAll(chunksTbl.id, `(beneficiaire_id,eq,${paulUuid})`);
console.log(`\n📦 ${chunks.length} chunk(s) dans mobile_document_chunks pour Paul DENA.`);

// 5. Vérification d'intégrité : chaque doc a-t-il ses chunks ?
const validDocUuids = new Set(docs.map((d) => sv(d.uuid_source)));
const orphanChunks = chunks.filter(
  (c) => !validDocUuids.has(sv(c.document_uuid_source)),
);
const docsWithoutChunks = docs.filter((d) => {
  const u = sv(d.uuid_source);
  return !chunks.some((c) => sv(c.document_uuid_source) === u);
});
console.log(`\n🔍 Intégrité :`);
console.log(`  - Chunks orphelins (sans doc parent) : ${orphanChunks.length}`);
console.log(`  - Docs sans chunks (uploads incomplets ?) : ${docsWithoutChunks.length}`);
if (docsWithoutChunks.length > 0) {
  console.log(`    Docs concernés :`);
  for (const d of docsWithoutChunks) {
    console.log(`      - ${sv(d.nom_fichier) || sv(d.titre)} (uuid=${sv(d.uuid_source).slice(0, 13)}…)`);
  }
}
