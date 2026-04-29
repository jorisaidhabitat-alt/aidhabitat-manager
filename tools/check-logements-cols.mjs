// Quick : liste les colonnes de la table `logements` côté NocoDB pour
// vérifier si `*_rooms_json` existent (sinon la sous-section "Niveaux"
// du Flutter écrit dans le vide côté serveur).
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
const TOKEN = process.env.NOCODB_API_TOKEN;
const BASE = process.env.NOCODB_BASE_ID;

const f = (u) =>
  fetch(u, { headers: { 'xc-token': TOKEN } }).then((r) => r.json());

const tables = (await f(`${API_URL}/api/v2/meta/bases/${BASE}/tables`)).list;
const logements = tables.find((t) => t.title === 'logements');
const schema = await f(`${API_URL}/api/v2/meta/tables/${logements.id}`);
const cols = schema.columns.map((c) => c.title);

console.log(`Total colonnes : ${cols.length}`);
console.log('\nColonnes liées aux pièces / niveaux / descriptions :');
for (const c of cols) {
  const lc = c.toLowerCase();
  if (
    lc.includes('rooms') ||
    lc.includes('description') ||
    lc.includes('piece') ||
    lc.includes('rdc') ||
    lc.includes('etage') ||
    lc.includes('sous_sol') ||
    lc.includes('basement') ||
    lc.includes('floor')
  ) {
    console.log(`  - ${c}`);
  }
}

// Vérifie aussi sur 1 record réel ce qui est rempli
const r = await f(`${API_URL}/api/v2/tables/${logements.id}/records?limit=3`);
console.log('\nÉchantillon de 3 records (champs niveaux/pièces) :');
for (const rec of r.list) {
  console.log('  Id', rec.Id);
  for (const k of Object.keys(rec)) {
    const lk = k.toLowerCase();
    if (
      lk.includes('rooms') ||
      lk.includes('description') ||
      lk.includes('rdc') ||
      lk.includes('etage') ||
      lk.includes('sous_sol')
    ) {
      const v = rec[k];
      const s = v == null ? 'null' : String(v).slice(0, 60);
      console.log(`    ${k.padEnd(35)} = ${s}`);
    }
  }
  console.log();
}
