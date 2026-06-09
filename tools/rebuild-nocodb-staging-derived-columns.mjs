#!/usr/bin/env node
// Reconstruit les colonnes dérivées NocoDB (Lookup + Formula) d'une base staging.
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
  console.error('Usage: node tools/rebuild-nocodb-staging-derived-columns.mjs <prod-full-schema.json> [--apply]');
  process.exit(1);
}

const API_URL = String(process.env.NOCODB_API_URL || '').trim().replace(/\/+$/, '');
const API_TOKEN = String(process.env.NOCODB_API_TOKEN || '').trim();
const BASE_ID = String(process.env.NOCODB_BASE_ID || '').trim();
const ALLOW_APPLY = process.env.NOCODB_RESTORE_ALLOW_APPLY === '1';
const RESTORE_TARGET = String(process.env.NOCODB_RESTORE_TARGET || '').trim().toLowerCase();
const MAX_RETRIES = Math.min(8, Math.max(0, Number(process.env.NOCODB_RESTORE_MAX_RETRIES) || 4));
const REQUEST_DELAY_MS = Math.max(0, Number(process.env.NOCODB_RESTORE_REQUEST_DELAY_MS) || 0);

const PROD_BASE_ID = 'pskgbjythubfzv9';

const fail = (message) => {
  console.error(`[rebuild-nocodb-staging-derived-columns] ÉCHEC: ${message}`);
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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const readJson = async (file) => JSON.parse(await readFile(file, 'utf8'));
const tableSchema = (entry) => entry.schema || entry.table || entry;
const columnsById = (table) => new Map((table.columns || []).map((column) => [column.id, column]));

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
      console.warn(`[rebuild-nocodb-staging-derived-columns] retry ${attempt + 1}/${MAX_RETRIES} dans ${backoff}ms: ${message.slice(0, 180)}`);
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
const prodColsByTableId = new Map(prodTables.map((table) => [table.id, columnsById(table)]));
const prodColumnRefs = new Map();
for (const table of prodTables) {
  for (const column of table.columns || []) {
    prodColumnRefs.set(column.id, {
      tableTitle: table.title,
      columnTitle: column.title,
      uidt: column.uidt,
    });
  }
}

const lookups = [];
const formulas = [];

for (const table of prodTables) {
  for (const column of table.columns || []) {
    if (column.uidt === 'Lookup') {
      const options = column.colOptions || {};
      const relationColumn = prodColsByTableId.get(table.id)?.get(options.fk_relation_column_id);
      const lookupColumnRef = prodColumnRefs.get(options.fk_lookup_column_id);
      const relationOptions = relationColumn?.colOptions || {};
      const relatedTable = prodById.get(relationOptions.fk_related_model_id);
      if (!relationColumn || !lookupColumnRef || !relatedTable) {
        fail(`lookup incomplet ${table.title}.${column.title}`);
      }
      lookups.push({
        tableTitle: table.title,
        title: column.title,
        columnName: column.column_name || column.title,
        relationTitle: relationColumn.title,
        relatedTableTitle: relatedTable.title,
        lookupColumnTitle: lookupColumnRef.columnTitle,
        lookupUidt: prodColumnRefs.get(options.fk_lookup_column_id)?.uidt,
      });
    }
    if (column.uidt === 'Formula') {
      const formula = column.colOptions?.formula_raw || column.formula_raw || column.colOptions?.formula || column.formula;
      formulas.push({
        tableTitle: table.title,
        title: column.title,
        columnName: column.column_name || column.title,
        formula,
      });
    }
  }
}

if (!apply) {
  console.log('[rebuild-nocodb-staging-derived-columns] dry-run OK - aucun changement NocoDB effectué');
  console.log(JSON.stringify({
    mode: 'dry-run',
    sourceBaseId: prod.baseId,
    targetBaseId: BASE_ID || null,
    lookups: lookups.length,
    formulas: formulas.length,
  }, null, 2));
  process.exit(0);
}

let targetTables = await fetchBaseTables();
let targetByTitle = new Map(targetTables.map((table) => [table.title, table]));

const refreshTarget = async () => {
  targetTables = await fetchBaseTables();
  targetByTitle = new Map(targetTables.map((table) => [table.title, table]));
};

const refreshTableByTitle = async (tableTitle) => {
  const table = targetByTitle.get(tableTitle);
  if (!table) return null;
  const fresh = await request('GET', `/api/v2/meta/tables/${encodeURIComponent(table.id)}`);
  targetByTitle.set(tableTitle, fresh);
  return fresh;
};

const getTargetColumn = (tableTitle, columnTitle, uidt = null) => {
  const table = targetByTitle.get(tableTitle);
  const column = (table?.columns || []).find((item) => item.title === columnTitle && (!uidt || item.uidt === uidt));
  return { table, column };
};

const buildColumnIdMap = () => {
  const map = new Map();
  for (const [prodId, ref] of prodColumnRefs.entries()) {
    const { column } = getTargetColumn(ref.tableTitle, ref.columnTitle);
    if (column) map.set(prodId, column.id);
  }
  return map;
};

const renameConflict = async (table, title, expectedUidt) => {
  const conflict = (table.columns || []).find((column) => column.title === title && column.uidt !== expectedUidt);
  if (!conflict) return false;
  const legacyTitle = uniqueLegacyTitle(table.columns || [], title);
  await request('PATCH', `/api/v2/meta/columns/${encodeURIComponent(conflict.id)}`, { title: legacyTitle });
  console.log(`[rebuild-nocodb-staging-derived-columns] renommé ${table.title}.${title} -> ${legacyTitle}`);
  return true;
};

const createLookup = async (lookup) => {
  const { table } = getTargetColumn(lookup.tableTitle, 'Id');
  if (!table) return false;
  const existing = (table.columns || []).find((column) => column.title === lookup.title && column.uidt === 'Lookup');
  if (existing) return true;

  const relation = (table.columns || []).find((column) => (
    column.title === lookup.relationTitle && column.uidt === 'LinkToAnotherRecord'
  ));
  const relatedTable = targetByTitle.get(lookup.relatedTableTitle);
  const lookupColumn = (relatedTable?.columns || []).find((column) => (
    column.title === lookup.lookupColumnTitle && column.uidt === lookup.lookupUidt
  ));
  if (!relation || !relatedTable || !lookupColumn) return false;

  await renameConflict(table, lookup.title, 'Lookup');
  const freshTable = await refreshTableByTitle(lookup.tableTitle);
  const freshRelation = (freshTable?.columns || []).find((column) => (
    column.title === lookup.relationTitle && column.uidt === 'LinkToAnotherRecord'
  ));
  const freshRelatedTable = targetByTitle.get(lookup.relatedTableTitle);
  const freshLookupColumn = (freshRelatedTable?.columns || []).find((column) => (
    column.title === lookup.lookupColumnTitle && column.uidt === lookup.lookupUidt
  ));
  if (!freshTable || !freshRelation || !freshLookupColumn) return false;

  await request('POST', `/api/v2/meta/tables/${encodeURIComponent(freshTable.id)}/columns`, {
    title: lookup.title,
    column_name: lookup.columnName,
    uidt: 'Lookup',
    fk_relation_column_id: freshRelation.id,
    fk_lookup_column_id: freshLookupColumn.id,
  });
  console.log(`[rebuild-nocodb-staging-derived-columns] lookup créé ${lookup.tableTitle}.${lookup.title}`);
  await refreshTableByTitle(lookup.tableTitle);
  return true;
};

const translateFormula = (formula, idMap) => {
  if (!formula) return null;
  const missing = new Set();
  const translated = String(formula).replace(/\{\{([^}]+)\}\}/g, (match, prodColumnId) => {
    const targetColumnId = idMap.get(prodColumnId);
    if (!targetColumnId) {
      missing.add(prodColumnId);
      return match;
    }
    return `{{${targetColumnId}}}`;
  });
  if (missing.size > 0) return null;
  return translated;
};

