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

import { readFile } from 'node:fs/promises';
import { gunzipSync } from 'node:zlib';
import path from 'node:path';
import process from 'node:process';

const backupPath = process.argv[2];

if (!backupPath) {
  console.error('Usage: node tools/verify-nocodb-backup.mjs <backup.json.gz|backup.json>');
  process.exit(1);
}

const REQUIRED_TABLES = [
  'Beneficiaires',
  '📁 dossiers',
  'mobile_documents',
  'mobile_document_chunks',
  'mobile_note_pages',
];

const TABLE_ALIASES = new Map([
  ['beneficiaires', 'Beneficiaires'],
  ['dossiers', '📁 dossiers'],
]);

const normalizeTableName = (name) => TABLE_ALIASES.get(String(name || '').trim()) || String(name || '').trim();
const value = (record, key) => record?.[key] == null ? '' : String(record[key]).trim();

const readBackup = async (file) => {
  const raw = await readFile(file);
  const isGzip = file.endsWith('.gz') || raw.subarray(0, 2).equals(Buffer.from([0x1f, 0x8b]));
  const jsonBuffer = isGzip ? gunzipSync(raw) : raw;
  return JSON.parse(jsonBuffer.toString('utf8'));
};

const fail = (message) => {
  console.error(`[verify-backup] ÉCHEC: ${message}`);
  process.exit(1);
};

const warn = (message) => {
  console.warn(`[verify-backup] attention: ${message}`);
};

const backup = await readBackup(path.resolve(backupPath)).catch((error) => {
  fail(`lecture/parsing impossible: ${error.message}`);
});

if (!backup || typeof backup !== 'object') fail('racine JSON invalide');
if (!backup.baseId) fail('baseId manquant');
if (!Array.isArray(backup.tables) || backup.tables.length === 0) {
  fail('aucune table dans le backup');
}

const tables = new Map();
for (const table of backup.tables) {
  const name = normalizeTableName(table?.name);
  if (!name) fail('table sans nom');
  if (!Array.isArray(table.records)) fail(`records non-tableau pour ${name}`);
  if (!Array.isArray(table.fields)) warn(`schema absent ou invalide pour ${name}`);
  tables.set(name, table);
}

for (const required of REQUIRED_TABLES) {
  const table = tables.get(required);
  if (!table) fail(`table critique absente: ${required}`);
  if (table.records.length === 0) fail(`table critique vide: ${required}`);
}

const documents = tables.get('mobile_documents')?.records || [];
const chunks = tables.get('mobile_document_chunks')?.records || [];
const notePages = tables.get('mobile_note_pages')?.records || [];

const documentIds = new Set(
  documents
    .map((record) => value(record, 'uuid_source'))
    .filter(Boolean),
);

let orphanChunks = 0;
for (const chunk of chunks) {
  const documentId = value(chunk, 'document_uuid_source');
  if (!documentId) {
    orphanChunks += 1;
    continue;
  }
  // Les chunks temporaires d'upload sont tolérés : ils peuvent exister
  // pendant une sauvegarde si un utilisateur importe un fichier.
  if (documentId.startsWith('upload_')) continue;
  if (!documentIds.has(documentId)) orphanChunks += 1;
}

if (orphanChunks > 0) {
  warn(`${orphanChunks} chunk(s) document sans mobile_document correspondant`);
}

const summary = {
  baseId: backup.baseId,
  createdAt: backup.createdAt || null,
  tables: backup.tables.length,
  records: backup.tables.reduce((sum, table) => sum + table.records.length, 0),
  documents: documents.length,
  documentChunks: chunks.length,
  notePages: notePages.length,
  orphanChunks,
};

console.log('[verify-backup] OK');
console.log(JSON.stringify(summary, null, 2));
