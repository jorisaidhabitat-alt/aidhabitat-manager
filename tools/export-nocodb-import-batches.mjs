#!/usr/bin/env node
// Exporte un backup/snapshot NocoDB en lots JSON prêts à être importés.
//
// Aucun appel réseau et aucune écriture NocoDB. Les fichiers produits sont
// destinés à préparer une restauration staging propre et vérifiable.

import { mkdir, writeFile, rm, access } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { REQUIRED_BACKUP_TABLES, readAndVerifyBackup } from './nocodbBackupLib.mjs';

const backupPath = process.argv[2];
const outputDir = process.argv[3] || 'tmp/nocodb-import-batches';
const batchSize = Math.min(1000, Math.max(1, Number(process.env.RESTORE_BATCH_SIZE) || 500));
const overwrite = process.env.IMPORT_BATCHES_OVERWRITE === '1';

if (!backupPath) {
  console.error('Usage: node tools/export-nocodb-import-batches.mjs <backup.json.gz|backup.json> [output-dir]');
  process.exit(1);
}

const SYSTEM_FIELDS = new Set([
  'Id',
  'CreatedAt',
  'UpdatedAt',
  'Id1',
]);

const DISPLAY_OBJECT_FIELDS = new Set([
  'beneficiaire',
  'beneficiaires',
  'dossier',
  'dossiers',
  'commune',
  'situation_proprietaire',
  'statut_occupation',
  'dependance_particuliere',
  'bareme_anah',
  'type_de_logement',
  'porte_de_garage',
  'portail',
]);

const safeSlug = (name) => String(name || 'table')
  .normalize('NFKD')
  .replace(/[\u0300-\u036f]/g, '')
  .replace(/[^a-zA-Z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .toLowerCase()
  .slice(0, 80) || 'table';

const shouldSkipField = (key, value) => {
  if (SYSTEM_FIELDS.has(key)) return 'system-field';
  if (DISPLAY_OBJECT_FIELDS.has(key) && value && typeof value === 'object') return 'display-object';
  if (value && typeof value === 'object' && !Array.isArray(value)) return 'nested-object';
  return '';
};

const normalizeRecordForInsert = (record) => {
  const fields = {};
  const skipped = {};

  for (const [key, value] of Object.entries(record || {})) {
    const reason = shouldSkipField(key, value);
    if (reason) {
      skipped[key] = reason;
      continue;
    }
    fields[key] = value;
  }

  return { fields, skipped };
};

const fileExists = async (file) => {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
};

const fail = (message) => {
  console.error(`[import-batches] ÉCHEC: ${message}`);
  process.exit(1);
};

const resolvedOutput = path.resolve(outputDir);
if (await fileExists(resolvedOutput)) {
  if (!overwrite) {
    fail(`le dossier existe déjà: ${resolvedOutput}. Définir IMPORT_BATCHES_OVERWRITE=1 pour remplacer.`);
  }
  await rm(resolvedOutput, { recursive: true, force: true });
}
await mkdir(resolvedOutput, { recursive: true });

const verification = await readAndVerifyBackup(path.resolve(backupPath)).catch((error) => {
  fail(`lecture/parsing impossible: ${error.message}`);
});

if (!verification.ok) fail(verification.failures.join(' ; '));

const orderedTables = [...verification.tables.values()].sort((a, b) => {
  const aCritical = REQUIRED_BACKUP_TABLES.includes(a.name);
  const bCritical = REQUIRED_BACKUP_TABLES.includes(b.name);
  if (aCritical !== bCritical) return aCritical ? -1 : 1;
  return b.records.length - a.records.length;
});

const manifest = {
  createdAt: new Date().toISOString(),
  sourceBackup: path.resolve(backupPath),
  sourceBaseId: verification.summary.baseId,
  sourceCreatedAt: verification.summary.createdAt,
  batchSize,
  mode: 'non-destructive-export',
  notes: [
    'Ces fichiers ne modifient pas NocoDB.',
    'Créer les tables/colonnes staging avant import.',
    'Importer avec POST /api/v2/tables/{tableId}/records en envoyant directement le tableau JSON batch.',
    'Relancer un backup staging puis backup:verify après import.',
  ],
  tables: [],
};

let totalBatches = 0;
let totalRecords = 0;

for (const table of orderedTables) {
  const tableSlug = safeSlug(table.name);
  const tableDir = path.join(resolvedOutput, `${tableSlug}__${table.id || 'no-id'}`);
  await mkdir(tableDir, { recursive: true });

  const normalized = table.records.map(normalizeRecordForInsert);
  const skippedFieldReasons = {};
  for (const row of normalized) {
    for (const [field, reason] of Object.entries(row.skipped)) {
      skippedFieldReasons[field] = reason;
    }
  }

  const batches = [];
  for (let index = 0; index < normalized.length; index += batchSize) {
    batches.push(normalized.slice(index, index + batchSize).map((row) => row.fields));
  }

  const tableManifest = {
    id: table.id || null,
    name: table.name,
    critical: REQUIRED_BACKUP_TABLES.includes(table.name),
    fields: Array.isArray(table.fields) ? table.fields : [],
    records: table.records.length,
    insertableRecords: normalized.length,
    skippedFieldReasons,
    batches: [],
  };

  for (let batchIndex = 0; batchIndex < batches.length; batchIndex += 1) {
    const batch = batches[batchIndex];
    const fileName = `batch-${String(batchIndex + 1).padStart(4, '0')}.json`;
    await writeFile(path.join(tableDir, fileName), JSON.stringify(batch, null, 2));
    tableManifest.batches.push({
      file: path.relative(resolvedOutput, path.join(tableDir, fileName)),
      records: batch.length,
    });
  }

  await writeFile(path.join(tableDir, 'schema.json'), JSON.stringify({
    id: table.id || null,
    name: table.name,
    fields: table.fields || [],
    skippedFieldReasons,
  }, null, 2));

  manifest.tables.push(tableManifest);
  totalBatches += batches.length;
  totalRecords += table.records.length;
}

manifest.summary = {
  tables: manifest.tables.length,
  records: totalRecords,
  batches: totalBatches,
};

await writeFile(path.join(resolvedOutput, 'manifest.json'), JSON.stringify(manifest, null, 2));
await writeFile(path.join(resolvedOutput, 'README.md'), `# Lots d'import NocoDB

Source : ${manifest.sourceBackup}

Base source : ${manifest.sourceBaseId}

Records : ${totalRecords}

Batches : ${totalBatches}

## Ordre

1. Créer une base NocoDB staging vide.
2. Créer les tables et colonnes avec les \`schema.json\`.
3. Importer les fichiers \`batch-*.json\` table par table.
4. Faire un backup de la base staging.
5. Lancer \`npm run backup:verify -- <backup-staging.json.gz>\`.
6. Lancer les flux critiques de l'app staging.

Les fichiers \`batch-*.json\` contiennent directement un tableau JSON compatible avec le bulk insert NocoDB v2.

Les champs système NocoDB comme \`Id\`, \`CreatedAt\` et \`UpdatedAt\` sont exclus des payloads d'import.
`);

console.log('[import-batches] OK - aucun changement NocoDB effectué');
console.log(JSON.stringify({
  output: resolvedOutput,
  sourceBaseId: manifest.sourceBaseId,
  tables: manifest.summary.tables,
  records: manifest.summary.records,
  batches: manifest.summary.batches,
  batchSize,
}, null, 2));
