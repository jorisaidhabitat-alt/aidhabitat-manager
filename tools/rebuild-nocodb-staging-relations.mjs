#!/usr/bin/env node
// Reconstruit les relations NocoDB d'une base staging à partir du schéma prod.
//
// Par défaut : dry-run, aucune écriture.
// Écriture réelle uniquement avec :
//   --apply
//   NOCODB_RESTORE_ALLOW_APPLY=1
//   NOCODB_RESTORE_TARGET=staging
//   NOCODB_BASE_ID différent de la prod

import { readFile } from 'node:fs/promises';
import process from 'node:process';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local', quiet: true });

const prodSchemaPath = process.argv[2];
const apply = process.argv.includes('--apply');

if (!prodSchemaPath) {
  console.error('Usage: node tools/rebuild-nocodb-staging-relations.mjs <prod-full-schema.json> [--apply]');
  process.exit(1);
}

const API_URL = String(process.env.NOCODB_API_URL || '').trim().replace(/\/+$/, '');
const API_TOKEN = String(process.env.NOCODB_API_TOKEN || '').trim();
const BASE_ID = String(process.env.NOCODB_BASE_ID || '').trim();
const ALLOW_APPLY = process.env.NOCODB_RESTORE_ALLOW_APPLY === '1';
const RESTORE_TARGET = String(process.env.NOCODB_RESTORE_TARGET || '').trim().toLowerCase();
const BATCH_SIZE = Math.min(100, Math.max(1, Number(process.env.NOCODB_RESTORE_RELATION_BATCH_SIZE) || 50));
const MAX_RETRIES = Math.min(8, Math.max(0, Number(process.env.NOCODB_RESTORE_MAX_RETRIES) || 4));
const REQUEST_DELAY_MS = Math.max(0, Number(process.env.NOCODB_RESTORE_REQUEST_DELAY_MS) || 0);

const PROD_BASE_ID = 'pskgbjythubfzv9';

const fail = (message) => {
  console.error(`[rebuild-nocodb-staging-relations] ÉCHEC: ${message}`);
  process.exit(1);
};

if (apply) {
  if (!ALLOW_APPLY) fail('écriture refusée: définir NOCODB_RESTORE_ALLOW_APPLY=1');
  if (RESTORE_TARGET !== 'staging') fail('écriture refusée: définir NOCODB_RESTORE_TARGET=staging');
  if (!API_URL || !API_TOKEN || !BASE_ID) {
    fail('écriture refusée: NOCODB_API_URL, NOCODB_API_TOKEN et NOCODB_BASE_ID requis');
  }
  if (BASE_ID === PROD_BASE_ID) {
    fail('écriture refusée: NOCODB_BASE_ID correspond à la production');
  }
}

const headers = {
  'xc-token': API_TOKEN,
  'Content-Type': 'application/json',
  Accept: 'application/json',
};

const readJson = async (file) => JSON.parse(await readFile(file, 'utf8'));
const tableSchema = (entry) => entry.schema || entry.table || entry;
const columnsById = (table) => new Map((table.columns || []).map((column) => [column.id, column]));

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isRetryable = (status, text) => (
  status === 429
  || status === 500
  || status === 502
  || status === 503
  || status === 504
  || /ERR_BASE_NOT_FOUND/i.test(text)
);

