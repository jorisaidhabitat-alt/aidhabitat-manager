#!/usr/bin/env node
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
  { tableId: 'mqwqqzsfopejd5q', label: 'situationProprietaire', fields: ['libelle'] },
  { tableId: 'm09p3a4xns7wqdg', label: 'dependancesParticulieres', fields: ['libelle'] },
  { tableId: 'my9em2miybwiwr0', label: 'porteDeGarage', fields: ['libelle'] },
  { tableId: 'm8e1g1ab3a4ubtx', label: 'portail', fields: ['libelle'] },
  { tableId: 'mtg6pgm9t274ya9', label: 'baremesAnah', fields: ['libelle', 'nombre_personnes', 'revenu_tres_modeste', 'revenu_modeste', 'revenu_intermediaire', 'revenu_haut', 'annee_plafond'] },
  { tableId: 'mww8mr4ngp3nbxh', label: 'ergotherapeutes', fields: ['uuid_source', 'nom', 'prenom', 'email', 'user_id', 'nom_etablissement_id', 'User', 'etablissements_id', 'etablissement', 'mot_de_passe'] },
  { tableId: 'mw1ajdw6ictkdzf', label: 'etablissements', fields: ['nom'] },
  { tableId: 'mtwhx481kcfn19h', label: 'communes', fields: ['nom', 'code_postal', 'epci_id1', 'epci'] },
  { tableId: 'mntevbq41mk4y6h', label: 'epci', fields: ['nom'] },
];

for (const test of tests) {
  try {
    const r = await callNocoTool('queryRecords', {
      tableId: test.tableId,
      page: 1,
      pageSize: 1,
      fields: test.fields,
    });
    const got = (r?.records || []).length;
    console.log(`✓ ${test.label}  (${got} record sample)`);
  } catch (err) {
    console.log(`✗ ${test.label}  → ${err.message}`);
  }
}
await closeMcpClient();
