#!/usr/bin/env node
// Analyse un backup NocoDB pour préparer la migration des fichiers lourds
// vers un stockage objet compatible S3.
//
// Aucun appel réseau, aucune écriture NocoDB. Le script lit uniquement un
// dump produit par `tools/backup-nocodb.mjs`.

import path from 'node:path';
import process from 'node:process';
import { readAndVerifyBackup } from './nocodbBackupLib.mjs';

const backupPath = process.argv[2];
const topLimit = Math.min(50, Math.max(1, Number(process.env.OBJECT_STORAGE_TOP_LIMIT) || 10));

if (!backupPath) {
  console.error('Usage: node tools/analyze-object-storage-readiness.mjs <backup.json.gz|backup.json>');
  process.exit(1);
}

const field = (record, name) => (record?.[name] == null ? '' : String(record[name]).trim());

const estimateBytesFromBase64 = (base64) => {
  const clean = String(base64 || '').replace(/\s/g, '');
  if (!clean) return 0;
  const padding = clean.endsWith('==') ? 2 : clean.endsWith('=') ? 1 : 0;
  return Math.max(0, Math.floor((clean.length * 3) / 4) - padding);
};

const formatBytes = (bytes) => {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = Number(bytes) || 0;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(unit === 0 ? 0 : 2)} ${units[unit]}`;
};

const fail = (message) => {
  console.error(`[object-storage-readiness] ÉCHEC: ${message}`);
  process.exit(1);
};

const verification = await readAndVerifyBackup(path.resolve(backupPath)).catch((error) => {
  fail(`lecture/parsing impossible: ${error.message}`);
});

if (!verification.ok) fail(verification.failures.join(' ; '));

const documents = verification.tables.get('mobile_documents')?.records || [];
const chunks = verification.tables.get('mobile_document_chunks')?.records || [];

const docsByUuid = new Map();
for (const doc of documents) {
  const uuid = field(doc, 'uuid_source');
  if (uuid) docsByUuid.set(uuid, doc);
}

const grouped = new Map();
for (const chunk of chunks) {
  const uuid = field(chunk, 'document_uuid_source');
  if (!uuid) continue;
  const entry = grouped.get(uuid) || {
    uuid,
    chunkCount: 0,
    estimatedBytes: 0,
    maxChunkIndex: -1,
    lastUpdate: '',
  };
  entry.chunkCount += 1;
  entry.estimatedBytes += estimateBytesFromBase64(chunk.chunk_base64);
  entry.maxChunkIndex = Math.max(entry.maxChunkIndex, Number(chunk.chunk_index) || 0);
  const updatedAt = field(chunk, 'updated_at');
  if (updatedAt > entry.lastUpdate) entry.lastUpdate = updatedAt;
  grouped.set(uuid, entry);
}

const rows = [...grouped.values()].map((entry) => {
  const meta = docsByUuid.get(entry.uuid) || null;
  const isTemporaryUpload = entry.uuid.startsWith('upload_');
  return {
    ...entry,
    isTemporaryUpload,
    hasMetadata: Boolean(meta),
    fileName: field(meta, 'nom_fichier') || field(meta, 'titre') || '',
    beneficiary: field(meta, 'beneficiaire_nom_complet'),
    mimeType: field(meta, 'mime_type'),
    syncedAt: field(meta, 'synced_at') || field(meta, 'updated_at'),
  };
});

const finalizedRows = rows.filter((row) => !row.isTemporaryUpload);
const temporaryUploads = rows.filter((row) => row.isTemporaryUpload);
const orphanRows = finalizedRows.filter((row) => !row.hasMetadata);
const bytesTotal = finalizedRows.reduce((sum, row) => sum + row.estimatedBytes, 0);
const chunksTotal = finalizedRows.reduce((sum, row) => sum + row.chunkCount, 0);
const largest = [...finalizedRows]
  .sort((a, b) => b.estimatedBytes - a.estimatedBytes)
  .slice(0, topLimit);

const suggestedObjectRows = finalizedRows.map((row) => {
  const safeBeneficiary = row.beneficiary || 'beneficiaire-inconnu';
  const safeFileName = row.fileName || `${row.uuid}.bin`;
  return {
    uuid: row.uuid,
    objectKey: `documents/${safeBeneficiary}/${row.uuid}/${safeFileName}`,
    bytes: row.estimatedBytes,
    mimeType: row.mimeType || 'application/octet-stream',
  };
});

const summary = {
  backup: path.resolve(backupPath),
  sourceBaseId: verification.summary.baseId,
  createdAt: verification.summary.createdAt,
  documentsWithChunks: finalizedRows.length,
  mobileDocumentRows: documents.length,
  chunks: chunksTotal,
  estimatedBinaryBytes: bytesTotal,
  estimatedBinarySize: formatBytes(bytesTotal),
  temporaryUploads: temporaryUploads.length,
  orphanChunkGroups: orphanRows.length,
  suggestedObjectRows: suggestedObjectRows.length,
};

console.log('[object-storage-readiness] OK - aucun changement effectué');
console.log(JSON.stringify(summary, null, 2));

if (orphanRows.length > 0) {
  console.log('\nPoints à corriger avant migration :');
  for (const row of orphanRows.slice(0, topLimit)) {
    console.log(`- Chunks sans metadata : ${row.uuid} (${row.chunkCount} chunks, ${formatBytes(row.estimatedBytes)})`);
  }
}

if (temporaryUploads.length > 0) {
  console.log('\nUploads temporaires présents :');
  for (const row of temporaryUploads.slice(0, topLimit)) {
    console.log(`- ${row.uuid} (${row.chunkCount} chunks, dernier update ${row.lastUpdate || 'inconnu'})`);
  }
}

console.log('\nPlus gros fichiers à migrer :');
for (const row of largest) {
  const name = row.fileName || '(nom absent)';
  const who = row.beneficiary || 'bénéficiaire inconnu';
  console.log(`- ${formatBytes(row.estimatedBytes)} | ${name} | ${who} | ${row.mimeType || 'mime inconnu'}`);
}

console.log('\nColonnes à prévoir dans `mobile_documents` avant bascule stockage objet :');
console.log('- storage_provider');
console.log('- object_key');
console.log('- object_size_bytes');
console.log('- object_sha256');
console.log('- object_synced_at');
console.log('- legacy_nocodb_chunks_kept');
