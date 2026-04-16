import express from 'express';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { requireAuth } from '../middleware/auth.mjs';
import {
  mobileSyncStore,
  field,
  stringValue,
  asArray,
  nullableString,
  toNumber,
  toBool,
  boolText,
  httpError,
  safeParseJsonArray,
  resolveBeneficiaryAccess,
  buildBeneficiaryDocumentContext,
  mapStoredDocument,
  mapStoredNotePage,
  escapeHtml,
  ensureDossierRecord,
  canAccessDossierRecord,
  readVisitPlanMeta,
  getVisitPlanFileUrl,
  parseImageDataUrl,
  queryAll,
  updateRecord,
  createRecord,
  TABLES,
  FIELD_SETS,
  VISIT_RECOMMENDATION_FIELDS,
  latestByFieldValue,
  parseJsonArrayField,
  buildLegacyBathroomInstances,
  buildLegacyWcInstances,
  getVisitRecommendationsTableId,
  mapVisitRecommendationRecord,
  loadWikiLibrary,
  buildWikiRecommendationLookup,
  resolveRecommendationWikiItem,
  normalizeVisitRecommendationItem,
  readVisitRecommendationsStore,
  writeVisitRecommendationsStore,
  absoluteUrl,
  buildVisitRecommendationMetadata,
  callNocoTool,
} from '../helpers.mjs';

const router = express.Router();

router.get('/api/documents/:patientId', requireAuth, async (req, res, next) => {
  try {
    const access = await resolveBeneficiaryAccess(req.appUser, req.params.patientId);
    const dossierId = stringValue(req.query?.dossierId).trim();
    const documents = await mobileSyncStore.listDocumentsByPatient(req.params.patientId, {
      dossierId: dossierId || undefined,
    });
    const documentContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId: req.params.patientId,
    });

    res.json({
      success: true,
      error: null,
      data: { documents: documents.map((document) => ({ ...documentContext, ...document })) },
    });
  } catch (error) {
    next(error);
  }
});

router.post(
  '/api/documents/upload',
  requireAuth,
  express.raw({ type: () => true, limit: '30mb' }),
  async (req, res, next) => {
    try {
      const patientId = stringValue(req.query?.patientId).trim();
      const documentLocalId = stringValue(req.query?.documentLocalId).trim();
      const title = stringValue(req.query?.title).trim() || 'Document';
      const requestedFileName = stringValue(req.query?.fileName).trim();
      const requestedDossierId = stringValue(req.query?.dossierId).trim();
      const tags = safeParseJsonArray(req.query?.tagsJson).map((tag) => String(tag).trim()).filter(Boolean);
      const mimeType = stringValue(req.get('content-type')).trim() || 'application/octet-stream';
      const bodyBuffer = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);

      if (!patientId) {
        throw httpError(400, 'patientId manquant');
      }

      if (bodyBuffer.length === 0) {
        throw httpError(400, 'Fichier manquant');
      }

      const access = await resolveBeneficiaryAccess(req.appUser, patientId);
      const documentContext = buildBeneficiaryDocumentContext({
        beneficiaryRecord: access.beneficiaryRecord,
        dossierRecord: access.dossierRecord,
        patientId,
      });
      const document = await mobileSyncStore.upsertDocument({
        patientId,
        dossierId: requestedDossierId || field(access.dossierRecord, 'uuid_source') || null,
        documentLocalId,
        title,
        fileName: requestedFileName || `${title}.bin`,
        mimeType,
        tags,
        contentBase64: bodyBuffer.toString('base64'),
        ...documentContext,
      });

      res.status(201).json({
        success: true,
        error: null,
        data: { document: mapStoredDocument(document) },
      });
    } catch (error) {
      next(error);
    }
  },
);

router.post('/api/documents', requireAuth, async (req, res, next) => {
  try {
    const patientId = stringValue(req.body?.patientId).trim();
    const documentLocalId = stringValue(req.body?.documentLocalId).trim();
    const title = stringValue(req.body?.title).trim() || 'Document';
    const requestedFileName = stringValue(req.body?.fileName).trim();
    const requestedDossierId = stringValue(req.body?.dossierId).trim();
    const tags = asArray(req.body?.tags).map((tag) => String(tag).trim()).filter(Boolean);

    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }

    const access = await resolveBeneficiaryAccess(req.appUser, patientId);
    const documentContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId,
    });
    const document = await mobileSyncStore.upsertDocument({
      patientId,
      dossierId: requestedDossierId || field(access.dossierRecord, 'uuid_source') || null,
      documentLocalId,
      title,
      fileName: requestedFileName || `${title}.bin`,
      mimeType: stringValue(req.body?.mimeType).trim() || 'application/octet-stream',
      tags,
      contentBase64: req.body?.contentBase64,
      ...documentContext,
    });

    res.status(201).json({
      success: true,
      error: null,
      data: { document: mapStoredDocument(document) },
    });
  } catch (error) {
    next(error);
  }
});

