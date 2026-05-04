#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from 'dotenv';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '.env.local') });
const { callNocoTool, closeMcpClient } = await import(
  path.resolve(__dirname, '..', 'server', 'nocodbMcpClient.mjs')
);

async function queryAll(tableId, options = {}) {
  const records = []; let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', { tableId, page, pageSize: 100, ...options });
    const batch = payload?.records || [];
    records.push(...batch);
    if (!payload?.next || batch.length === 0) break;
    page += 1;
  }
  return records;
}

try {
  const TABLES = {
    dossiers: 'mez74y7ndoej30p',
    logements: 'mgdpvdrnzyy6n4k',
    contexteDeVie: 'mjyj2lz4wfs5pd5',
    informationsAdministratives: 'mv2hgaqj3u5ittg',
    diagnosticSanitaires: 'mdukulxcd18ae3o',
    mesuresAnthropometriques: 'mbaj91z97utreco',
    observations: 'mbkuomk0aazes1c',
    visitPhotos: 'mfeu4lijbge4opz',
  };
  const JACK_ID = 3;

  const dossiers = (await queryAll(TABLES.dossiers)).filter((r) => Number(r.fields?.beneficiaires_id) === JACK_ID);
  console.log('Dossiers :');
  for (const d of dossiers) {
    console.log(`  Id=${d.id} uuid=${d.fields?.uuid_source} status=${d.fields?.status} nature=${d.fields?.nature_accompagnement}`);
  }

  const logements = (await queryAll(TABLES.logements)).filter((r) => Number(r.fields?.beneficiaires_id) === JACK_ID);
  console.log(`\nLogements :`);
  for (const l of logements) {
    console.log(`  Id=${l.id} typology=${l.fields?.type_de_logement} year=${l.fields?.annee_construction}`);
  }

  for (const [label, tid] of Object.entries(TABLES)) {
    if (label === 'dossiers' || label === 'logements') continue;
    const all = await queryAll(tid);
    let matching;
    if (label === 'visitPhotos') {
      matching = all.filter((r) =>
        Number(r.fields?.beneficiaires_id) === JACK_ID
        || String(r.fields?.beneficiaire_id || '') === 'nocodb-beneficiaire-3');
    } else if (label === 'contexteDeVie' || label === 'informationsAdministratives') {
      matching = all.filter((r) => Number(r.fields?.beneficiaires_id) === JACK_ID);
    } else {
      // diagnosticSanitaires, mesuresAnthropometriques, observations : par dossier
      matching = all.filter((r) => dossiers.some((d) => Number(r.fields?.dossiers_id) === Number(d.id)));
    }
    console.log(`\n${label}: ${matching.length} matching rows`);
    for (const m of matching.slice(0, 3)) {
      console.log(`  Id=${m.id} dossiers_id=${m.fields?.dossiers_id} beneficiaires_id=${m.fields?.beneficiaires_id}`);
    }
  }
} catch (err) { console.error(err); process.exitCode = 1; }
finally { await closeMcpClient(); }
