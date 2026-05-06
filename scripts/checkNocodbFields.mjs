#!/usr/bin/env node
/**
 * Diagnostic : vérifie que les champs requis par le serveur Express
 * existent bien dans NocoDB. Si une query échoue avec ERR_FIELD_NOT_FOUND,
 * c'est qu'un nom de colonne du code ne matche pas le schéma actuel.
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

const tests = [
  {
    label: 'baremesAnah (used by /api/references)',
    tableId: 'mtg6pgm9t274ya9',
    fields: [
      'libelle',
      'nombre_personnes',
      'revenu_tres_modeste',
      'revenu_modeste',
      'revenu_intermediaire',
      'revenu_haut',
      'annee_plafond',
    ],
  },
  {
    label: 'caissesRetraiteComplementaires (used by /api/retirement-funds)',
    tableId: 'm067j5k5a03beog',
    fields: [
      'nom',
      'numero_telephone_contact',
      'aide_complementaire',
      'a_une_aide_specifique',
    ],
  },
];

for (const test of tests) {
  console.log(`\n=== ${test.label} ===`);
  for (const f of test.fields) {
    try {
      await callNocoTool('queryRecords', {
        tableId: test.tableId,
        page: 1,
        pageSize: 1,
        fields: [f],
      });
      console.log(`  ✓ ${f}`);
    } catch (err) {
      console.log(`  ✗ ${f}  → ${err.message}`);
    }
  }
}

await closeMcpClient();