router.patch('/api/documents/:documentId', requireAuth, async (req, res, next) => {
  try {
    const document = await mobileSyncStore.getDocumentById(req.params.documentId);
    if (!document) {
      throw httpError(404, 'Document introuvable');
    }

    await resolveBeneficiaryAccess(req.appUser, document.patientId);
    const title = req.body?.title == null ? undefined : stringValue(req.body.title).trim();
    const tags = req.body?.tags == null
      ? undefined
      : asArray(req.body.tags).map((tag) => String(tag).trim()).filter(Boolean);

    const updated = await mobileSyncStore.updateDocument(req.params.documentId, {
      title,
      tags,
    });

    if (!updated) {
      throw httpError(404, 'Document introuvable');
    }

    res.json({
      success: true,
      error: null,
      data: { document: mapStoredDocument(updated) },
    });
  } catch (error) {
    next(error);
  }
});

router.delete('/api/documents/:documentId', requireAuth, async (req, res, next) => {
  try {
    const document = await mobileSyncStore.getDocumentById(req.params.documentId);
    if (!document) {
      throw httpError(404, 'Document introuvable');
    }

    await resolveBeneficiaryAccess(req.appUser, document.patientId);
    const deleted = await mobileSyncStore.deleteDocument(req.params.documentId);

    res.json({
      success: deleted,
      error: deleted ? null : 'Document introuvable',
      data: { deleted },
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/mobile-documents/:documentId/content', requireAuth, async (req, res, next) => {
  try {
    const content = await mobileSyncStore.getDocumentContent(req.params.documentId);
    if (!content) {
      throw httpError(404, 'Document introuvable');
    }

    await resolveBeneficiaryAccess(req.appUser, content.patientId);
    res.setHeader('Content-Type', content.mimeType || 'application/octet-stream');
    res.setHeader('Content-Disposition', 'inline');
    res.send(content.buffer);
  } catch (error) {
    next(error);
  }
});

router.get('/public/note-pages/:notePageId/preview', async (req, res, next) => {
  try {
    const notePage = await mobileSyncStore.getNotePageById(req.params.notePageId);
    if (!notePage) {
      throw httpError(404, 'Note introuvable');
    }

    const previewDataUrl = stringValue(notePage.previewDataUrl).trim();
    const noteTitle = [
      stringValue(notePage.patientFirstName).trim(),
      stringValue(notePage.patientLastName).trim(),
    ].filter(Boolean).join(' ').trim() || 'Note';
    const textPreview = stringValue(notePage.textContent).trim();

    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.send(`<!doctype html>
<html lang="fr">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHtml(noteTitle)} - Pr\u00e9visualisation note</title>
    <style>
      body { margin:0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:#f8fafc; color:#0f172a; }
      .shell { min-height:100vh; display:flex; align-items:center; justify-content:center; padding:32px 20px; }
      .card { width:min(820px, 100%); background:#fff; border:1px solid #e2e8f0; border-radius:24px; box-shadow:0 20px 40px rgba(15, 23, 42, 0.08); overflow:hidden; }
      .header { padding:20px 24px 12px; border-bottom:1px solid #e2e8f0; }
      .meta { color:#64748b; font-size:13px; font-weight:600; text-transform:uppercase; letter-spacing:.08em; }
      h1 { margin:8px 0 0; font-size:22px; }
      .body { padding:24px; display:grid; gap:20px; }
      .preview { border:1px solid #e2e8f0; border-radius:18px; background:#fff; overflow:hidden; }
      .preview img { display:block; width:100%; height:auto; }
      .empty { padding:48px 24px; color:#94a3b8; text-align:center; font-weight:600; }
      .text { white-space:pre-wrap; line-height:1.6; color:#334155; border:1px solid #e2e8f0; border-radius:18px; background:#f8fafc; padding:18px; }
    </style>
  </head>
  <body>
    <div class="shell">
      <article class="card">
        <header class="header">
          <div class="meta">${escapeHtml(notePage.tabKey)} \u00b7 page ${Number(notePage.pageNumber) + 1}</div>
          <h1>${escapeHtml(noteTitle)}</h1>
        </header>
        <div class="body">
          <section class="preview">
            ${previewDataUrl ? `<img src="${escapeHtml(previewDataUrl)}" alt="Pr\u00e9visualisation de la note" />` : '<div class="empty">Aucune miniature disponible</div>'}
          </section>
          ${textPreview ? `<section class="text">${escapeHtml(textPreview)}</section>` : ''}
        </div>
      </article>
    </div>
  </body>
</html>`);
  } catch (error) {
    next(error);
  }
});

router.get('/api/note-pages/:patientId', requireAuth, async (req, res, next) => {
  try {
    await resolveBeneficiaryAccess(req.appUser, req.params.patientId);
    const scopeType = stringValue(req.query?.scopeType).trim();
    const scopeId = stringValue(req.query?.scopeId).trim();
    const tabKey = stringValue(req.query?.tabKey).trim();
    const subTabKey = stringValue(req.query?.subTabKey).trim();
    const pageNumber = req.query?.pageNumber == null || req.query.pageNumber === ''
      ? null
      : Number(req.query.pageNumber);
    const notePages = await mobileSyncStore.listNotePagesByPatient(
      req.params.patientId,
      { scopeType, scopeId, tabKey, subTabKey, pageNumber },
    );

    res.json({
      success: true,
      error: null,
      data: { notePages },
    });
  } catch (error) {
    next(error);
  }
});

router.put('/api/note-pages', requireAuth, async (req, res, next) => {
  try {
    const notePageId = stringValue(req.body?.notePageId).trim();
    const patientId = stringValue(req.body?.patientId).trim();
    const scopeType = stringValue(req.body?.scopeType).trim();
    const scopeId = stringValue(req.body?.scopeId).trim();
    const tabKey = stringValue(req.body?.tabKey).trim();
    const subTabKey = stringValue(req.body?.subTabKey).trim();
    const pageNumber = Number(req.body?.pageNumber ?? 0);
    const textContent = typeof req.body?.textContent === 'string' ? req.body.textContent : '';
    const drawingJson = typeof req.body?.drawingJson === 'string' ? req.body.drawingJson : JSON.stringify(req.body?.drawingJson ?? '');
    const previewDataUrl = typeof req.body?.previewDataUrl === 'string' ? req.body.previewDataUrl : '';
    const layoutKind = stringValue(req.body?.layoutKind).trim() || 'freeform';

    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }
    if (!scopeType) {
      throw httpError(400, 'scopeType manquant');
    }
    if (!scopeId) {
      throw httpError(400, 'scopeId manquant');
    }
    if (!tabKey) {
      throw httpError(400, 'tabKey manquant');
    }
    if (!Number.isFinite(pageNumber) || pageNumber < 0) {
      throw httpError(400, 'pageNumber invalide');
    }

    const access = await resolveBeneficiaryAccess(req.appUser, patientId);
    const notePageContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId,
    });
    const notePage = await mobileSyncStore.upsertNotePage({
      notePageId: notePageId || null,
      patientId,
      dossierId: field(access.dossierRecord, 'uuid_source') || null,
      scopeType,
      scopeId,
      tabKey,
      subTabKey,
      pageNumber,
      textContent,
      drawingJson,
      previewDataUrl,
      layoutKind,
      ...notePageContext,
    });

    res.json({
      success: true,
      error: null,
      data: { notePage: mapStoredNotePage(notePage) },
    });
  } catch (error) {
    next(error);
  }
});