const createFormula = async (formulaSpec) => {
  const { table } = getTargetColumn(formulaSpec.tableTitle, 'Id');
  if (!table) return false;
  const existing = (table.columns || []).find((column) => column.title === formulaSpec.title && column.uidt === 'Formula');
  if (existing) return true;

  const translated = translateFormula(formulaSpec.formula, buildColumnIdMap());
  if (!translated) return false;

  await renameConflict(table, formulaSpec.title, 'Formula');
  const freshTable = await refreshTableByTitle(formulaSpec.tableTitle);
  if (!freshTable) return false;
  await request('POST', `/api/v2/meta/tables/${encodeURIComponent(freshTable.id)}/columns`, {
    title: formulaSpec.title,
    column_name: formulaSpec.columnName,
    uidt: 'Formula',
    formula: translated,
    formula_raw: translated,
  });
  console.log(`[rebuild-nocodb-staging-derived-columns] formule créée ${formulaSpec.tableTitle}.${formulaSpec.title}`);
  await refreshTableByTitle(formulaSpec.tableTitle);
  return true;
};

const pendingLookups = new Set(lookups.map((_, index) => index));
const pendingFormulas = new Set(formulas.map((_, index) => index));

for (let pass = 1; pass <= 6; pass += 1) {
  let progressed = false;
  for (const index of [...pendingLookups]) {
    if (await createLookup(lookups[index])) {
      pendingLookups.delete(index);
      progressed = true;
    }
  }
  for (const index of [...pendingFormulas]) {
    if (await createFormula(formulas[index])) {
      pendingFormulas.delete(index);
      progressed = true;
    }
  }
  if (!progressed) break;
}

if (pendingLookups.size > 0 || pendingFormulas.size > 0) {
  fail(`colonnes non créées: lookups=${pendingLookups.size}, formulas=${pendingFormulas.size}`);
}

console.log('[rebuild-nocodb-staging-derived-columns] terminé');
console.log(JSON.stringify({
  mode: 'apply',
  targetBaseId: BASE_ID,
  lookups: lookups.length,
  formulas: formulas.length,
}, null, 2));
