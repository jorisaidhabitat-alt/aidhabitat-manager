#!/usr/bin/env node
// Vérifie qu'un dump `tools/backup-nocodb.mjs` est lisible et cohérent.
//
// Usage :
//   node tools/verify-nocodb-backup.mjs backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
//
// Ce script ne restaure rien et ne contacte pas NocoDB. Il valide le
// minimum indispensable avant de considérer un backup comme exploitable :
// gzip lisible, JSON parseable, tables présentes, records en tableaux,
// tables critiques non vides, et chunks documents reliés à des documents.

import path from 'node:path';
import process from 'node:process';
import { readAndVerifyBackup } from './nocodbBackupLib.mjs';

const backupPath = process.argv[2];

if (!backupPath) {
  console.error('Usage: node tools/verify-nocodb-backup.mjs <backup.json.gz|backup.json>');
  process.exit(1);
}

const fail = (message) => {
  console.error(`[verify-backup] ÉCHEC: ${message}`);
  process.exit(1);
};

const warn = (message) => {
  console.warn(`[verify-backup] attention: ${message}`);
};

const verification = await readAndVerifyBackup(path.resolve(backupPath)).catch((error) => {
  fail(`lecture/parsing impossible: ${error.message}`);
});

if (!verification.ok) fail(verification.failures.join(' ; '));
for (const message of verification.warnings) warn(message);

console.log('[verify-backup] OK');
console.log(JSON.stringify(verification.summary, null, 2));
