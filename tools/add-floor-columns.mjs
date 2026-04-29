// Ajoute 2 colonnes booléennes à la table `logements` côté NocoDB :
// `second_etage` (2e étage activé) et `third_etage` (3e étage activé).
// Permet au PDF d'afficher dynamiquement Étage 1 / Étage 2 / Étage 3.
//
// Idempotent : si les colonnes existent déjà, on skip.
//
// Usage : node tools/add-floor-columns.mjs

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

const f = async (url, init = {}) => {
  const res = await fetch(url, {
    ...init,
    headers: {
      'xc-token': TOKEN,
      'Content-Type': 'application/json',
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`${res.status} on ${url} :: ${text}`);
  }
  return text ? JSON.parse(text) : null;
};

// 1. Trouver la table logements.
const tablesResp = await f(`${API_URL}/api/v2/meta/bases/${BASE}/tables`);
const logements = (tablesResp.list || tablesResp).find(
  (t) => t.title === 'logements',
);
if (!logements) {
  console.error("Table 'logements' introuvable.");
  process.exit(1);
}
const tableId = logements.id;
console.log(`📋 Table logements : ${tableId}`);

// 2. Lire le schéma pour voir les colonnes existantes.
const schema = await f(`${API_URL}/api/v2/meta/tables/${tableId}`);
const existingCols = new Set(schema.columns.map((c) => c.title));

// 3. Pour chaque colonne à ajouter, créer si absente.
const toAdd = [
  { title: 'second_etage', uidt: 'Checkbox' },
  { title: 'third_etage', uidt: 'Checkbox' },
];

for (const col of toAdd) {
  if (existingCols.has(col.title)) {
    console.log(`  ✓ "${col.title}" existe déjà — skip.`);
    continue;
  }
  console.log(`  + création "${col.title}" (${col.uidt})…`);
  await f(`${API_URL}/api/v2/meta/tables/${tableId}/columns`, {
    method: 'POST',
    body: JSON.stringify({
      title: col.title,
      column_name: col.title,
      uidt: col.uidt,
      cdf: 'false', // valeur par défaut = false
    }),
  });
  console.log(`    ✅ "${col.title}" créée.`);
}

console.log('\n✅ Schéma logements à jour.');
