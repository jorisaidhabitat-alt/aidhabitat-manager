import { readFile } from 'node:fs/promises';
import { gunzipSync } from 'node:zlib';
import path from 'node:path';

export const REQUIRED_BACKUP_TABLES = [
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

export const normalizeTableName = (name) => (
  TABLE_ALIASES.get(String(name || '').trim()) || String(name || '').trim()
);

const value = (record, key) => (record?.[key] == null ? '' : String(record[key]).trim());

export async function readBackupFile(file) {
  const resolvedPath = path.resolve(file);
  const raw = await readFile(resolvedPath);
  const isGzip = resolvedPath.endsWith('.gz') || raw.subarray(0, 2).equals(Buffer.from([0x1f, 0x8b]));
  const jsonBuffer = isGzip ? gunzipSync(raw) : raw;
  return JSON.parse(jsonBuffer.toString('utf8'));
}

export function verifyBackupData(backup) {
  const failures = [];
  const warnings = [];

  if (!backup || typeof backup !== 'object') {
    return { ok: false, failures: ['racine JSON invalide'], warnings, tables: new Map(), summary: null };
  }

  if (!backup.baseId) failures.push('baseId manquant');
  if (!Array.isArray(backup.tables) || backup.tables.length === 0) {
    failures.push('aucune table dans le backup');
  }

  const tables = new Map();
  if (Array.isArray(backup.tables)) {
    for (const table of backup.tables) {
      const name = normalizeTableName(table?.name);
      if (!name) {
        failures.push('table sans nom');
        continue;
      }
      if (!Array.isArray(table.records)) {
        failures.push(`records non-tableau pour ${name}`);
        continue;
      }
      if (!Array.isArray(table.fields)) warnings.push(`schema absent ou invalide pour ${name}`);
      tables.set(name, { ...table, name });
    }
  }

  for (const required of REQUIRED_BACKUP_TABLES) {
    const table = tables.get(required);
    if (!table) {
      failures.push(`table critique absente: ${required}`);
      continue;
    }
    if (table.records.length === 0) failures.push(`table critique vide: ${required}`);
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
    if (documentId.startsWith('upload_')) continue;
    if (!documentIds.has(documentId)) orphanChunks += 1;
  }

  if (orphanChunks > 0) {
    warnings.push(`${orphanChunks} chunk(s) document sans mobile_document correspondant`);
  }

  const summary = {
    baseId: backup.baseId || null,
    createdAt: backup.createdAt || null,
    tables: Array.isArray(backup.tables) ? backup.tables.length : 0,
    records: Array.isArray(backup.tables)
      ? backup.tables.reduce((sum, table) => sum + (Array.isArray(table.records) ? table.records.length : 0), 0)
      : 0,
    documents: documents.length,
    documentChunks: chunks.length,
    notePages: notePages.length,
    orphanChunks,
  };

  return {
    ok: failures.length === 0,
    failures,
    warnings,
    tables,
    summary,
  };
}

export async function readAndVerifyBackup(file) {
  const backup = await readBackupFile(file);
  const verification = verifyBackupData(backup);
  return { backup, ...verification };
}
