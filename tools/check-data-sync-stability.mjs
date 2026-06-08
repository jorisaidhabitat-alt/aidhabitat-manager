#!/usr/bin/env node
// Audit read-only de stabilité data/sync App'Ergo.
//
// Objectif : bloquer les risques prod évidents avant/après déploiement :
// API injoignable, erreurs 502/5xx, schéma NocoDB critique cassé,
// colonnes/relation métier absentes, latences anormales, backup non vérifié.

import { access, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import dotenv from 'dotenv';
import { readAndVerifyBackup } from './nocodbBackupLib.mjs';

dotenv.config({ path: '.env.local', quiet: true });

const args = process.argv.slice(2);

if (args.includes('--help') || args.includes('-h')) {
  console.log(`Usage: npm run data:stability-check -- [options]

Options:
  --backup <file>           Vérifie aussi un backup NocoDB existant.
  --output-dir <dir>        Dossier du rapport (défaut: tmp/data-sync-stability).
  --app-url <url>           URL app prod (défaut: https://app.aidhabitat.fr).
  --api-url <url>           URL API prod (défaut: https://api.aidhabitat.fr).
  --base-id <id>            Base NocoDB à contrôler.
  --skip-live               Ignore les checks app/API.
  --warn-latency-ms <ms>    Seuil d'alerte latence (défaut: 3000).
  --fail-latency-ms <ms>    Seuil d'échec latence (défaut: 8000).
  --timeout-ms <ms>         Timeout HTTP (défaut: 15000).
`);
  process.exit(0);
}

const readArg = (name, fallback = '') => {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  return args[index + 1] || fallback;
};

const hasFlag = (name) => args.includes(name);
const VALUE_OPTIONS = new Set([
  '--backup',
  '--output-dir',
  '--app-url',
  '--api-url',
  '--base-id',
  '--nocodb-url',
  '--nocodb-token',
  '--timeout-ms',
  '--warn-latency-ms',
  '--fail-latency-ms',
  '--sample-limit',
]);
const positionals = [];
for (let index = 0; index < args.length; index += 1) {
  const arg = args[index];
  if (VALUE_OPTIONS.has(arg)) {
    index += 1;
    continue;
  }
  if (!arg.startsWith('--')) positionals.push(arg);
}

const positionalOutput = positionals[0] || '';
const outputDir = path.resolve(
  positionalOutput || readArg('--output-dir', 'tmp/data-sync-stability'),
);
const backupPath = readArg('--backup', '');
const timeoutMs = Number(readArg('--timeout-ms', process.env.DATA_STABILITY_TIMEOUT_MS || '15000'));
const warnLatencyMs = Number(readArg('--warn-latency-ms', process.env.DATA_STABILITY_WARN_LATENCY_MS || '3000'));
const failLatencyMs = Number(readArg('--fail-latency-ms', process.env.DATA_STABILITY_FAIL_LATENCY_MS || '8000'));
const sampleLimit = Math.min(1000, Math.max(25, Number(readArg('--sample-limit', process.env.DATA_STABILITY_SAMPLE_LIMIT || '500'))));
const skipLive = hasFlag('--skip-live');

const appUrl = readArg('--app-url', process.env.AIDHABITAT_APP_URL || 'https://app.aidhabitat.fr');
const apiUrl = readArg('--api-url', process.env.AIDHABITAT_API_URL || 'https://api.aidhabitat.fr');
const nocodbUrl = (readArg('--nocodb-url', process.env.NOCODB_API_URL || '')).replace(/\/+$/, '');
const nocodbToken = readArg('--nocodb-token', process.env.NOCODB_API_TOKEN || '');
const nocodbBaseId = readArg('--base-id', process.env.NOCODB_STABILITY_BASE_ID || process.env.NOCODB_BASE_ID || '');
const expectedProdBaseId = process.env.NOCODB_PROD_BASE_ID || 'pskgbjythubfzv9';

const failures = [];
const warnings = [];
const checks = [];

const CRITICAL_TABLES = [
  { key: 'beneficiaires', id: 'muvp56d5i9z2qbe', titles: ['Beneficiaires'] },
  { key: 'dossiers', id: 'mez74y7ndoej30p', titles: ['📁 dossiers', 'dossiers'] },
  { key: 'logements', id: 'mgdpvdrnzyy6n4k', titles: ['Logements'] },
  { key: 'observations', id: 'mbkuomk0aazes1c', titles: ['📝 observations', 'observations'] },
  { key: 'diagnostic_sanitaires', id: 'mdukulxcd18ae3o', titles: ['🚿 diagnostic_sanitaires', 'diagnostic_sanitaires'] },
  { key: 'mesures_anthropometriques', id: 'mbaj91z97utreco', titles: ['📏 mesures_anthropometriques', 'mesures_anthropometriques'] },
  { key: 'contexte_de_vie', id: 'mjyj2lz4wfs5pd5', titles: ['👨‍👩‍👧 contexte_de_vie', 'contexte_de_vie'] },
  { key: 'informations_administratives', id: 'mv2hgaqj3u5ittg', titles: ['📋 informations_administratives', 'informations_administratives'] },
  { key: 'communes', id: 'mtwhx481kcfn19h', titles: ['communes'] },
  { key: 'ergotherapeutes', id: 'mww8mr4ngp3nbxh', titles: ['👷🏻‍♀️ ergotherapeutes', 'ergotherapeutes'] },
  { key: 'etablissements', id: 'mw1ajdw6ictkdzf', titles: ['etablissements'] },
  { key: 'caisses_retraite', id: 'mxmsm320nnljdmm', titles: ['caisses_de_retraite'] },
  { key: 'caisses_retraite_complementaires', id: 'm067j5k5a03beog', titles: ['caisses_de_retraite_complementaires'] },
  { key: 'mobile_documents', titles: ['mobile_documents'] },
  { key: 'mobile_document_chunks', titles: ['mobile_document_chunks'] },
  { key: 'mobile_note_pages', titles: ['mobile_note_pages'] },
  { key: 'mobile_visit_photos', id: 'mfeu4lijbge4opz', titles: ['mobile_visit_photos'] },
  { key: 'mobile_visit_recommendations', titles: ['mobile_visit_recommendations'] },
];

const COLUMN_CHECKS = {
  beneficiaires: {
    required: [
      'prenom',
      'nom',
      'occupants_json',
      'adresse_logement',
      'communes_id',
      'commune',
      'code_postal',
      'date_visite',
      'date_naissance_monsieur',
      'date_naissance_madame',
      'caisses_de_retraite_id',
      'caisses_de_retraite_complementaires_id',
    ],
    typedWarnings: {
      communes_id: ['ForeignKey', 'LinkToAnotherRecord', 'Number'],
      commune: ['LinkToAnotherRecord', 'Lookup', 'SingleLineText'],
      code_postal: ['Lookup', 'SingleLineText', 'Number'],
    },
  },
  dossiers: {
    required: [
      'uuid_source',
      'patient_id',
      'beneficiaires_id',
      'status',
      'ergo_id',
      'visit_date',
    ],
    typedWarnings: {
      beneficiaires_id: ['ForeignKey', 'LinkToAnotherRecord', 'Number'],
    },
  },
  logements: {
    required: [
      'uuid_source',
      'beneficiaire_id',
      'beneficiaires_id',
      'type_de_logement',
      'annee_construction',
      'nombre_niveaux',
    ],
  },
  mobile_documents: {
    required: [
      'uuid_source',
      'beneficiaire_id',
      'dossier_id',
      'client_document_id',
      'titre',
      'nom_fichier',
      'mime_type',
      'contenu_base64',
    ],
  },
  mobile_document_chunks: {
    required: [
      'document_uuid_source',
      'chunk_index',
      'chunk_base64',
    ],
  },
  mobile_note_pages: {
    required: [
      'beneficiaire_id',
      'beneficiaire_nom',
      'dossier_id',
      'tab_key',
      'sub_tab_key',
      'page_number',
      'drawing_json',
      'preview_data_url',
    ],
  },
  mobile_visit_photos: {
    required: [
      'uuid_source',
      'beneficiaire_id',
      'dossier_id',
      'client_document_id',
      'titre',
      'categorie',
      'contenu_base64',
      'preview_data_url',
    ],
  },
  mobile_visit_recommendations: {
    required: [
      'uuid_source',
      'beneficiaire_id',
      'dossier_id',
      'wiki_item_id',
      'wiki_title',
      'wiki_image_url',
      'note',
    ],
  },
};

const COUNT_TABLE_KEYS = [
  'beneficiaires',
  'dossiers',
  'logements',
  'contexte_de_vie',
  'informations_administratives',
  'diagnostic_sanitaires',
  'mesures_anthropometriques',
  'mobile_documents',
  'mobile_document_chunks',
  'mobile_note_pages',
  'mobile_visit_photos',
  'mobile_visit_recommendations',
  'communes',
];

const mark = (name, payload = {}) => {
  checks.push({ name, ok: true, ...payload });
};

const warn = (message, payload = {}) => {
  warnings.push({ message, ...payload });
};

const fail = (message, payload = {}) => {
  failures.push({ message, ...payload });
};

const normalizeTitle = (value) => String(value || '').trim().toLowerCase();

const recordValue = (record, key) => {
  const value = record?.[key] ?? record?.fields?.[key];
  return value == null ? '' : String(value).trim();
};

async function fileExists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function fetchTimed(url, init = {}) {
  const controller = new AbortController();
  const startedAt = Date.now();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      redirect: 'follow',
      ...init,
      signal: controller.signal,
    });
    return { response, durationMs: Date.now() - startedAt };
  } finally {
    clearTimeout(timer);
  }
}

