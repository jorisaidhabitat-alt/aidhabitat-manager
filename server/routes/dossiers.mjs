import express from 'express';
import crypto from 'node:crypto';
import { requireAuth } from '../middleware/auth.mjs';
import {
  getDossiersForApp,
  queryAll,
  updateRecord,
  createRecord,
  TABLES,
  FIELD_SETS,
  field,
  stringValue,
  nullableString,
  boolText,
  toNumber,
  parseSyntheticBeneficiaryId,
  syntheticBeneficiaryId,
  findByRecordId,
  resolveBeneficiaryRecord,
  latestByFieldValue,
  latestRecord,
  canAccessDossierRecord,
  mapBeneficiaryUpdatesToFields,
  loadBeneficiaryReferenceSets,
  resolveRequestedErgoLabel,
  ensureDossierRecord,
  upsertContexte,
  sanitizeUndefined,
  findByLabel,
  mobileSyncStore,
} from '../helpers.mjs';

const router = express.Router();

router.get('/api/dossiers', requireAuth, async (req, res, next) => {
  try {
    res.json(await getDossiersForApp(req.appUser));
  } catch (error) {
    next(error);
  }
});

router.post('/api/beneficiaires', requireAuth, async (req, res, next) => {
  try {
    const updates = req.body || {};
    const assignedErgoLabel = await resolveRequestedErgoLabel(req.appUser, updates.ergoId);
    const references = await loadBeneficiaryReferenceSets();
    const fields = mapBeneficiaryUpdatesToFields(updates, references);
    const relationFieldNames = [
      'situation_proprietaire_id1',
      'statut_occupation_id1',
      'dependances_particulieres_id',
      'caisses_de_retraite_id',
      'caisses_de_retraite_complementaires_id',
      'categorie_revenu_id1',
    ];
    const relationFields = Object.fromEntries(
      Object.entries(fields).filter(([key]) => relationFieldNames.includes(key))
    );
    const baseFields = Object.fromEntries(
      Object.entries(fields).filter(([key]) => !relationFieldNames.includes(key))
    );

    if (!fields.nom) {
      throw new Error('Le nom du bénéficiaire est obligatoire');
    }

    const created = await createRecord(TABLES.beneficiaires, baseFields);
    if (Object.keys(relationFields).length > 0) {
      await updateRecord(TABLES.beneficiaires, created.id, relationFields);
    }
    const createdDossier = await createRecord(TABLES.dossiers, {
      uuid_source: crypto.randomUUID(),
      patient_id: syntheticBeneficiaryId(created.id),
      beneficiaires_id: Number(created.id),
      ergo_id: assignedErgoLabel,
      status: 'À visiter',
      created_at: new Date().toISOString(),
    });
    res.status(201).json({
      success: true,
      error: null,
      data: {
        id: syntheticBeneficiaryId(created.id),
        dossierId: field(createdDossier, 'uuid_source') || String(createdDossier.id),
      },
    });
  } catch (error) {
    next(error);
  }
});

router.patch('/api/beneficiaires/:patientId', requireAuth, async (req, res, next) => {
  try {
    const patientId = req.params.patientId;
    const updates = req.body || {};
    const syntheticId = parseSyntheticBeneficiaryId(patientId);
    const [beneficiaires, references, dossiers] = await Promise.all([
      queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires }),
      loadBeneficiaryReferenceSets(),
      queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers }),
    ]);

    const beneficiaryRecord = syntheticId != null
      ? findByRecordId(beneficiaires, syntheticId)
      : resolveBeneficiaryRecord({
          beneficiaires,
          dossiers,
          appBeneficiaryId: patientId,
        });
    if (!beneficiaryRecord) {
      throw new Error(`Bénéficiaire ${patientId} introuvable`);
    }

    const dossierRecord = latestByFieldValue(dossiers, 'beneficiaires_id', beneficiaryRecord.id);
    if (dossierRecord && !canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce bénéficiaire' });
      return;
    }

    const fields = mapBeneficiaryUpdatesToFields(updates, references);

    await updateRecord(TABLES.beneficiaires, beneficiaryRecord.id, fields);
    const refreshedDossiers = await getDossiersForApp(req.appUser);
    const refreshedDossier = refreshedDossiers.find((dossier) => String(dossier?.patient?.id) === String(patientId));
    if (refreshedDossier?.patient) {
      await mobileSyncStore.syncNotePagesBeneficiaryMetadata(patientId, {
        patientFirstName: refreshedDossier.patient.firstName,
        patientLastName: refreshedDossier.patient.lastName,
        patientDisplayName: [refreshedDossier.patient.firstName, refreshedDossier.patient.lastName].filter(Boolean).join(' ').trim(),
        dossierLabel: refreshedDossier.label || [refreshedDossier.patient.firstName, refreshedDossier.patient.lastName].filter(Boolean).join(' ').trim(),
        dossierId: refreshedDossier.id,
      });
    }
    res.json({
      success: true,
      error: null,
      data: {},
    });
  } catch (error) {
    next(error);
  }
});