router.post('/api/note-pages', requireAuth, async (req, res, next) => {
  try {
    const patientId = stringValue(req.body?.patientId).trim();
    const scopeType = stringValue(req.body?.scopeType).trim();
    const scopeId = stringValue(req.body?.scopeId).trim();
    const tabKey = stringValue(req.body?.tabKey).trim();
    const subTabKey = stringValue(req.body?.subTabKey).trim();
    const layoutKind = stringValue(req.body?.layoutKind).trim() || 'freeform';

    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }
    if (!scopeType) {
      throw httpError(400, 'scopeType manquant');
    }
    if (!scopeId) {
      throw httpError(400, 'scopeId manquant');
    }
    if (!tabKey) {
      throw httpError(400, 'tabKey manquant');
    }

    const access = await resolveBeneficiaryAccess(req.appUser, patientId);
    const notePageContext = buildBeneficiaryDocumentContext({
      beneficiaryRecord: access.beneficiaryRecord,
      dossierRecord: access.dossierRecord,
      patientId,
    });
    const notePage = await mobileSyncStore.createNotePage({
      patientId,
      dossierId: field(access.dossierRecord, 'uuid_source') || null,
      scopeType,
      scopeId,
      tabKey,
      subTabKey,
      layoutKind,
      ...notePageContext,
    });

    res.json({
      success: true,
      error: null,
      data: { notePage: mapStoredNotePage(notePage) },
    });
  } catch (error) {
    next(error);
  }
});

