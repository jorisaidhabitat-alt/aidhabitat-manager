#!/usr/bin/env node
// Produit un plan de restauration à partir d'un backup NocoDB.
//
// Important : ce script est volontairement non destructif. Il ne contacte pas
// NocoDB et n'écrit aucune donnée. Il sert à vérifier qu'un backup peut être
// transformé en plan d'action clair avant un vrai exercice de restauration.

import path from 'node:path';
import process from 'node:process';
import { REQUIRED_BACKUP_TABLES, readAndVerifyBackup } from './nocodbBackupLib.mjs';

const backupPath = process.argv[2];
const batchSize = Math.min(1000, Math.max(1, Number(process.env.RESTORE_BATCH_SIZE) || 1000));

if (!backupPath) {
  console.error('Usage: node tools/plan-nocodb-restore.mjs <backup.json.gz|backup.json>');
  process.exit(1);
}

const fail = (message) => {
  console.error(`[restore-plan] ÉCHEC: ${message}`);
  process.exit(1);
};

const verification = await readAndVerifyBackup(path.resolve(backupPath)).catch((error) => {
  fail(`lecture/parsing impossible: ${error.message}`);
});

if (!verification.ok) fail(verification.failures.join(' ; '));

const orderedTables = [...verification.tables.values()]
  .map((table) => ({
    id: String(table.id || ''),
    name: table.name,
    fields: Array.isArray(table.fields) ? table.fields.length : 0,
    records: table.records.length,
    batches: Math.ceil(table.records.length / batchSize),
    critical: REQUIRED_BACKUP_TABLES.includes(table.name),
  }))
  .sort((a, b) => {
    if (a.critical !== b.critical) return a.critical ? -1 : 1;
    return b.records - a.records;
  });

const summary = {
  backup: path.resolve(backupPath),
  sourceBaseId: verification.summary.baseId,
  createdAt: verification.summary.createdAt,
  batchSize,
  tables: verification.summary.tables,
  records: verification.summary.records,
  estimatedPostBatches: orderedTables.reduce((sum, table) => sum + table.batches, 0),
  warnings: verification.warnings,
};

console.log('[restore-plan] OK - aucun changement effectué');
console.log(JSON.stringify(summary, null, 2));
console.log('\nTables à restaurer :');

for (const table of orderedTables) {
  const marker = table.critical ? 'critique' : 'standard';
  console.log(
    `- ${table.name} (${marker}) : ${table.records} records, ${table.fields} champs, ${table.batches} batch(es)`,
  );
}

console.log('\nOrdre recommandé :');
console.log('1. Créer une base NocoDB vide ou utiliser une base staging dédiée.');
console.log('2. Recréer les tables et colonnes depuis les champs du backup.');
console.log(`3. Réimporter les records par batch de ${batchSize} maximum via l'API NocoDB.`);
console.log('4. Relancer tools/verify-nocodb-backup.mjs sur un nouveau dump de la base restaurée.');
console.log('5. Tester les flux critiques de l’application avant toute bascule production.');
