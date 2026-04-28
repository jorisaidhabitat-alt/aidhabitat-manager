// Analyse approfondie de la base NocoDB côté application ergo :
//
//   1. Statut workflow par dossier (checklist : qu'est-ce qui est rempli ?)
//   2. Taux de complétion par champ (champs jamais utilisés / souvent vides)
//   3. Usage des tables de référence (wiki, communes, baremes_anah…)
//   4. Activité dans le temps (dossiers récents vs anciens, abandonnés)
//   5. Couverture des notes par tab_key et bénéficiaire
//   6. Couverture des recommandations
//   7. Ergothérapeutes actifs
//
// Lecture seule. Sortie : tmp/ergo-analysis-<ts>.md

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

const queryAllRecords = async (tableId, fields = []) => {
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
const truthy = (v) => v === true || v === 'true' || v === 1 || v === '1';

// 1. Topologie des tables.
console.log('📋 Lecture du schéma…');
const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = (tablesResp.list || tablesResp).filter((t) => t && t.id);
const findTable = (n) => tables.find((t) => String(t.title).toLowerCase() === n.toLowerCase());

// 2. Lecture des tables clés (tous les champs cette fois — on veut analyser).
const TABLES_TO_READ = [
  'beneficiaires', 'dossiers', 'logements', 'observations',
  'diagnostic_sanitaires', 'mesures_anthropometriques',
  'contexte_de_vie', 'informations_administratives',
  'mobile_documents', 'mobile_note_pages', 'mobile_visit_recommendations',
  '👷🏻‍♀️ ergotherapeutes', 'wiki', 'wiki_tags', 'communes', 'epci',
];

console.log('📥 Lecture des données…');
const data = {};
for (const name of TABLES_TO_READ) {
  const t = findTable(name);
  if (!t) {
    data[name] = [];
    console.log(`   - ${name} : table introuvable`);
    continue;
  }
  data[name] = await queryAllRecords(t.id);
  console.log(`   - ${name} : ${data[name].length} records`);
}
console.log();

// 3. Helpers.
const dossiersByUuid = new Map();
for (const d of data.dossiers) {
  const u = stringValue(d.uuid_source);
  if (u) dossiersByUuid.set(u, d);
}
const beneficiairesByName = new Map();
for (const b of data.beneficiaires) {
  const fullName = `${stringValue(b.prenom)} ${stringValue(b.nom)}`.trim().toLowerCase();
  if (fullName) beneficiairesByName.set(fullName, b);
}

const benefIdToBenef = new Map(); // UUID legacy → record bénéficiaire
for (const m of [...data.mobile_documents, ...data.mobile_note_pages, ...data.mobile_visit_recommendations]) {
  const uuid = stringValue(m.beneficiaire_id);
  const fullName = stringValue(m.beneficiaire_nom_complet);
  if (uuid && fullName && !benefIdToBenef.has(uuid)) {
    const b = beneficiairesByName.get(fullName.toLowerCase());
    if (b) benefIdToBenef.set(uuid, b);
  }
}

// 4. Analyse 1 : statut workflow par dossier.
const dossierStatus = data.dossiers.map((d) => {
  const dUuid = stringValue(d.uuid_source);
  const benefName = String(d.beneficiaire?.nom || d.beneficiaire?.prenom || '').trim()
    || (() => {
      // Fallback : trouver via patient_id (UUID legacy → benef record).
      const pid = stringValue(d.patient_id);
      const b = benefIdToBenef.get(pid);
      return b ? `${stringValue(b.prenom)} ${stringValue(b.nom)}` : '?';
    })();

  const obs = data.observations.find((o) => stringValue(o.dossier_id) === dUuid);
  const diag = data.diagnostic_sanitaires.find((o) => stringValue(o.dossier_id) === dUuid);
  const mesu = data.mesures_anthropometriques.find((o) => stringValue(o.dossier_id) === dUuid);
  const ctx = data.contexte_de_vie.find((o) => stringValue(o.dossier_id) === dUuid);
  const ia = data.informations_administratives.find((o) => stringValue(o.dossier_id) === dUuid);
  const docs = data.mobile_documents.filter((o) => stringValue(o.dossier_id) === dUuid);
  const notes = data.mobile_note_pages.filter((o) => stringValue(o.dossier_id) === dUuid);
  const recos = data.mobile_visit_recommendations.filter((o) => stringValue(o.dossier_id) === dUuid);

  return {
    Id: d.Id,
    uuid: dUuid,
    benef: benefName,
    visitDate: stringValue(d.visit_date),
    ergo: stringValue(d.ergo_id),
    status: stringValue(d.status) || '(vide)',
    natureAccompagnement: stringValue(d.nature_accompagnement),
    envoiRapport: stringValue(d.envoi_rapport),
    compteAnah: stringValue(d.compte_anah),
    hasObservation: !!obs,
    obsFilled: obs && (
      stringValue(obs.observation_equipements) ||
      stringValue(obs.projet_souhait_usage) ||
      stringValue(obs.resume_preconisations)
    ),
    hasDiagnostic: !!diag,
    diagFilled: diag && stringValue(diag.observation_equipements_utilisation),
    hasMesures: !!mesu,
    hasContexte: !!ctx,
    hasIA: !!ia,
    docsCount: docs.length,
    notesCount: notes.length,
    recosCount: recos.length,
    updatedAt: stringValue(d.UpdatedAt) || stringValue(d.updated_at),
  };
});

// 5. Analyse 2 : champs jamais ou rarement remplis.
const fieldFillRates = (rows, ignoreFields = new Set()) => {
  if (rows.length === 0) return [];
  const out = [];
  // Set de champs : union de tous les champs présents.
  const allKeys = new Set();
  for (const r of rows) for (const k of Object.keys(r)) allKeys.add(k);
  for (const k of allKeys) {
    if (ignoreFields.has(k)) continue;
    let filled = 0;
    for (const r of rows) {
      const v = r[k];
      if (v == null) continue;
      if (typeof v === 'object') {
        if (Array.isArray(v)) {
          if (v.length > 0) filled += 1;
        } else if (Object.keys(v).length > 0) {
          filled += 1;
        }
      } else if (stringValue(v)) filled += 1;
    }
    out.push({ field: k, filled, total: rows.length, rate: filled / rows.length });
  }
  return out.sort((a, b) => a.rate - b.rate);
};

const META_FIELDS = new Set([
  'Id', 'CreatedAt', 'UpdatedAt', 'nc_created_by', 'nc_updated_by', 'nc_order',
  'Id1', 'created_at', 'updated_at', 'uuid_source',
]);

const fillReports = {
  beneficiaires: fieldFillRates(data.beneficiaires, META_FIELDS),
  dossiers: fieldFillRates(data.dossiers, META_FIELDS),
  logements: fieldFillRates(data.logements, META_FIELDS),
  diagnostic_sanitaires: fieldFillRates(data.diagnostic_sanitaires, META_FIELDS),
  contexte_de_vie: fieldFillRates(data.contexte_de_vie, META_FIELDS),
};

// 6. Analyse 3 : activité dans le temps.
const today = new Date();
const dossierActivity = data.dossiers.map((d) => {
  const u = stringValue(d.UpdatedAt) || stringValue(d.updated_at);
  const last = u ? new Date(u) : null;
  const daysSinceUpdate = last ? Math.floor((today - last) / (1000 * 60 * 60 * 24)) : null;
  return {
    Id: d.Id,
    benef: d.beneficiaire?.nom || '?',
    lastUpdate: u || '?',
    daysSinceUpdate,
  };
});

// 7. Notes par tab_key.
const notesByTab = new Map();
for (const n of data.mobile_note_pages) {
  const tab = stringValue(n.tab_key) || '(empty)';
  notesByTab.set(tab, (notesByTab.get(tab) || 0) + 1);
}

// 8. Recommandations par wiki_title.
const recosByWiki = new Map();
for (const r of data.mobile_visit_recommendations) {
  const w = stringValue(r.wiki_title) || stringValue(r.custom_title) || '(custom)';
  recosByWiki.set(w, (recosByWiki.get(w) || 0) + 1);
}

// 9. Wiki utilisé vs orphelin.
const wikiUsed = new Set(
  data.mobile_visit_recommendations
    .map((r) => stringValue(r.wiki_item_id))
    .filter(Boolean),
);
const wikiOrphans = data.wiki.filter((w) => !wikiUsed.has(stringValue(w.uuid_source)));

// 10. Ergothérapeutes : qui est actif ?
const ergoActivity = data['👷🏻‍♀️ ergotherapeutes'].map((e) => {
  const fullName = `${stringValue(e.prenom)} ${stringValue(e.nom)}`.trim() || `Id ${e.Id}`;
  const dossiersCreated = data.dossiers.filter(
    (d) => stringValue(d.ergo_id).toLowerCase() === stringValue(e.prenom).toLowerCase(),
  ).length;
  return {
    name: fullName,
    email: stringValue(e.email),
    dossiers: dossiersCreated,
  };
});

// 11. Communes / EPCI utilisées.
const communesUsed = new Set();
for (const b of data.beneficiaires) {
  const c = stringValue(b.code_postal) || stringValue(b.code_postal_libre);
  if (c) communesUsed.add(c);
}

// 12. Doublons potentiels en table de référence.
const communeKey = (c) => `${stringValue(c.nom).toLowerCase()}|${stringValue(c.code_postal)}`;
const communeGroups = new Map();
for (const c of data.communes) {
  const k = communeKey(c);
  if (!stringValue(c.nom)) continue;
  (communeGroups.get(k) || communeGroups.set(k, []).get(k)).push(c);
}
const communeDups = [...communeGroups.values()].filter((g) => g.length > 1);

// 13. Génération du rapport.
const now = new Date();
const ts = now.toISOString().replace(/[:.]/g, '-');
const reportPath = path.resolve(__dirname, `../tmp/ergo-analysis-${ts}.md`);
fs.mkdirSync(path.dirname(reportPath), { recursive: true });

let md = '';
md += `# Analyse base NocoDB — application ergo\n\n`;
md += `Date : ${now.toISOString().replace('T', ' ').slice(0, 16)} · Base \`${BASE_ID}\`\n\n`;

md += `## 1. Statut workflow par dossier\n\n`;
md += `Pour chaque dossier, ce qui est rempli (✅) ou manquant (❌) — base d'évaluation : la complétion attendue par l'app ergo.\n\n`;
md += `| # | Bénéficiaire | Visite | Ergo | Statut | Obs | Diag | Mesu | Ctx | IA | Docs | Notes | Recos | Mis à jour |\n`;
md += `|---|---|---|---|---|:---:|:---:|:---:|:---:|:---:|---:|---:|---:|---|\n`;
const cb = (v) => v ? '✅' : '❌';
const cbFilled = (has, filled) => !has ? '❌' : (filled ? '✅' : '⚠️');
for (const s of dossierStatus.sort((a, b) => (b.updatedAt || '').localeCompare(a.updatedAt || ''))) {
  md += `| ${s.Id} | ${s.benef} | ${s.visitDate || '?'} | ${s.ergo || '?'} | ${s.status} | `;
  md += `${cbFilled(s.hasObservation, s.obsFilled)} | ${cbFilled(s.hasDiagnostic, s.diagFilled)} | ${cb(s.hasMesures)} | ${cb(s.hasContexte)} | ${cb(s.hasIA)} | `;
  md += `${s.docsCount} | ${s.notesCount} | ${s.recosCount} | ${(s.updatedAt || '').slice(0, 10)} |\n`;
}
md += `\n`;
md += `Légende : ✅ rempli · ⚠️ existe mais champs principaux vides · ❌ manquant\n\n`;

md += `## 2. Champs jamais ou rarement utilisés\n\n`;
md += `Champs qui sont vides dans la majorité des records — candidats pour suppression du schéma ou de l'UI.\n\n`;
for (const [table, rows] of Object.entries(fillReports)) {
  if (rows.length === 0) continue;
  const veryEmpty = rows.filter((r) => r.rate < 0.2 && r.total > 0);
  if (veryEmpty.length === 0) {
    md += `### \`${table}\` — aucun champ critique vide\n\n`;
    continue;
  }
  md += `### \`${table}\` — ${veryEmpty.length} champ(s) remplis < 20%\n\n`;
  md += `| Champ | Remplis | Taux |\n|---|---:|---:|\n`;
  for (const f of veryEmpty.slice(0, 25)) {
    md += `| \`${f.field}\` | ${f.filled} / ${f.total} | ${(f.rate * 100).toFixed(0)}% |\n`;
  }
  if (veryEmpty.length > 25) md += `_(+${veryEmpty.length - 25} autres non affichés)_\n`;
  md += `\n`;
}

md += `## 3. Activité — fraîcheur des dossiers\n\n`;
md += `| Dossier | Bénéficiaire | Dernière mise à jour | Jours depuis |\n|---|---|---|---:|\n`;
for (const a of dossierActivity.sort((x, y) => (x.daysSinceUpdate ?? 1e9) - (y.daysSinceUpdate ?? 1e9))) {
  md += `| ${a.Id} | ${a.benef} | ${a.lastUpdate.slice(0, 10) || '?'} | ${a.daysSinceUpdate ?? '?'} |\n`;
}
md += `\n`;

md += `## 4. Couverture des notes par onglet\n\n`;
md += `| Onglet (\`tab_key\`) | Pages |\n|---|---:|\n`;
const sortedTabs = [...notesByTab.entries()].sort((a, b) => b[1] - a[1]);
for (const [tab, n] of sortedTabs) md += `| \`${tab}\` | ${n} |\n`;
md += `\n`;

md += `## 5. Recommandations utilisées (top wiki)\n\n`;
md += `${data.mobile_visit_recommendations.length} recos au total · `;
md += `${data.wiki.length} items wiki dans le catalogue · `;
md += `${wikiOrphans.length} jamais utilisés.\n\n`;
md += `| Wiki / titre | Fois utilisé |\n|---|---:|\n`;
for (const [title, n] of [...recosByWiki.entries()].sort((a, b) => b[1] - a[1]).slice(0, 30)) {
  md += `| ${title} | ${n} |\n`;
}
md += `\n`;

md += `## 6. Ergothérapeutes — activité\n\n`;
md += `| Ergo | Email | Dossiers créés (par ergo_id) |\n|---|---|---:|\n`;
for (const e of ergoActivity.sort((a, b) => b.dossiers - a.dossiers)) {
  md += `| ${e.name} | ${e.email || '—'} | ${e.dossiers} |\n`;
}
md += `\n`;

md += `## 7. Référentiels\n\n`;
md += `### Communes\n`;
md += `- ${data.communes.length} communes au catalogue · ${communesUsed.size} référencées par un bénéficiaire (par CP).\n`;
if (communeDups.length > 0) {
  md += `- ⚠️ **${communeDups.length} doublons probables** (même nom + CP) :\n`;
  for (const g of communeDups.slice(0, 20)) {
    const f = g[0];
    md += `   - ${stringValue(f.nom)} (${stringValue(f.code_postal)}) → ${g.length} entrées (Ids ${g.map((c) => c.Id).join(', ')})\n`;
  }
  md += `\n`;
} else {
  md += `- Pas de doublon détecté.\n\n`;
}

md += `### Wiki (catalogue de préconisations)\n`;
md += `- ${data.wiki.length} items au catalogue · ${data.wiki.length - wikiOrphans.length} utilisés dans des dossiers · **${wikiOrphans.length} jamais utilisés**.\n`;
if (wikiOrphans.length > 0 && wikiOrphans.length <= 50) {
  md += `\nWiki jamais référencés (top 30) :\n`;
  for (const w of wikiOrphans.slice(0, 30)) {
    md += `- ${stringValue(w.titre) || '(sans titre)'} (uuid=${stringValue(w.uuid_source) || w.Id})\n`;
  }
}
md += `\n`;

md += `### EPCI / Caisses retraite / Barèmes\n`;
md += `- \`epci\` : ${data.epci.length} entités · \`caisses_de_retraite\` (référentiel principal) : voir checkup global.\n\n`;

md += `## 8. Recommandations d'action\n\n`;
const actions = [];
const incompleteDossiers = dossierStatus.filter(
  (s) => !s.obsFilled || !s.diagFilled || !s.hasMesures || !s.hasContexte,
);
if (incompleteDossiers.length > 0) {
  actions.push(
    `**${incompleteDossiers.length} dossier(s)** sont incomplets côté workflow ` +
    `(au moins une section principale vide ou champ critique vide). Voir tableau §1.`,
  );
}
if (wikiOrphans.length > 0) {
  actions.push(
    `**${wikiOrphans.length} fiches wiki** ne sont jamais référencées dans une recommandation. ` +
    `Soit elles sont nouvelles (catalogue qui se construit), soit obsolètes (à archiver).`,
  );
}
if (communeDups.length > 0) {
  actions.push(
    `**${communeDups.length} doublons** en table \`communes\` à dédoublonner.`,
  );
}
const staleDossiers = dossierActivity.filter((a) => (a.daysSinceUpdate ?? 0) > 90);
if (staleDossiers.length > 0) {
  actions.push(
    `**${staleDossiers.length} dossier(s)** non mis à jour depuis plus de 90 jours — ` +
    `à clôturer ou réactiver.`,
  );
}
if (actions.length === 0) {
  md += `✅ Aucune action urgente identifiée.\n`;
} else {
  for (const a of actions) md += `- ${a}\n`;
}
md += `\n`;

fs.writeFileSync(reportPath, md);
console.log(`📝 Rapport : ${reportPath}\n`);
console.log('━'.repeat(50));
console.log(`Dossiers analysés      : ${data.dossiers.length}`);
console.log(`Dossiers incomplets    : ${incompleteDossiers.length}`);
console.log(`Wiki jamais utilisés   : ${wikiOrphans.length}`);
console.log(`Doublons communes      : ${communeDups.length}`);
console.log(`Dossiers > 90j stale   : ${staleDossiers.length}`);
console.log('━'.repeat(50));
