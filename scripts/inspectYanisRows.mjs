#!/usr/bin/env node
/**
 * Diagnostic ad-hoc : recense les rows liées à Yanis (Id=5) dans
 * les tables visite-report.
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

const TABLES = {
  contexteDeVie: 'mjyj2lz4wfs5pd5',
  informationsAdministratives: 'mv2hgaqj3u5ittg',
  diagnosticSanitaires: 'mdukulxcd18ae3o',
  mesuresAnthropometriques: 'mbaj91z97utreco',
  observations: 'mbkuomk0aazes1c',
  visitPhotos: 'mfeu4lijbge4opz',
  beneficiaires: 'muvp56d5i9z2qbe',
  logements: 'mgdpvdrnzyy6n4k',
  dossiers: 'mez74y7ndoej30p',
};

const YANIS_ID = 5;
const YANIS_DOSSIER_ID = 10;

async function queryAll(tableId, options = {}) {
  const records = [];
  let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId,
      page,
      pageSize: 100,
      ...options,
    });
    const batch = Array.isArray(payload?.records) ? payload.records : [];
    records.push(...batch);
    if (!payload?.next || batch.length === 0) break;
    page += 1;
  }
  return records;
}

async function inspect(label, tableId, filterFn) {
  const records = await queryAll(tableId);
  const matching = records.filter(filterFn);
  console.log(
    `\n=== ${label} (${tableId}) — ${matching.length} matching / ${records.length} total ===`,
  );
  for (const r of matching.slice(0, 3)) {
    const summary = {
      id: r.id,
      beneficiaires_id: r.fields?.beneficiaires_id,
      beneficiaire_id: r.fields?.beneficiaire_id,
      dossiers_id: r.fields?.dossiers_id,
      dossier_id: r.fields?.dossier_id,
      uuid_source: r.fields?.uuid_source,
    };
    console.log(JSON.stringify(summary));
  }
}

const byBenef = (id) => (r) =>
  Number(r.fields?.beneficiaires_id) === id ||
  Number(r.fields?.beneficiaire_id) === id;
const byDossier = (id) => (r) =>
  Number(r.fields?.dossiers_id) === id ||
  Number(r.fields?.dossier_id) === id;

try {
  await inspect('contexte_de_vie', TABLES.contexteDeVie, byBenef(YANIS_ID));
  await inspect(
    'informations_administratives',
    TABLES.informationsAdministratives,
    byBenef(YANIS_ID),
  );
  await inspect(
    'diagnostic_sanitaires',
    TABLES.diagnosticSanitaires,
    byDossier(YANIS_DOSSIER_ID),
  );
  await inspect(
    'mesures_anthropometriques',
    TABLES.mesuresAnthropometriques,
    byDossier(YANIS_DOSSIER_ID),
  );
  await inspect('observations', TABLES.observations, byDossier(YANIS_DOSSIER_ID));
  await inspect(
    'mobile_visit_photos',
    TABLES.visitPhotos,
    (r) =>
      String(r.fields?.beneficiaire_id || '') === 'nocodb-beneficiaire-5' ||
      Number(r.fields?.beneficiaire_id) === YANIS_ID,
  );
  // Yanis lui-même
  await inspect(
    'beneficiaires (Yanis)',
    TABLES.beneficiaires,
    (r) => Number(r.id) === YANIS_ID,
  );
  await inspect(
    'logements (Yanis)',
    TABLES.logements,
    byBenef(YANIS_ID),
  );
  await inspect(
    'dossiers (Yanis)',
    TABLES.dossiers,
    byBenef(YANIS_ID),
  );
} catch (err) {
  console.error('Erreur :', err);
  process.exitCode = 1;
} finally {
  await closeMcpClient();
}
