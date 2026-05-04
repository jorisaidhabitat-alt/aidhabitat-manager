#!/usr/bin/env node
/**
 * Wipe complet des données « relevé de visite » du dossier DIRECT Jack
 * (beneficiaire Id=3) sur NocoDB.
 *
 * Conserve EXPLICITEMENT, par demande utilisateur 2026-05-04 :
 *   - adresse complète (adresse_logement, code_postal_libre, ville_libre,
 *     code_postal, communes_id, commune)
 *   - revenu fiscal de référence (revenu_fiscal_reference)
 *   - type d'accompagnement (nature_accompagnement sur dossiers)
 *   - catégorie de revenu (categorie_revenu_calculee + nombre_personnes
 *     car ils sont liés au calcul de la catégorie)
 *
 * Conserve aussi : nom, prénom, date de naissance (identification de la
 * personne).
 *
 * Vide / supprime tout le reste.
 *
 * Usage : `node scripts/wipeJackVisitReport.mjs`
 */

import process from 'node:process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import dotenv from 'dotenv';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '.env.local') });

const { callNocoTool, closeMcpClient } = await import(
  path.resolve(__dirname, '..', 'server', 'nocodbMcpClient.mjs')
);

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

const JACK = {
  beneficiaireId: 3,
  dossierId: 1,
  dossierUuid: '99e6b6ed-1ba4-4386-8d4c-0bccb36e7dd4',
  logementId: 17,
  beneficiaireAppId: 'nocodb-beneficiaire-3',
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const asArray = (v) => (Array.isArray(v) ? v : []);

const queryAll = async (tableId, options = {}) => {
  const records = []; let page = 1;
  while (true) {
    const payload = await callNocoTool('queryRecords', {
      tableId, page, pageSize: 100, ...options,
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
    tableId, records: [{ id: String(id), fields }],
  });
};

const deleteRecords = async (tableId, recordIds) => {
  if (!recordIds.length) return;
  await callNocoTool('deleteRecords', {
    tableId, records: recordIds.map((id) => ({ id: String(id) })),
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

const matchesBenef = (record, numericId) =>
  Number(field(record, 'beneficiaires_id')) === numericId ||
  Number(field(record, 'beneficiaire_id')) === numericId;
const matchesDossier = (record, numericId) =>
  Number(field(record, 'dossiers_id')) === numericId ||
  Number(field(record, 'dossier_id')) === numericId;

// ---------------------------------------------------------------------------
// Wipes
// ---------------------------------------------------------------------------
async function wipeLogement() {
  console.log(`[logements] reset Id=${JACK.logementId}`);
  await updateRecord(TABLES.logements, JACK.logementId, {
    // Linked records : on dé-link via la colonne *_id (numérique) à null.
    // Mettre `type_de_logement: null` ne désalie PAS le link côté NocoDB.
    type_de_logement_id: null,
    porte_de_garage_id: null,
    portail_id1: null,
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
  console.log(
    `[dossiers] reset Id=${JACK.dossierId} (préserve nature_accompagnement)`,
  );
  // Préserve : nature_accompagnement (= type d'accompagnement)
  await updateRecord(TABLES.dossiers, JACK.dossierId, {
    status: null,
    ergo_id: null,
    visit_date: null,
    compte_anah: null,
    envoi_rapport: null,
    personnes_presentes_visite: null,
    // nature_accompagnement: NON TOUCHÉ
  });
}

async function wipeBeneficiaireVisitFields() {
  console.log(
    `[beneficiaires] reset visit fields Id=${JACK.beneficiaireId} ` +
      `(préserve adresse, RFR, catégorie_revenu, nombre_personnes)`,
  );
  // Préserve : adresse_logement, code_postal_libre, ville_libre,
  //   code_postal, communes_id, commune, revenu_fiscal_reference,
  //   categorie_revenu_calculee, nombre_personnes,
  //   nom, prenom, date_naissance_*, telephone, mail
  await updateRecord(TABLES.beneficiaires, JACK.beneficiaireId, {
    date_visite: null,
    situation_proprietaire: null,
    statut_occupation: null,
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
    prenom_occupant_2: null,
    nom_occupant_2: null,
  });
}

async function deleteRowsLinkedToBeneficiaire(label, tableId) {
  const records = await queryAll(tableId);
  const matching = records.filter((r) => matchesBenef(r, JACK.beneficiaireId));
  console.log(`[${label}] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(tableId, matching.map((r) => r.id));
}

async function deleteRowsLinkedToDossier(label, tableId) {
  const records = await queryAll(tableId);
  const matching = records.filter((r) => matchesDossier(r, JACK.dossierId));
  console.log(`[${label}] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(tableId, matching.map((r) => r.id));
}

async function deleteVisitPhotos() {
  const records = await queryAll(TABLES.visitPhotos);
  const matching = records.filter(
    (r) =>
      String(field(r, 'beneficiaire_id') || '') === JACK.beneficiaireAppId
      || Number(field(r, 'beneficiaires_id')) === JACK.beneficiaireId,
  );
  console.log(`[mobile_visit_photos] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(TABLES.visitPhotos, matching.map((r) => r.id));
}

async function deleteMobileDocumentsForDossier() {
  const tablesList = await callNocoTool('getTablesList');
  const docsTable = asArray(tablesList).find(
    (t) => String(t.title).trim().toLowerCase() === 'mobile_documents',
  );
  if (!docsTable) {
    console.warn('[mobile_documents] table introuvable — skip');
    return;
  }
  const records = await queryAll(String(docsTable.id));
  const matching = records.filter((r) => {
    return (
      Number(field(r, 'dossiers_id')) === JACK.dossierId
      || String(field(r, 'dossier_id') ?? '') === JACK.dossierUuid
      || String(field(r, 'patient_id') ?? '') === JACK.beneficiaireAppId
      || Number(field(r, 'beneficiaires_id')) === JACK.beneficiaireId
    );
  });
  console.log(`[mobile_documents] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(String(docsTable.id), matching.map((r) => r.id));
}

async function deleteVisitRecommendations() {
  const tablesList = await callNocoTool('getTablesList');
  const recoTable = asArray(tablesList).find(
    (t) => ['visit_recommendations', 'visit recommendations'].includes(
      String(t.title).trim().toLowerCase(),
    ),
  );
  if (!recoTable) {
    console.warn('[visit_recommendations] table introuvable — skip');
    return;
  }
  const records = await queryAll(String(recoTable.id));
  const matching = records.filter(
    (r) =>
      Number(field(r, 'dossiers_id')) === JACK.dossierId
      || String(field(r, 'dossier_id') ?? '') === JACK.dossierUuid,
  );
  console.log(`[visit_recommendations] ${matching.length} rows trouvées → suppression`);
  await deleteRecords(String(recoTable.id), matching.map((r) => r.id));
}

async function main() {
  console.log(`\n=== Wipe relevé de visite — DIRECT Jack (Id=${JACK.beneficiaireId}) ===\n`);
  await wipeLogement();
  await deleteRowsLinkedToBeneficiaire('contexte_de_vie', TABLES.contexteDeVie);
  await deleteRowsLinkedToBeneficiaire('informations_administratives', TABLES.informationsAdministratives);
  await deleteRowsLinkedToDossier('diagnostic_sanitaires', TABLES.diagnosticSanitaires);
  await deleteRowsLinkedToDossier('mesures_anthropometriques', TABLES.mesuresAnthropometriques);
  await deleteRowsLinkedToDossier('observations', TABLES.observations);
  await deleteVisitPhotos();
  await deleteMobileDocumentsForDossier();
  await deleteVisitRecommendations();
  await wipeDossier();
  await wipeBeneficiaireVisitFields();
  console.log('\n=== Wipe terminé ===');
  console.log('Conservé : adresse complète, RFR, type accompagnement, ' +
    'catégorie revenu (+ nombre_personnes), nom/prénom/contacts.');
  console.log('\nCôté iPad : logout + login (et effacer données du PWA si ' +
    'besoin) pour re-fetch SQLite depuis NocoDB propre.');
}

try { await main(); }
catch (err) { console.error('Erreur fatale :', err); process.exitCode = 1; }
finally { await closeMcpClient(); }