router.delete('/api/note-pages/:notePageId', requireAuth, async (req, res, next) => {
  try {
    const patientId = stringValue(req.query?.patientId).trim();
    if (!patientId) {
      throw httpError(400, 'patientId manquant');
    }

    await resolveBeneficiaryAccess(req.appUser, patientId);
    const deleted = await mobileSyncStore.deleteNotePage(req.params.notePageId);
    if (!deleted) {
      throw httpError(404, 'Note introuvable');
    }

    res.json({
      success: true,
      error: null,
      data: { deleted: true },
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/visit-plans/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }

    const visitPlan = await readVisitPlanMeta(field(dossierRecord, 'uuid_source') || req.params.dossierId);
    res.json({
      success: true,
      error: null,
      data: { visitPlan },
    });
  } catch (error) {
    next(error);
  }
});

router.put('/api/visit-plans/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }

    const contentBase64 = stringValue(req.body?.contentBase64).trim();
    if (!contentBase64) {
      throw httpError(400, 'Contenu du plan manquant');
    }

    const image = parseImageDataUrl(contentBase64);
    const dossierId = field(dossierRecord, 'uuid_source') || req.params.dossierId;
    const targetUrl = getVisitPlanFileUrl(dossierId);
    await fs.mkdir(new URL('./', targetUrl), { recursive: true });
    await fs.writeFile(targetUrl, image.buffer);

    const visitPlan = await readVisitPlanMeta(dossierId);
    res.json({
      success: true,
      error: null,
      data: { visitPlan },
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/diagnostic-sanitaires/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }
    const records = await queryAll(TABLES.diagnosticSanitaires, { fields: FIELD_SETS.diagnosticSanitaires });
    const record = latestByFieldValue(records, 'dossier_id', req.params.dossierId);
    res.json(record ? {
      id: field(record, 'uuid_source') || String(record.id),
      dossierId: field(record, 'dossier_id'),
      sdbInstances: (() => {
        const parsed = parseJsonArrayField(field(record, 'sdb_instances_json'));
        return parsed.length > 0 ? parsed : buildLegacyBathroomInstances({
          sdbNiveauPiecesVie: toBool(field(record, 'sdb_niveau_pieces_vie')),
          sdbBaignoire: toBool(field(record, 'sdb_baignoire')),
          sdbBaignoireHauteur: toNumber(field(record, 'sdb_baignoire_hauteur')),
          sdbBacDouche: toBool(field(record, 'sdb_bac_douche')),
          sdbBacDoucheHauteur: toNumber(field(record, 'sdb_bac_douche_hauteur')),
          sdbVasqueSuspendue: toBool(field(record, 'sdb_vasque_suspendue')),
          sdbVasqueSuspendueHauteur: toNumber(field(record, 'sdb_vasque_suspendue_hauteur')),
          sdbVasqueColonne: toBool(field(record, 'sdb_vasque_colonne')),
          sdbVasqueColonneHauteur: toNumber(field(record, 'sdb_vasque_colonne_hauteur')),
          sdbMeubleVasque: toBool(field(record, 'sdb_meuble_vasque')),
          sdbMeubleVasqueHauteur: toNumber(field(record, 'sdb_meuble_vasque_hauteur')),
          sdbBidet: toBool(field(record, 'sdb_bidet')),
          sdbBidetHauteur: toNumber(field(record, 'sdb_bidet_hauteur')),
          sdbParoiDouche: toBool(field(record, 'sdb_paroi_douche')),
          sdbParoiDoucheHauteur: toNumber(field(record, 'sdb_paroi_douche_hauteur')),
          sdbSolGlissant: toBool(field(record, 'sdb_sol_glissant')),
          sdbMachineALaver: toBool(field(record, 'sdb_machine_a_laver')),
          sdbMachineALaverHauteur: toNumber(field(record, 'sdb_machine_a_laver_hauteur')),
          porteSdbLargeurSuffisante: toBool(field(record, 'porte_sdb_largeur_suffisante')),
          porteSdbDimension: toNumber(field(record, 'porte_sdb_dimension')),
          porteSdbSensAdapte: toBool(field(record, 'porte_sdb_sens_adapte')),
        });
      })(),
      wcInstances: (() => {
        const parsed = parseJsonArrayField(field(record, 'wc_instances_json'));
        return parsed.length > 0 ? parsed : buildLegacyWcInstances({
          wcNiveau: toBool(field(record, 'wc_niveau')),
          wcCuvetteBonneHauteur: toBool(field(record, 'wc_cuvette_bonne_hauteur')),
          wcCuvetteTropBasse: toBool(field(record, 'wc_cuvette_trop_basse')),
          wcCuvetteHauteur: toNumber(field(record, 'wc_cuvette_hauteur')),
          wcBarreRelevement: toBool(field(record, 'wc_barre_relevement')),
          porteWcLargeurSuffisante: toBool(field(record, 'porte_wc_largeur_suffisante')),
          porteWcDimension: toNumber(field(record, 'porte_wc_dimension')),
          porteWcSensAdapte: toBool(field(record, 'porte_wc_sens_adapte')),
          observationEquipementsUtilisation: stringValue(field(record, 'observation_equipements_utilisation')),
        });
      })(),
      sdbNiveauPiecesVie: toBool(field(record, 'sdb_niveau_pieces_vie')),
      wcNiveau: toBool(field(record, 'wc_niveau')),
      wcEtage: toBool(field(record, 'wc_etage')),
      sdbBaignoire: toBool(field(record, 'sdb_baignoire')),
      sdbBaignoireHauteur: toNumber(field(record, 'sdb_baignoire_hauteur')),
      sdbBacDouche: toBool(field(record, 'sdb_bac_douche')),
      sdbBacDoucheHauteur: toNumber(field(record, 'sdb_bac_douche_hauteur')),
      sdbVasqueSuspendue: toBool(field(record, 'sdb_vasque_suspendue')),
      sdbVasqueSuspendueHauteur: toNumber(field(record, 'sdb_vasque_suspendue_hauteur')),
      sdbVasqueColonne: toBool(field(record, 'sdb_vasque_colonne')),
      sdbVasqueColonneHauteur: toNumber(field(record, 'sdb_vasque_colonne_hauteur')),
      sdbMeubleVasque: toBool(field(record, 'sdb_meuble_vasque')),
      sdbMeubleVasqueHauteur: toNumber(field(record, 'sdb_meuble_vasque_hauteur')),
      sdbBidet: toBool(field(record, 'sdb_bidet')),
      sdbBidetHauteur: toNumber(field(record, 'sdb_bidet_hauteur')),
      sdbParoiDouche: toBool(field(record, 'sdb_paroi_douche')),
      sdbParoiDoucheHauteur: toNumber(field(record, 'sdb_paroi_douche_hauteur')),
      sdbSolGlissant: toBool(field(record, 'sdb_sol_glissant')),
      sdbMachineALaver: toBool(field(record, 'sdb_machine_a_laver')),
      sdbMachineALaverHauteur: toNumber(field(record, 'sdb_machine_a_laver_hauteur')),
      wcCuvetteBonneHauteur: toBool(field(record, 'wc_cuvette_bonne_hauteur')),
      wcCuvetteTropBasse: toBool(field(record, 'wc_cuvette_trop_basse')),
      wcCuvetteHauteur: toNumber(field(record, 'wc_cuvette_hauteur')),
      wcBarreRelevement: toBool(field(record, 'wc_barre_relevement')),
      porteSdbLargeurSuffisante: toBool(field(record, 'porte_sdb_largeur_suffisante')),
      porteSdbDimension: toNumber(field(record, 'porte_sdb_dimension')),
      porteSdbSensAdapte: toBool(field(record, 'porte_sdb_sens_adapte')),
      porteWcLargeurSuffisante: toBool(field(record, 'porte_wc_largeur_suffisante')),
      porteWcDimension: toNumber(field(record, 'porte_wc_dimension')),
      porteWcSensAdapte: toBool(field(record, 'porte_wc_sens_adapte')),
      observationEquipementsUtilisation: stringValue(field(record, 'observation_equipements_utilisation')),
    } : null);
  } catch (error) {
    next(error);
  }
});

