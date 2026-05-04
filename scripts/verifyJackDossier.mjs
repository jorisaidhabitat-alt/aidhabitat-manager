#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from 'dotenv';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '.env.local') });
const { callNocoTool, closeMcpClient } = await import(
  path.resolve(__dirname, '..', 'server', 'nocodbMcpClient.mjs')
);
try {
  // Vérifie nature_accompagnement préservée sur dossier Id=1
  const dossiers = await callNocoTool('queryRecords', {
    tableId: 'mez74y7ndoej30p', page: 1, pageSize: 100,
    fields: ['uuid_source', 'beneficiaires_id', 'status', 'nature_accompagnement', 'visit_date', 'ergo_id'],
  });
  const jackDossier = dossiers.records.find((r) => Number(r.id) === 1);
  console.log('Jack dossier (Id=1) :');
  console.log(JSON.stringify(jackDossier, null, 2));
  // Vérifie logement vidé Id=17
  const logements = await callNocoTool('queryRecords', {
    tableId: 'mgdpvdrnzyy6n4k', page: 1, pageSize: 100,
    fields: ['type_de_logement', 'annee_construction', 'surface_habitable', 'chauffage', 'acces_facile_rue'],
  });
  const jackLog = logements.records.find((r) => Number(r.id) === 17);
  console.log('\nJack logement (Id=17) :');
  console.log(JSON.stringify(jackLog, null, 2));
} catch (err) { console.error(err); process.exitCode = 1; }
finally { await closeMcpClient(); }
