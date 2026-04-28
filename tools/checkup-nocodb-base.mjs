// Checkup global de la base NocoDB v2 — calibré sur les vrais noms
// de tables et de champs de la base aid'habitat.
//
// Usage : node tools/checkup-nocodb-base.mjs
// Sortie : tmp/nocodb-checkup-<ts>.md (lecture seule, aucune modif)

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

// 1. Inventaire complet des 27 tables.
console.log('📋 Inventaire…');
const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = (tablesResp.list || tablesResp).filter((t) => t && t.id);
const findTable = (n) => tables.find((t) => String(t.title).toLowerCase() === n.toLowerCase());

// Comptage (en parallèle pour aller vite).
const counts = await Promise.all(
  tables.map(async (t) => {
    try {
      const r = await nocoFetch(`${API_URL}/api/v2/tables/${t.id}/records?limit=1`);
      return { title: t.title, id: t.id, count: r.pageInfo?.totalRows ?? r.list?.length ?? 0 };
    } catch {
      return { title: t.title, id: t.id, count: -1 };
    }
  }),
);

console.log(`   ${tables.length} tables.\n`);

// 2. Tables métier à inspecter en profondeur.
const TABLE_SPECS = {
  beneficiaires: {
    fields: ['Id', 'nom', 'prenom', 'date_naissance_monsieur', 'date_naissance_madame',
      'mail', 'telephone', 'adresse_logement', 'commune', 'code_postal',
      'logements', 'dossiers', 'contexte_de_vie'],
    label: 'Bénéficiaires',
  },
  dossiers: {
    fields: ['Id', 'uuid_source', 'patient_id', 'beneficiaires_id', 'beneficiaire',
      'visit_date', 'ergo_id', 'status', 'logement', 'observations', 'diagnostic_sanitaires'],
    label: 'Dossiers',
  },
  logements: {
    fields: ['Id', 'uuid_source', 'beneficiaire_id', 'beneficiaires_id', 'beneficiaire',
      'type_de_logement', 'annee_construction', 'surface_habitable', 'commentaire'],
    label: 'Logements',
  },
  observations: {
    fields: ['Id', 'uuid_source', 'dossier_id', 'dossiers_id', 'dossier',
      'observation_equipements', 'projet_souhait_usage', 'resume_preconisations'],
    label: 'Observations',
  },
  diagnostic_sanitaires: {
    fields: ['Id', 'uuid_source', 'dossier_id', 'dossiers_id', 'dossier',
      'observation_equipements_utilisation'],
    label: 'Diagnostic sanitaires',
  },
  mesures_anthropometriques: {
    fields: ['Id', 'uuid_source', 'dossier_id', 'dossiers_id', 'dossier'],
    label: 'Mesures anthropométriques',
  },
  contexte_de_vie: {
    fields: ['Id', 'uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaires_id', 'dossiers_id'],
    label: 'Contexte de vie',
  },
  informations_administratives: {
    fields: ['Id', 'uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaires_id', 'dossiers_id'],
    label: 'Informations administratives',
  },
  mobile_documents: {
    fields: ['Id', 'uuid_source', 'beneficiaire_id', 'dossier_id',
      'beneficiaire_nom_complet', 'titre', 'nom_fichier', 'mime_type'],
    label: 'mobile_documents',
  },
  mobile_document_chunks: {
    fields: ['Id', 'uuid_source', 'document_uuid_source', 'chunk_index'],
    label: 'mobile_document_chunks',
  },
  mobile_note_pages: {
    fields: ['Id', 'uuid_source', 'beneficiaire_id', 'dossier_id', 'tab_key', 'page_number',
      'beneficiaire_nom_complet'],
    label: 'mobile_note_pages',
  },
  mobile_visit_recommendations: {
    fields: ['Id', 'uuid_source', 'dossier_id', 'beneficiaire_id', 'wiki_title', 'note',
      'beneficiaire_nom_complet'],
    label: 'mobile_visit_recommendations',
  },
};

