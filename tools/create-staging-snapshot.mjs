#!/usr/bin/env node
// Crée un snapshot NocoDB léger pour staging à partir d'un backup vérifié.
//
// Aucun appel réseau, aucune écriture NocoDB. Par défaut les informations
// personnelles des bénéficiaires sélectionnés sont anonymisées.

import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { gzipSync } from 'node:zlib';
import { readAndVerifyBackup } from './nocodbBackupLib.mjs';

const backupPath = process.argv[2];
const outputPath = process.argv[3] || 'tmp/staging-snapshot.json.gz';
const beneficiaryLimit = Math.min(10, Math.max(1, Number(process.env.STAGING_BENEFICIARY_LIMIT) || 3));
const keepRealPersonalData = process.env.STAGING_KEEP_REAL_PERSONAL_DATA === '1';

if (!backupPath) {
  console.error('Usage: node tools/create-staging-snapshot.mjs <backup.json.gz|backup.json> [output.json.gz]');
  process.exit(1);
}

const value = (record, key) => (record?.[key] == null ? '' : String(record[key]).trim());
const lower = (input) => String(input || '').trim().toLowerCase();
const hasOwn = (record, key) => Object.prototype.hasOwnProperty.call(record || {}, key);

const REFERENCE_TABLES = new Set([
  'communes',
  'epci',
  'situation_proprietaire',
  'statut_occupation',
  'dependances_particulieres',
  'etablissements',
  '👷🏻‍♀️ ergotherapeutes',
  'caisses_de_retraite',
  'caisses_de_retraite_complementaires',
  'type_de_logement',
  'porte_de_garage',
  'portail',
  'baremes_anah',
  'wiki_tags',
  '📚 wiki',
]);

const ALWAYS_DROP_TABLES = new Set([]);

const PERSONAL_FIELD_PATTERNS = [
  /adresse/i,
  /mail/i,
  /telephone/i,
  /sécurite/i,
  /securite/i,
  /personne_confiance/i,
  /photo_logement/i,
  /^prenom_occupant/i,
  /^nom_occupant/i,
];

const sanitizeRecord = (tableName, record, indexByBenefId) => {
  if (keepRealPersonalData) return { ...record };
  const clone = { ...record };

  if (tableName === 'Beneficiaires') {
    const fake = indexByBenefId.get(String(record.Id)) || { n: 0 };
    clone.prenom = `Bénéficiaire ${fake.n}`;
    clone.nom = 'TEST';
    clone.nom_complet = `${clone.prenom} ${clone.nom}`;
    clone.ville_libre = value(record, 'ville_libre') || 'Ville test';
    clone.code_postal_libre = value(record, 'code_postal_libre') || '00000';
  }

  for (const key of Object.keys(clone)) {
    if (PERSONAL_FIELD_PATTERNS.some((pattern) => pattern.test(key))) {
      if (typeof clone[key] === 'boolean') continue;
      clone[key] = '';
    }
  }

  if (hasOwn(clone, 'occupants_json')) {
    clone.occupants_json = '[]';
  }

  for (const key of ['beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet', 'Bénéficiaire', 'dossier_libelle', 'nom_complet']) {
    if (!hasOwn(clone, key)) continue;
    const original = lower(clone[key]);
    const found = [...indexByBenefId.values()].find((info) => info.realNames.has(original));
    if (found) clone[key] = found.label;
  }

  for (const key of ['titre', 'nom_fichier', 'wiki_title', 'custom_title']) {
    if (!hasOwn(clone, key) || typeof clone[key] !== 'string') continue;
    let text = clone[key];
    for (const info of indexByBenefId.values()) {
      for (const realName of info.realNames) {
        if (!realName) continue;
        const escaped = realName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        text = text.replace(new RegExp(escaped, 'ig'), info.label);
      }
    }
    clone[key] = text;
  }

  if (clone.beneficiaire && typeof clone.beneficiaire === 'object') {
    const nested = { ...clone.beneficiaire };
    const found = [...indexByBenefId.values()].find((info) => info.realNames.has(lower(nested.nom_complet)));
    if (found) nested.nom_complet = found.label;
    clone.beneficiaire = nested;
  }

  return clone;
};

