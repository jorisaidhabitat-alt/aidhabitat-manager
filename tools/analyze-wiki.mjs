// Analyse fine des 403 fiches wiki pour décider du sort des 363
// orphelines (jamais utilisées en reco) :
//   - Date de création / dernière mise à jour
//   - Distribution par tag
//   - Présence de contenu vs fiches stub
//   - Doublons par titre
//   - Source (auto-importée vs créée à la main par l'ergo)
//
// Lecture seule. Sortie : tmp/wiki-analysis-<ts>.md

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
  queryAll(recosTable.id),
]);

console.log(`📚 ${wikis.length} fiches wiki, ${tags.length} tags, ${recos.length} recos.\n`);

// 1. Index : wikis utilisés.
const usedWikiUuids = new Set(
  recos.map((r) => stringValue(r.wiki_item_id)).filter(Boolean),
);
const used = wikis.filter((w) => usedWikiUuids.has(stringValue(w.uuid_source)));
const orphans = wikis.filter((w) => !usedWikiUuids.has(stringValue(w.uuid_source)));

// 2. Distribution par tag.
const tagCounts = new Map();
const orphansByTag = new Map();
const usedByTag = new Map();
const tagById = new Map();
for (const t of tags) tagById.set(String(t.Id), stringValue(t.tags));

const tagOf = (w) => {
  // Lit le lien wiki_tags_id (peut être un ID, un objet, ou un tableau).
  const v = w.wiki_tags_id ?? w.wiki_tags ?? null;
  if (!v) return '(sans tag)';
  if (typeof v === 'object') {
    if (Array.isArray(v) && v.length) return tagById.get(String(v[0].Id || v[0])) || '(sans tag)';
    return tagById.get(String(v.Id || v)) || stringValue(v.tags) || '(sans tag)';
  }
  return tagById.get(String(v)) || '(sans tag)';
};

for (const w of wikis) {
  const t = tagOf(w);
  tagCounts.set(t, (tagCounts.get(t) || 0) + 1);
}
for (const w of orphans) {
  const t = tagOf(w);
  orphansByTag.set(t, (orphansByTag.get(t) || 0) + 1);
}
for (const w of used) {
  const t = tagOf(w);
  usedByTag.set(t, (usedByTag.get(t) || 0) + 1);
}

// 3. Stub vs contenu réel : `contenu` rempli ? `photos` rempli ?
const hasContent = (w) => {
  const c = stringValue(w.contenu);
  return c.length > 50; // Au-delà de "{}"  ou texte minimal.
};
const hasPhoto = (w) => stringValue(w.photos);

const orphansStub = orphans.filter((w) => !hasContent(w));
const orphansFilled = orphans.filter((w) => hasContent(w));
const orphansWithPhoto = orphans.filter(hasPhoto);

// 4. Dates de création.
const orphansByMonth = new Map();
for (const w of orphans) {
  const d = stringValue(w.CreatedAt);
  const ym = d.slice(0, 7) || 'inconnu';
  orphansByMonth.set(ym, (orphansByMonth.get(ym) || 0) + 1);
}

// 5. Doublons par titre.
const titleGroups = new Map();
for (const w of wikis) {
  const k = stringValue(w.titre).toLowerCase();
  if (!k) continue;
  (titleGroups.get(k) || titleGroups.set(k, []).get(k)).push(w);
}
const dupTitles = [...titleGroups.values()].filter((g) => g.length > 1);

// 6. Préfixe d'uuid_source : indice de la source d'import.
const uuidPrefixes = new Map();
for (const w of orphans) {
  const u = stringValue(w.uuid_source);
  const prefix = u.split('-')[0] || '(sans uuid)';
  // Heuristique : si l'UUID ressemble à un slug ("preco-chambre-…"),
  // c'est un import auto. Sinon UUID standard = créé via l'app.
  const kind = u.match(/^[0-9a-f]{8}$/i) ? 'uuid-standard' :
    u.startsWith('preco-') ? 'import auto (preco-*)' :
    u ? 'autre slug' : '(sans uuid)';
  uuidPrefixes.set(kind, (uuidPrefixes.get(kind) || 0) + 1);
}

// 7. Génération du rapport.
const ts = new Date().toISOString().replace(/[:.]/g, '-');
const reportPath = path.resolve(__dirname, `../tmp/wiki-analysis-${ts}.md`);

