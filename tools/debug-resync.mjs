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

const meta = await f(`${URL}/api/v2/meta/bases/${BASE}/tables`);
const tables = (meta.list || meta);
const docs = tables.find(t => t.title === 'mobile_documents');
const dossiers = tables.find(t => t.title === 'dossiers');
const benefs = tables.find(t => t.title === 'beneficiaires');

const dRows = (await f(`${URL}/api/v2/tables/${dossiers.id}/records?limit=100`)).list;
console.log('=== Dossiers ===');
for (const d of dRows) {
  console.log(`  patient_id=${String(d.patient_id || '').slice(0,15)}…  benef_link=${JSON.stringify(d.beneficiaires_id || null).slice(0,80)}`);
}

const bRows = (await f(`${URL}/api/v2/tables/${benefs.id}/records?limit=100`)).list;
console.log('\n=== Bénéficiaires ===');
for (const b of bRows) {
  console.log(`  Id=${b.Id}  ${(b.prenom||'').padEnd(15)} ${b.nom||''}`);
}

// Test la requête avec where clause
const sample = await f(`${URL}/api/v2/tables/${docs.id}/records?limit=3&where=${encodeURIComponent('(beneficiaire_id,eq,58ab26f3-a158-4cc3-8ded-fb91f9e1edd1)')}`);
console.log('\n=== mobile_documents WHERE beneficiaire_id=58ab26f3... ===');
console.log(`  ${sample.list?.length || 0} matches`);
for (const d of (sample.list || [])) {
  console.log(`  Id=${d.Id} prenom="${d.beneficiaire_prenom}" nom="${d.beneficiaire_nom}" full="${d.beneficiaire_nom_complet}"`);
}

// Test SANS where
const all = await f(`${URL}/api/v2/tables/${docs.id}/records?limit=5`);
console.log('\n=== mobile_documents (5 random) ===');
for (const d of (all.list || [])) {
  console.log(`  Id=${d.Id} benef_id="${String(d.beneficiaire_id||'').slice(0,20)}…" full="${d.beneficiaire_nom_complet}"`);
}
