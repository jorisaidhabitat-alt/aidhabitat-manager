#!/usr/bin/env node
// Exporte un plan de recréation de schéma NocoDB pour staging.
//
// Aucun appel réseau et aucune écriture NocoDB. Le plan sépare les colonnes
// simples importables des champs système/relationnels à reconstruire ensuite.

import { mkdir, writeFile, rm, access } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { REQUIRED_BACKUP_TABLES, readAndVerifyBackup } from './nocodbBackupLib.mjs';

const backupPath = process.argv[2];
const outputDir = process.argv[3] || 'tmp/nocodb-schema-plan';
const overwrite = process.env.SCHEMA_PLAN_OVERWRITE === '1';

if (!backupPath) {
  console.error('Usage: node tools/export-nocodb-schema-plan.mjs <backup.json.gz|backup.json> [output-dir]');
  process.exit(1);
}

const AUTO_TYPES = new Set([
  'ID',
  'CreatedTime',
  'LastModifiedTime',
  'CreatedBy',
  'LastModifiedBy',
  'Order',
  'Deleted',
  'Meta',
]);

const RELATION_TYPES = new Set([
  'ForeignKey',
  'LinkToAnotherRecord',
  'Links',
  'Lookup',
]);

const COMPUTED_TYPES = new Set([
  'Formula',
  'Rollup',
  'Count',
]);

const SIMPLE_TYPES = new Set([
  'SingleLineText',
  'LongText',
  'Number',
  'Decimal',
  'Currency',
  'Percent',
  'Checkbox',
  'Date',
  'DateTime',
  'Email',
  'PhoneNumber',
  'URL',
  'Attachment',
  'UUID',
  'User',
  'SingleSelect',
  'MultiSelect',
  'Rating',
  'Duration',
  'Year',
  'Time',
  'JSON',
  'SpecificDBType',
]);

const safeSlug = (name) => String(name || 'table')
  .normalize('NFKD')
  .replace(/[\u0300-\u036f]/g, '')
  .replace(/[^a-zA-Z0-9]+/g, '-')
  .replace(/^-+|-+$/g, '')
  .toLowerCase()
  .slice(0, 80) || 'table';

const fileExists = async (file) => {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
};

const classifyField = (field) => {
  const type = String(field.type || '');
  if (AUTO_TYPES.has(type)) return 'auto';
  if (RELATION_TYPES.has(type)) return 'relation';
  if (COMPUTED_TYPES.has(type)) return 'computed';
  if (SIMPLE_TYPES.has(type)) return 'simple';
  return 'unknown';
};

const fail = (message) => {
  console.error(`[schema-plan] ÉCHEC: ${message}`);
  process.exit(1);
};

const resolvedOutput = path.resolve(outputDir);
if (await fileExists(resolvedOutput)) {
  if (!overwrite) {
    fail(`le dossier existe déjà: ${resolvedOutput}. Définir SCHEMA_PLAN_OVERWRITE=1 pour remplacer.`);
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

const typeTotals = {};
const categoryTotals = { simple: 0, relation: 0, computed: 0, auto: 0, unknown: 0 };
const manifest = {
  createdAt: new Date().toISOString(),
  sourceBackup: path.resolve(backupPath),
  sourceBaseId: verification.summary.baseId,
  sourceCreatedAt: verification.summary.createdAt,
  mode: 'non-destructive-schema-plan',
  notes: [
    'Créer d’abord les tables et colonnes simples.',
    'Importer ensuite les lots JSON.',
    'Reconstruire les relations, lookups et formules après import.',
    'Ne pas recréer manuellement les champs système NocoDB.',
  ],
  tables: [],
};

for (const table of orderedTables) {
  const fields = Array.isArray(table.fields) ? table.fields : [];
  const classifiedFields = fields.map((field) => {
    const category = classifyField(field);
    const type = String(field.type || 'unknown');
    typeTotals[type] = (typeTotals[type] || 0) + 1;
    categoryTotals[category] += 1;
    return {
      id: field.id || null,
      name: field.name || '',
      type,
      required: Boolean(field.required),
      category,
      createPhase: category === 'simple' ? 'initial-table-column' : 'post-import-or-auto',
    };
  });

  const tablePlan = {
    id: table.id || null,
    name: table.name,
    slug: safeSlug(table.name),
    critical: REQUIRED_BACKUP_TABLES.includes(table.name),
    records: table.records.length,
    fields: classifiedFields,
    initialColumns: classifiedFields.filter((field) => field.category === 'simple'),
    postImportFields: classifiedFields.filter((field) => ['relation', 'computed'].includes(field.category)),
    autoFields: classifiedFields.filter((field) => field.category === 'auto'),
    unknownFields: classifiedFields.filter((field) => field.category === 'unknown'),
  };

  manifest.tables.push({
    id: tablePlan.id,
    name: tablePlan.name,
    slug: tablePlan.slug,
    critical: tablePlan.critical,
    records: tablePlan.records,
    initialColumns: tablePlan.initialColumns.length,
    postImportFields: tablePlan.postImportFields.length,
    autoFields: tablePlan.autoFields.length,
    unknownFields: tablePlan.unknownFields.length,
  });

  await writeFile(
    path.join(resolvedOutput, `${tablePlan.slug}.schema-plan.json`),
    JSON.stringify(tablePlan, null, 2),
  );
}

manifest.summary = {
  tables: manifest.tables.length,
  records: manifest.tables.reduce((sum, table) => sum + table.records, 0),
  categories: categoryTotals,
  types: Object.fromEntries(Object.entries(typeTotals).sort((a, b) => b[1] - a[1])),
};

await writeFile(path.join(resolvedOutput, 'manifest.json'), JSON.stringify(manifest, null, 2));

const markdown = [
  '# Plan schéma NocoDB staging',
  '',
  `Source : ${manifest.sourceBackup}`,
  '',
  `Base source : ${manifest.sourceBaseId}`,
  '',
  `Tables : ${manifest.summary.tables}`,
  '',
  `Records : ${manifest.summary.records}`,
  '',
  '## Ordre recommandé',
  '',
  '1. Créer les tables vides.',
  '2. Ajouter les colonnes `initial-table-column`.',
  '3. Importer les lots JSON staging.',
  '4. Recréer les relations, lookups et formules.',
  '5. Lancer un backup staging puis `backup:verify`.',
  '',
  '## Totaux par catégorie',
  '',
  ...Object.entries(categoryTotals).map(([key, value]) => `- ${key}: ${value}`),
  '',
  '## Tables',
  '',
  ...manifest.tables.map((table) =>
    `- ${table.name}: ${table.initialColumns} colonnes initiales, `
    + `${table.postImportFields} champs post-import, ${table.autoFields} auto, `
    + `${table.unknownFields} inconnus, ${table.records} records`
  ),
  '',
].join('\n');

await writeFile(path.join(resolvedOutput, 'README.md'), markdown);

console.log('[schema-plan] OK - aucun changement NocoDB effectué');
console.log(JSON.stringify({
  output: resolvedOutput,
  sourceBaseId: manifest.sourceBaseId,
  tables: manifest.summary.tables,
  records: manifest.summary.records,
  categories: manifest.summary.categories,
}, null, 2));