router.put('/api/diagnostic-sanitaires/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierId = req.params.dossierId;
    const payload = req.body || {};
    const records = await queryAll(TABLES.diagnosticSanitaires, { fields: FIELD_SETS.diagnosticSanitaires });
    const dossierRecord = await ensureDossierRecord(dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }
    const existing = latestByFieldValue(records, 'dossier_id', field(dossierRecord, 'uuid_source'));
    const sdbInstances = Array.isArray(payload.sdbInstances) ? payload.sdbInstances : [];
    const wcInstances = Array.isArray(payload.wcInstances) ? payload.wcInstances : [];
    const primaryBathroom = sdbInstances[0] || {};
    const primaryWc = wcInstances[0] || {};
    const fields = {
      dossier_id: field(dossierRecord, 'uuid_source'),
      dossiers_id: Number(dossierRecord.id),
      sdb_instances_json: nullableString(sdbInstances.length > 0 ? JSON.stringify(sdbInstances) : null),
      wc_instances_json: nullableString(wcInstances.length > 0 ? JSON.stringify(wcInstances) : null),
      sdb_niveau_pieces_vie: boolText(sdbInstances.length > 0 ? primaryBathroom.levelField === 'rdc' : payload.sdbNiveauPiecesVie),
      wc_niveau: boolText(wcInstances.length > 0 ? primaryWc.levelField === 'rdc' : payload.wcNiveau),
      wc_etage: boolText(wcInstances.length > 0 ? primaryWc.levelField !== 'rdc' : payload.wcEtage),
      sdb_baignoire: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbBaignoire : payload.sdbBaignoire),
      sdb_baignoire_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbBaignoireHauteur : payload.sdbBaignoireHauteur),
      sdb_bac_douche: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbBacDouche : payload.sdbBacDouche),
      sdb_bac_douche_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbBacDoucheHauteur : payload.sdbBacDoucheHauteur),
      sdb_vasque_suspendue: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueSuspendue : payload.sdbVasqueSuspendue),
      sdb_vasque_suspendue_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueSuspendueHauteur : payload.sdbVasqueSuspendueHauteur),
      sdb_vasque_colonne: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueColonne : payload.sdbVasqueColonne),
      sdb_vasque_colonne_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbVasqueColonneHauteur : payload.sdbVasqueColonneHauteur),
      sdb_meuble_vasque: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbMeubleVasque : payload.sdbMeubleVasque),
      sdb_meuble_vasque_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbMeubleVasqueHauteur : payload.sdbMeubleVasqueHauteur),
      sdb_bidet: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbBidet : payload.sdbBidet),
      sdb_bidet_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbBidetHauteur : payload.sdbBidetHauteur),
      sdb_paroi_douche: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbParoiDouche : payload.sdbParoiDouche),
      sdb_paroi_douche_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbParoiDoucheHauteur : payload.sdbParoiDoucheHauteur),
      sdb_sol_glissant: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbSolGlissant : payload.sdbSolGlissant),
      sdb_machine_a_laver: boolText(sdbInstances.length > 0 ? primaryBathroom.sdbMachineALaver : payload.sdbMachineALaver),
      sdb_machine_a_laver_hauteur: nullableString(sdbInstances.length > 0 ? primaryBathroom.sdbMachineALaverHauteur : payload.sdbMachineALaverHauteur),
      wc_cuvette_bonne_hauteur: boolText(wcInstances.length > 0 ? primaryWc.wcCuvetteBonneHauteur : payload.wcCuvetteBonneHauteur),
      wc_cuvette_trop_basse: boolText(wcInstances.length > 0 ? primaryWc.wcCuvetteTropBasse : payload.wcCuvetteTropBasse),
      wc_cuvette_hauteur: nullableString(wcInstances.length > 0 ? primaryWc.wcCuvetteHauteur : payload.wcCuvetteHauteur),
      wc_barre_relevement: boolText(wcInstances.length > 0 ? primaryWc.wcBarreRelevement : payload.wcBarreRelevement),
      porte_sdb_largeur_suffisante: boolText(sdbInstances.length > 0 ? primaryBathroom.porteSdbLargeurSuffisante : payload.porteSdbLargeurSuffisante),
      porte_sdb_dimension: nullableString(sdbInstances.length > 0 ? primaryBathroom.porteSdbDimension : payload.porteSdbDimension),
      porte_sdb_sens_adapte: boolText(sdbInstances.length > 0 ? primaryBathroom.porteSdbSensAdapte : payload.porteSdbSensAdapte),
      porte_wc_largeur_suffisante: boolText(wcInstances.length > 0 ? primaryWc.porteWcLargeurSuffisante : payload.porteWcLargeurSuffisante),
      porte_wc_dimension: nullableString(wcInstances.length > 0 ? primaryWc.porteWcDimension : payload.porteWcDimension),
      porte_wc_sens_adapte: boolText(wcInstances.length > 0 ? primaryWc.porteWcSensAdapte : payload.porteWcSensAdapte),
      observation_equipements_utilisation: nullableString(wcInstances.length > 0 ? primaryWc.observationEquipementsUtilisation : payload.observationEquipementsUtilisation),
      updated_at: new Date().toISOString(),
    };

    if (existing) {
      await updateRecord(TABLES.diagnosticSanitaires, existing.id, fields);
    } else {
      await createRecord(TABLES.diagnosticSanitaires, { uuid_source: crypto.randomUUID(), created_at: new Date().toISOString(), ...fields });
    }

    res.json({ success: true, error: null });
  } catch (error) {
    next(error);
  }
});

