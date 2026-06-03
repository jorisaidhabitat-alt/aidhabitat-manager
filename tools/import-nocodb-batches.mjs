#!/usr/bin/env node
// Importe des lots NocoDB dans une base staging.
//
// Par défaut : dry-run uniquement, aucun appel d'écriture.
// Écriture réelle uniquement avec :
//   --apply
//   NOCODB_RESTORE_ALLOW_APPLY=1
//   NOCODB_RESTORE_TARGET=staging
//   NOCODB_BASE_ID différent de la base source du manifest
//
// Usage :
//   node tools/import-nocodb-batches.mjs tmp/staging-import-batches
//   node tools/import-nocodb-batches.mjs tmp/staging-import-batches table-map.json --apply

import { access, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const batchesDir = process.argv[2];
const maybeMapPath = process.argv[3] && !process.argv[3].startsWith('--') ? process.argv[3] : '';
const apply = process.argv.includes('--apply');

if (!batchesDir) {
  console.error('Usage: node tools/import-nocodb-batches.mjs <batches-dir> [table-map.json] [--apply]');
  process.exit(1);
}

const API_URL = String(process.env.NOCODB_API_URL || '').trim().replace(/\/+$/, '');
const API_TOKEN = String(process.env.NOCODB_API_TOKEN || '').trim();
const BASE_ID = String(process.env.NOCODB_BASE_ID || '').trim();
const ALLOW_APPLY = process.env.NOCODB_RESTORE_ALLOW_APPLY === '1';
const RESTORE_TARGET = String(process.env.NOCODB_RESTORE_TARGET || '').trim().toLowerCase();
const MAX_BATCH_RECORDS = Math.min(1000, Math.max(1, Number(process.env.NOCODB_RESTORE_MAX_BATCH_RECORDS) || 1000));

const SYSTEM_FIELDS = new Set(['Id', 'CreatedAt', 'UpdatedAt', 'Id1']);

const fail = (message) => {
  console.error(`[import-nocodb-batches] ÉCHEC: ${message}`);
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

const resolvedBatchesDir = path.resolve(batchesDir);
const manifestPath = path.join(resolvedBatchesDir, 'manifest.json');
if (!(await fileExists(manifestPath))) fail(`manifest introuvable: ${manifestPath}`);

const manifest = await readJson(manifestPath).catch((error) => {
  fail(`manifest invalide: ${error.message}`);
});

const mapTemplatePath = path.join(resolvedBatchesDir, 'table-map.template.json');
const tableMapTemplate = {
  targetBaseId: '<NOCODB_BASE_ID_STAGING>',
  tables: Object.fromEntries((manifest.tables || []).map((table) => [
    table.name,
    {
      sourceTableId: table.id || null,
      stagingTableId: '',
      records: table.records,
      batches: table.batches?.length || 0,
    },
  ])),
};

if (!maybeMapPath) {
  await writeFile(mapTemplatePath, JSON.stringify(tableMapTemplate, null, 2));
  console.log('[import-nocodb-batches] dry-run OK - aucun changement NocoDB effectué');
  console.log(JSON.stringify({
    mode: 'mapping-template',
    manifest: manifestPath,
    sourceBaseId: manifest.sourceBaseId,
    mapTemplate: mapTemplatePath,
    tables: manifest.tables?.length || 0,
    records: manifest.summary?.records || 0,
    batches: manifest.summary?.batches || 0,
  }, null, 2));
  process.exit(0);
}

const tableMapPath = path.resolve(maybeMapPath);
const tableMap = await readJson(tableMapPath).catch((error) => {
  fail(`mapping table invalide: ${error.message}`);
});

if (apply) {
  if (!ALLOW_APPLY) fail('écriture refusée: définir NOCODB_RESTORE_ALLOW_APPLY=1');
  if (RESTORE_TARGET !== 'staging') fail('écriture refusée: définir NOCODB_RESTORE_TARGET=staging');
  if (!API_URL || !API_TOKEN || !BASE_ID) {
    fail('écriture refusée: NOCODB_API_URL, NOCODB_API_TOKEN et NOCODB_BASE_ID requis');
  }
  if (BASE_ID === manifest.sourceBaseId || BASE_ID === 'pskgbjythubfzv9') {
    fail('écriture refusée: NOCODB_BASE_ID ressemble à la production/source');
  }
  if (tableMap.targetBaseId && tableMap.targetBaseId !== BASE_ID) {
    fail(`mapping incohérent: targetBaseId=${tableMap.targetBaseId} mais NOCODB_BASE_ID=${BASE_ID}`);
  }
}

const planned = [];
let totalRecords = 0;
let totalBatches = 0;
const missingMappings = [];
const badSystemFields = [];
const oversizedBatches = [];

for (const table of manifest.tables || []) {
  const mapping = tableMap.tables?.[table.name] || tableMap.tables?.[table.id] || null;
  const stagingTableId = String(mapping?.stagingTableId || '').trim();
  if (!stagingTableId) missingMappings.push(table.name);

  for (const batch of table.batches || []) {
    const batchFile = path.join(resolvedBatchesDir, batch.file);
    const payload = await readJson(batchFile).catch((error) => {
      fail(`batch invalide ${batch.file}: ${error.message}`);
    });
    if (!Array.isArray(payload)) fail(`batch ${batch.file} ne contient pas un tableau JSON`);
    if (payload.length > MAX_BATCH_RECORDS) oversizedBatches.push(`${batch.file}: ${payload.length}`);
    for (const [index, record] of payload.entries()) {
      for (const field of SYSTEM_FIELDS) {
        if (Object.prototype.hasOwnProperty.call(record, field)) {
          badSystemFields.push(`${batch.file}[${index}].${field}`);
        }
      }
    }

    planned.push({
      tableName: table.name,
      stagingTableId,
      file: batch.file,
      records: payload.length,
      payload,
    });
    totalRecords += payload.length;
    totalBatches += 1;
  }
}

if (badSystemFields.length > 0) {
  fail(`champs système interdits dans les lots: ${badSystemFields.slice(0, 5).join(', ')}`);
}
if (oversizedBatches.length > 0) {
  fail(`lots trop volumineux: ${oversizedBatches.slice(0, 5).join(', ')}`);
}
if (missingMappings.length > 0) {
  fail(`mapping stagingTableId manquant pour: ${missingMappings.slice(0, 10).join(', ')}`);
}

const headers = {
  'xc-token': API_TOKEN,
  'Content-Type': 'application/json',
  Accept: 'application/json',
};

const postBatch = async (tableId, payload) => {
  const response = await fetch(`${API_URL}/api/v2/tables/${encodeURIComponent(tableId)}/records`, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload),
  });
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new Error(`HTTP ${response.status} ${response.statusText}: ${text.slice(0, 500)}`);
  }
  return response.json().catch(() => ({}));
};

if (!apply) {
  console.log('[import-nocodb-batches] dry-run OK - aucun changement NocoDB effectué');
  console.log(JSON.stringify({
    mode: 'dry-run',
    sourceBaseId: manifest.sourceBaseId,
    targetBaseId: tableMap.targetBaseId || null,
    tables: manifest.tables?.length || 0,
    batches: totalBatches,
    records: totalRecords,
  }, null, 2));
  process.exit(0);
}

let importedRecords = 0;
let importedBatches = 0;
for (const item of planned) {
  try {
    await postBatch(item.stagingTableId, item.payload);
    importedRecords += item.records;
    importedBatches += 1;
    console.log(`[import-nocodb-batches] importé ${item.tableName} ${item.file} (${item.records} records)`);
  } catch (error) {
    fail(`import échoué ${item.tableName} ${item.file}: ${error.message}`);
  }
}

console.log('[import-nocodb-batches] import terminé');
console.log(JSON.stringify({
  mode: 'apply',
  targetBaseId: BASE_ID,
  batches: importedBatches,
  records: importedRecords,
}, null, 2));
