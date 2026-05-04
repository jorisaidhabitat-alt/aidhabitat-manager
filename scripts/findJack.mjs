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
  const payload = await callNocoTool('queryRecords', {
    tableId: 'muvp56d5i9z2qbe',
    page: 1,
    pageSize: 100,
    fields: ['nom', 'prenom', 'adresse_logement', 'code_postal_libre', 'ville_libre',
             'revenu_fiscal_reference', 'categorie_revenu_calculee', 'nombre_personnes'],
  });
  for (const r of payload.records) {
    console.log(`Id=${r.id} | nom=${r.fields?.nom} | prenom=${r.fields?.prenom}`);
    console.log(`  adresse: ${r.fields?.adresse_logement} | ${r.fields?.code_postal_libre} ${r.fields?.ville_libre}`);
    console.log(`  rfr=${r.fields?.revenu_fiscal_reference} | cat=${r.fields?.categorie_revenu_calculee} | personnes=${r.fields?.nombre_personnes}`);
    console.log('');
  }
} catch (err) { console.error(err); process.exitCode = 1; }
finally { await closeMcpClient(); }