router.get('/api/mesures/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }
    const records = await queryAll(TABLES.mesuresAnthropometriques, { fields: FIELD_SETS.mesuresAnthropometriques });
    const record = latestByFieldValue(records, 'dossier_id', req.params.dossierId);
    res.json(record ? {
      id: field(record, 'uuid_source') || String(record.id),
      dossierId: field(record, 'dossier_id'),
      deboutHauteurCoude: toNumber(field(record, 'debout_hauteur_coude')),
      assisHauteurAssise: toNumber(field(record, 'assis_hauteur_assise')),
      assisProfondeurGenoux: toNumber(field(record, 'assis_profondeur_genoux')),
      assisHauteurCoudes: toNumber(field(record, 'assis_hauteur_coudes')),
      observations: stringValue(field(record, 'observations')),
    } : null);
  } catch (error) {
    next(error);
  }
});

router.put('/api/mesures/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierId = req.params.dossierId;
    const payload = req.body || {};
    const records = await queryAll(TABLES.mesuresAnthropometriques, { fields: FIELD_SETS.mesuresAnthropometriques });
    const dossierRecord = await ensureDossierRecord(dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }
    const existing = latestByFieldValue(records, 'dossier_id', field(dossierRecord, 'uuid_source'));
    const fields = {
      dossier_id: field(dossierRecord, 'uuid_source'),
      dossiers_id: Number(dossierRecord.id),
      debout_hauteur_coude: nullableString(payload.deboutHauteurCoude),
      assis_hauteur_assise: nullableString(payload.assisHauteurAssise),
      assis_profondeur_genoux: nullableString(payload.assisProfondeurGenoux),
      assis_hauteur_coudes: nullableString(payload.assisHauteurCoudes),
      observations: nullableString(payload.observations),
      updated_at: new Date().toISOString(),
    };

    if (existing) {
      await updateRecord(TABLES.mesuresAnthropometriques, existing.id, fields);
    } else {
      await createRecord(TABLES.mesuresAnthropometriques, { uuid_source: crypto.randomUUID(), created_at: new Date().toISOString(), ...fields });
    }

    res.json({ success: true, error: null });
  } catch (error) {
    next(error);
  }
});

