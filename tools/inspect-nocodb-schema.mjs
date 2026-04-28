// Inspecte le schéma réel des 27 tables NocoDB pour calibrer le
// checkup. Lecture seule.

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

const nocoFetch = async (url) => {
  const res = await fetch(url, {
    headers: { 'xc-token': API_TOKEN, 'Content-Type': 'application/json' },
  });
  if (!res.ok) throw new Error(`${res.status} on ${url} :: ${await res.text().catch(() => '')}`);
  return res.json();
};

const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = (tablesResp.list || tablesResp).filter((t) => t && t.id);

console.log(`📋 ${tables.length} tables :\n`);
for (const t of tables) {
  // Lit le schéma complet pour avoir la liste des colonnes.
  let schema;
  try {
    schema = await nocoFetch(`${API_URL}/api/v2/meta/tables/${t.id}`);
  } catch {
    console.log(`  ${t.title.padEnd(40)} (schéma non lisible)`);
    continue;
  }
  // 1ère row (si existe) pour voir un exemple de valeurs.
  const recs = await nocoFetch(`${API_URL}/api/v2/tables/${t.id}/records?limit=1`);
  const sample = (recs.list || [])[0] || null;
  const cols = (schema.columns || []).map((c) => c.title);

  console.log(`▼ ${t.title}  (${t.id})  cols=${cols.length}`);
  console.log(`    ${cols.join(', ')}`);
  if (sample) {
    const tiny = Object.fromEntries(
      Object.entries(sample)
        .map(([k, v]) => {
          const s = v == null ? 'null' : String(v);
          return [k, s.length > 50 ? s.slice(0, 50) + '…' : s];
        })
        .slice(0, 8),
    );
    console.log(`    sample: ${JSON.stringify(tiny)}`);
  }
  console.log();
}