router.patch('/api/dossiers/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const updates = req.body || {};
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce dossier' });
      return;
    }
    const dossierUuid = field(dossierRecord, 'uuid_source');
    const beneficiaryUuid = field(dossierRecord, 'patient_id');

    const fields = sanitizeUndefined({
      compte_anah: updates.compteAnah,
      nature_accompagnement: updates.natureAccompagnement,
      envoi_rapport: updates.envoiRapport,
      personnes_presentes_visite: updates.personnesPresentesVisite,
      status: updates.status,
      visit_date: nullableString(updates.visitDate),
      ergo_id: Object.prototype.hasOwnProperty.call(updates, 'ergoId')
        ? nullableString(await resolveRequestedErgoLabel(req.appUser, updates.ergoId))
        : undefined,
    });

    if (Object.keys(fields).length > 0) {
      await updateRecord(TABLES.dossiers, dossierRecord.id, fields);
    }

    if (updates.medicalContext || updates.autonomy) {
      await upsertContexte(dossierUuid, beneficiaryUuid, updates.medicalContext, updates.autonomy, {
        dossierRecord,
        beneficiaryRecordId: field(dossierRecord, 'beneficiaires_id'),
      });
    }

    res.json({
      success: true,
      error: null,
      data: { id: dossierUuid },
    });
  } catch (error) {
    next(error);
  }
});