router.get('/api/observations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }
    const records = await queryAll(TABLES.observations, { fields: FIELD_SETS.observations });
    const record = latestByFieldValue(records, 'dossier_id', req.params.dossierId);
    res.json(record ? {
      id: field(record, 'uuid_source') || String(record.id),
      dossierId: field(record, 'dossier_id'),
      observationEquipements: stringValue(field(record, 'observation_equipements')),
      projetSouhaitUsage: stringValue(field(record, 'projet_souhait_usage')),
      resumePreconisations: stringValue(field(record, 'resume_preconisations')),
    } : null);
  } catch (error) {
    next(error);
  }
});

router.put('/api/observations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierId = req.params.dossierId;
    const payload = req.body || {};
    const records = await queryAll(TABLES.observations, { fields: FIELD_SETS.observations });
    const dossierRecord = await ensureDossierRecord(dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }
    const existing = latestByFieldValue(records, 'dossier_id', field(dossierRecord, 'uuid_source'));
    const fields = {
      dossier_id: field(dossierRecord, 'uuid_source'),
      dossiers_id: Number(dossierRecord.id),
      observation_equipements: nullableString(payload.observationEquipements),
      projet_souhait_usage: nullableString(payload.projetSouhaitUsage),
      resume_preconisations: nullableString(payload.resumePreconisations),
    };

    if (existing) {
      await updateRecord(TABLES.observations, existing.id, fields);
    } else {
      await createRecord(TABLES.observations, { uuid_source: crypto.randomUUID(), ...fields });
    }

    res.json({ success: true, error: null });
  } catch (error) {
    next(error);
  }
});

