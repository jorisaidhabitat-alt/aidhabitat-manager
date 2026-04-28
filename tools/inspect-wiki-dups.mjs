// Inspection détaillée des groupes de doublons wiki :
// pour chaque groupe partageant le même titre, on compare le contenu,
// le tag, la photo, l'uuid_source. Si tout est identique → vrai doublon.
// Si différences → variantes légitimes à conserver.

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
  if (!res.ok) throw new Error(`${res.status} on ${url}`);
  return res.json();
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
const tagsTable = tables.find((t) => t.title === 'wiki_tags');
const recosTable = tables.find((t) => t.title === 'mobile_visit_recommendations');

const [wikis, tags, recos] = await Promise.all([
  queryAll(wikiTable.id),
  queryAll(tagsTable.id),
  queryAll(recosTable.id, ['Id', 'wiki_item_id', 'wiki_title']),
]);

const tagById = new Map();
for (const t of tags) tagById.set(String(t.Id), stringValue(t.tags));
const tagOf = (w) => {
  const v = w.wiki_tags_id;
  if (!v) return '?';
  if (Array.isArray(v) && v.length) return tagById.get(String(v[0].Id || v[0])) || '?';
  if (typeof v === 'object') return tagById.get(String(v.Id || v)) || stringValue(v.tags) || '?';
  return tagById.get(String(v)) || '?';
};

const referencedUuids = new Set(recos.map((r) => stringValue(r.wiki_item_id)).filter(Boolean));

// Groupe par titre.
const groups = new Map();
for (const w of wikis) {
  const k = stringValue(w.titre).toLowerCase();
  if (!k) continue;
  (groups.get(k) || groups.set(k, []).get(k)).push(w);
}
const dupGroups = [...groups.values()].filter((g) => g.length > 1)
  .sort((a, b) => b.length - a.length);

console.log(`📚 ${wikis.length} wikis, ${dupGroups.length} groupes de doublons à inspecter.\n`);

// Pour chaque groupe, comparer les attributs.
let trueDups = 0;
let variants = 0;
const detailedReport = [];

for (const g of dupGroups) {
  const cmpKey = (w) => JSON.stringify({
    contenu: stringValue(w.contenu),
    photos: stringValue(w.photos),
    tag: tagOf(w),
  });

  const uniqueShapes = new Set(g.map(cmpKey));
  const isTrueDup = uniqueShapes.size === 1;

  if (isTrueDup) trueDups += 1; else variants += 1;

  detailedReport.push({
    title: stringValue(g[0].titre),
    count: g.length,
    isTrueDup,
    distinctShapes: uniqueShapes.size,
    referencedCount: g.filter((w) => referencedUuids.has(stringValue(w.uuid_source))).length,
    items: g.map((w) => ({
      Id: w.Id,
      uuid_source: stringValue(w.uuid_source),
      tag: tagOf(w),
      hasContent: stringValue(w.contenu).length > 50,
      contentLen: stringValue(w.contenu).length,
      hasPhoto: !!stringValue(w.photos),
      photoPath: stringValue(w.photos).slice(0, 60),
      contentPreview: stringValue(w.contenu).slice(0, 150),
      referenced: referencedUuids.has(stringValue(w.uuid_source)),
    })),
  });
}

const ts = new Date().toISOString().replace(/[:.]/g, '-');
const reportPath = path.resolve(__dirname, `../tmp/wiki-dups-detail-${ts}.md`);
fs.mkdirSync(path.dirname(reportPath), { recursive: true });

let md = `# Détail des doublons wiki — analyse fine\n\n`;
md += `Date : ${new Date().toISOString().slice(0, 16).replace('T', ' ')}\n\n`;
md += `## Synthèse\n\n`;
md += `- ${dupGroups.length} groupes de doublons (même titre).\n`;
md += `- **${trueDups} vrais doublons** : tag + contenu + photo IDENTIQUES dans toutes les copies.\n`;
md += `- **${variants} groupes de variantes** : au moins une différence (tag, contenu ou photo).\n`;
md += `- Total fiches en doublons : ${dupGroups.reduce((n, g) => n + g.length, 0)}.\n\n`;

// Groupes vrais doublons (compactés)
md += `## ✅ Vrais doublons (à supprimer en sécurité)\n\n`;
md += `Tous les attributs (tag, contenu, photo) sont identiques dans le groupe → ce sont des copies générées par un import qui s'est exécuté plusieurs fois.\n\n`;
md += `| Titre | Copies | Tag | Réf par reco | UUIDs |\n|---|---:|---|:---:|---|\n`;
for (const r of detailedReport.filter((r) => r.isTrueDup)) {
  const refMark = r.referencedCount > 0 ? `✅ ×${r.referencedCount}` : '—';
  const uuidPreviews = r.items.map((i) => i.uuid_source.split('-').slice(-1)[0] || '?').join(', ');
  md += `| ${r.title} | ${r.count} | ${r.items[0].tag} | ${refMark} | ${uuidPreviews} |\n`;
}
md += `\n`;

// Groupes variantes (détail complet)
if (variants > 0) {
  md += `## ⚠️ Groupes avec variantes (à inspecter manuellement)\n\n`;
  md += `Au moins un attribut diffère entre les copies — ce ne sont pas des copies pures.\n\n`;
  for (const r of detailedReport.filter((r) => !r.isTrueDup)) {
    md += `### ${r.title} (${r.count} entrées, ${r.distinctShapes} shapes distinctes)\n\n`;
    md += `| Id | UUID | Tag | Content len | Photo path | Réf |\n|---|---|---|---:|---|:---:|\n`;
    for (const i of r.items) {
      md += `| ${i.Id} | ${i.uuid_source} | ${i.tag} | ${i.contentLen} | ${i.photoPath} | ${i.referenced ? '✅' : '—'} |\n`;
    }
    md += `\n#### Aperçu du contenu (premier 150 chars de chaque)\n\n`;
    for (const i of r.items) {
      md += `- **Id ${i.Id}** : ${i.contentPreview}\n`;
    }
    md += `\n`;
  }
}

fs.writeFileSync(reportPath, md);
console.log(`📝 Rapport : ${reportPath}\n`);
console.log('━'.repeat(50));
console.log(`Vrais doublons (purge sûre) : ${trueDups}`);
console.log(`Variantes (à inspecter)     : ${variants}`);
console.log('━'.repeat(50));
