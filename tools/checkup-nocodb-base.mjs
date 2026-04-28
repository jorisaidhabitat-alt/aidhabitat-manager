// Checkup global de la base NocoDB :
//
//   1. Inventaire des tables (titre + count records)
//   2. Orphelins (records pointant vers un parent inexistant)
//   3. Doublons probables (mêmes clés naturelles sur plusieurs lignes)
//   4. Champs critiques vides (Nom, Prénom, etc.)
//   5. Lignes zombies (pending_delete=1, _archived=1, soft-deleted)
//   6. Cohérence dossier ↔ patient ↔ housing
//   7. Compteurs par patient (docs, notes, dossiers)
//
// Usage :
//   node tools/checkup-nocodb-base.mjs
//
// Sortie :
//   tmp/nocodb-checkup-<timestamp>.md   (rapport lisible)
//
// Lecture seule — aucune modification de la base.

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

if (!API_URL || !API_TOKEN || !BASE_ID) {
  console.error('NOCODB_API_URL / NOCODB_API_TOKEN / NOCODB_BASE_ID requis (.env.local)');
  process.exit(1);
}

const nocoFetch = async (url) => {
  const res = await fetch(url, {
    headers: { 'xc-token': API_TOKEN, 'Content-Type': 'application/json' },
  });
  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText} on ${url} :: ${await res.text().catch(() => '')}`);
  }
  return res.json();
};

const queryAllRecords = async (tableId, fields = []) => {
  const all = [];
  let offset = 0;
  const pageSize = 1000;
  while (true) {
    const fieldsParam = fields.length ? `&fields=${encodeURIComponent(fields.join(','))}` : '';
    const url = `${API_URL}/api/v2/tables/${tableId}/records?limit=${pageSize}&offset=${offset}${fieldsParam}`;
    const r = await nocoFetch(url);
    const list = r.list || [];
    all.push(...list);
    if (list.length < pageSize) break;
    offset += pageSize;
  }
  return all;
};

const stringValue = (v) => (v == null ? '' : String(v).trim());
const truthy = (v) => v === true || v === 1 || v === '1' || v === 'true';

// -------------------------------------------------------------------
// 1. Inventaire des tables
// -------------------------------------------------------------------
console.log('📋 Inventaire des tables…');
const tablesResp = await nocoFetch(`${API_URL}/api/v2/meta/bases/${BASE_ID}/tables`);
const tables = (tablesResp.list || tablesResp).filter((t) => t && t.id && t.title);
console.log(`   ${tables.length} tables détectées.\n`);

const tableByName = (n) =>
  tables.find((t) => String(t.title).toLowerCase() === String(n).toLowerCase());

// -------------------------------------------------------------------
// 2. Lecture parallèle des tables clés (champs minimaux)
// -------------------------------------------------------------------
const KEY_TABLES = {
  beneficiaires: [
    'Id', 'uuid_source', 'nom', 'prenom', 'birth_date',
    'phone', 'email', 'address', 'zip_code', 'city',
    'pending_delete', 'UpdatedAt', 'updated_at',
  ],
  dossiers: [
    'Id', 'uuid_source', 'beneficiaire_id', 'commentaire',
    'pending_delete', 'UpdatedAt', 'updated_at',
  ],
  housings: [
    'Id', 'uuid_source', 'dossier_id', 'beneficiaire_id',
    'pending_delete', 'UpdatedAt', 'updated_at',
  ],
  observations_synthese: [
    'Id', 'uuid_source', 'dossier_id',
    'pending_delete', 'UpdatedAt', 'updated_at',
  ],
  diagnostic_sanitaires: [
    'Id', 'uuid_source', 'dossier_id',
    'pending_delete', 'UpdatedAt', 'updated_at',
  ],
  visit_recommendations: [
    'Id', 'uuid_source', 'dossier_id',
    'pending_delete', 'UpdatedAt', 'updated_at',
  ],
  mobile_documents: [
    'Id', 'uuid_source', 'beneficiaire_id', 'dossier_id',
    'beneficiaire_nom_complet', 'titre', 'nom_fichier', 'mime_type',
    'updated_at',
  ],
  mobile_document_chunks: [
    'Id', 'document_uuid_source', 'chunk_index', 'updated_at',
  ],
  mobile_note_pages: [
    'Id', 'uuid_source', 'patient_id', 'tab_key', 'page_number',
    'updated_at',
  ],
};

console.log('📥 Lecture des tables clés…');
const data = {};
for (const [tableName, fields] of Object.entries(KEY_TABLES)) {
  const t = tableByName(tableName);
  if (!t) {
    console.log(`   - ${tableName} : table introuvable, skip`);
    data[tableName] = [];
    continue;
  }
  // On filtre les champs demandés à ceux qui existent vraiment côté
  // schéma (sinon NocoDB renvoie 422). Lecture rapide du schema.
  let availableFields = null;
  try {
    const schema = await nocoFetch(`${API_URL}/api/v2/meta/tables/${t.id}`);
    availableFields = new Set((schema.columns || []).map((c) => c.title));
  } catch {
    availableFields = null;
  }
  const usedFields = availableFields
    ? fields.filter((f) => availableFields.has(f))
    : fields;
  data[tableName] = await queryAllRecords(t.id, usedFields);
  console.log(`   - ${tableName} : ${data[tableName].length} records`);
}
console.log();

// Index des UUIDs valides par table.
const uuidsOf = (rows) =>
  new Set(rows.map((r) => stringValue(r.uuid_source)).filter(Boolean));
const validBeneficiaires = uuidsOf(data.beneficiaires);
const validDossiers = uuidsOf(data.dossiers);
const validDocuments = uuidsOf(data.mobile_documents);

const findings = [];
const push = (level, area, msg, details = []) => {
  findings.push({ level, area, msg, details });
};

// -------------------------------------------------------------------
// 3. Bénéficiaires : doublons, champs requis vides, pending_delete
// -------------------------------------------------------------------
{
  const rows = data.beneficiaires;
  const missingName = rows.filter(
    (r) => !stringValue(r.nom) && !stringValue(r.prenom),
  );
  if (missingName.length > 0) {
    push(
      'critical',
      'Bénéficiaires',
      `${missingName.length} bénéficiaire(s) SANS nom NI prénom`,
      missingName.map((r) => `uuid=${r.uuid_source} id=${r.Id}`),
    );
  }

  const missingBirthDate = rows.filter(
    (r) => stringValue(r.nom) && !stringValue(r.birth_date),
  );
  if (missingBirthDate.length > 0) {
    push(
      'warn',
      'Bénéficiaires',
      `${missingBirthDate.length} bénéficiaire(s) sans date de naissance`,
      missingBirthDate
        .slice(0, 20)
        .map((r) => `${stringValue(r.prenom)} ${stringValue(r.nom)} (uuid=${r.uuid_source})`),
    );
  }

  const missingAddr = rows.filter(
    (r) => stringValue(r.nom) && !stringValue(r.address) && !stringValue(r.city),
  );
  if (missingAddr.length > 0) {
    push(
      'info',
      'Bénéficiaires',
      `${missingAddr.length} bénéficiaire(s) sans adresse ni ville`,
      missingAddr
        .slice(0, 20)
        .map((r) => `${stringValue(r.prenom)} ${stringValue(r.nom)} (uuid=${r.uuid_source})`),
    );
  }

  // Doublons : même nom + prénom + birth_date.
  const dupKey = (r) =>
    `${stringValue(r.nom).toUpperCase()}|${stringValue(r.prenom).toUpperCase()}|${stringValue(r.birth_date)}`;
  const groups = new Map();
  for (const r of rows) {
    if (!stringValue(r.nom) && !stringValue(r.prenom)) continue;
    const k = dupKey(r);
    const arr = groups.get(k) || [];
    arr.push(r);
    groups.set(k, arr);
  }
  const dups = [...groups.values()].filter((g) => g.length > 1);
  if (dups.length > 0) {
    push(
      'warn',
      'Bénéficiaires',
      `${dups.length} groupe(s) de doublons (même nom+prénom+date de naissance)`,
      dups.map((g) => {
        const first = g[0];
        return `${stringValue(first.prenom)} ${stringValue(first.nom)} ` +
          `(${stringValue(first.birth_date) || 'sans date'}) — ${g.length} entrées : ${g.map((r) => r.uuid_source).join(', ')}`;
      }),
    );
  }

  const pending = rows.filter((r) => truthy(r.pending_delete));
  if (pending.length > 0) {
    push(
      'warn',
      'Bénéficiaires',
      `${pending.length} bénéficiaire(s) avec pending_delete=1 (zombies)`,
      pending
        .slice(0, 20)
        .map((r) => `${stringValue(r.prenom)} ${stringValue(r.nom)} (uuid=${r.uuid_source})`),
    );
  }
}

// -------------------------------------------------------------------
// 4. Dossiers : orphelins, pending_delete
// -------------------------------------------------------------------
{
  const rows = data.dossiers;
  const orphans = rows.filter((r) => {
    const bid = stringValue(r.beneficiaire_id);
    return !bid || !validBeneficiaires.has(bid);
  });
  if (orphans.length > 0) {
    push(
      'critical',
      'Dossiers',
      `${orphans.length} dossier(s) orphelin(s) (beneficiaire_id manquant ou inexistant)`,
      orphans
        .slice(0, 20)
        .map((r) => `uuid=${r.uuid_source} beneficiaire_id="${r.beneficiaire_id || ''}"`),
    );
  }

  const pending = rows.filter((r) => truthy(r.pending_delete));
  if (pending.length > 0) {
    push(
      'warn',
      'Dossiers',
      `${pending.length} dossier(s) avec pending_delete=1`,
      pending.slice(0, 20).map((r) => `uuid=${r.uuid_source}`),
    );
  }

  // Beneficiaires sans dossier (info, peut être normal pendant onboarding).
  const beneficiairesWithDossier = new Set(
    rows.map((r) => stringValue(r.beneficiaire_id)).filter(Boolean),
  );
  const benefSansDossier = data.beneficiaires.filter(
    (b) => stringValue(b.uuid_source) &&
      !beneficiairesWithDossier.has(stringValue(b.uuid_source)),
  );
  if (benefSansDossier.length > 0) {
    push(
      'info',
      'Dossiers',
      `${benefSansDossier.length} bénéficiaire(s) sans aucun dossier rattaché`,
      benefSansDossier
        .slice(0, 20)
        .map((b) => `${stringValue(b.prenom)} ${stringValue(b.nom)} (uuid=${b.uuid_source})`),
    );
  }
}

// -------------------------------------------------------------------
// 5. Housings : orphelins
// -------------------------------------------------------------------
{
  const rows = data.housings;
  const orphans = rows.filter((r) => {
    const did = stringValue(r.dossier_id);
    return !did || !validDossiers.has(did);
  });
  if (orphans.length > 0) {
    push(
      'critical',
      'Housings',
      `${orphans.length} housing(s) orphelin(s) (dossier_id absent ou inexistant)`,
      orphans
        .slice(0, 20)
        .map((r) => `uuid=${r.uuid_source} dossier_id="${r.dossier_id || ''}"`),
    );
  }

  // Dossiers sans housing.
  const housingDossiers = new Set(
    rows.map((r) => stringValue(r.dossier_id)).filter(Boolean),
  );
  const dossiersSansHousing = data.dossiers.filter(
    (d) => stringValue(d.uuid_source) &&
      !housingDossiers.has(stringValue(d.uuid_source)),
  );
  if (dossiersSansHousing.length > 0) {
    push(
      'warn',
      'Housings',
      `${dossiersSansHousing.length} dossier(s) sans housing rattaché`,
      dossiersSansHousing.slice(0, 20).map((d) => `uuid=${d.uuid_source}`),
    );
  }
}

// -------------------------------------------------------------------
// 6. Observations / Diagnostic / Recommandations : orphelins
// -------------------------------------------------------------------
for (const t of ['observations_synthese', 'diagnostic_sanitaires', 'visit_recommendations']) {
  const rows = data[t] || [];
  const orphans = rows.filter((r) => {
    const did = stringValue(r.dossier_id);
    return !did || !validDossiers.has(did);
  });
  if (orphans.length > 0) {
    push(
      'critical',
      t,
      `${orphans.length} ligne(s) orpheline(s) (dossier_id manquant)`,
      orphans
        .slice(0, 20)
        .map((r) => `uuid=${r.uuid_source} dossier_id="${r.dossier_id || ''}"`),
    );
  }
}

// -------------------------------------------------------------------
// 7. mobile_documents : metadata patient incomplète, doublons
// -------------------------------------------------------------------
{
  const rows = data.mobile_documents;
  const missingPatient = rows.filter(
    (r) => !stringValue(r.beneficiaire_id) && !stringValue(r.beneficiaire_nom_complet),
  );
  if (missingPatient.length > 0) {
    push(
      'warn',
      'mobile_documents',
      `${missingPatient.length} document(s) sans bénéficiaire rattaché`,
      missingPatient
        .slice(0, 20)
        .map((r) => `${stringValue(r.nom_fichier) || stringValue(r.titre) || '?'} (uuid=${r.uuid_source})`),
    );
  }

  // Orphelins par dossier (si dossier_id renseigné mais ne pointe nulle part).
  const orphansByDossier = rows.filter(
    (r) => stringValue(r.dossier_id) && !validDossiers.has(stringValue(r.dossier_id)),
  );
  if (orphansByDossier.length > 0) {
    push(
      'warn',
      'mobile_documents',
      `${orphansByDossier.length} document(s) avec dossier_id pointant vers un dossier inexistant`,
      orphansByDossier
        .slice(0, 20)
        .map((r) => `${stringValue(r.nom_fichier)} (dossier_id=${r.dossier_id})`),
    );
  }

  // Doublons par nom_fichier + beneficiaire_id (uploads multiples).
  const dupKey = (r) =>
    `${stringValue(r.beneficiaire_id)}|${stringValue(r.nom_fichier).toLowerCase()}`;
  const groups = new Map();
  for (const r of rows) {
    if (!stringValue(r.nom_fichier)) continue;
    const k = dupKey(r);
    const arr = groups.get(k) || [];
    arr.push(r);
    groups.set(k, arr);
  }
  const dups = [...groups.values()].filter((g) => g.length > 1);
  if (dups.length > 0) {
    push(
      'info',
      'mobile_documents',
      `${dups.length} groupe(s) de documents avec même nom_fichier pour un même bénéficiaire`,
      dups.slice(0, 30).map((g) => {
        const first = g[0];
        return `${stringValue(first.nom_fichier)} pour ${stringValue(first.beneficiaire_nom_complet) || '?'} : ${g.length} copies`;
      }),
    );
  }
}

// -------------------------------------------------------------------
// 8. mobile_document_chunks : orphelins déjà purgés, on revérifie
// -------------------------------------------------------------------
{
  const rows = data.mobile_document_chunks;
  const orphans = rows.filter((r) => {
    const u = stringValue(r.document_uuid_source);
    return !u || !validDocuments.has(u);
  });
  if (orphans.length > 0) {
    push(
      'warn',
      'mobile_document_chunks',
      `${orphans.length} chunk(s) orphelin(s) (document_uuid_source absent ou inexistant)`,
      orphans
        .slice(0, 20)
        .map((r) => `Id=${r.Id} document_uuid_source="${r.document_uuid_source || ''}"`),
    );
  }
}

// -------------------------------------------------------------------
// 9. mobile_note_pages : orphelins par patient_id
// -------------------------------------------------------------------
{
  const rows = data.mobile_note_pages;
  const orphans = rows.filter((r) => {
    const p = stringValue(r.patient_id);
    return !p || !validBeneficiaires.has(p);
  });
  if (orphans.length > 0) {
    push(
      'warn',
      'mobile_note_pages',
      `${orphans.length} note(s) avec patient_id manquant ou pointant vers un bénéficiaire inexistant`,
      orphans
        .slice(0, 20)
        .map((r) => `tab_key=${r.tab_key || '?'} page=${r.page_number ?? '?'} (uuid=${r.uuid_source})`),
    );
  }
}

// -------------------------------------------------------------------
// 10. Compteurs par bénéficiaire
// -------------------------------------------------------------------
const counters = new Map();
for (const b of data.beneficiaires) {
  const u = stringValue(b.uuid_source);
  if (!u) continue;
  counters.set(u, {
    name: `${stringValue(b.prenom)} ${stringValue(b.nom)}`.trim(),
    uuid: u,
    dossiers: 0,
    documents: 0,
    notes: 0,
  });
}
for (const d of data.dossiers) {
  const c = counters.get(stringValue(d.beneficiaire_id));
  if (c) c.dossiers += 1;
}
for (const m of data.mobile_documents) {
  const c = counters.get(stringValue(m.beneficiaire_id));
  if (c) c.documents += 1;
}
for (const n of data.mobile_note_pages) {
  const c = counters.get(stringValue(n.patient_id));
  if (c) c.notes += 1;
}

// -------------------------------------------------------------------
// 11. Génération du rapport markdown
// -------------------------------------------------------------------
const now = new Date();
const ts = now.toISOString().replace(/[:.]/g, '-');
const reportDir = path.resolve(__dirname, '../tmp');
fs.mkdirSync(reportDir, { recursive: true });
const reportPath = path.resolve(reportDir, `nocodb-checkup-${ts}.md`);

const levelEmoji = { critical: '🔴', warn: '🟠', info: '🟡' };
const levelLabel = { critical: 'CRITIQUE', warn: 'ATTENTION', info: 'INFO' };

let md = '';
md += `# Checkup NocoDB — ${now.toISOString().split('T')[0]} ${now.toISOString().split('T')[1].slice(0, 5)}\n\n`;
md += `Base : \`${BASE_ID}\` · ${tables.length} tables.\n\n`;