router.get('/api/visit-recommendations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }

    const dossierId = field(dossierRecord, 'uuid_source');
    const tableId = await getVisitRecommendationsTableId();
    let items = [];

    if (tableId) {
      const records = await queryAll(tableId, {
        fields: VISIT_RECOMMENDATION_FIELDS,
        where: `(dossier_id,eq,${JSON.stringify(String(dossierId))})`,
      });
      items = records
        .map(mapVisitRecommendationRecord)
        .sort((left, right) => new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime());
    } else {
      const store = await readVisitRecommendationsStore();
      const payload = store.dossiers?.[dossierId];
      items = asArray(payload?.items).map((item) => ({
        ...item,
        wikiImageUrl: absoluteUrl(item?.wikiImageUrl),
      }));
    }

    const wikiItems = await loadWikiLibrary();
    const wikiLookup = buildWikiRecommendationLookup(wikiItems);
    items = items.map((item) => {
      const matchedWikiItem = resolveRecommendationWikiItem(item, wikiLookup);
      if (!matchedWikiItem) {
        return {
          ...item,
          wikiImageUrl: absoluteUrl(item?.wikiImageUrl),
        };
      }
      return {
        ...item,
        wikiItemId: stringValue(matchedWikiItem.id),
        wikiTitle: stringValue(matchedWikiItem.title),
        wikiImageUrl: stringValue(matchedWikiItem.imageUrl),
        wikiTag: stringValue(matchedWikiItem.tags?.[0] || item?.wikiTag),
      };
    });

    res.json({
      success: true,
      error: null,
      data: { items },
    });
  } catch (error) {
    next(error);
  }
});

router.put('/api/visit-recommendations/:dossierId', requireAuth, async (req, res, next) => {
  try {
    const dossierRecord = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossierRecord)) {
      res.status(403).json({ success: false, error: 'Acc\u00e8s interdit \u00e0 ce dossier' });
      return;
    }

    const wikiItems = await loadWikiLibrary();
    const wikiLookup = buildWikiRecommendationLookup(wikiItems);
    const dossierId = field(dossierRecord, 'uuid_source');
    const rawItems = asArray(req.body?.items);

    const normalizedItems = rawItems.map((item) => {
      const normalized = normalizeVisitRecommendationItem(item, wikiLookup);
      if (!normalized.wikiItemId || !wikiLookup.byId.has(normalized.wikiItemId)) {
        throw new Error('Chaque pr\u00e9conisation doit \u00eatre li\u00e9e \u00e0 une image de la biblioth\u00e8que');
      }
      return normalized;
    });

    const tableId = await getVisitRecommendationsTableId();

    if (tableId) {
      const metadata = await buildVisitRecommendationMetadata(dossierRecord);
      const existingRecords = await queryAll(tableId, {
        fields: ['uuid_source'],
        where: `(dossier_id,eq,${JSON.stringify(String(dossierId))})`,
      });

      for (const record of existingRecords) {
        await callNocoTool('deleteRecords', {
          tableId,
          records: [{ id: String(record.id) }],
        });
      }

      for (const item of normalizedItems) {
        await createRecord(tableId, {
          uuid_source: item.id,
          dossier_id: metadata.dossierId,
          beneficiaire_id: metadata.patientId,
          beneficiaire_prenom: metadata.patientFirstName || null,
          beneficiaire_nom: metadata.patientLastName || null,
          beneficiaire_nom_complet: metadata.patientDisplayName || null,
          dossier_libelle: metadata.dossierLabel || null,
          wiki_item_id: item.wikiItemId,
          wiki_title: item.wikiTitle || null,
          wiki_image_url: item.wikiImageUrl || null,
          wiki_tag: item.wikiTag || null,
          note: item.note || null,
          created_at: item.createdAt,
          updated_at: item.updatedAt,
        });
      }
    } else {
      const store = await readVisitRecommendationsStore();
      store.dossiers[dossierId] = {
        updatedAt: new Date().toISOString(),
        items: normalizedItems,
      };
      await writeVisitRecommendationsStore(store);
    }

    res.json({
      success: true,
      error: null,
      data: {
        items: normalizedItems.map((item) => ({
          ...item,
          wikiImageUrl: absoluteUrl(item.wikiImageUrl),
        })),
      },
    });
  } catch (error) {
    if (error instanceof Error && error.message.includes('biblioth\u00e8que')) {
      res.status(400).json({ success: false, error: error.message });
      return;
    }
    next(error);
  }
});

export default router;