const verification = await readAndVerifyBackup(path.resolve(backupPath)).catch((error) => {
  console.error(`[staging-snapshot] ÉCHEC lecture/parsing: ${error.message}`);
  process.exit(1);
});

if (!verification.ok) {
  console.error(`[staging-snapshot] ÉCHEC backup invalide: ${verification.failures.join(' ; ')}`);
  process.exit(1);
}

const beneficiariesTable = verification.tables.get('Beneficiaires');
const dossiersTable = verification.tables.get('📁 dossiers');
if (!beneficiariesTable || !dossiersTable) {
  console.error('[staging-snapshot] Tables Beneficiaires ou dossiers absentes');
  process.exit(1);
}

const beneficiaryScore = new Map();
for (const beneficiary of beneficiariesTable.records) {
  beneficiaryScore.set(String(beneficiary.Id), {
    beneficiary,
    score: 0,
  });
}

const beneficiaryNames = new Map();
for (const beneficiary of beneficiariesTable.records) {
  const id = String(beneficiary.Id);
  const names = new Set([
    lower(beneficiary.nom_complet),
    lower(`${value(beneficiary, 'prenom')} ${value(beneficiary, 'nom')}`),
    lower(`${value(beneficiary, 'nom')} ${value(beneficiary, 'prenom')}`),
  ].filter(Boolean));
  beneficiaryNames.set(id, names);
}

const bump = (id, amount = 1) => {
  const entry = beneficiaryScore.get(String(id));
  if (entry) entry.score += amount;
};

for (const table of verification.tables.values()) {
  for (const record of table.records) {
    if (hasOwn(record, 'beneficiaires_id')) bump(value(record, 'beneficiaires_id'), 2);
    const fullName = lower(record.beneficiaire_nom_complet || record['Bénéficiaire'] || record.dossier_libelle || record.nom_complet);
    if (fullName) {
      for (const [id, names] of beneficiaryNames.entries()) {
        if (names.has(fullName)) bump(id, 1);
      }
    }
  }
}

const selectedBeneficiaries = [...beneficiaryScore.values()]
  .sort((a, b) => b.score - a.score || String(a.beneficiary.Id).localeCompare(String(b.beneficiary.Id)))
  .slice(0, beneficiaryLimit)
  .map((entry) => entry.beneficiary);

const selectedBeneficiaryIds = new Set(selectedBeneficiaries.map((record) => String(record.Id)));
const selectedNames = new Set();
const indexByBenefId = new Map();
selectedBeneficiaries.forEach((beneficiary, index) => {
  const id = String(beneficiary.Id);
  const realNames = beneficiaryNames.get(id) || new Set();
  for (const name of realNames) selectedNames.add(name);
  indexByBenefId.set(id, {
    n: index + 1,
    label: `Bénéficiaire ${index + 1} TEST`,
    realNames,
  });
});

const selectedDossiers = dossiersTable.records.filter((record) => {
  if (selectedBeneficiaryIds.has(value(record, 'beneficiaires_id'))) return true;
  const name = lower(record.nom_complet || record.dossier_libelle);
  return selectedNames.has(name);
});

const selectedDossierIds = new Set(selectedDossiers.map((record) => String(record.Id)));
const selectedDossierUuids = new Set(selectedDossiers.map((record) => value(record, 'uuid_source')).filter(Boolean));
const selectedPatientIds = new Set(selectedDossiers.map((record) => value(record, 'patient_id')).filter(Boolean));