console.log('📥 Lecture détaillée…');
const data = {};
for (const [name, spec] of Object.entries(TABLE_SPECS)) {
  const t = findTable(name);
  if (!t) { data[name] = []; console.log(`   - ${name} : table introuvable`); continue; }
  // Filtre les champs selon le schéma réel.
  let availableFields = null;
  try {
    const sch = await nocoFetch(`${API_URL}/api/v2/meta/tables/${t.id}`);
    availableFields = new Set((sch.columns || []).map((c) => c.title));
  } catch { /**/ }
  const used = availableFields ? spec.fields.filter((f) => availableFields.has(f)) : spec.fields;
  data[name] = await queryAllRecords(t.id, used);
  console.log(`   - ${name} : ${data[name].length} records`);
}
console.log();

// 3. Index pour les jointures.
//
// IMPORTANT : la base utilise DEUX systèmes d'identifiants :
//   - Id NocoDB (numérique, "1", "2", …) — clé primaire technique
//   - UUIDs métier (legacy SQLite Flutter) :
//       beneficiaires : pas de champ uuid_source (les UUIDs des autres
//                       tables pointent vers un client Flutter, pas vers
//                       beneficiaires.Id directement). Donc on bâtit
//                       l'index par les UUIDs RÉFÉRENCÉS dans les
//                       tables enfants.
//       dossiers / logements / etc. : `uuid_source` = identifiant métier
//
// Pour vérifier l'intégrité référentielle côté NocoDB lui-même, on
// regarde aussi les colonnes Lookup résolues (beneficiaire / dossier),
// qui valent un objet (résolu) ou null (lien cassé).
const dossiersByUuid = new Set(data.dossiers.map((d) => stringValue(d.uuid_source)).filter(Boolean));
const allBeneficiaireIds = new Set(); // Tous les beneficiaire_id rencontrés.
for (const r of data.contexte_de_vie) {
  const id = stringValue(r.beneficiaire_id);
  if (id) allBeneficiaireIds.add(id);
}
for (const r of data.informations_administratives) {
  const id = stringValue(r.beneficiaire_id);
  if (id) allBeneficiaireIds.add(id);
}
for (const r of data.logements) {
  const id = stringValue(r.beneficiaire_id);
  if (id) allBeneficiaireIds.add(id);
}
for (const r of data.dossiers) {
  const id = stringValue(r.patient_id);
  if (id) allBeneficiaireIds.add(id);
}

// Documents (uuid_source des mobile_documents pour vérifier les chunks).
const validDocumentUuids = new Set(
  data.mobile_documents.map((d) => stringValue(d.uuid_source)).filter(Boolean),
);

// 4. Findings.
const findings = [];
const push = (level, area, msg, details = []) =>
  findings.push({ level, area, msg, details });

// 4.1 Bénéficiaires : champs critiques
{
  const rows = data.beneficiaires;
  const noNameNorPrenom = rows.filter(
    (r) => !stringValue(r.nom) && !stringValue(r.prenom),
  );
  if (noNameNorPrenom.length > 0) {
    push('critical', 'Bénéficiaires',
      `${noNameNorPrenom.length} bénéficiaire(s) SANS nom NI prénom`,
      noNameNorPrenom.map((r) => `Id=${r.Id}`));
  }

  const noBirthDate = rows.filter(
    (r) => !stringValue(r.date_naissance_monsieur) && !stringValue(r.date_naissance_madame),
  );
  if (noBirthDate.length > 0) {
    push('warn', 'Bénéficiaires',
      `${noBirthDate.length} bénéficiaire(s) sans aucune date de naissance`,
      noBirthDate.map((r) => `Id=${r.Id} ${stringValue(r.prenom)} ${stringValue(r.nom)}`));
  }

  const noAddress = rows.filter(
    (r) => !stringValue(r.adresse_logement) && !stringValue(r.commune),
  );
  if (noAddress.length > 0) {
    push('info', 'Bénéficiaires',
      `${noAddress.length} bénéficiaire(s) sans adresse ni commune`,
      noAddress.map((r) => `Id=${r.Id} ${stringValue(r.prenom)} ${stringValue(r.nom)}`));
  }

  // Doublons probables : même nom + prénom (case-insensitive).
  const groups = new Map();
  for (const r of rows) {
    const k = `${stringValue(r.nom).toUpperCase()}|${stringValue(r.prenom).toUpperCase()}`;
    if (k === '|') continue;
    (groups.get(k) || groups.set(k, []).get(k)).push(r);
  }
  const dups = [...groups.values()].filter((g) => g.length > 1);
  if (dups.length > 0) {
    push('warn', 'Bénéficiaires',
      `${dups.length} groupe(s) de doublons (même nom + prénom)`,
      dups.map((g) => {
        const f = g[0];
        return `${stringValue(f.prenom)} ${stringValue(f.nom)} → ${g.length} entrées (Id=${g.map((r) => r.Id).join(', ')})`;
      }));
  }
}

