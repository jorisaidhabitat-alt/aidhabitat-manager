#!/usr/bin/env node
// Bootstrap sécurisé d'un schéma NocoDB staging à partir d'un plan exporté.
//
// Par défaut : dry-run, aucune écriture.
// Écriture réelle uniquement avec :
//   --apply
//   NOCODB_RESTORE_ALLOW_APPLY=1
//   NOCODB_RESTORE_TARGET=staging
//   NOCODB_BASE_ID différent de la production/source

import { access, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

import dotenv from 'dotenv';

dotenv.config({ path: '.env.local', quiet: true });
dotenv.config({ quiet: true });

const schemaPlanDir = process.argv[2];
const batchesDir = process.argv[3] && !process.argv[3].startsWith('--') ? process.argv[3] : '';
const apply = process.argv.includes('--apply');
const writeMapIndex = process.argv.findIndex((arg) => arg === '--write-map');
const writeMapPath = writeMapIndex >= 0 ? process.argv[writeMapIndex + 1] : '';

if (!schemaPlanDir) {
  console.error('Usage: node tools/bootstrap-nocodb-staging-schema.mjs <schema-plan-dir> [import-batches-dir] [--apply] [--write-map table-map.json]');
  process.exit(1);
}

const API_URL = String(process.env.NOCODB_API_URL || '').trim().replace(/\/+$/, '');
const API_TOKEN = String(process.env.NOCODB_API_TOKEN || '').trim();
const BASE_ID = String(process.env.NOCODB_BASE_ID || '').trim();
const ALLOW_APPLY = process.env.NOCODB_RESTORE_ALLOW_APPLY === '1';
const RESTORE_TARGET = String(process.env.NOCODB_RESTORE_TARGET || '').trim().toLowerCase();
const PROD_BASE_ID = 'pskgbjythubfzv9';
const MAX_COLUMNS_PER_TABLE = Math.min(500, Math.max(1, Number(process.env.NOCODB_STAGING_MAX_COLUMNS_PER_TABLE) || 500));
const REQUEST_DELAY_MS = Math.max(0, Number(process.env.NOCODB_STAGING_REQUEST_DELAY_MS) || 0);
const MAX_RETRIES = Math.min(8, Math.max(0, Number(process.env.NOCODB_STAGING_MAX_RETRIES) || 4));

const fail = (message) => {
  console.error(`[bootstrap-staging-schema] ÉCHEC: ${message}`);
  process.exit(1);
};

const fileExists = async (file) => {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
};

const readJson = async (file) => JSON.parse(await readFile(file, 'utf8'));

const safeSlug = (name) => String(name || 'table')
  .normalize('NFKD')
  .replace(/[\u0300-\u036f]/g, '')
  .replace(/[^a-zA-Z0-9]+/g, '_')
  .replace(/^_+|_+$/g, '')
  .toLowerCase()
  .slice(0, 55) || 'table';

const normalizeTitle = (value) => String(value || '').trim().toLowerCase();

const columnName = (title) => safeSlug(title)
  .replace(/^id$/, 'legacy_id')
  .slice(0, 55) || 'column';

const isIsoDateLike = (value) => /^\d{4}-\d{2}-\d{2}/.test(String(value || ''));

const inferTypeFromValues = (values) => {
  const filtered = values.filter((value) => value !== null && value !== undefined && value !== '');
  if (filtered.length === 0) return 'LongText';
  if (filtered.every((value) => typeof value === 'boolean')) return 'Checkbox';
  if (filtered.every((value) => Number.isInteger(value))) return 'Number';
  if (filtered.every((value) => typeof value === 'number')) return 'Decimal';
  if (filtered.every((value) => typeof value === 'string' && isIsoDateLike(value))) return 'DateTime';
  if (filtered.some((value) => typeof value === 'object')) return 'LongText';
  const maxLength = Math.max(...filtered.map((value) => String(value).length));
  return maxLength > 255 ? 'LongText' : 'SingleLineText';
};

const TYPE_TO_COLUMN = {
  SingleLineText: { uidt: 'SingleLineText', dt: 'character varying' },
  LongText: { uidt: 'LongText', dt: 'text' },
  Number: { uidt: 'Number', dt: 'integer', np: '32', ns: '0' },
  Decimal: { uidt: 'Decimal', dt: 'decimal', np: '18', ns: '4' },
  Currency: { uidt: 'Decimal', dt: 'decimal', np: '18', ns: '4' },
  Percent: { uidt: 'Decimal', dt: 'decimal', np: '18', ns: '4' },
  Checkbox: { uidt: 'Checkbox', dt: 'boolean' },
  Date: { uidt: 'Date', dt: 'date' },
  DateTime: { uidt: 'DateTime', dt: 'datetime' },
  Email: { uidt: 'Email', dt: 'character varying' },
  PhoneNumber: { uidt: 'PhoneNumber', dt: 'character varying' },
  URL: { uidt: 'URL', dt: 'text' },
  SingleSelect: { uidt: 'SingleSelect', dt: 'character varying' },
  MultiSelect: { uidt: 'MultiSelect', dt: 'text' },
  JSON: { uidt: 'LongText', dt: 'text' },
  Attachment: { uidt: 'LongText', dt: 'text' },
  UUID: { uidt: 'SingleLineText', dt: 'character varying' },
  User: { uidt: 'SingleLineText', dt: 'character varying' },
  Rating: { uidt: 'Number', dt: 'integer', np: '32', ns: '0' },
  Duration: { uidt: 'Number', dt: 'integer', np: '32', ns: '0' },
  Year: { uidt: 'Number', dt: 'integer', np: '32', ns: '0' },
  Time: { uidt: 'SingleLineText', dt: 'character varying' },
  SpecificDBType: { uidt: 'LongText', dt: 'text' },
};

const buildColumnDefinition = (title, rawType) => {
  const template = TYPE_TO_COLUMN[rawType] || TYPE_TO_COLUMN.LongText;
  return {
    title,
    column_name: columnName(title),
    ...template,
  };
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isRetryableResponse = (status, payload) => {
  if ([429, 500, 502, 503, 504].includes(Number(status))) return true;
  const text = typeof payload === 'string' ? payload : JSON.stringify(payload || {});
  return /ERR_BASE_NOT_FOUND/i.test(text);
};

const requestJsonOnce = async (method, requestPath, { body, expectedStatuses = [200] } = {}) => {
  if (REQUEST_DELAY_MS > 0 && method !== 'GET') await sleep(REQUEST_DELAY_MS);
  const response = await fetch(`${API_URL}${requestPath}`, {
    method,
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      'xc-token': API_TOKEN,
    },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }
  if (!expectedStatuses.includes(response.status)) {
    const details = typeof payload === 'string' ? payload : JSON.stringify(payload);
    const error = new Error(`HTTP ${response.status} ${method} ${requestPath}: ${String(details || '').slice(0, 500)}`);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
};

const requestJson = async (method, requestPath, { body, expectedStatuses = [200] } = {}) => {
  let lastError = null;
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt += 1) {
    try {
      return await requestJsonOnce(method, requestPath, { body, expectedStatuses });
    } catch (error) {
      lastError = error;
      if (attempt >= MAX_RETRIES || !isRetryableResponse(error.status, error.payload)) break;
      const backoff = Math.min(15_000, 750 * (2 ** attempt));
      console.warn(`[bootstrap-staging-schema] retry ${attempt + 1}/${MAX_RETRIES} dans ${backoff}ms: ${error.message}`);
      await sleep(backoff);
    }
  }
  throw lastError;
};

const listTables = async () => {
  const payload = await requestJson('GET', `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`);
  return Array.isArray(payload) ? payload : (payload.list || payload.tables || []);
};

const getTableSchema = async (tableId) => {
  const payload = await requestJson('GET', `/api/v2/meta/tables/${encodeURIComponent(tableId)}`);
  return Array.isArray(payload?.columns) ? payload.columns : (payload?.fields || []);
};

const createTable = async (tableName, index) => requestJson('POST', `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`, {
  expectedStatuses: [200, 201],
  body: {
    title: tableName,
    table_name: `${safeSlug(tableName)}_${String(index + 1).padStart(2, '0')}`.slice(0, 63),
    columns: [
      {
        title: 'Id',
        column_name: 'id',
        uidt: 'Number',
        dt: 'integer',
        np: '32',
        ns: '0',
        pk: true,
        rqd: true,
      },
    ],
  },
});

const createColumn = async (tableId, field) => requestJson('POST', `/api/v2/meta/tables/${encodeURIComponent(tableId)}/columns`, {
  expectedStatuses: [200, 201],
  body: buildColumnDefinition(field.name, field.type),
});

const resolvedSchemaDir = path.resolve(schemaPlanDir);
const manifestPath = path.join(resolvedSchemaDir, 'manifest.json');
if (!(await fileExists(manifestPath))) fail(`manifest schéma introuvable: ${manifestPath}`);

const manifest = await readJson(manifestPath).catch((error) => {
  fail(`manifest schéma invalide: ${error.message}`);
});

const tablePlans = [];
for (const table of manifest.tables || []) {
  const planPath = path.join(resolvedSchemaDir, `${table.slug}.schema-plan.json`);
  const plan = await readJson(planPath).catch((error) => {
    fail(`plan invalide ${planPath}: ${error.message}`);
  });
  const fields = new Map();
  for (const field of plan.initialColumns || []) {
    if (!field.name || field.name === 'Id') continue;
    fields.set(field.name, { name: field.name, type: field.type || 'LongText', source: 'schema-plan' });
  }
  tablePlans.push({
    name: plan.name,
    sourceTableId: plan.id || table.id || null,
    fields,
  });
}

if (batchesDir) {
  const resolvedBatchesDir = path.resolve(batchesDir);
  const importManifest = await readJson(path.join(resolvedBatchesDir, 'manifest.json')).catch((error) => {
    fail(`manifest lots invalide: ${error.message}`);
  });
  const plansByName = new Map(tablePlans.map((table) => [table.name, table]));
  for (const table of importManifest.tables || []) {
    const plan = plansByName.get(table.name);
    if (!plan) continue;
    const valuesByKey = new Map();
    for (const batch of table.batches || []) {
      const payload = await readJson(path.join(resolvedBatchesDir, batch.file)).catch((error) => {
        fail(`lot invalide ${batch.file}: ${error.message}`);
      });
      for (const row of payload || []) {
        for (const [key, value] of Object.entries(row || {})) {
          if (key === 'Id' || plan.fields.has(key)) continue;
          if (!valuesByKey.has(key)) valuesByKey.set(key, []);
          valuesByKey.get(key).push(value);
        }
      }
    }
    for (const [key, values] of valuesByKey.entries()) {
      plan.fields.set(key, { name: key, type: inferTypeFromValues(values), source: 'import-batch' });
    }
  }
}

for (const table of tablePlans) {
  if (table.fields.size > MAX_COLUMNS_PER_TABLE) {
    fail(`trop de colonnes pour ${table.name}: ${table.fields.size} > ${MAX_COLUMNS_PER_TABLE}`);
  }
}

if (apply) {
  if (!ALLOW_APPLY) fail('écriture refusée: définir NOCODB_RESTORE_ALLOW_APPLY=1');
  if (RESTORE_TARGET !== 'staging') fail('écriture refusée: définir NOCODB_RESTORE_TARGET=staging');
  if (!API_URL || !API_TOKEN || !BASE_ID) fail('NOCODB_API_URL, NOCODB_API_TOKEN et NOCODB_BASE_ID requis');
  if (BASE_ID === PROD_BASE_ID || BASE_ID === manifest.sourceBaseId) {
    fail('écriture refusée: la base cible ressemble à la production/source');
  }
}

let existingTables = [];
if (API_URL && API_TOKEN && BASE_ID) {
  existingTables = await listTables().catch((error) => {
    if (apply) fail(`impossible de lister les tables cible: ${error.message}`);
    return [];
  });
}

const existingByTitle = new Map(existingTables.map((table) => [normalizeTitle(table.title || table.table_name), table]));
const planned = tablePlans.map((table, index) => ({
  index,
  name: table.name,
  sourceTableId: table.sourceTableId,
  fields: [...table.fields.values()],
  existingTableId: existingByTitle.get(normalizeTitle(table.name))?.id || '',
}));

if (!apply) {
  console.log('[bootstrap-staging-schema] dry-run OK - aucun changement NocoDB effectué');
  console.log(JSON.stringify({
    mode: 'dry-run',
    sourceBaseId: manifest.sourceBaseId,
    targetBaseId: BASE_ID || null,
    existingTargetTables: existingTables.length,
    tablesToCreate: planned.filter((table) => !table.existingTableId).length,
    tablesToPatch: planned.filter((table) => table.existingTableId).length,
    columns: planned.reduce((sum, table) => sum + table.fields.length, 0),
  }, null, 2));
  process.exit(0);
}

const tableMap = {
  targetBaseId: BASE_ID,
  tables: {},
};

for (const table of planned) {
  let targetTableId = table.existingTableId;
  if (!targetTableId) {
    console.log(`[bootstrap-staging-schema] création table ${table.name}`);
    await createTable(table.name, table.index);
    existingTables = await listTables();
    targetTableId = existingTables.find((entry) => normalizeTitle(entry.title || entry.table_name) === normalizeTitle(table.name))?.id || '';
  }
  if (!targetTableId) fail(`table cible introuvable après création: ${table.name}`);

  const schema = await getTableSchema(targetTableId);
  const existingColumns = new Set(schema.map((column) => normalizeTitle(column.title || column.column_name)));
  let addedColumns = 0;
  for (const field of table.fields) {
    if (existingColumns.has(normalizeTitle(field.name))) continue;
    console.log(`[bootstrap-staging-schema] ajout colonne ${table.name}.${field.name} (${field.type})`);
    await createColumn(targetTableId, field);
    addedColumns += 1;
  }
  tableMap.tables[table.name] = {
    sourceTableId: table.sourceTableId,
    stagingTableId: targetTableId,
    columns: table.fields.length,
  };
  console.log(`[bootstrap-staging-schema] ${table.name}: table=${targetTableId}, colonnes ajoutées=${addedColumns}`);
}

if (writeMapPath) {
  await writeFile(path.resolve(writeMapPath), JSON.stringify(tableMap, null, 2));
  console.log(`[bootstrap-staging-schema] mapping écrit: ${path.resolve(writeMapPath)}`);
}

console.log('[bootstrap-staging-schema] terminé');
console.log(JSON.stringify({
  mode: 'apply',
  targetBaseId: BASE_ID,
  tables: Object.keys(tableMap.tables).length,
  mapPath: writeMapPath ? path.resolve(writeMapPath) : null,
}, null, 2));