async function fetchJson(url, init = {}) {
  let lastError;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      const result = await fetchTimed(url, {
        ...init,
        headers: {
          Accept: 'application/json',
          'Content-Type': 'application/json',
          ...(init.headers || {}),
        },
      });
      const { response, durationMs } = result;
      const text = await response.text();
      let json = null;
      try {
        json = text ? JSON.parse(text) : null;
      } catch {
        json = null;
      }
      if (!response.ok) {
        const error = new Error(`HTTP ${response.status} ${response.statusText}: ${text.slice(0, 220)}`);
        error.status = response.status;
        error.durationMs = durationMs;
        throw error;
      }
      return { json, durationMs, status: response.status };
    } catch (error) {
      lastError = error;
      if (error.name === 'AbortError') break;
      if (!error.status || error.status < 500 || attempt === 2) break;
      await new Promise((resolve) => setTimeout(resolve, 400));
    }
  }
  throw lastError;
}

function assessLatency(label, durationMs) {
  if (durationMs >= failLatencyMs) {
    fail(`${label}: latence critique ${durationMs} ms`, { durationMs });
  } else if (durationMs >= warnLatencyMs) {
    warn(`${label}: latence élevée ${durationMs} ms`, { durationMs });
  }
}

async function checkLiveEndpoint(label, url, expectedStatus = '') {
  try {
    const { response, durationMs } = await fetchTimed(url);
    const text = await response.text().catch(() => '');
    if (response.status >= 500) {
      fail(`${label}: HTTP ${response.status}`, { url, durationMs });
      return;
    }
    if (!response.ok) {
      fail(`${label}: HTTP ${response.status}`, { url, durationMs });
      return;
    }
    if (expectedStatus) {
      const json = JSON.parse(text);
      if (json?.success !== true || json?.status !== expectedStatus) {
        fail(`${label}: payload inattendu`, { url, durationMs, payload: json });
        return;
      }
    }
    assessLatency(label, durationMs);
    mark(label, { url, durationMs, status: response.status });
  } catch (error) {
    fail(`${label}: ${error.name === 'AbortError' ? `timeout ${timeoutMs} ms` : error.message}`, { url });
  }
}

