import express from 'express';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { requireAuth } from '../middleware/auth.mjs';
import {
  queryAll,
  updateRecord,
  createRecord,
  TABLES,
  FIELD_SETS,
  field,
  stringValue,
  asArray,
  normalizeEmail,
  nullableString,
  toNumber,
  getReferences,
  readRetirementFundsStore,
  writeRetirementFundsStore,
  normalizeRetirementFundPayload,
  buildRetirementFundResponse,
  getRetirementFundMeta,
  readAnahStatus,
  loadWikiLibrary,
  readWikiLibraryStore,
  writeWikiLibraryStore,
  normalizeWikiItemPayload,
  mapWikiLibraryItem,
  parseImageDataUrl,
  safeSlug,
  WIKI_LIBRARY_DIR_URL,
  WIKI_FILTER_TAGS,
  ensureWikiTagsInNocodb,
  serializeWikiContent,
  callNocoTool,
} from '../helpers.mjs';

const router = express.Router();

router.get('/api/health', async (_req, res, next) => {
  try {
    const beneficiaires = await queryAll(TABLES.beneficiaires, { fields: FIELD_SETS.beneficiaires });
    res.json({
      success: true,
      message: 'Connexion active à la base métier',
      count: beneficiaires.length,
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/references', requireAuth, async (req, res, next) => {
  try {
    res.json(await getReferences(req.appUser));
  } catch (error) {
    next(error);
  }
});

router.get('/api/retirement-funds', requireAuth, async (_req, res, next) => {
  try {
    const records = await queryAll(TABLES.caissesRetraiteComplementaires, { fields: FIELD_SETS.caissesRetraiteComplementaires });
    const store = await readRetirementFundsStore();
    const remoteFunds = records
      .filter((record) => normalizeEmail(field(record, 'nom')).replace(/\s+/g, ' ') !== 'humanis')
      .map((record) => {
      const name = field(record, 'nom') || '';
      const override = store.funds[String(record.id)] || {};
      return buildRetirementFundResponse({
        id: String(record.id),
        name: override.name || name,
        phone: override.phone || field(record, 'numero_telephone_contact') || '',
        audience: override.audience || '',
        requestMethod: override.requestMethod || '',
        requestDelay: override.requestDelay || '',
        aidAmount: override.aidAmount || '',
        therapistNote: override.therapistNote || field(record, 'aide_complementaire') || '',
        website: override.website || '',
        logoUrl: override.logoUrl || '',
        lastEditedAt: override.lastEditedAt || field(record, 'UpdatedAt') || field(record, 'CreatedAt') || null,
      });
      })
      .sort((a, b) => a.name.localeCompare(b.name));
    const customFunds = store.customFunds
      .map((fund) => buildRetirementFundResponse(fund))
      .sort((a, b) => a.name.localeCompare(b.name));
    const funds = [...remoteFunds, ...customFunds].sort((a, b) => a.name.localeCompare(b.name));

    res.json({ success: true, error: null, data: { funds } });
  } catch (error) {
    next(error);
  }
});

router.get('/api/anah-status', requireAuth, async (_req, res, next) => {
  try {
    const status = await readAnahStatus();
    res.json({
      success: true,
      error: null,
      data: {
        status,
      },
    });
  } catch (error) {
    next(error);
  }
});

router.get('/api/wiki-library', requireAuth, async (_req, res, next) => {
  try {
    const items = await loadWikiLibrary();
    res.json({
      success: true,
      error: null,
      data: {
        items,
      },
    });
  } catch (error) {
    next(error);
  }
});

router.post('/api/wiki-library', requireAuth, async (req, res, next) => {
  try {
    const now = new Date().toISOString();
    const store = await readWikiLibraryStore();
    const title = stringValue(req.body?.title).trim();
    const description = stringValue(req.body?.description).trim();
    const category = stringValue(req.body?.category).trim() || 'Autre';
    const tags = asArray(req.body?.tags).map((tag) => String(tag).trim()).filter(Boolean);

    if (!title) {
      res.status(400).json({ success: false, error: 'Titre obligatoire' });
      return;
    }

    let imageUrl = stringValue(req.body?.imageUrl).trim() || '/wiki-access.svg';
    const imageDataUrl = stringValue(req.body?.imageDataUrl).trim();
    if (imageDataUrl) {
      const imagePayload = parseImageDataUrl(imageDataUrl);
      await fs.mkdir(WIKI_LIBRARY_DIR_URL, { recursive: true });
      const fileName = `${safeSlug(title, 'wiki-item')}-${Date.now()}.${imagePayload.extension}`;
      const targetUrl = new URL(fileName, WIKI_LIBRARY_DIR_URL);
      await fs.writeFile(targetUrl, imagePayload.buffer);
      imageUrl = `/uploads/wiki-library/${fileName}`;
    }

    const item = normalizeWikiItemPayload({
      id: crypto.randomUUID(),
      title,
      description,
      imageUrl,
      tags,
      category,
      createdAt: now,
      updatedAt: now,
    });

    store.items.unshift(item);
    await writeWikiLibraryStore(store);

    try {
      const [wikiRecords, initialTagRecords] = await Promise.all([
        queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki }),
        queryAll(TABLES.wikiTags, { fields: FIELD_SETS.wikiTags }),
      ]);
      const { normalizedMap } = await ensureWikiTagsInNocodb(WIKI_FILTER_TAGS, initialTagRecords);
      const primaryTag = stringValue(item.tags[0]).trim();
      const primaryTagRecord = primaryTag ? normalizedMap.get(primaryTag.toLowerCase()) : undefined;
      const existing = wikiRecords.find((record) => stringValue(field(record, 'uuid_source')).trim() === item.id);
      const payload = {
        uuid_source: item.id,
        titre: item.title,
        photos: item.imageUrl,
        contenu: serializeWikiContent(item),
        wiki_tags_id: primaryTagRecord ? Number(primaryTagRecord.id) : null,
      };
      if (existing) {
        await updateRecord(TABLES.wiki, existing.id, payload);
      } else {
        await createRecord(TABLES.wiki, payload);
      }
    } catch (syncError) {
      console.error('Wiki Noco sync failed on create', syncError);
    }

    res.json({
      success: true,
      error: null,
      data: {
        item: mapWikiLibraryItem(item),
      },
    });
  } catch (error) {
    next(error);
  }
});

router.put('/api/wiki-library/:itemId', requireAuth, async (req, res, next) => {
  try {
    const store = await readWikiLibraryStore();
    const index = store.items.findIndex((item) => String(item.id) === String(req.params.itemId));
    if (index === -1) {
      res.status(404).json({ success: false, error: 'Element introuvable' });
      return;
    }

    const current = store.items[index];
    const title = Object.prototype.hasOwnProperty.call(req.body || {}, 'title') ? stringValue(req.body?.title).trim() : current.title;
    if (!title) {
      res.status(400).json({ success: false, error: 'Titre obligatoire' });
      return;
    }

    let imageUrl = current.imageUrl;
    const imageDataUrl = stringValue(req.body?.imageDataUrl).trim();
    if (imageDataUrl) {
      const imagePayload = parseImageDataUrl(imageDataUrl);
      await fs.mkdir(WIKI_LIBRARY_DIR_URL, { recursive: true });
      const fileName = `${safeSlug(title, 'wiki-item')}-${Date.now()}.${imagePayload.extension}`;
      const targetUrl = new URL(fileName, WIKI_LIBRARY_DIR_URL);
      await fs.writeFile(targetUrl, imagePayload.buffer);
      imageUrl = `/uploads/wiki-library/${fileName}`;
    }

    const updated = normalizeWikiItemPayload({
      ...current,
      title,
      description: Object.prototype.hasOwnProperty.call(req.body || {}, 'description') ? stringValue(req.body?.description).trim() : current.description,
      category: Object.prototype.hasOwnProperty.call(req.body || {}, 'category') ? stringValue(req.body?.category).trim() || 'Autre' : current.category,
      tags: Object.prototype.hasOwnProperty.call(req.body || {}, 'tags') ? asArray(req.body?.tags).map((tag) => String(tag).trim()).filter(Boolean) : current.tags,
      imageUrl,
      updatedAt: new Date().toISOString(),
    });

    store.items[index] = updated;
    await writeWikiLibraryStore(store);

    try {
      const [wikiRecords, initialTagRecords] = await Promise.all([
        queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki }),
        queryAll(TABLES.wikiTags, { fields: FIELD_SETS.wikiTags }),
      ]);
      const { normalizedMap } = await ensureWikiTagsInNocodb(WIKI_FILTER_TAGS, initialTagRecords);
      const primaryTag = stringValue(updated.tags[0]).trim();
      const primaryTagRecord = primaryTag ? normalizedMap.get(primaryTag.toLowerCase()) : undefined;
      const existing = wikiRecords.find((record) => stringValue(field(record, 'uuid_source')).trim() === updated.id);
      const payload = {
        uuid_source: updated.id,
        titre: updated.title,
        photos: updated.imageUrl,
        contenu: serializeWikiContent(updated),
        wiki_tags_id: primaryTagRecord ? Number(primaryTagRecord.id) : null,
      };
      if (existing) {
        await updateRecord(TABLES.wiki, existing.id, payload);
      } else {
        await createRecord(TABLES.wiki, payload);
      }
    } catch (syncError) {
      console.error('Wiki Noco sync failed on update', syncError);
    }

    res.json({
      success: true,
      error: null,
      data: {
        item: mapWikiLibraryItem(updated),
      },
    });
  } catch (error) {
    next(error);
  }
});

