// Dédoublonnage du catalogue wiki :
// pour chaque groupe de fiches partageant le même titre, on garde
// 1 exemplaire — celui référencé par une reco existante en priorité,
// sinon le plus récent (Id max).
//
// Usage :
//   node tools/dedupe-wiki.mjs           # dry-run
//   node tools/dedupe-wiki.mjs --apply   # supprime réellement
//
// Sortie : tmp/wiki-dedupe-backup-<ts>.json (archive avant suppression)

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

const queryAll = async (tableId, fields = []) => {
  const all = [];
  let offset = 0;
  while (true) {
    const f = fields.length ? `&fields=${encodeURIComponent(fields.join(','))}` : '';
    const r = await nocoFetch(`${API_URL}/api/v2/tables/${tableId}/records?limit=1000&offset=${offset}${f}`);
    const list = r.list || [];
    all.push(...list);
    if (list.length < 1000) break;
    offset += 1000;
  }
  return all;
};

const stringValue = (v) => (v == null || v === 'null' ? '' : String(v).trim());

const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = (tablesResp.list || tablesResp).filter((t) => t && t.id);
const wikiTable = tables.find((t) => t.title === 'wiki');
const recosTable = tables.find((t) => t.title === 'mobile_visit_recommendations');

console.log('🔍 Lecture wiki + recos…');
const [wikis, recos] = await Promise.all([
  queryAll(wikiTable.id, ['Id', 'uuid_source', 'titre', 'contenu', 'photos', 'CreatedAt']),
  queryAll(recosTable.id, ['Id', 'wiki_item_id', 'wiki_title']),
]);
console.log(`   ${wikis.length} wikis, ${recos.length} recos.\n`);

// Set des UUIDs wiki effectivement référencés.
const referencedUuids = new Set(recos.map((r) => stringValue(r.wiki_item_id)).filter(Boolean));

// Groupe par titre (case-insensitive).
const groups = new Map();
for (const w of wikis) {
  const k = stringValue(w.titre).toLowerCase();
  if (!k) continue;
  (groups.get(k) || groups.set(k, []).get(k)).push(w);
}

const dupGroups = [...groups.values()].filter((g) => g.length > 1);
console.log(`📦 ${dupGroups.length} groupe(s) de doublons.\n`);

// Pour chaque groupe : choix du « gardé » + liste des « à supprimer ».
const toDelete = [];
const decisions = [];
for (const g of dupGroups) {
  // Priorité 1 : un exemplaire référencé par une reco.
  const refed = g.find((w) => referencedUuids.has(stringValue(w.uuid_source)));
  // Priorité 2 : le plus récent (Id max).
  const sortedById = [...g].sort((a, b) => Number(b.Id) - Number(a.Id));
  const keep = refed || sortedById[0];
  const drop = g.filter((w) => w.Id !== keep.Id);
  toDelete.push(...drop);
  decisions.push({
    title: stringValue(g[0].titre),
    keptId: keep.Id,
    keptReason: refed ? 'référencé par reco' : 'plus récent',
    droppedIds: drop.map((w) => w.Id),
  });
}

console.log(`Récap par groupe :`);
for (const d of decisions.slice(0, 60)) {
  console.log(
    `  • ${d.title.padEnd(40)} keep Id=${String(d.keptId).padStart(4)} (${d.keptReason})  drop ${d.droppedIds.length}× (${d.droppedIds.join(', ')})`,
  );
}
if (decisions.length > 60) console.log(`  …(+${decisions.length - 60} autres groupes)`);
console.log();
console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
console.log(`Total à supprimer : ${toDelete.length} fiche(s) wiki`);
console.log(`Catalogue après   : ${wikis.length - toDelete.length} fiches uniques`);
console.log(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);

if (toDelete.length === 0) {
  console.log('\n✅ Rien à dédupliquer.');
  process.exit(0);
}

// Archive avant suppression.
const ts = new Date().toISOString().replace(/[:.]/g, '-');
const backupPath = path.resolve(__dirname, `../tmp/wiki-dedupe-backup-${ts}.json`);
fs.mkdirSync(path.dirname(backupPath), { recursive: true });
fs.writeFileSync(
  backupPath,
  JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      decisions,
      deletedDetails: toDelete.map((w) => ({
        Id: w.Id,
        uuid_source: w.uuid_source,
        titre: w.titre,
        photos: w.photos,
        contenu_preview: stringValue(w.contenu).slice(0, 200),
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

// Suppression batch.
const ids = toDelete.map((w) => w.Id);
const BATCH = 50;
for (let i = 0; i < ids.length; i += BATCH) {
  await nocoFetch(`${API_URL}/api/v2/tables/${wikiTable.id}/records`, {
    method: 'DELETE',
    body: JSON.stringify(ids.slice(i, i + BATCH).map((id) => ({ Id: id }))),
  });
  process.stdout.write(`\r   ${Math.min(i + BATCH, ids.length)} / ${ids.length}`);
}
console.log(`\n✅ ${ids.length} fiche(s) wiki supprimée(s).`);
