#!/usr/bin/env node
/**
 * Wipe complet des données « relevé de visite » du dossier RETOUR Yanis
 * (beneficiaire Id=5) sur NocoDB.
 *
 * Conserve : la fiche bénéficiaire (nom, prénom, adresse, contacts) et
 * le dossier (Id=10) eux-mêmes — ces deux entités sont juste vidées de
 * leurs champs visite, pas supprimées.
 *
 * Supprime / vide :
 *   - logements (Id=20) : tous les champs accessibilité / équipements
 *     reset à leurs valeurs par défaut
 *   - contexte_de_vie : row supprimée
 *   - informations_administratives : row supprimée
 *   - diagnostic_sanitaires : row supprimée
 *   - mesures_anthropometriques : row supprimée
 *   - observations : row supprimée
 *   - mobile_visit_photos : toutes les photos liées au beneficiaire
 *   - mobile_documents : tous les rapports PDF générés liés au dossier
 *   - visit_recommendations (table dynamique par titre) : toutes les
 *     préconisations liées au dossier
 *   - dossiers (Id=10) : champs de visite vidés (status, visit_date,
 *     ergo_id, etc.) sauf le lien beneficiaire_id et l'uuid
 *   - beneficiaires (Id=5) : champs de visite vidés (date_visite,
 *     dependance_*, mdph_*, beneficiaire_apa, etc.) sauf
 *     identification (nom, prénom, adresse)
 *
 * Usage : `node scripts/wipeYanisVisitReport.mjs`
 *
 * IMPORTANT : ce script bypasse le sync engine Flutter — la base SQLite
 * locale de l'iPad doit être réinitialisée séparément (logout/login ou
 * effacement des données du PWA) pour ne pas re-pousser les données
 * locales préservées vers NocoDB après le wipe distant.
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

// ---------------------------------------------------------------------------
// Tables (alignées sur server/index.mjs::TABLES)
// ---------------------------------------------------------------------------
const TABLES = {
  beneficiaires: 'muvp56d5i9z2qbe',
  logements: 'mgdpvdrnzyy6n4k',
  dossiers: 'mez74y7ndoej30p',
  contexteDeVie: 'mjyj2lz4wfs5pd5',
  informationsAdministratives: 'mv2hgaqj3u5ittg',
  diagnosticSanitaires: 'mdukulxcd18ae3o',
  mesuresAnthropometriques: 'mbaj91z97utreco',
  observations: 'mbkuomk0aazes1c',
  visitPhotos: 'mfeu4lijbge4opz',
};

const YANIS = {
  beneficiaireId: 5,
  dossierId: 10,
  dossierUuid: '207edb39-1862-4b1c-a33c-77aa8edddc19',
  logementId: 20,
  beneficiaireAppId: 'nocodb-beneficiaire-5',
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const asArray = (v) => (Array.isArray(v) ? v : []);

const queryAll = async (tableId, options = {}) => {
  const records = [];
  let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId,
      page,
      pageSize: 100,
      ...options,
    });
    const batch = asArray(payload?.records);
    records.push(...batch);
    if (!payload?.next || batch.length === 0) break;
    page += 1;
  }
  return records;
};

const updateRecord = async (tableId, id, fields) => {
  await callNocoTool('updateRecords', {
    tableId,
    records: [{ id: String(id), fields }],
  });
};

const deleteRecords = async (tableId, recordIds) => {
  if (!recordIds.length) return;
  await callNocoTool('deleteRecords', {
    tableId,
    records: recordIds.map((id) => ({ id: String(id) })),
  });
};

const field = (record, fieldName) => {
  if (!record) return null;
  if (record.fields && Object.prototype.hasOwnProperty.call(record.fields, fieldName)) {
    return record.fields[fieldName];
  }
  if (Object.prototype.hasOwnProperty.call(record, fieldName)) {
    return record[fieldName];
  }
  return null;
};

const matchesBeneficiaire = (record, numericId) =>
  Number(field(record, 'beneficiaires_id')) === numericId ||
  Number(field(record, 'beneficiaire_id')) === numericId;

const matchesDossier = (record, numericId) =>
  Number(field(record, 'dossiers_id')) === numericId ||
  Number(field(record, 'dossier_id')) === numericId;

// ---------------------------------------------------------------------------
// Étapes de wipe
// ---------------------------------------------------------------------------

async function wipeLogement() {
  console.log(`[logements] reset Id=${YANIS.logementId}`);
  await updateRecord(TABLES.logements, YANIS.logementId, {
    type_de_logement: null,
    annee_construction: null,
    annee_habitation: null,
    surface_habitable: null,
    nombre_niveaux: 0,
    sous_sol: false,
    description_sous_sol: null,
    rdc: false,
    description_rdc: null,
    etage: false,
    second_etage: false,
    third_etage: false,
    description_etage: null,
    garage: false,
    veranda: false,
    balcon: false,
    terrasse: false,
    jardin: false,
    chauffage: null,
    radiateurs_electrique: false,
    chaudiere_gaz: false,
    chaudiere_fioul: false,
    pompe_a_chaleur: false,
    chaudiere_collective: false,
    cheminee_pole_bois: false,
    poele_granules: false,
    autre_chauffage: false,
    volets_roulants_manuels_localisation: null,
    volets_roulants_manuels_entier: false,
    volets_roulants_electriques_localisation: null,
    volets_roulants_electriques_entier: false,
    volets_persiennes_localisation: null,
    volets_persiennes_entier: false,
    cheminement_escalier_exterieur: false,
    cheminement_escalier_interieur: false,
    cheminement_pente_douce: false,
    cheminement_plat: false,
    cheminement_quelques_marches: false,
    cheminement_par_arriere: false,
    cheminement_seuil_porte: false,
    difficultes_circulation_interieure: null,
    acces_facile_rue: null,
    commentaire: null,
    observation_accessibilite: null,
  });
}

async function wipeDossier() {
  console.log(`[dossiers] reset Id=${YANIS.dossierId}`);
  await updateRecord(TABLES.dossiers, YANIS.dossierId, {
    status: null,
    ergo_id: null,
    visit_date: null,
    compte_anah: null,
    nature_accompagnement: null,
    envoi_rapport: null,
    personnes_presentes_visite: null,
  });
}

async function wipeBeneficiaireVisitFields() {
  console.log(`[beneficiaires] reset visit fields Id=${YANIS.beneficiaireId}`);
  await updateRecord(TABLES.beneficiaires, YANIS.beneficiaireId, {
    date_visite: null,
    situation_proprietaire: null,
    statut_occupation: null,
    nombre_personnes: null,
    categorie_revenu_calculee: null,
    revenu_fiscal_reference: null,
    beneficiaire_apa: null,
    reconnaissance_invalidite_mdph: null,
    'reconnaissance_invalidité_mdph_txt': null,
    aide_a_domicile: null,
    aide_a_domicile_txt: null,
    dependance_particuliere: null,
    dependance_particuliere_txt: null,
    personne_confiance: null,
    telephone_personne_confiance: null,
    mail_personne_confiance: null,
    occupants_json: null,
    caisse_retraite_principale: null,
    caisse_retraite_secondaire: null,
  });
}

async function deleteRowsLinkedToBeneficiaire(label, tableId) {
  const records = await queryAll(tableId);
  const matching = records.filter((r) =>
    matchesBeneficiaire(r, YANIS.beneficiaireId),
  );
  console.log(`[${label}] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(
    tableId,
    matching.map((r) => r.id),
  );
}

async function deleteRowsLinkedToDossier(label, tableId) {
  const records = await queryAll(tableId);
  const matching = records.filter((r) => matchesDossier(r, YANIS.dossierId));
  console.log(`[${label}] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(
    tableId,
    matching.map((r) => r.id),
  );
}

async function deleteVisitPhotos() {
  const records = await queryAll(TABLES.visitPhotos);
  const matching = records.filter(
    (r) =>
      String(field(r, 'beneficiaire_id') || '') === YANIS.beneficiaireAppId ||
      String(field(r, 'beneficiaire_id') || '') === String(YANIS.beneficiaireId),
  );
  console.log(`[mobile_visit_photos] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(
    TABLES.visitPhotos,
    matching.map((r) => r.id),
  );
}

async function deleteMobileDocumentsForDossier() {
  // mobile_documents : table résolue par nom (pas dans TABLES)
  const tablesList = await callNocoTool('getTablesList');
  const tables = asArray(tablesList);
  const docsTable = tables.find(
    (t) => String(t.title).trim().toLowerCase() === 'mobile_documents',
  );
  if (!docsTable) {
    console.warn('[mobile_documents] table introuvable — skip');
    return;
  }
  const records = await queryAll(String(docsTable.id));
  const beneficiaireAppId = YANIS.beneficiaireAppId;
  const matching = records.filter((r) => {
    const linkedDossierNum = Number(field(r, 'dossiers_id'));
    const linkedDossierUuid = String(field(r, 'dossier_id') ?? '');
    const linkedPatient = String(field(r, 'patient_id') ?? '');
    return (
      linkedDossierNum === YANIS.dossierId ||
      linkedDossierUuid === YANIS.dossierUuid ||
      linkedPatient === beneficiaireAppId ||
      Number(field(r, 'beneficiaires_id')) === YANIS.beneficiaireId
    );
  });
  console.log(`[mobile_documents] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(
    String(docsTable.id),
    matching.map((r) => r.id),
  );
}

async function deleteVisitRecommendations() {
  const tablesList = await callNocoTool('getTablesList');
  const tables = asArray(tablesList);
  const recoTable = tables.find(
    (t) =>
      String(t.title).trim().toLowerCase() === 'visit_recommendations' ||
      String(t.title).trim().toLowerCase() === 'visit recommendations',
  );
  if (!recoTable) {
    console.warn('[visit_recommendations] table introuvable — skip');
    return;
  }
  const records = await queryAll(String(recoTable.id));
  const dossierId = String(YANIS.dossierId);
  const matching = records.filter(
    (r) => String(field(r, 'dossier_id') ?? '') === dossierId,
  );
  console.log(`[visit_recommendations] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(
    String(recoTable.id),
    matching.map((r) => r.id),
  );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  console.log(
    `\n=== Wipe relevé de visite — Yanis RETOUR (Id=${YANIS.beneficiaireId}) ===\n`,
  );

  await wipeLogement();
  await deleteRowsLinkedToBeneficiaire('contexte_de_vie', TABLES.contexteDeVie);
  await deleteRowsLinkedToBeneficiaire(
    'informations_administratives',
    TABLES.informationsAdministratives,
  );
  await deleteRowsLinkedToDossier(
    'diagnostic_sanitaires',
    TABLES.diagnosticSanitaires,
  );
  await deleteRowsLinkedToDossier(
    'mesures_anthropometriques',
    TABLES.mesuresAnthropometriques,
  );
  await deleteRowsLinkedToDossier('observations', TABLES.observations);
  await deleteVisitPhotos();
  await deleteMobileDocumentsForDossier();
  await deleteVisitRecommendations();
  await wipeDossier();
  await wipeBeneficiaireVisitFields();

  console.log('\n=== Wipe terminé ===\n');
  console.log(
    'Pour propre test côté iPad : logout + login (ou effacer les ' +
      'données du PWA) afin que la base SQLite locale soit re-fetchée ' +
      'depuis NocoDB et ne re-pousse pas les anciennes valeurs.',
  );
}

try {
  await main();
} catch (err) {
  console.error('Erreur fatale :', err);
  process.exitCode = 1;
} finally {
  await closeMcpClient();
}
