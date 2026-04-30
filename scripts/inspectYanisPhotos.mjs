#!/usr/bin/env node
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from 'dotenv';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
dotenv.config({ path: path.resolve(__dirname, '..', '.env.local') });

const { callNocoTool, closeMcpClient } = await import(
  path.resolve(__dirname, '..', 'server', 'nocodbMcpClient.mjs')
);

try {
  const records = [];
  let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId: 'mfeu4lijbge4opz',
      page,
      pageSize: 100,
    });
    const batch = payload?.records || [];
    records.push(...batch);
    if (!payload?.next || batch.length === 0) break;
    page += 1;
  }
  console.log(`Total mobile_visit_photos: ${records.length}`);
  // Group by beneficiaire_id
  const byBenef = new Map();
  for (const r of records) {
    const benef = r.fields?.beneficiaire_id || '(null)';
    const nomComplet = r.fields?.beneficiaire_nom_complet || '(null)';
    const key = `${benef} | ${nomComplet}`;
    byBenef.set(key, (byBenef.get(key) || 0) + 1);
  }
  console.log('\nBy beneficiaire_id | nom_complet :');
  for (const [k, v] of byBenef.entries()) {
    console.log(`  ${v}x  ${k}`);
  }
} catch (err) {
  console.error(err);
} finally {
  await closeMcpClient();
}