const requestOnce = async (method, path, body) => {
  const response = await fetch(`${API_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let payload;
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    payload = text;
  }
  if (!response.ok) {
    throw new Error(`${method} ${path} ${response.status}: ${text.slice(0, 800)}`);
  }
  return payload;
};

const request = async (method, path, body) => {
  let lastError = null;
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt += 1) {
    try {
      const payload = await requestOnce(method, path, body);
      if (REQUEST_DELAY_MS > 0) await sleep(REQUEST_DELAY_MS);
      return payload;
    } catch (error) {
      lastError = error;
      const message = String(error?.message || '');
      const status = Number(message.match(/\s(\d{3}):/)?.[1] || 0);
      if (attempt >= MAX_RETRIES || !isRetryable(status, message)) break;
      const backoff = Math.min(10_000, 700 * (2 ** attempt));
      console.warn(`[rebuild-nocodb-staging-relations] retry ${attempt + 1}/${MAX_RETRIES} dans ${backoff}ms: ${message.slice(0, 180)}`);
      await sleep(backoff);
    }
  }
  throw lastError;
};

const fetchBaseTables = async () => {
  const list = await request('GET', `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`);
  const tables = Array.isArray(list?.list) ? list.list : Array.isArray(list) ? list : [];
  const full = [];
  for (const table of tables) {
    full.push(await request('GET', `/api/v2/meta/tables/${encodeURIComponent(table.id)}`));
  }
  return full;
};

const fetchRecords = async (tableId) => {
  const records = [];
  let offset = 0;
  const limit = 1000;
  for (;;) {
    const payload = await request(
      'GET',
      `/api/v2/tables/${encodeURIComponent(tableId)}/records?limit=${limit}&offset=${offset}`,
    );
    const list = Array.isArray(payload?.list) ? payload.list : [];
    records.push(...list);
    if (list.length < limit) break;
    offset += limit;
  }
  return records;
};

const updateRecords = async (tableId, records) => {
  let updated = 0;
  for (let index = 0; index < records.length; index += BATCH_SIZE) {
    const batch = records.slice(index, index + BATCH_SIZE);
    if (apply) {
      await request('PATCH', `/api/v2/tables/${encodeURIComponent(tableId)}/records`, batch);
    }
    updated += batch.length;
  }
  return updated;
};

const uniqueLegacyTitle = (columns, title) => {
  const base = `${title}_legacy`;
  const used = new Set(columns.map((column) => column.title));
  if (!used.has(base)) return base;
  let suffix = 2;
  while (used.has(`${base}_${suffix}`)) suffix += 1;
  return `${base}_${suffix}`;
};

const prod = await readJson(prodSchemaPath).catch((error) => {
  fail(`schéma prod invalide: ${error.message}`);
});

if (prod.baseId !== PROD_BASE_ID) {
  fail(`schéma source inattendu: ${prod.baseId || 'inconnu'}`);
}

const prodTables = (prod.tables || []).map(tableSchema);
const prodById = new Map(prodTables.map((table) => [table.id, table]));
const prodByTitle = new Map(prodTables.map((table) => [table.title, table]));
const prodColsByTableId = new Map(prodTables.map((table) => [table.id, columnsById(table)]));

const relations = [];
for (const table of prodTables) {
  for (const column of table.columns || []) {
    if (column.uidt !== 'LinkToAnotherRecord') continue;
    const options = column.colOptions || {};
    if (options.type !== 'bt') {
      fail(`relation non supportée ${table.title}.${column.title}: type=${options.type || 'inconnu'}`);
    }
    const relatedTable = prodById.get(options.fk_related_model_id);
    const childFkColumn = prodColsByTableId.get(table.id)?.get(options.fk_child_column_id);
    if (!relatedTable || !childFkColumn) {
      fail(`relation incomplète ${table.title}.${column.title}`);
    }
    relations.push({
      tableTitle: table.title,
      relationTitle: column.title,
      relationColumnName: column.column_name || column.title,
      relatedTitle: relatedTable.title,
      oldFkTitle: childFkColumn.title,
    });
  }
}

if (!apply) {
  console.log('[rebuild-nocodb-staging-relations] dry-run OK - aucun changement NocoDB effectué');
  console.log(JSON.stringify({
    mode: 'dry-run',
    sourceBaseId: prod.baseId,
    targetBaseId: BASE_ID || null,
    relations: relations.length,
    sample: relations.slice(0, 10),
  }, null, 2));
  process.exit(0);
}

let targetTables = await fetchBaseTables();
let targetByTitle = new Map(targetTables.map((table) => [table.title, table]));

const refreshTable = async (tableId) => request('GET', `/api/v2/meta/tables/${encodeURIComponent(tableId)}`);

const stats = [];

for (const relation of relations) {
  let childTable = targetByTitle.get(relation.tableTitle);
  const parentTable = targetByTitle.get(relation.relatedTitle);
  if (!childTable || !parentTable) {
    fail(`table introuvable pour ${relation.tableTitle}.${relation.relationTitle}`);
  }

  let columns = childTable.columns || [];
  const existingRelation = columns.find((column) => (
    column.title === relation.relationTitle && column.uidt === 'LinkToAnotherRecord'
  ));

  const conflictingColumn = columns.find((column) => (
    column.title === relation.relationTitle && column.uidt !== 'LinkToAnotherRecord'
  ));
  if (conflictingColumn) {
    const legacyTitle = uniqueLegacyTitle(columns, relation.relationTitle);
    await request('PATCH', `/api/v2/meta/columns/${encodeURIComponent(conflictingColumn.id)}`, {
      title: legacyTitle,
    });
    console.log(`[rebuild-nocodb-staging-relations] renommé ${relation.tableTitle}.${relation.relationTitle} -> ${legacyTitle}`);
    childTable = await refreshTable(childTable.id);
    columns = childTable.columns || [];
  }

  if (!existingRelation) {
    await request('POST', `/api/v2/meta/tables/${encodeURIComponent(childTable.id)}/columns`, {
      title: relation.relationTitle,
      column_name: relation.relationColumnName,
      childId: childTable.id,
      parentId: parentTable.id,
      type: 'bt',
      uidt: 'LinkToAnotherRecord',
    });
    console.log(`[rebuild-nocodb-staging-relations] relation créée ${relation.tableTitle}.${relation.relationTitle} -> ${relation.relatedTitle}`);
  }

  childTable = await refreshTable(childTable.id);
  columns = childTable.columns || [];
  targetByTitle.set(childTable.title, childTable);

  const relationColumn = columns.find((column) => (
    column.title === relation.relationTitle && column.uidt === 'LinkToAnotherRecord'
  ));
  const newFkId = relationColumn?.colOptions?.fk_child_column_id;
  const newFkColumn = columns.find((column) => column.id === newFkId);
  const oldFkColumn = columns.find((column) => column.title === relation.oldFkTitle);

  if (!relationColumn || !newFkColumn) {
    fail(`nouvelle colonne relation introuvable pour ${relation.tableTitle}.${relation.relationTitle}`);
  }

  if (!oldFkColumn) {
    stats.push({ ...relation, created: true, copied: 0, skipped: 'old_fk_missing', newFkTitle: newFkColumn.title });
    continue;
  }

  const records = await fetchRecords(childTable.id);
  const updates = [];
  for (const row of records) {
    const value = row[oldFkColumn.title];
    if (value === null || value === undefined || value === '') continue;
    if (String(row[newFkColumn.title] ?? '') === String(value)) continue;
    updates.push({ Id: row.Id, [newFkColumn.title]: value });
  }

  const copied = await updateRecords(childTable.id, updates);
  stats.push({
    table: relation.tableTitle,
    relation: relation.relationTitle,
    related: relation.relatedTitle,
    oldFkTitle: oldFkColumn.title,
    newFkTitle: newFkColumn.title,
    copied,
  });
  console.log(`[rebuild-nocodb-staging-relations] valeurs copiées ${relation.tableTitle}.${relation.relationTitle}: ${copied}`);
}

console.log('[rebuild-nocodb-staging-relations] terminé');
console.log(JSON.stringify({
  mode: 'apply',
  targetBaseId: BASE_ID,
  relations: stats.length,
  copiedRecords: stats.reduce((total, item) => total + (item.copied || 0), 0),
  skipped: stats.filter((item) => item.skipped).length,
}, null, 2));