// 4.2 Dossiers
{
  const rows = data.dossiers;
  const noUuid = rows.filter((r) => !stringValue(r.uuid_source));
  if (noUuid.length > 0) {
    push('warn', 'Dossiers', `${noUuid.length} dossier(s) sans uuid_source`,
      noUuid.map((r) => `Id=${r.Id}`));
  }

  // Lookup `beneficiaire` cassé (lien NocoDB vers beneficiaires inexistant).
  const linkBroken = rows.filter((r) => {
    const v = r.beneficiaire;
    if (v == null) return true;
    const s = String(v);
    return s === 'null' || s === '' || s === '[object Object]'
      ? !v || (typeof v === 'object' && Object.keys(v).length === 0)
      : false;
  });
  if (linkBroken.length > 0) {
    push('warn', 'Dossiers',
      `${linkBroken.length} dossier(s) avec lien Bénéficiaire NocoDB non résolu (champ "beneficiaire" vide)`,
      linkBroken.map((r) => `uuid=${r.uuid_source || `Id=${r.Id}`}`));
  }
}

// 4.3 Logements (pas de table housings — c'est `logements`)
{
  const rows = data.logements;
  const noUuid = rows.filter((r) => !stringValue(r.uuid_source));
  if (noUuid.length > 0) {
    push('warn', 'Logements', `${noUuid.length} logement(s) sans uuid_source`,
      noUuid.map((r) => `Id=${r.Id}`));
  }

  // Bénéficiaire de logement non lié.
  const linkBroken = rows.filter((r) => !r.beneficiaire || (typeof r.beneficiaire === 'object' && !Object.keys(r.beneficiaire).length));
  if (linkBroken.length > 0) {
    push('warn', 'Logements',
      `${linkBroken.length} logement(s) avec lien Bénéficiaire NocoDB non résolu`,
      linkBroken.map((r) => `uuid=${r.uuid_source || `Id=${r.Id}`}`));
  }
}

// 4.4 Observations / Diagnostic / Mesures : orphelin si dossier_id n'est pas dans dossiersByUuid
for (const tableName of ['observations', 'diagnostic_sanitaires', 'mesures_anthropometriques']) {
  const rows = data[tableName] || [];
  const orphans = rows.filter((r) => {
    const did = stringValue(r.dossier_id);
    return did && !dossiersByUuid.has(did);
  });
  if (orphans.length > 0) {
    push('warn', tableName,
      `${orphans.length} ligne(s) avec dossier_id pointant vers un dossier inexistant`,
      orphans.slice(0, 20).map((r) => `Id=${r.Id} dossier_id=${r.dossier_id}`));
  }
  const noDossierId = rows.filter((r) => !stringValue(r.dossier_id));
  if (noDossierId.length > 0) {
    push('warn', tableName,
      `${noDossierId.length} ligne(s) sans dossier_id`,
      noDossierId.map((r) => `Id=${r.Id}`));
  }
}