async function checkLiveStack() {
  if (skipLive) {
    warn('contrôle live app/API ignoré via --skip-live');
    return;
  }
  await checkLiveEndpoint('app:web', appUrl);
  await checkLiveEndpoint('api:live', new URL('/api/health/live', apiUrl).toString(), 'live');
  await checkLiveEndpoint('api:ready', new URL('/api/health/ready', apiUrl).toString(), 'ready');
}

async function listNocoTables() {
  if (!nocodbUrl || !nocodbToken || !nocodbBaseId) {
    fail('variables NocoDB manquantes: NOCODB_API_URL, NOCODB_API_TOKEN, NOCODB_BASE_ID');
    return [];
  }
  if (nocodbBaseId !== expectedProdBaseId) {
    warn(`base contrôlée différente de la prod attendue (${nocodbBaseId} au lieu de ${expectedProdBaseId})`);
  }
  const url = `${nocodbUrl}/api/v2/meta/bases/${encodeURIComponent(nocodbBaseId)}/tables`;
  const { json, durationMs } = await fetchJson(url, {
    headers: { 'xc-token': nocodbToken },
  });
  assessLatency('nocodb:meta-tables', durationMs);
  const list = json?.list || json?.tables || [];
  if (!Array.isArray(list) || list.length === 0) {
    fail('NocoDB: aucune table trouvée dans la base', { baseId: nocodbBaseId });
    return [];
  }
  mark('nocodb:meta-tables', { baseId: nocodbBaseId, tables: list.length, durationMs });
  return list;
}