router.delete('/api/wiki-library/:itemId', requireAuth, async (req, res, next) => {
  try {
    const store = await readWikiLibraryStore();
    const nextItems = store.items.filter((item) => String(item.id) !== String(req.params.itemId));
    if (nextItems.length === store.items.length) {
      res.status(404).json({ success: false, error: 'Element introuvable' });
      return;
    }
    store.items = nextItems;
    await writeWikiLibraryStore(store);

    try {
      const wikiRecords = await queryAll(TABLES.wiki, { fields: FIELD_SETS.wiki });
      const existing = wikiRecords.find((record) => stringValue(field(record, 'uuid_source')).trim() === String(req.params.itemId));
      if (existing) {
        await callNocoTool('deleteRecords', {
          tableId: TABLES.wiki,
          records: [{ id: String(existing.id) }],
        });
      }
    } catch (syncError) {
      console.error('Wiki Noco sync failed on delete', syncError);
    }

    res.status(204).end();
  } catch (error) {
    next(error);
  }
});

router.post('/api/retirement-funds', requireAuth, async (req, res, next) => {
  try {
    const name = stringValue(req.body?.name).trim();
    const phone = stringValue(req.body?.phone).trim();
    const audience = stringValue(req.body?.audience).trim();
    const requestMethod = stringValue(req.body?.requestMethod).trim();
    const requestDelay = stringValue(req.body?.requestDelay).trim();
    const aidAmount = stringValue(req.body?.aidAmount).trim();
    const therapistNote = stringValue(req.body?.therapistNote).trim();
    const website = stringValue(req.body?.website).trim();
    const logoUrl = stringValue(req.body?.logoUrl).trim();

    if (!name) {
      res.status(400).json({ success: false, error: 'Nom obligatoire' });
      return;
    }

    const store = await readRetirementFundsStore();
    const lastEditedAt = new Date().toISOString();
    const storePayload = {
      name,
      phone,
      audience,
      requestMethod,
      requestDelay,
      aidAmount,
      therapistNote,
      website,
      logoUrl,
      lastEditedAt,
      lastEditedBy: req.appUser?.displayName || req.appUser?.email || '',
    };

    let createdId = null;
    try {
      const created = await createRecord(TABLES.caissesRetraiteComplementaires, {
        nom: nullableString(name),
        numero_telephone_contact: nullableString(phone),
        aide_complementaire: nullableString(therapistNote),
      });
      createdId = String(created?.id || '').trim() || null;
    } catch (createError) {
      console.error('Retirement fund Noco sync failed on create', createError);
    }

    if (createdId) {
      store.funds[createdId] = {
        ...(store.funds[createdId] || {}),
        ...storePayload,
      };
    } else {
      store.customFunds.unshift(normalizeRetirementFundPayload({
        id: `custom-${crypto.randomUUID()}`,
        ...storePayload,
      }));
    }
    await writeRetirementFundsStore(store);

    const createdFund = createdId
      ? buildRetirementFundResponse({ id: createdId, ...storePayload })
      : buildRetirementFundResponse(store.customFunds[0]);

    res.json({
      success: true,
      error: null,
      data: {
        fund: createdFund,
      },
    });
  } catch (error) {
    next(error);
  }
});