// 4.5 mobile_documents : sans bénéficiaire rattaché
{
  const rows = data.mobile_documents;
  const noBenef = rows.filter((r) => !stringValue(r.beneficiaire_nom_complet) && !stringValue(r.beneficiaire_id));
  if (noBenef.length > 0) {
    push('info', 'mobile_documents',
      `${noBenef.length} document(s) sans bénéficiaire rattaché (uploads de test ?)`,
      noBenef.slice(0, 30).map((r) => `${stringValue(r.nom_fichier) || stringValue(r.titre)} (uuid=${r.uuid_source})`));
  }

  // Doublons par nom_fichier + beneficiaire_id (uploads multiples).
  const dupGroups = new Map();
  for (const r of rows) {
    const fn = stringValue(r.nom_fichier);
    if (!fn) continue;
    const k = `${stringValue(r.beneficiaire_id) || '_no_benef'}|${fn.toLowerCase()}`;
    (dupGroups.get(k) || dupGroups.set(k, []).get(k)).push(r);
  }
  const dups = [...dupGroups.values()].filter((g) => g.length > 1);
  if (dups.length > 0) {
    push('info', 'mobile_documents',
      `${dups.length} groupe(s) de documents avec même nom_fichier pour un même bénéficiaire`,
      dups.map((g) => {
        const f = g[0];
        return `"${stringValue(f.nom_fichier)}" pour ${stringValue(f.beneficiaire_nom_complet) || '?'} → ${g.length} copies`;
      }));
  }
}

// 4.6 mobile_document_chunks : orphelins (chunks dont document_uuid_source n'existe plus)
{
  const orphans = data.mobile_document_chunks.filter((r) => {
    const u = stringValue(r.document_uuid_source);
    return !u || !validDocumentUuids.has(u);
  });
  if (orphans.length > 0) {
    push('warn', 'mobile_document_chunks',
      `${orphans.length} chunk(s) orphelin(s) (document_uuid_source absent ou inexistant)`,
      orphans.slice(0, 20).map((r) => `Id=${r.Id} doc_uuid=${r.document_uuid_source || '(empty)'}`));
  }
}

// 4.7 mobile_note_pages : orphelins par dossier
{
  const orphans = data.mobile_note_pages.filter((r) => {
    const d = stringValue(r.dossier_id);
    return d && !dossiersByUuid.has(d);
  });
  if (orphans.length > 0) {
    push('info', 'mobile_note_pages',
      `${orphans.length} note(s) avec dossier_id pointant vers un dossier inexistant (peut-être normal pour notes globales)`,
      orphans.slice(0, 20).map((r) => `${r.tab_key || '?'} page=${r.page_number} dossier_id=${r.dossier_id}`));
  }
  const noDossier = data.mobile_note_pages.filter((r) => !stringValue(r.dossier_id));
  if (noDossier.length > 0) {
    push('info', 'mobile_note_pages',
      `${noDossier.length} note(s) sans dossier_id (notes patient-globales)`,
      []);
  }
}

// 4.8 mobile_visit_recommendations : sans dossier
{
  const rows = data.mobile_visit_recommendations;
  const noDossier = rows.filter((r) => !stringValue(r.dossier_id));
  if (noDossier.length > 0) {
    push('warn', 'mobile_visit_recommendations',
      `${noDossier.length} recommandation(s) sans dossier_id`,
      noDossier.slice(0, 20).map((r) => `Id=${r.Id} wiki=${r.wiki_title}`));
  }
  const orphans = rows.filter((r) => {
    const d = stringValue(r.dossier_id);
    return d && !dossiersByUuid.has(d);
  });
  if (orphans.length > 0) {
    push('warn', 'mobile_visit_recommendations',
      `${orphans.length} recommandation(s) avec dossier_id pointant vers un dossier inexistant`,
      orphans.slice(0, 20).map((r) => `Id=${r.Id} dossier_id=${r.dossier_id}`));
  }
}

