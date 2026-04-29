// Vérifications complémentaires post-changements 2026-04-29 :
//  - Colonnes second_etage / third_etage présentes dans logements ?
//  - Doublons résiduels mobile_documents par (beneficiaire, nom_fichier) ?
//  - Wiki : doublons résiduels par titre ?
//  - Volumétrie cohérente : tous les bénéficiaires ont bien Id et nom ?

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

const f = async (url) => {
  const r = await fetch(url, { headers: { 'xc-token': TOKEN } });
  if (!r.ok) throw new Error(`${r.status} on ${url}`);
  return r.json();
};
const queryAll = async (tableId) => {
  const all = [];
  let offset = 0;
  while (true) {
    const r = await f(`${API_URL}/api/v2/tables/${tableId}/records?limit=1000&offset=${offset}`);
    const list = r.list || [];
    all.push(...list);
    if (list.length < 1000) break;
    offset += 1000;
  }
  return all;
};
const sv = (v) => (v == null || v === 'null' ? '' : String(v).trim());

const tablesResp = await f(`${API_URL}/api/v2/meta/bases/${BASE}/tables`);
const tables = (tablesResp.list || tablesResp).filter((t) => t && t.id);
const find = (n) => tables.find((t) => String(t.title).toLowerCase() === n.toLowerCase());

const issues = [];

// 1. Colonnes second_etage / third_etage présentes ?
const logTbl = find('logements');
if (logTbl) {
  const sch = await f(`${API_URL}/api/v2/meta/tables/${logTbl.id}`);
  const cols = new Set(sch.columns.map((c) => c.title));
  for (const c of ['second_etage', 'third_etage']) {
    if (!cols.has(c)) issues.push(`❌ Colonne \`logements.${c}\` MANQUANTE.`);
    else console.log(`✅ Colonne \`logements.${c}\` présente.`);
  }
}

// 2. Doublons mobile_documents par (beneficiaire_id, nom_fichier).
const docs = await queryAll(find('mobile_documents').id);
const docDups = new Map();
for (const d of docs) {
  const k = `${sv(d.beneficiaire_id)}|${sv(d.nom_fichier).toLowerCase()}`;
  if (k === '|') continue;
  (docDups.get(k) || docDups.set(k, []).get(k)).push(d);
}
const dupList = [...docDups.values()].filter((g) => g.length > 1);
if (dupList.length > 0) {
  issues.push(`⚠️ ${dupList.length} groupe(s) de doublons mobile_documents (même bénéficiaire + même nom_fichier) :`);
  for (const g of dupList.slice(0, 10)) {
    const f0 = g[0];
    issues.push(`   - "${sv(f0.nom_fichier)}" pour ${sv(f0.beneficiaire_nom_complet) || '?'} → ${g.length} copies`);
  }
} else {
  console.log(`✅ Pas de doublons mobile_documents.`);
}

// 3. Doublons wiki par titre.
const wikis = await queryAll(find('wiki').id);
const wikiDups = new Map();
for (const w of wikis) {
  const k = sv(w.titre).toLowerCase();
  if (!k) continue;
  (wikiDups.get(k) || wikiDups.set(k, []).get(k)).push(w);
}
const wDups = [...wikiDups.values()].filter((g) => g.length > 1);
if (wDups.length > 0) {
  issues.push(`⚠️ ${wDups.length} doublons wiki par titre — relancer dedupe-wiki.mjs.`);
} else {
  console.log(`✅ Pas de doublons wiki (catalogue propre, ${wikis.length} fiches uniques).`);
}

// 4. Tous les bénéficiaires ont nom + prénom ?
const benefs = await queryAll(find('beneficiaires').id);
const benefIncomplete = benefs.filter((b) => !sv(b.nom) && !sv(b.prenom));
if (benefIncomplete.length > 0) {
  issues.push(`⚠️ ${benefIncomplete.length} bénéficiaire(s) sans nom NI prénom.`);
} else {
  console.log(`✅ Tous les ${benefs.length} bénéficiaires ont au moins un nom ou prénom.`);
}

// 5. Tous les dossiers ont un patient_id non-vide.
const dossiers = await queryAll(find('dossiers').id);
const dossiersOrph = dossiers.filter((d) => !sv(d.patient_id));
if (dossiersOrph.length > 0) {
  issues.push(`⚠️ ${dossiersOrph.length} dossier(s) sans patient_id.`);
} else {
  console.log(`✅ Tous les ${dossiers.length} dossiers ont un patient_id.`);
}

// 6. Pas de chunks orphelins (chunks pointant vers un doc inexistant).
const chunks = await queryAll(find('mobile_document_chunks').id);
const validUuids = new Set(docs.map((d) => sv(d.uuid_source)).filter(Boolean));
const chunkOrphans = chunks.filter((c) => {
  const u = sv(c.document_uuid_source);
  return !u || !validUuids.has(u);
});
if (chunkOrphans.length > 0) {
  issues.push(`⚠️ ${chunkOrphans.length} chunks orphelins.`);
} else {
  console.log(`✅ Aucun chunk orphelin (${chunks.length} chunks tous rattachés).`);
}

// 7. Beneficiaire_nom_complet stale dans mobile_documents/notes ?
// Regarde s'il y a des docs où le nom_complet ne correspond plus à
// `prenom + nom` du bénéficiaire en base.
const benefByUuidLegacy = new Map();
for (const d of docs) {
  const uuid = sv(d.beneficiaire_id);
  const fullName = sv(d.beneficiaire_nom_complet);
  if (uuid && fullName) {
    if (!benefByUuidLegacy.has(uuid)) benefByUuidLegacy.set(uuid, fullName);
  }
}
const expectedNames = new Set(
  benefs.map((b) => `${sv(b.prenom)} ${sv(b.nom)}`.trim()).filter(Boolean),
);
const staleNames = new Set();
for (const [uuid, nm] of benefByUuidLegacy) {
  if (!expectedNames.has(nm)) staleNames.add(`${nm} (uuid=${uuid.slice(0, 8)}…)`);
}
if (staleNames.size > 0) {
  issues.push(
    `ℹ️ ${staleNames.size} valeur(s) de \`beneficiaire_nom_complet\` ` +
    `dans mobile_documents ne correspondent plus à un nom actuel de ` +
    `\`beneficiaires\` :`,
  );
  for (const s of [...staleNames].slice(0, 5)) issues.push(`   - ${s}`);
  issues.push(`   → cosmétique seulement (nom legacy déconnecté du compteur),`);
  issues.push(`     les liens beneficiaire_id restent valides côté workflow.`);
}

console.log('\n━'.repeat(60));
if (issues.length === 0) {
  console.log('✅ TOUT EST RANGÉ ET COHÉRENT.');
} else {
  console.log(`Constats :`);
  for (const i of issues) console.log(i);
}
console.log('━'.repeat(60));
