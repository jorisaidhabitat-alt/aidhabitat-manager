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
const docs = (meta.list).find(t => t.title === 'mobile_documents');

// Test : where avec quotes JSON.stringify
const wQuoted = JSON.stringify('58ab26f3-a158-4cc3-8ded-fb91f9e1edd1');
const r1 = await f(`${URL}/api/v2/tables/${docs.id}/records?limit=10&where=${encodeURIComponent('(beneficiaire_id,eq,'+wQuoted+')')}`);
console.log(`Avec quotes JSON : ${r1.list?.length || 0} matches`);
for (const d of (r1.list || []).slice(0, 5)) {
  console.log(`  Id=${d.Id} full="${d.beneficiaire_nom_complet}"`);
}

// Test : where sans quotes
const r2 = await f(`${URL}/api/v2/tables/${docs.id}/records?limit=10&where=${encodeURIComponent('(beneficiaire_id,eq,58ab26f3-a158-4cc3-8ded-fb91f9e1edd1)')}`);
console.log(`\nSans quotes : ${r2.list?.length || 0} matches`);
for (const d of (r2.list || []).slice(0, 5)) {
  console.log(`  Id=${d.Id} full="${d.beneficiaire_nom_complet}"`);
}

// Test : pagination COMPLETE (le limit=10 cache peut-être les vrais stales)
let offset = 0;
const all = [];
while (true) {
  const r = await f(`${URL}/api/v2/tables/${docs.id}/records?limit=1000&offset=${offset}&where=${encodeURIComponent('(beneficiaire_id,eq,58ab26f3-a158-4cc3-8ded-fb91f9e1edd1)')}`);
  const list = r.list || [];
  all.push(...list);
  if (list.length < 1000) break;
  offset += 1000;
}
console.log(`\nTotal docs benef=58ab26f3 : ${all.length}`);
const distinctFull = new Set(all.map(d => d.beneficiaire_nom_complet));
console.log(`Valeurs distinctes de beneficiaire_nom_complet :`);
for (const v of distinctFull) console.log(`  "${v}"`);