router.put('/api/retirement-funds/:fundId', requireAuth, async (req, res, next) => {
  try {
    const fundId = String(req.params.fundId || '').trim();
    if (!fundId) {
      res.status(400).json({ success: false, error: 'Identifiant de caisse manquant' });
      return;
    }

    const updates = req.body || {};
    const store = await readRetirementFundsStore();

    if (fundId.startsWith('custom-')) {
      const customIndex = store.customFunds.findIndex((fund) => fund.id === fundId);
      if (customIndex === -1) {
        res.status(404).json({ success: false, error: 'Caisse introuvable' });
        return;
      }

      const current = store.customFunds[customIndex];
      const updatedFund = normalizeRetirementFundPayload({
        ...current,
        name: stringValue(updates.name ?? current.name).trim(),
        phone: stringValue(updates.phone ?? current.phone).trim(),
        audience: stringValue(updates.audience ?? current.audience).trim(),
        requestMethod: stringValue(updates.requestMethod ?? current.requestMethod).trim(),
        requestDelay: stringValue(updates.requestDelay ?? current.requestDelay).trim(),
        aidAmount: stringValue(updates.aidAmount ?? current.aidAmount).trim(),
        therapistNote: stringValue(updates.therapistNote ?? current.therapistNote).trim(),
        website: stringValue(updates.website ?? current.website).trim(),
        logoUrl: stringValue(updates.logoUrl ?? current.logoUrl).trim(),
        lastEditedAt: new Date().toISOString(),
        lastEditedBy: req.appUser?.displayName || req.appUser?.email || '',
      });

      store.customFunds[customIndex] = updatedFund;
      await writeRetirementFundsStore(store);

      res.json({
        success: true,
        error: null,
        data: {
          fund: buildRetirementFundResponse(updatedFund),
        },
      });
      return;
    }

    const records = await queryAll(TABLES.caissesRetraiteComplementaires, { fields: FIELD_SETS.caissesRetraiteComplementaires });
    const record = records.find((entry) => String(entry.id) === fundId);
    if (!record) {
      res.status(404).json({ success: false, error: 'Caisse introuvable' });
      return;
    }

    if (normalizeEmail(field(record, 'nom')).replace(/\s+/g, ' ') === 'humanis') {
      res.status(410).json({ success: false, error: 'Cette caisse a été retirée' });
      return;
    }

    const meta = getRetirementFundMeta(field(record, 'nom') || '');
    const nextName = String(updates.name || meta?.displayName || field(record, 'nom') || '').trim();
    const nextPhone = String(updates.phone || '').trim();
    const nextAudience = String(updates.audience || '').trim();
    const nextRequestMethod = String(updates.requestMethod || '').trim();
    const nextRequestDelay = String(updates.requestDelay || '').trim();
    const nextAidAmount = String(updates.aidAmount || '').trim();
    const nextTherapistNote = String(updates.therapistNote || '').trim();
    const nextWebsite = String(updates.website || '').trim();
    const nextLogoUrl = String(updates.logoUrl || '').trim();
    const lastEditedAt = new Date().toISOString();

    await updateRecord(TABLES.caissesRetraiteComplementaires, fundId, {
      nom: nullableString(nextName),
      numero_telephone_contact: nullableString(nextPhone),
      aide_complementaire: nullableString(nextTherapistNote),
    });

    store.funds[fundId] = {
      ...(store.funds[fundId] || {}),
      name: nextName,
      phone: nextPhone,
      audience: nextAudience,
      requestMethod: nextRequestMethod,
      requestDelay: nextRequestDelay,
      aidAmount: nextAidAmount,
      therapistNote: nextTherapistNote,
      website: nextWebsite,
      logoUrl: nextLogoUrl,
      lastEditedAt,
      lastEditedBy: req.appUser?.displayName || req.appUser?.email || '',
    };
    await writeRetirementFundsStore(store);

    res.json({
      success: true,
      error: null,
      data: {
        fund: {
          id: fundId,
          name: nextName,
          phone: nextPhone,
          audience: nextAudience,
          requestMethod: nextRequestMethod,
          requestDelay: nextRequestDelay,
          aidAmount: nextAidAmount,
          therapistNote: nextTherapistNote,
          website: nextWebsite,
          logoUrl: nextLogoUrl || meta?.logoUrl || '',
          lastEditedAt,
        },
      },
    });
  } catch (error) {
    next(error);
  }
});

export default router;