md += `## Inventaire\n\n`;
md += `| Table | Records |\n|---|---|\n`;
for (const [name, rows] of Object.entries(data)) {
  md += `| \`${name}\` | ${rows.length} |\n`;
}
md += '\n';

const grouped = { critical: [], warn: [], info: [] };
for (const f of findings) grouped[f.level].push(f);

const totalIssues = findings.length;
md += `## Synthèse\n\n`;
md += `**${totalIssues} constat(s)** : ${grouped.critical.length} critique(s), ${grouped.warn.length} attention, ${grouped.info.length} info.\n\n`;

if (totalIssues === 0) {
  md += `✅ Base saine — aucune anomalie détectée.\n\n`;
}

for (const level of ['critical', 'warn', 'info']) {
  if (grouped[level].length === 0) continue;
  md += `## ${levelEmoji[level]} ${levelLabel[level]}\n\n`;
  for (const f of grouped[level]) {
    md += `### ${f.area} — ${f.msg}\n\n`;
    if (f.details && f.details.length) {
      const visible = f.details.slice(0, 30);
      for (const d of visible) md += `- ${d}\n`;
      if (f.details.length > 30) md += `- _(+${f.details.length - 30} non affichés)_\n`;
      md += '\n';
    }
  }
}

// Top 10 bénéficiaires en volume.
const topByDossiers = [...counters.values()]
  .sort((a, b) => b.dossiers - a.dossiers || b.documents - a.documents)
  .slice(0, 10);
md += `## Top 10 bénéficiaires (volume)\n\n`;
md += `| Bénéficiaire | Dossiers | Documents | Notes |\n|---|---:|---:|---:|\n`;
for (const c of topByDossiers) {
  md += `| ${c.name || '(sans nom)'} | ${c.dossiers} | ${c.documents} | ${c.notes} |\n`;
}
md += '\n';

fs.writeFileSync(reportPath, md);
console.log(`📝 Rapport écrit : ${reportPath}\n`);

// Résumé console.
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
console.log(`Tables scannées : ${Object.keys(data).length}`);
console.log(`Critiques : ${grouped.critical.length}`);
console.log(`Attention : ${grouped.warn.length}`);
console.log(`Info      : ${grouped.info.length}`);
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