const selectedDocUuids = new Set();
const shouldKeepRecord = (tableName, record) => {
  if (REFERENCE_TABLES.has(tableName)) return true;
  if (ALWAYS_DROP_TABLES.has(tableName)) return false;
  if (tableName === 'Beneficiaires') return selectedBeneficiaryIds.has(String(record.Id));
  if (tableName === '📁 dossiers') return selectedDossiers.includes(record);

  if (hasOwn(record, 'beneficiaires_id') && selectedBeneficiaryIds.has(value(record, 'beneficiaires_id'))) return true;
  if (hasOwn(record, 'dossiers_id') && selectedDossierIds.has(value(record, 'dossiers_id'))) return true;
  if (hasOwn(record, 'dossier_id') && selectedDossierUuids.has(value(record, 'dossier_id'))) return true;
  if (hasOwn(record, 'scope_id') && selectedDossierUuids.has(value(record, 'scope_id'))) return true;

  const beneficiaryId = value(record, 'beneficiaire_id');
  if (beneficiaryId) {
    if (selectedPatientIds.has(beneficiaryId)) return true;
    for (const id of selectedBeneficiaryIds) {
      if (beneficiaryId === id || beneficiaryId === `nocodb-beneficiaire-${id}`) return true;
    }
  }

  const names = [
    lower(record.beneficiaire_nom_complet),
    lower(record['Bénéficiaire']),
    lower(record.dossier_libelle),
    lower(record.nom_complet),
  ].filter(Boolean);
  return names.some((name) => selectedNames.has(name));
};

const mobileDocumentsTable = verification.backup.tables.find((table) => table.name === 'mobile_documents');
if (mobileDocumentsTable) {
  for (const record of mobileDocumentsTable.records) {
    if (shouldKeepRecord('mobile_documents', record)) {
      const uuid = value(record, 'uuid_source');
      if (uuid) selectedDocUuids.add(uuid);
    }
  }
}

const filteredTables = [];
for (const table of verification.backup.tables) {
  const tableName = table.name;
  let records = [];

  if (tableName === 'mobile_document_chunks') {
    records = table.records.filter((record) => selectedDocUuids.has(value(record, 'document_uuid_source')));
  } else {
    records = table.records.filter((record) => shouldKeepRecord(tableName, record));
  }

  filteredTables.push({
    ...table,
    records: records.map((record) => sanitizeRecord(tableName, record, indexByBenefId)),
  });
}

const snapshot = {
  ...verification.backup,
  version: verification.backup.version || 1,
  createdAt: new Date().toISOString(),
  sourceBackupCreatedAt: verification.backup.createdAt || null,
  sourceBaseId: verification.backup.baseId || null,
  baseId: `${verification.backup.baseId || 'unknown'}-staging-snapshot`,
  stagingSnapshot: {
    createdAt: new Date().toISOString(),
    beneficiaryLimit,
    personalData: keepRealPersonalData ? 'kept' : 'sanitized',
    selectedBeneficiaries: selectedBeneficiaries.map((record, index) => ({
      sourceId: record.Id,
      label: `Bénéficiaire ${index + 1} TEST`,
      score: beneficiaryScore.get(String(record.Id))?.score || 0,
    })),
  },
  tables: filteredTables,
};

await mkdir(path.dirname(path.resolve(outputPath)), { recursive: true });
const payload = Buffer.from(JSON.stringify(snapshot), 'utf8');
const finalBuffer = outputPath.endsWith('.gz') ? gzipSync(payload, { level: 9 }) : payload;
await writeFile(outputPath, finalBuffer);

const tableSummary = filteredTables
  .map((table) => ({ name: table.name, records: table.records.length }))
  .filter((table) => table.records > 0)
  .sort((a, b) => b.records - a.records);

console.log('[staging-snapshot] OK - aucun changement NocoDB effectué');
console.log(JSON.stringify({
  output: path.resolve(outputPath),
  personalData: keepRealPersonalData ? 'kept' : 'sanitized',
  beneficiaries: selectedBeneficiaries.length,
  dossiers: selectedDossiers.length,
  documentChunks: filteredTables.find((table) => table.name === 'mobile_document_chunks')?.records.length || 0,
  tablesWithRecords: tableSummary.length,
  bytes: finalBuffer.length,
}, null, 2));

console.log('\nTables incluses :');
for (const table of tableSummary) {
  console.log(`- ${table.name}: ${table.records}`);
}