// 5. Compteurs par bénéficiaire NocoDB (par Id).
const counters = new Map();
for (const b of data.beneficiaires) {
  counters.set(b.Id, {
    name: `${stringValue(b.prenom)} ${stringValue(b.nom)}`.trim() || `(Id ${b.Id})`,
    Id: b.Id,
    dossiers: Number(b.dossiers || 0),
    logements: Number(b.logements || 0),
    contextes: Number(b.contexte_de_vie || 0),
    documents: 0,
    notes: 0,
    recos: 0,
  });
}
// Compteur docs/notes/recos par UUID (legacy mapping).
const benefIdToNocodbId = new Map(); // beneficiaire_id (UUID) → beneficiaires.Id (numérique)
// On essaie de retrouver le mapping via mobile_documents (qui a beneficiaire_nom_complet) :
for (const m of data.mobile_documents) {
  const uuid = stringValue(m.beneficiaire_id);
  const fullName = stringValue(m.beneficiaire_nom_complet);
  if (uuid && fullName) {
    const b = data.beneficiaires.find(
      (b) => `${stringValue(b.prenom)} ${stringValue(b.nom)}`.trim().toLowerCase() === fullName.toLowerCase(),
    );
    if (b) benefIdToNocodbId.set(uuid, b.Id);
  }
}
for (const m of data.mobile_documents) {
  const id = benefIdToNocodbId.get(stringValue(m.beneficiaire_id));
  if (id && counters.has(id)) counters.get(id).documents += 1;
}
for (const n of data.mobile_note_pages) {
  const id = benefIdToNocodbId.get(stringValue(n.beneficiaire_id));
  if (id && counters.has(id)) counters.get(id).notes += 1;
}
for (const r of data.mobile_visit_recommendations) {
  const id = benefIdToNocodbId.get(stringValue(r.beneficiaire_id));
  if (id && counters.has(id)) counters.get(id).recos += 1;
}

// 6. Rapport markdown.
const now = new Date();
const ts = now.toISOString().replace(/[:.]/g, '-');
const reportPath = path.resolve(__dirname, `../tmp/nocodb-checkup-${ts}.md`);
fs.mkdirSync(path.dirname(reportPath), { recursive: true });

const levelEmoji = { critical: '🔴', warn: '🟠', info: '🟡' };
const levelLabel = { critical: 'CRITIQUE', warn: 'ATTENTION', info: 'INFO' };

let md = '';
md += `# Checkup NocoDB — ${now.toISOString().slice(0, 16).replace('T', ' ')}\n\n`;
md += `Base : \`${BASE_ID}\` · ${tables.length} tables.\n\n`;

md += `## Inventaire complet\n\n`;
md += `| Table | Records |\n|---|---:|\n`;
const sortedCounts = counts.sort((a, b) => b.count - a.count);
for (const c of sortedCounts) md += `| \`${c.title}\` | ${c.count >= 0 ? c.count : '?'} |\n`;
md += '\n';

const grouped = { critical: [], warn: [], info: [] };
for (const f of findings) grouped[f.level].push(f);

md += `## Synthèse\n\n`;
md += `**${findings.length} constat(s)** : ${grouped.critical.length} critique(s), ${grouped.warn.length} attention, ${grouped.info.length} info.\n\n`;
if (findings.length === 0) md += `✅ Aucune anomalie détectée — la base est saine.\n\n`;

for (const lvl of ['critical', 'warn', 'info']) {
  if (grouped[lvl].length === 0) continue;
  md += `## ${levelEmoji[lvl]} ${levelLabel[lvl]}\n\n`;
  for (const f of grouped[lvl]) {
    md += `### ${f.area} — ${f.msg}\n\n`;
    if (f.details && f.details.length) {
      const visible = f.details.slice(0, 30);
      for (const d of visible) md += `- ${d}\n`;
      if (f.details.length > 30) md += `- _(+${f.details.length - 30} autres non affichés)_\n`;
      md += '\n';
    }
  }
}

md += `## Volumétrie par bénéficiaire\n\n`;
md += `| Bénéficiaire | Dossiers | Logements | Contextes | Docs | Notes | Recos |\n`;
md += `|---|---:|---:|---:|---:|---:|---:|\n`;
for (const c of [...counters.values()].sort((a, b) => b.dossiers - a.dossiers || b.documents - a.documents)) {
  md += `| ${c.name} | ${c.dossiers} | ${c.logements} | ${c.contextes} | ${c.documents} | ${c.notes} | ${c.recos} |\n`;
}
md += '\n';

fs.writeFileSync(reportPath, md);
console.log(`📝 Rapport : ${reportPath}\n`);
console.log('━'.repeat(50));
console.log(`Critiques : ${grouped.critical.length}`);
console.log(`Attention : ${grouped.warn.length}`);
console.log(`Info      : ${grouped.info.length}`);
console.log('━'.repeat(50));