let md = `# Analyse des 403 fiches wiki\n\n`;
md += `Date : ${new Date().toISOString().slice(0, 16).replace('T', ' ')}\n\n`;
md += `## Synthèse\n\n`;
md += `- **${wikis.length} fiches** au catalogue, **${tags.length} tags**, **${recos.length} recos** dans des dossiers.\n`;
md += `- **${used.length} fiches utilisées** (référencées dans une reco) → 10%\n`;
md += `- **${orphans.length} fiches jamais utilisées** → 90%\n`;
md += `- Parmi les orphelines :\n`;
md += `   - ${orphansFilled.length} ont du contenu (\`contenu\` > 50 chars) — sont prêtes à être proposées.\n`;
md += `   - ${orphansStub.length} sont des stubs (peu/pas de contenu).\n`;
md += `   - ${orphansWithPhoto.length} ont une illustration (\`photos\` renseigné).\n`;
md += `   - Sources des UUIDs : ${[...uuidPrefixes.entries()].map(([k, v]) => `${v} ${k}`).join(', ')}.\n\n`;

md += `## Distribution par tag (orphelines vs utilisées)\n\n`;
md += `| Tag | Total | Orphelines | Utilisées | Taux d'usage |\n|---|---:|---:|---:|---:|\n`;
const allTags = new Set([...tagCounts.keys(), ...orphansByTag.keys(), ...usedByTag.keys()]);
const sortedTags = [...allTags].sort((a, b) => (tagCounts.get(b) || 0) - (tagCounts.get(a) || 0));
for (const t of sortedTags) {
  const total = tagCounts.get(t) || 0;
  const orph = orphansByTag.get(t) || 0;
  const u = usedByTag.get(t) || 0;
  md += `| ${t} | ${total} | ${orph} | ${u} | ${total ? ((u / total) * 100).toFixed(0) + '%' : '—'} |\n`;
}
md += `\n`;

md += `## Création des fiches orphelines par mois\n\n`;
md += `| Mois | Fiches créées (orphelines) |\n|---|---:|\n`;
for (const [m, n] of [...orphansByMonth.entries()].sort()) {
  md += `| ${m} | ${n} |\n`;
}
md += `\n`;

md += `## Doublons par titre\n\n`;
if (dupTitles.length === 0) {
  md += `Aucun doublon de titre détecté.\n\n`;
} else {
  md += `${dupTitles.length} groupe(s) de doublons :\n\n`;
  for (const g of dupTitles.slice(0, 30)) {
    const f = g[0];
    md += `- **${stringValue(f.titre)}** → ${g.length} entrées (Ids ${g.map((w) => w.Id).join(', ')})\n`;
  }
  md += `\n`;
}

md += `## Échantillon orphelines avec contenu (top 30 par tag)\n\n`;
md += `Si la grande majorité du catalogue est cohérente avec les besoins ergo, c'est un **catalogue ouvert** (chargé en avance). Si beaucoup paraissent hors sujet ou redondantes, c'est un **cimetière** à archiver.\n\n`;
md += `| Tag | Titre | Contenu | Photo | UUID |\n|---|---|:---:|:---:|---|\n`;
const sampleByTag = new Map();
for (const w of orphans) {
  const t = tagOf(w);
  if (!sampleByTag.has(t)) sampleByTag.set(t, []);
  if (sampleByTag.get(t).length < 5) sampleByTag.get(t).push(w);
}
for (const [t, group] of sampleByTag) {
  for (const w of group) {
    md += `| ${t} | ${stringValue(w.titre) || '(sans titre)'} | ${hasContent(w) ? '✅' : '—'} | ${hasPhoto(w) ? '🖼' : '—'} | ${stringValue(w.uuid_source).slice(0, 30)} |\n`;
  }
}
md += `\n`;

md += `## Décision recommandée\n\n`;
const allFromAutoImport = orphans.every((w) => stringValue(w.uuid_source).startsWith('preco-'));
if (allFromAutoImport) {
  md += `🟢 **Catalogue ouvert** : 100% des orphelines ont un UUID slug \`preco-*\` → import auto en avance, à conserver. C'est par design : l'ergo choisit dans une banque préchargée.\n\n`;
  md += `**Action recommandée** : aucune. Le catalogue se construit pour servir les futurs dossiers.\n`;
} else {
  md += `Les orphelines mélangent UUIDs auto-importés et UUIDs créés via l'app — analyse à approfondir avant suppression de masse.\n`;
}
md += `\n`;

fs.writeFileSync(reportPath, md);
console.log(`📝 Rapport : ${reportPath}\n`);
console.log('━'.repeat(50));
console.log(`Utilisées       : ${used.length}/${wikis.length}`);
console.log(`Orphelines      : ${orphans.length}/${wikis.length}`);
console.log(`  avec contenu  : ${orphansFilled.length}`);
console.log(`  stubs vides   : ${orphansStub.length}`);
console.log(`  avec photo    : ${orphansWithPhoto.length}`);
console.log(`Sources UUIDs   :`);
for (const [k, v] of uuidPrefixes) console.log(`  ${k.padEnd(28)} ${v}`);
console.log('━'.repeat(50));