function buildTableIndex(tables) {
  const byId = new Map();
  const byTitle = new Map();
  for (const table of tables) {
    const title = table.title || table.table_name || table.name || table.id;
    if (table.id) byId.set(String(table.id), { ...table, title });
    byTitle.set(normalizeTitle(title), { ...table, title });
  }
  return { byId, byTitle };
}

function resolveTable(target, index) {
  if (target.id && index.byId.has(target.id)) return index.byId.get(target.id);
  for (const title of target.titles || []) {
    const table = index.byTitle.get(normalizeTitle(title));
    if (table) return table;
  }
  return null;
}

async function getTableSchema(tableId) {
  const url = `${nocodbUrl}/api/v2/meta/tables/${encodeURIComponent(tableId)}`;
  const { json, durationMs } = await fetchJson(url, {
    headers: { 'xc-token': nocodbToken },
  });
  assessLatency(`nocodb:schema:${tableId}`, durationMs);
  const columns = json?.columns || json?.fields || [];
  return { columns: Array.isArray(columns) ? columns : [], durationMs };
}

function columnName(column) {
  return String(column?.title || column?.column_name || column?.name || '').trim();
}

async function checkSchema(resolvedTables) {
  const schemas = new Map();
  for (const [key, table] of resolvedTables) {
    const { columns, durationMs } = await getTableSchema(table.id);
    schemas.set(key, columns);
    mark(`schema:${key}`, { tableId: table.id, title: table.title, columns: columns.length, durationMs });
  }

  for (const [key, rule] of Object.entries(COLUMN_CHECKS)) {
    const columns = schemas.get(key);
    const table = resolvedTables.get(key);
    if (!columns || !table) continue;
    const byName = new Map(columns.map((column) => [columnName(column), column]));
    for (const required of rule.required) {
      if (!byName.has(required)) {
        fail(`colonne critique absente: ${table.title}.${required}`, { table: table.title, column: required });
      }
    }
    for (const [name, acceptedTypes] of Object.entries(rule.typedWarnings || {})) {
      const column = byName.get(name);
      if (!column) continue;
      const type = column.uidt || column.type || '';
      if (!acceptedTypes.includes(type)) {
        warn(`type inattendu: ${table.title}.${name} = ${type || 'inconnu'}`, {
          table: table.title,
          column: name,
          acceptedTypes,
          type,
        });
      }
    }
  }
}

async function countTableRecords(key, table) {
  const url = new URL(`${nocodbUrl}/api/v2/tables/${encodeURIComponent(table.id)}/records`);
  url.searchParams.set('limit', '1');
  const { json, durationMs } = await fetchJson(url.toString(), {
    headers: { 'xc-token': nocodbToken },
  });
  assessLatency(`count:${key}`, durationMs);
  const totalRows = Number(json?.pageInfo?.totalRows ?? json?.list?.length ?? 0);
  mark(`count:${key}`, { tableId: table.id, title: table.title, totalRows, durationMs });
  return totalRows;
}

