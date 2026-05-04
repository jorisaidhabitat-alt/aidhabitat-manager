#!/usr/bin/env node
/**
 * Diagnostic : vérifie si les 3 tables mobile_* nécessaires au sync
 * (documents / document_chunks / note_pages) existent côté NocoDB.
 * Si l'une manque, le serveur retombe sur les JSON locaux dans
 * `server/data/` qui sont éphémères sur Vercel (`/tmp` perdu à chaque
 * cold-start).
 *
 * Usage : node scripts/checkMobileSyncTables.mjs
 */
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from 'dotenv';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, '..', '.env.local') });

const { callNocoTool, closeMcpClient } = await import(
  path.resolve(__dirname, '..', 'server', 'nocodbMcpClient.mjs')
);

const TABLE_NAMES = {
  documents: process.env.NOCODB_MOBILE_DOCUMENTS_TABLE_NAME || 'mobile_documents',
  documentChunks: process.env.NOCODB_MOBILE_DOCUMENT_CHUNKS_TABLE_NAME || 'mobile_document_chunks',
  notePages: process.env.NOCODB_MOBILE_NOTE_PAGES_TABLE_NAME || 'mobile_note_pages',
};

try {
  const tablesPayload = await callNocoTool('getTablesList');
  const tables = Array.isArray(tablesPayload) ? tablesPayload : [];
  const present = new Map(tables.map((t) => [String(t.title).trim().toLowerCase(), t]));

  console.log('\n=== Tables mobile_sync attendues ===\n');
  for (const [key, name] of Object.entries(TABLE_NAMES)) {
    const found = present.get(name.toLowerCase());
    if (found) {
      console.log(`  ✓ ${name}  (Id ${found.id})  — ${key}`);
    } else {
      console.log(`  ✗ ${name}  ABSENT  — ${key}`);
    }
  }

  console.log('\nSi une table est ABSENT, lance bootstrapNocodbMobileSchema.mjs');
  console.log('pour la créer (ou re-créer le schéma complet).\n');

  // Compte les rows note_pages si présent
  if (present.has(TABLE_NAMES.notePages.toLowerCase())) {
    const tableId = String(present.get(TABLE_NAMES.notePages.toLowerCase()).id);
    const records = [];
    let page = 1;
    while (true) {
      const payload = await callNocoTool('queryRecords', {
        tableId,
        page,
        pageSize: 100,
        fields: ['uuid_source'],
      });
      const batch = Array.isArray(payload?.records) ? payload.records : [];
      records.push(...batch);
      if (!payload?.next || batch.length === 0) break;
      page += 1;
    }
    console.log(`mobile_note_pages : ${records.length} row(s) côté NocoDB.`);
  }
} catch (err) {
  console.error('Erreur :', err.message);
  process.exitCode = 1;
} finally {
  await closeMcpClient();
}