router.patch('/api/logements/by-beneficiary/:beneficiaryId', requireAuth, async (req, res, next) => {
  try {
    const beneficiaryId = req.params.beneficiaryId;
    const updates = req.body || {};
    const syntheticId = parseSyntheticBeneficiaryId(beneficiaryId);
    const [beneficiaires, logements, typeLogements, porteGarageRefs, portailRefs, dossiers] = await Promise.all([
      queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires }),
      queryAll(TABLES.logements, { fields: FIELD_SETS.logements }),
      queryAll(TABLES.typeDeLogement, { fields: FIELD_SETS.referencesLibelle }),
      queryAll(TABLES.porteDeGarage, { fields: FIELD_SETS.referencesLibelle }),
      queryAll(TABLES.portail, { fields: FIELD_SETS.referencesLibelle }),
      queryAll(TABLES.dossiers, { fields: FIELD_SETS.dossiers }),
    ]);

    const beneficiaryRecord = syntheticId != null
      ? findByRecordId(beneficiaires, syntheticId)
      : resolveBeneficiaryRecord({
          beneficiaires,
          dossiers,
          logements,
          appBeneficiaryId: beneficiaryId,
        });
    if (!beneficiaryRecord) {
      throw new Error(`Bénéficiaire ${beneficiaryId} introuvable pour le logement`);
    }

    const dossierRecord = latestByFieldValue(dossiers, 'beneficiaires_id', beneficiaryRecord.id);
    if (dossierRecord && !canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Accès interdit à ce logement' });
      return;
    }

    const existingHousing = latestRecord(
      logements.filter((record) => field(record, 'beneficiaire_id') === beneficiaryId || String(field(record, 'beneficiaires_id')) === String(beneficiaryRecord.id))
    );
    const typeLogement = findByLabel(typeLogements, updates.typology);
    const porteGarage = findByLabel(porteGarageRefs, updates.motorisationPorteGarage);
    const portail = findByLabel(portailRefs, updates.motorisationPortail);

    const fields = sanitizeUndefined({
      uuid_source: existingHousing ? undefined : crypto.randomUUID(),
      beneficiaire_id: beneficiaryId,
      beneficiaires_id: Number(beneficiaryRecord.id),
      annee_construction: nullableString(updates.yearConstruction),
      annee_habitation: nullableString(updates.yearHabitation),
      surface_habitable: nullableString(updates.surface),
      nombre_niveaux: updates.levels,
      sous_sol: boolText(updates.basement),
      description_sous_sol: nullableString(updates.basementDesc),
      rdc: boolText(updates.rdc),
      description_rdc: nullableString(updates.rdcDesc),
      etage: boolText(updates.floor),
      description_etage: nullableString(updates.floorDesc),
      garage: boolText(updates.garage),
      veranda: boolText(updates.veranda),
      balcon: boolText(updates.balcon),
      terrasse: boolText(updates.terrasse),
      jardin: boolText(updates.jardin),
      chauffage: boolText(updates.heatingMain),
      radiateurs_electrique: boolText(updates.heatingDetails?.electric),
      chaudiere_gaz: boolText(updates.heatingDetails?.gas),
      chaudiere_fioul: boolText(updates.heatingDetails?.oil),
      pompe_a_chaleur: boolText(updates.heatingDetails?.heatPump),
      chaudiere_collective: boolText(updates.heatingDetails?.collective),
      cheminee_pole_bois: boolText(updates.heatingDetails?.wood),
      poele_granules: boolText(updates.heatingDetails?.pellet),
      autre_chauffage: boolText(updates.heatingDetails?.other),
      volets_roulants_manuels_localisation: nullableString(updates.voletsRoulantsManuelsLocalisation),
      volets_roulants_manuels_entier: boolText(updates.voletsRoulantsManuelsEntier),
      volets_roulants_electriques_localisation: nullableString(updates.voletsRoulantsElectriquesLocalisation),
      volets_roulants_electriques_entier: boolText(updates.voletsRoulantsElectriquesEntier),
      volets_persiennes_localisation: nullableString(updates.voletsPersiennesLocalisation),
      volets_persiennes_entier: boolText(updates.voletsPersiennesEntier),
      cheminement_escalier_exterieur: boolText(updates.cheminementEscalierExterieur),
      cheminement_escalier_interieur: boolText(updates.cheminementEscalierInterieur),
      cheminement_pente_douce: boolText(updates.cheminementPenteDouce),
      cheminement_plat: boolText(updates.cheminementPlat),
      cheminement_quelques_marches: boolText(updates.cheminementQuelquesMarches),
      cheminement_par_arriere: boolText(updates.cheminementParArriere),
      cheminement_seuil_porte: boolText(updates.cheminementSeuilPorte),
      difficultes_circulation_interieure: boolText(updates.difficultesCirculationInterieure),
      acces_facile_rue: boolText(updates.easyAccess),
      commentaire: nullableString(updates.comments),
      observation_accessibilite: nullableString(updates.accessObservation),
      type_de_logement_id: typeLogement ? Number(typeLogement.id) : undefined,
      porte_de_garage_id: porteGarage ? Number(porteGarage.id) : undefined,
      portail_id1: portail ? Number(portail.id) : undefined,
    });

    // Helper inline pour extraire le UpdatedAt d'un record NocoDB.
    // `getRecordUpdatedAt` existe dans index.mjs mais n'est pas exporté
    // depuis helpers.mjs — on inline pour éviter de chambouler les imports.
    const extractUpdatedAt = (record) => {
      const raw = field(record, 'updated_at') ||
          field(record, 'UpdatedAt') ||
          field(record, 'created_at') ||
          field(record, 'CreatedAt');
      return raw ? new Date(raw).toISOString() : null;
    };

    if (existingHousing) {
      await updateRecord(TABLES.logements, existingHousing.id, fields);
      // Fix 2026-05-13 : on renvoie le nouvel `updatedAt` du logement
      // pour que le client puisse mettre à jour son `remote_updated_at`
      // local. Sans ça, le 2e save consécutif envoie l'ancien
      // `expectedUpdatedAt` → 409 conflit garanti → retry force-local
      // bruyant à chaque save. Cf. fix identique sur PATCH beneficiaires.
      let refreshedUpdatedAt = null;
      try {
        const refreshedLogements = await queryAll(TABLES.logements, { fields: FIELD_SETS.logements });
        const refreshed = refreshedLogements.find((r) => String(r.id) === String(existingHousing.id));
        if (refreshed) refreshedUpdatedAt = extractUpdatedAt(refreshed);
      } catch (_) {
        // best-effort : client gardera son ancien remote_updated_at
      }
      res.json({
        success: true,
        error: null,
        data: {
          id: field(existingHousing, 'uuid_source') || `nocodb-housing-${existingHousing.id}`,
          updatedAt: refreshedUpdatedAt,
        },
      });
      return;
    }

    const created = await createRecord(TABLES.logements, fields);
    res.json({
      success: true,
      error: null,
      data: {
        id: field(created, 'uuid_source') || `nocodb-housing-${created.id}`,
        updatedAt: extractUpdatedAt(created),
      },
    });
  } catch (error) {
    next(error);
  }
});

export default router;