async function fetchRecordsSample(key, table, limit = sampleLimit) {
  const records = [];
  let offset = 0;
  while (records.length < limit) {
    const url = new URL(`${nocodbUrl}/api/v2/tables/${encodeURIComponent(table.id)}/records`);
    url.searchParams.set('limit', String(Math.min(1000, limit - records.length)));
    url.searchParams.set('offset', String(offset));
    const { json, durationMs } = await fetchJson(url.toString(), {
      headers: { 'xc-token': nocodbToken },
    });
    assessLatency(`sample:${key}`, durationMs);
    const list = Array.isArray(json?.list) ? json.list : [];
    records.push(...list);
    if (json?.pageInfo?.isLastPage || list.length === 0) break;
    offset += list.length;
  }
  return records;
}

async function checkCountsAndConsistency(resolvedTables) {
  for (const key of COUNT_TABLE_KEYS) {
    const table = resolvedTables.get(key);
    if (!table) continue;
    try {
      await countTableRecords(key, table);
    } catch (error) {
      if (error.status >= 500) {
        fail(`count:${key}: HTTP ${error.status}`, { table: table.title, durationMs: error.durationMs });
      } else {
        fail(`count:${key}: ${error.message}`, { table: table.title });
      }
    }
  }

  const documentsTable = resolvedTables.get('mobile_documents');
  const chunksTable = resolvedTables.get('mobile_document_chunks');
  if (documentsTable && chunksTable) {
    const [documents, chunks] = await Promise.all([
      fetchRecordsSample('mobile_documents', documentsTable),
      fetchRecordsSample('mobile_document_chunks', chunksTable),
    ]);
    const documentIds = new Set(
      documents.map((record) => recordValue(record, 'uuid_source')).filter(Boolean),
    );
    const orphanChunks = chunks.filter((record) => {
      const documentId = recordValue(record, 'document_uuid_source');
      if (!documentId || documentId.startsWith('upload_')) return false;
      return !documentIds.has(documentId);
    });
    if (orphanChunks.length > 0) {
      warn(`${orphanChunks.length} chunk(s) document sans mobile_document dans l'échantillon`, {
        checkedChunks: chunks.length,
        checkedDocuments: documents.length,
      });
    }
    mark('consistency:documents-chunks', {
      checkedDocuments: documents.length,
      checkedChunks: chunks.length,
      orphanChunks: orphanChunks.length,
      sampleLimit,
    });
  }

  const notePagesTable = resolvedTables.get('mobile_note_pages');
  if (notePagesTable) {
    const notes = await fetchRecordsSample('mobile_note_pages', notePagesTable);
    const incomplete = notes.filter((record) => (
      !recordValue(record, 'beneficiaire_id')
      || !recordValue(record, 'tab_key')
      || !recordValue(record, 'page_number')
    ));
    if (incomplete.length > 0) {
      warn(`${incomplete.length} note(s) incomplète(s) dans l'échantillon`, {
        checkedNotes: notes.length,
      });
    }
    mark('consistency:note-pages', {
      checkedNotes: notes.length,
      incompleteNotes: incomplete.length,
      sampleLimit,
    });
  }
}

async function checkNocoDB() {
  let tables = [];
  try {
    tables = await listNocoTables();
  } catch (error) {
    fail(`NocoDB meta inaccessible: ${error.message}`, { status: error.status || null });
    return;
  }
  const index = buildTableIndex(tables);
  const resolvedTables = new Map();
  for (const target of CRITICAL_TABLES) {
    const table = resolveTable(target, index);
    if (!table) {
      fail(`table critique absente: ${target.key}`, { expected: target.titles || target.id });
      continue;
    }
    resolvedTables.set(target.key, table);
  }
  mark('schema:critical-tables', { expected: CRITICAL_TABLES.length, found: resolvedTables.size });
  await checkSchema(resolvedTables);
  await checkCountsAndConsistency(resolvedTables);
}

async function checkBackupReadiness() {
  const requiredScripts = [
    'tools/backup-nocodb.mjs',
    'tools/verify-nocodb-backup.mjs',
    'tools/plan-nocodb-restore.mjs',
    'tools/nocodbBackupLib.mjs',
  ];
  for (const script of requiredScripts) {
    if (!(await fileExists(path.resolve(script)))) {
      fail(`script backup/restauration absent: ${script}`);
    }
  }
  mark('backup:scripts', { scripts: requiredScripts.length });

  if (!backupPath) {
    warn('aucun backup fourni à vérifier (--backup chemin/backup.json.gz)');
    return;
  }

  const resolvedBackup = path.resolve(backupPath);
  try {
    const verification = await readAndVerifyBackup(resolvedBackup);
    if (!verification.ok) {
      fail(`backup invalide: ${verification.failures.join(' ; ')}`, { backup: resolvedBackup });
      return;
    }
    for (const message of verification.warnings) {
      warn(`backup: ${message}`, { backup: resolvedBackup });
    }
    mark('backup:verify', {
      backup: resolvedBackup,
      ...verification.summary,
    });
  } catch (error) {
    fail(`backup illisible: ${error.message}`, { backup: resolvedBackup });
  }
}

function markdownReport(report) {
  const status = report.ok ? 'OK' : 'ÉCHEC';
  const lines = [
    '# Audit stabilité data/sync',
    '',
    `Statut : ${status}`,
    '',
    `Date : ${report.createdAt}`,
    '',
    `App : ${report.targets.appUrl}`,
    '',
    `API : ${report.targets.apiUrl}`,
    '',
    `NocoDB : ${report.targets.nocodbUrl || 'non configuré'}`,
    '',
    `Base contrôlée : ${report.targets.nocodbBaseId || 'non configurée'}`,
    '',
    '## Résumé',
    '',
    `- Échecs bloquants : ${report.failures.length}`,
    `- Alertes : ${report.warnings.length}`,
    `- Contrôles OK : ${report.checks.length}`,
    '',
  ];

  if (report.failures.length > 0) {
    lines.push('## Échecs bloquants', '');
    for (const failure of report.failures) lines.push(`- ${failure.message}`);
    lines.push('');
  }

  if (report.warnings.length > 0) {
    lines.push('## Alertes', '');
    for (const warning of report.warnings) lines.push(`- ${warning.message}`);
    lines.push('');
  }

  lines.push('## Contrôles', '');
  for (const check of report.checks) {
    const details = [];
    if (check.title) details.push(check.title);
    if (Number.isFinite(check.durationMs)) details.push(`${check.durationMs} ms`);
    if (Number.isFinite(check.totalRows)) details.push(`${check.totalRows} lignes`);
    if (Number.isFinite(check.tables)) details.push(`${check.tables} tables`);
    lines.push(`- ${check.name}${details.length ? ` (${details.join(', ')})` : ''}`);
  }
  lines.push('');
  return `${lines.join('\n')}\n`;
}

await mkdir(outputDir, { recursive: true });

await checkLiveStack();
await checkNocoDB();
await checkBackupReadiness();

const report = {
  ok: failures.length === 0,
  createdAt: new Date().toISOString(),
  destructive: false,
  targets: {
    appUrl,
    apiUrl,
    nocodbUrl,
    nocodbBaseId,
    expectedProdBaseId,
  },
  thresholds: {
    timeoutMs,
    warnLatencyMs,
    failLatencyMs,
    sampleLimit,
  },
  failures,
  warnings,
  checks,
};

await writeFile(path.join(outputDir, 'report.json'), JSON.stringify(report, null, 2));
await writeFile(path.join(outputDir, 'report.md'), markdownReport(report));

if (!report.ok) {
  console.error('[data-sync-stability] ÉCHEC');
  console.error(`Rapport: ${path.join(outputDir, 'report.md')}`);
  for (const failure of failures) console.error(`- ${failure.message}`);
  process.exit(1);
}

console.log('[data-sync-stability] OK');
console.log(JSON.stringify({
  report: path.join(outputDir, 'report.md'),
  warnings: warnings.length,
  checks: checks.length,
}, null, 2));
