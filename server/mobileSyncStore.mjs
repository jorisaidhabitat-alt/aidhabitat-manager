import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import process from 'node:process';

import { callNocoTool } from './nocodbMcpClient.mjs';

const DATA_DIR_URL = new URL('./data/', import.meta.url);
const DOCUMENTS_DIR_URL = new URL('./data/documents/', import.meta.url);
const DOCUMENT_STORE_URL = new URL('./data/documents-store.json', import.meta.url);
const NOTE_PAGES_STORE_URL = new URL('./data/note-pages-store.json', import.meta.url);

const asArray = (value) => Array.isArray(value) ? value : [];
const field = (record, name) => record?.fields?.[name];
const stringValue = (value) => value == null ? '' : String(value);
const safeParseJsonArray = (value) => {
  try {
    const parsed = JSON.parse(stringValue(value) || '[]');
    return asArray(parsed).map((entry) => String(entry));
  } catch {
    return [];
  }
};

const TABLE_NAMES = {
  documents: process.env.NOCODB_MOBILE_DOCUMENTS_TABLE_NAME || 'mobile_documents',
  documentChunks: process.env.NOCODB_MOBILE_DOCUMENT_CHUNKS_TABLE_NAME || 'mobile_document_chunks',
  notePages: process.env.NOCODB_MOBILE_NOTE_PAGES_TABLE_NAME || 'mobile_note_pages',
};

const MAX_NOCODB_LONG_TEXT_LENGTH = 100000;
const DOCUMENT_CONTENT_CHUNK_SIZE = 95000;

export const MOBILE_SYNC_SCHEMA_SPEC = {
  documents: {
    tableName: TABLE_NAMES.documents,
    fields: [
      ['uuid_source', 'SingleLineText'],
      ['beneficiaire_id', 'SingleLineText'],
      ['dossier_id', 'SingleLineText'],
      ['beneficiaire_prenom', 'SingleLineText'],
      ['beneficiaire_nom', 'SingleLineText'],
      ['beneficiaire_nom_complet', 'SingleLineText'],
      ['dossier_libelle', 'SingleLineText'],
      ['client_document_id', 'SingleLineText'],
      ['titre', 'SingleLineText'],
      ['nom_fichier', 'SingleLineText'],
      ['mime_type', 'SingleLineText'],
      ['tags_json', 'LongText'],
      ['contenu_base64', 'LongText'],
      ['created_at', 'DateTime'],
      ['updated_at', 'DateTime'],
    ],
  },
  documentChunks: {
    tableName: TABLE_NAMES.documentChunks,
    fields: [
      ['uuid_source', 'SingleLineText'],
      ['document_uuid_source', 'SingleLineText'],
      ['beneficiaire_id', 'SingleLineText'],
      ['dossier_id', 'SingleLineText'],
      ['beneficiaire_prenom', 'SingleLineText'],
      ['beneficiaire_nom', 'SingleLineText'],
      ['beneficiaire_nom_complet', 'SingleLineText'],
      ['dossier_libelle', 'SingleLineText'],
      ['chunk_index', 'Number'],
      ['chunk_base64', 'LongText'],
      ['updated_at', 'DateTime'],
    ],
  },
  notePages: {
    tableName: TABLE_NAMES.notePages,
    fields: [
      ['uuid_source', 'SingleLineText'],
      ['beneficiaire_id', 'SingleLineText'],
      ['dossier_id', 'SingleLineText'],
      ['beneficiaire_prenom', 'SingleLineText'],
      ['beneficiaire_nom', 'SingleLineText'],
      ['beneficiaire_nom_complet', 'SingleLineText'],
      ['dossier_libelle', 'SingleLineText'],
      ['scope_type', 'SingleLineText'],
      ['scope_id', 'SingleLineText'],
      ['tab_key', 'SingleLineText'],
      ['page_number', 'Number'],
      ['text_content', 'LongText'],
      ['drawing_json', 'LongText'],
      ['layout_kind', 'SingleLineText'],
      ['updated_at', 'DateTime'],
    ],
  },
};

const splitBase64IntoChunks = (base64) => {
  const normalized = stringValue(base64);
  if (!normalized) return [];

  const chunks = [];
  for (let index = 0; index < normalized.length; index += DOCUMENT_CONTENT_CHUNK_SIZE) {
    chunks.push(normalized.slice(index, index + DOCUMENT_CONTENT_CHUNK_SIZE));
  }
  return chunks;
};

const normalizeBeneficiaryMetadata = (metadata = {}) => {
  const patientFirstName = stringValue(metadata.patientFirstName).trim();
  const patientLastName = stringValue(metadata.patientLastName).trim();
  const patientDisplayName = stringValue(metadata.patientDisplayName).trim()
    || [patientFirstName, patientLastName].filter(Boolean).join(' ').trim();
  const dossierLabel = stringValue(metadata.dossierLabel).trim()
    || patientDisplayName
    || stringValue(metadata.dossierId).trim();

  return {
    patientFirstName,
    patientLastName,
    patientDisplayName,
    dossierLabel,
  };
};

const latestRecord = (records) => {
  const sorted = [...records].sort((a, b) => {
    const aDate = new Date(field(a, 'updated_at') || field(a, 'created_at') || 0).getTime();
    const bDate = new Date(field(b, 'updated_at') || field(b, 'created_at') || 0).getTime();
    if (aDate !== bDate) return bDate - aDate;
    return Number(b.id) - Number(a.id);
  });
  return sorted[0];
};

const safeSlug = (value, fallback = 'item') => {
  const normalized = String(value || '')
    .trim()
    .replace(/[^a-z0-9._-]+/gi, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .toLowerCase();
  return normalized || fallback;
};

const safeFileName = (value, fallback = 'document.bin') => {
  const normalized = String(value || '')
    .trim()
    .replace(/[/\\?%*:|"<>]+/g, '-')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
  return normalized || fallback;
};

const inferMimeTypeFromFileName = (fileName) => {
  const extension = String(fileName || '').trim().split('.').pop()?.toLowerCase() || '';
  return ({
    jpg: 'image/jpeg',
    jpeg: 'image/jpeg',
    png: 'image/png',
    webp: 'image/webp',
    gif: 'image/gif',
    bmp: 'image/bmp',
    svg: 'image/svg+xml',
    pdf: 'application/pdf',
  })[extension] || 'application/octet-stream';
};

const inferExtensionFromMimeType = (mimeType) => ({
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/gif': 'gif',
  'application/pdf': 'pdf',
})[String(mimeType || '').trim().toLowerCase()] || 'bin';

const normalizeMimeType = (mimeType, fileName) => {
  const normalized = String(mimeType || '').trim().toLowerCase();
  if (!normalized || normalized === 'application/octet-stream') {
    return inferMimeTypeFromFileName(fileName);
  }
  return normalized;
};

const decodeBase64FilePayload = ({ contentBase64, mimeType, fileName }) => {
  const rawValue = String(contentBase64 || '').trim();
  if (!rawValue) {
    throw new Error('Contenu fichier manquant');
  }

  const dataUrlMatch = rawValue.match(/^data:([^;]+);base64,(.+)$/);
  const resolvedMimeType = normalizeMimeType(
    dataUrlMatch?.[1]?.toLowerCase() || mimeType,
    fileName,
  );
  const base64Payload = dataUrlMatch?.[2] || rawValue;
  const buffer = Buffer.from(base64Payload, 'base64');

  if (buffer.length === 0) {
    throw new Error('Contenu fichier invalide');
  }

  return {
    mimeType: resolvedMimeType,
    buffer,
    base64: base64Payload,
  };
};

const readJsonStore = async (storeUrl, fallbackValue) => {
  try {
    const raw = await fs.readFile(storeUrl, 'utf8');
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object') {
      return fallbackValue;
    }
    return parsed;
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
    return fallbackValue;
  }
};

const writeJsonStore = async (storeUrl, payload) => {
  await fs.mkdir(DATA_DIR_URL, { recursive: true });
  await fs.writeFile(storeUrl, JSON.stringify(payload, null, 2));
};

const readDocumentStore = async () => {
  const store = await readJsonStore(DOCUMENT_STORE_URL, { version: 1, documents: [] });
  return {
    version: 1,
    documents: asArray(store.documents),
  };
};

const writeDocumentStore = async (store) => {
  await writeJsonStore(DOCUMENT_STORE_URL, {
    version: 1,
    documents: asArray(store.documents),
  });
};

const readNotePagesStore = async () => {
  const store = await readJsonStore(NOTE_PAGES_STORE_URL, { version: 1, notePages: [] });
  return {
    version: 1,
    notePages: asArray(store.notePages),
  };
};

const writeNotePagesStore = async (store) => {
  await writeJsonStore(NOTE_PAGES_STORE_URL, {
    version: 1,
    notePages: asArray(store.notePages),
  });
};

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

    if (!payload?.next || batch.length === 0) {
      break;
    }

    page += 1;
  }

  return records;
};

const createRecord = async (tableId, fields) => {
  const payload = await callNocoTool('createRecords', {
    tableId,
    records: [{ fields }],
  });

  return asArray(payload).at(0) || asArray(payload?.records).at(0);
};

const updateRecord = async (tableId, id, fields) => {
  await callNocoTool('updateRecords', {
    tableId,
    records: [{ id: String(id), fields }],
  });
};

const deleteRecord = async (tableId, id) => {
  await callNocoTool('deleteRecords', {
    tableId,
    records: [{ id: String(id) }],
  });
};

const discoverMobileSyncTables = async () => {
  const payload = await callNocoTool('getTablesList');
  const tables = asArray(payload);
  const documentsTable = tables.find((table) => String(table.title).trim().toLowerCase() === TABLE_NAMES.documents.toLowerCase());
  const documentChunksTable = tables.find((table) => String(table.title).trim().toLowerCase() === TABLE_NAMES.documentChunks.toLowerCase());
  const notePagesTable = tables.find((table) => String(table.title).trim().toLowerCase() === TABLE_NAMES.notePages.toLowerCase());

  if (!documentsTable || !documentChunksTable || !notePagesTable) {
    return null;
  }

  return {
    documentsTableId: String(documentsTable.id),
    documentChunksTableId: String(documentChunksTable.id),
    notePagesTableId: String(notePagesTable.id),
  };
};

const discoverMobileSyncTablesDetailed = async () => {
  const payload = await callNocoTool('getTablesList');
  const tables = asArray(payload);
  const documentsTable = tables.find((table) => String(table.title).trim().toLowerCase() === TABLE_NAMES.documents.toLowerCase()) || null;
  const documentChunksTable = tables.find((table) => String(table.title).trim().toLowerCase() === TABLE_NAMES.documentChunks.toLowerCase()) || null;
  const notePagesTable = tables.find((table) => String(table.title).trim().toLowerCase() === TABLE_NAMES.notePages.toLowerCase()) || null;

  return {
    documentsTable,
    documentChunksTable,
    notePagesTable,
  };
};

const listDocumentChunks = async (documentChunksTableId, documentId) => {
  const records = await queryAll(documentChunksTableId, {
    fields: ['document_uuid_source', 'chunk_index', 'chunk_base64', 'updated_at'],
    where: `(document_uuid_source,eq,${JSON.stringify(String(documentId))})`,
  });

  return records.sort((a, b) => Number(field(a, 'chunk_index')) - Number(field(b, 'chunk_index')));
};

const replaceDocumentChunks = async (documentChunksTableId, documentId, chunks, metadata = {}) => {
  const existingChunks = await listDocumentChunks(documentChunksTableId, documentId);
  const beneficiary = normalizeBeneficiaryMetadata(metadata);

  for (const chunkRecord of existingChunks) {
    await deleteRecord(documentChunksTableId, chunkRecord.id);
  }

  for (let index = 0; index < chunks.length; index += 1) {
    await createRecord(documentChunksTableId, {
      uuid_source: crypto.randomUUID(),
      document_uuid_source: String(documentId),
      beneficiaire_id: stringValue(metadata.patientId),
      dossier_id: stringValue(metadata.dossierId) || null,
      beneficiaire_prenom: beneficiary.patientFirstName,
      beneficiaire_nom: beneficiary.patientLastName,
      beneficiaire_nom_complet: beneficiary.patientDisplayName,
      dossier_libelle: beneficiary.dossierLabel,
      chunk_index: index,
      chunk_base64: chunks[index],
      updated_at: new Date().toISOString(),
    });
  }
};

const buildDocumentPayload = (document, absoluteUrl, mode) => {
  const contentPath = mode === 'nocodb'
    ? `/api/mobile-documents/${encodeURIComponent(document.id)}/content`
    : document.relativeUrl;

  return {
    id: document.id,
    patientId: document.patientId,
    dossierId: document.dossierId || null,
    patientFirstName: stringValue(document.patientFirstName),
    patientLastName: stringValue(document.patientLastName),
    patientDisplayName: stringValue(document.patientDisplayName),
    dossierLabel: stringValue(document.dossierLabel),
    title: document.title,
    fileName: document.fileName,
    mimeType: normalizeMimeType(document.mimeType, document.fileName),
    tags: asArray(document.tags).map((tag) => String(tag)),
    createdAt: document.createdAt,
    updatedAt: document.updatedAt,
    remotePath: contentPath,
    publicUrl: absoluteUrl(contentPath),
  };
};

const buildNotePagePayload = (notePage, absoluteUrl) => ({
  id: notePage.id,
  patientId: notePage.patientId,
  dossierId: notePage.dossierId || null,
  patientFirstName: stringValue(notePage.patientFirstName),
  patientLastName: stringValue(notePage.patientLastName),
  patientDisplayName: stringValue(notePage.patientDisplayName),
  dossierLabel: stringValue(notePage.dossierLabel),
  scopeType: notePage.scopeType || 'legacy',
  scopeId: notePage.scopeId || notePage.dossierId || notePage.patientId,
  tabKey: notePage.tabKey,
  pageNumber: Number(notePage.pageNumber) || 0,
  textContent: stringValue(notePage.textContent),
  drawingJson: stringValue(notePage.drawingJson),
  layoutKind: stringValue(notePage.layoutKind) || 'freeform',
  updatedAt: notePage.updatedAt,
  remotePath: `note-pages/${notePage.patientId}/${notePage.scopeType || 'legacy'}/${notePage.scopeId || notePage.dossierId || notePage.patientId}/${notePage.tabKey}/${Number(notePage.pageNumber) || 0}`,
  remoteUrl: absoluteUrl(`/api/note-pages/${encodeURIComponent(notePage.patientId)}?scopeType=${encodeURIComponent(notePage.scopeType || 'legacy')}&scopeId=${encodeURIComponent(notePage.scopeId || notePage.dossierId || notePage.patientId)}&tabKey=${encodeURIComponent(notePage.tabKey)}&pageNumber=${Number(notePage.pageNumber) || 0}`),
});

const localDocumentFileUrl = (document) => {
  const relativeUrl = stringValue(document?.relativeUrl).trim();
  if (!relativeUrl) return null;
  const relativePath = relativeUrl.replace(/^\/uploads\/documents\//, '');
  return new URL(relativePath, DOCUMENTS_DIR_URL);
};

const createLocalStoreAdapter = ({ absoluteUrl }) => ({
  mode: 'local',

  async listDocumentsByPatient(patientId, filters = {}) {
    const store = await readDocumentStore();
    return store.documents
      .filter((document) => String(document.patientId) === String(patientId))
      .filter((document) => !filters.dossierId || String(document.dossierId || '') === String(filters.dossierId))
      .sort((a, b) => new Date(b.updatedAt || b.createdAt || 0).getTime() - new Date(a.updatedAt || a.createdAt || 0).getTime())
      .map((document) => buildDocumentPayload(document, absoluteUrl, 'local'));
  },

  async getDocumentById(documentId) {
    const store = await readDocumentStore();
    const document = store.documents.find((entry) => String(entry.id) === String(documentId));
    return document ? buildDocumentPayload(document, absoluteUrl, 'local') : null;
  },

  async upsertDocument({ patientId, dossierId, documentLocalId, title, fileName, mimeType, tags, contentBase64 }) {
    const { mimeType: resolvedMimeType, buffer } = decodeBase64FilePayload({ contentBase64, mimeType, fileName });
    if (buffer.length > 15 * 1024 * 1024) {
      throw new Error('Fichier trop volumineux');
    }

    const store = await readDocumentStore();
    const existing = documentLocalId
      ? store.documents.find((document) =>
        String(document.patientId) === String(patientId)
        && String(document.clientDocumentId || '') === String(documentLocalId))
      : undefined;

    if (existing) {
      return buildDocumentPayload(existing, absoluteUrl, 'local');
    }

    const extension = inferExtensionFromMimeType(resolvedMimeType);
    let safeRequestedName = safeFileName(fileName || title, `document.${extension}`);
    if (!/\.[a-z0-9]{1,8}$/i.test(safeRequestedName)) {
      safeRequestedName = `${safeRequestedName}.${extension}`;
    }

    const patientDirName = safeSlug(patientId, 'patient');
    const patientDirUrl = new URL(`${patientDirName}/`, DOCUMENTS_DIR_URL);
    await fs.mkdir(patientDirUrl, { recursive: true });
    const storedFileName = `${Date.now()}-${safeRequestedName}`;
    const fileUrl = new URL(storedFileName, patientDirUrl);
    await fs.writeFile(fileUrl, buffer);

    const now = new Date().toISOString();
    const document = {
      id: crypto.randomUUID(),
      clientDocumentId: documentLocalId || null,
      patientId,
      dossierId: dossierId || null,
      title,
      fileName: safeRequestedName,
      mimeType: resolvedMimeType,
      tags: tags.length > 0 ? tags : ['Autre'],
      relativeUrl: `/uploads/documents/${patientDirName}/${storedFileName}`,
      createdAt: now,
      updatedAt: now,
    };

    store.documents.push(document);
    await writeDocumentStore(store);
    return buildDocumentPayload(document, absoluteUrl, 'local');
  },

  async updateDocument(documentId, updates = {}) {
    const store = await readDocumentStore();
    const existingIndex = store.documents.findIndex((document) => String(document.id) === String(documentId));
    if (existingIndex < 0) {
      return null;
    }

    const existing = store.documents[existingIndex];
    const currentFileName = stringValue(existing.fileName) || 'document.bin';
    const extension = currentFileName.includes('.')
      ? currentFileName.split('.').pop()
      : '';
    const nextTitle = stringValue(updates.title).trim() || stringValue(existing.title) || currentFileName.replace(/\.[^.]+$/, '') || 'Document';
    const nextFileName = extension
      ? `${nextTitle}.${extension}`
      : nextTitle;

    store.documents[existingIndex] = {
      ...existing,
      title: nextTitle,
      fileName: nextFileName,
      tags: asArray(updates.tags).length > 0 ? asArray(updates.tags).map((tag) => String(tag)) : asArray(existing.tags),
      updatedAt: new Date().toISOString(),
    };

    await writeDocumentStore(store);
    return buildDocumentPayload(store.documents[existingIndex], absoluteUrl, 'local');
  },

  async deleteDocument(documentId) {
    const store = await readDocumentStore();
    const existingIndex = store.documents.findIndex((document) => String(document.id) === String(documentId));
    if (existingIndex < 0) {
      return false;
    }

    const [removed] = store.documents.splice(existingIndex, 1);
    await writeDocumentStore(store);

    const fileUrl = localDocumentFileUrl(removed);
    if (fileUrl) {
      await fs.unlink(fileUrl).catch(() => undefined);
    }

    return true;
  },

  async listNotePagesByPatient(patientId, filters = {}) {
    const store = await readNotePagesStore();
    return store.notePages
      .filter((notePage) => String(notePage.patientId) === String(patientId))
      .filter((notePage) => !filters.scopeType || String(notePage.scopeType || 'legacy') === String(filters.scopeType))
      .filter((notePage) => !filters.scopeId || String(notePage.scopeId || notePage.dossierId || notePage.patientId) === String(filters.scopeId))
      .filter((notePage) => !filters.tabKey || String(notePage.tabKey) === String(filters.tabKey))
      .filter((notePage) => filters.pageNumber == null || Number(notePage.pageNumber) === Number(filters.pageNumber))
      .sort((a, b) => Number(a.pageNumber) - Number(b.pageNumber))
      .map((notePage) => buildNotePagePayload(notePage, absoluteUrl));
  },

  async createNotePage({ patientId, dossierId, scopeType, scopeId, tabKey, layoutKind, patientFirstName, patientLastName, patientDisplayName, dossierLabel }) {
    const store = await readNotePagesStore();
    const now = new Date().toISOString();
    const beneficiary = normalizeBeneficiaryMetadata({ patientFirstName, patientLastName, patientDisplayName, dossierLabel, dossierId });
    const matchingPages = store.notePages.filter((notePage) =>
      String(notePage.patientId) === String(patientId)
      && String(notePage.scopeType || 'legacy') === String(scopeType || 'legacy')
      && String(notePage.scopeId || notePage.dossierId || notePage.patientId) === String(scopeId || dossierId || patientId)
      && String(notePage.tabKey) === String(tabKey));
    const pageNumber = matchingPages.length === 0
      ? 0
      : Math.max(...matchingPages.map((notePage) => Number(notePage.pageNumber) || 0)) + 1;

    const notePage = {
      id: crypto.randomUUID(),
      patientId,
      dossierId: dossierId || null,
      patientFirstName: beneficiary.patientFirstName,
      patientLastName: beneficiary.patientLastName,
      patientDisplayName: beneficiary.patientDisplayName,
      dossierLabel: beneficiary.dossierLabel,
      scopeType: scopeType || 'legacy',
      scopeId: scopeId || dossierId || patientId,
      tabKey,
      pageNumber,
      textContent: '',
      drawingJson: '',
      layoutKind: layoutKind || 'freeform',
      updatedAt: now,
    };

    store.notePages.push(notePage);
    await writeNotePagesStore(store);
    return buildNotePagePayload(notePage, absoluteUrl);
  },

  async upsertNotePage({
    notePageId,
    patientId,
    dossierId,
    patientFirstName,
    patientLastName,
    patientDisplayName,
    dossierLabel,
    scopeType,
    scopeId,
    tabKey,
    pageNumber,
    textContent,
    drawingJson,
    layoutKind,
  }) {
    const store = await readNotePagesStore();
    const now = new Date().toISOString();
    const beneficiary = normalizeBeneficiaryMetadata({ patientFirstName, patientLastName, patientDisplayName, dossierLabel, dossierId });
    const existingIndex = store.notePages.findIndex((notePage) =>
      (notePageId && String(notePage.id) === String(notePageId))
      || (
        String(notePage.patientId) === String(patientId)
        && String(notePage.scopeType || 'legacy') === String(scopeType || 'legacy')
        && String(notePage.scopeId || notePage.dossierId || notePage.patientId) === String(scopeId || dossierId || patientId)
        && String(notePage.tabKey) === String(tabKey)
        && Number(notePage.pageNumber) === Number(pageNumber)
      ));

    const notePage = {
      id: existingIndex >= 0 ? store.notePages[existingIndex].id : crypto.randomUUID(),
      patientId,
      dossierId: dossierId || null,
      patientFirstName: beneficiary.patientFirstName,
      patientLastName: beneficiary.patientLastName,
      patientDisplayName: beneficiary.patientDisplayName,
      dossierLabel: beneficiary.dossierLabel,
      scopeType: scopeType || 'legacy',
      scopeId: scopeId || dossierId || patientId,
      tabKey,
      pageNumber,
      textContent: stringValue(textContent),
      drawingJson,
      layoutKind: layoutKind || 'freeform',
      updatedAt: now,
    };

    if (existingIndex >= 0) {
      store.notePages[existingIndex] = notePage;
    } else {
      store.notePages.push(notePage);
    }
    await writeNotePagesStore(store);
    return buildNotePagePayload(notePage, absoluteUrl);
  },

  async deleteNotePage(notePageId) {
    const store = await readNotePagesStore();
    const existingIndex = store.notePages.findIndex((notePage) => String(notePage.id) === String(notePageId));
    if (existingIndex < 0) {
      return false;
    }
    store.notePages.splice(existingIndex, 1);
    await writeNotePagesStore(store);
    return true;
  },

  async getDocumentContent(documentId) {
    const store = await readDocumentStore();
    const document = store.documents.find((entry) => String(entry.id) === String(documentId));
    if (!document?.relativeUrl) return null;
    const relativePath = document.relativeUrl.replace(/^\/uploads\/documents\//, '');
    const fileUrl = new URL(relativePath, DOCUMENTS_DIR_URL);
    const buffer = await fs.readFile(fileUrl);
    return {
      patientId: document.patientId,
      fileName: document.fileName,
      mimeType: normalizeMimeType(document.mimeType, document.fileName),
      buffer,
    };
  },
});

const createNocodbStoreAdapter = ({ absoluteUrl, documentsTableId, documentChunksTableId, notePagesTableId }) => ({
  mode: 'nocodb',

  async listDocumentsByPatient(patientId, filters = {}) {
    const clauses = [
      `(beneficiaire_id,eq,${JSON.stringify(String(patientId))})`,
    ];
    if (filters.dossierId) {
      clauses.push(`(dossier_id,eq,${JSON.stringify(String(filters.dossierId))})`);
    }

    const records = await queryAll(documentsTableId, {
      fields: ['uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet', 'dossier_libelle', 'titre', 'nom_fichier', 'mime_type', 'tags_json', 'created_at', 'updated_at'],
      where: clauses.join('~and'),
    });

    return records
      .map((record) => ({
        id: stringValue(field(record, 'uuid_source') || record.id),
        patientId: stringValue(field(record, 'beneficiaire_id')),
        dossierId: stringValue(field(record, 'dossier_id')) || null,
        patientFirstName: stringValue(field(record, 'beneficiaire_prenom')),
        patientLastName: stringValue(field(record, 'beneficiaire_nom')),
        patientDisplayName: stringValue(field(record, 'beneficiaire_nom_complet')),
        dossierLabel: stringValue(field(record, 'dossier_libelle')),
        title: stringValue(field(record, 'titre')),
        fileName: stringValue(field(record, 'nom_fichier')),
        mimeType: normalizeMimeType(
          stringValue(field(record, 'mime_type')),
          stringValue(field(record, 'nom_fichier')),
        ),
        tags: safeParseJsonArray(field(record, 'tags_json')),
        createdAt: stringValue(field(record, 'created_at')) || new Date().toISOString(),
        updatedAt: stringValue(field(record, 'updated_at')) || stringValue(field(record, 'created_at')) || new Date().toISOString(),
      }))
      .sort((a, b) => new Date(b.updatedAt || b.createdAt || 0).getTime() - new Date(a.updatedAt || a.createdAt || 0).getTime())
      .map((document) => buildDocumentPayload(document, absoluteUrl, 'nocodb'));
  },

  async getDocumentById(documentId) {
    const existing = latestRecord(await queryAll(documentsTableId, {
      fields: ['uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet', 'dossier_libelle', 'titre', 'nom_fichier', 'mime_type', 'tags_json', 'created_at', 'updated_at'],
      where: `(uuid_source,eq,${JSON.stringify(String(documentId))})`,
    }));

    if (!existing) {
      return null;
    }

    return buildDocumentPayload({
      id: stringValue(field(existing, 'uuid_source') || existing.id),
      patientId: stringValue(field(existing, 'beneficiaire_id')),
      dossierId: stringValue(field(existing, 'dossier_id')) || null,
      patientFirstName: stringValue(field(existing, 'beneficiaire_prenom')),
      patientLastName: stringValue(field(existing, 'beneficiaire_nom')),
      patientDisplayName: stringValue(field(existing, 'beneficiaire_nom_complet')),
      dossierLabel: stringValue(field(existing, 'dossier_libelle')),
      title: stringValue(field(existing, 'titre')),
      fileName: stringValue(field(existing, 'nom_fichier')),
      mimeType: stringValue(field(existing, 'mime_type')) || 'application/octet-stream',
      tags: safeParseJsonArray(field(existing, 'tags_json')),
      createdAt: stringValue(field(existing, 'created_at')) || new Date().toISOString(),
      updatedAt: stringValue(field(existing, 'updated_at')) || stringValue(field(existing, 'created_at')) || new Date().toISOString(),
    }, absoluteUrl, 'nocodb');
  },

  async upsertDocument({ patientId, dossierId, documentLocalId, title, fileName, mimeType, tags, contentBase64, patientFirstName, patientLastName, patientDisplayName, dossierLabel }) {
    const { mimeType: resolvedMimeType, buffer, base64 } = decodeBase64FilePayload({ contentBase64, mimeType, fileName });
    if (buffer.length > 5 * 1024 * 1024) {
      throw new Error('Fichier trop volumineux pour le stockage NocoDB (> 5 MB)');
    }

    const existingRecords = documentLocalId
      ? await queryAll(documentsTableId, {
        fields: ['uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet', 'dossier_libelle', 'titre', 'nom_fichier', 'mime_type', 'tags_json', 'created_at', 'updated_at', 'client_document_id'],
        where: `(beneficiaire_id,eq,${JSON.stringify(String(patientId))})~and(client_document_id,eq,${JSON.stringify(String(documentLocalId))})`,
      })
      : [];

    const existing = latestRecord(existingRecords);
    const now = new Date().toISOString();
    const storedInlineContent = base64.length <= MAX_NOCODB_LONG_TEXT_LENGTH ? base64 : '';
    const beneficiary = normalizeBeneficiaryMetadata({ patientFirstName, patientLastName, patientDisplayName, dossierLabel, dossierId });
    if (existing) {
      await updateRecord(documentsTableId, existing.id, {
        dossier_id: dossierId || null,
        beneficiaire_prenom: beneficiary.patientFirstName,
        beneficiaire_nom: beneficiary.patientLastName,
        beneficiaire_nom_complet: beneficiary.patientDisplayName,
        dossier_libelle: beneficiary.dossierLabel,
        client_document_id: documentLocalId || null,
        titre: title,
        nom_fichier: fileName,
        mime_type: resolvedMimeType,
        tags_json: JSON.stringify(tags.length > 0 ? tags : ['Autre']),
        contenu_base64: storedInlineContent,
        updated_at: now,
      });

      if (storedInlineContent) {
        await replaceDocumentChunks(documentChunksTableId, stringValue(field(existing, 'uuid_source') || existing.id), [], {
          patientId,
          dossierId,
          patientFirstName,
          patientLastName,
          patientDisplayName,
          dossierLabel,
        });
      } else {
        await replaceDocumentChunks(documentChunksTableId, stringValue(field(existing, 'uuid_source') || existing.id), splitBase64IntoChunks(base64), {
          patientId,
          dossierId,
          patientFirstName,
          patientLastName,
          patientDisplayName,
          dossierLabel,
        });
      }

      return buildDocumentPayload({
        id: stringValue(field(existing, 'uuid_source') || existing.id),
        patientId,
        dossierId: dossierId || null,
        patientFirstName: beneficiary.patientFirstName,
        patientLastName: beneficiary.patientLastName,
        patientDisplayName: beneficiary.patientDisplayName,
        dossierLabel: beneficiary.dossierLabel,
        title,
        fileName,
        mimeType: resolvedMimeType,
        tags: tags.length > 0 ? tags : ['Autre'],
        createdAt: stringValue(field(existing, 'created_at')),
        updatedAt: now,
      }, absoluteUrl, 'nocodb');
    }

    const documentId = crypto.randomUUID();
    const created = await createRecord(documentsTableId, {
      uuid_source: documentId,
      beneficiaire_id: patientId,
      dossier_id: dossierId || null,
      beneficiaire_prenom: beneficiary.patientFirstName,
      beneficiaire_nom: beneficiary.patientLastName,
      beneficiaire_nom_complet: beneficiary.patientDisplayName,
      dossier_libelle: beneficiary.dossierLabel,
      client_document_id: documentLocalId || null,
      titre: title,
      nom_fichier: fileName,
      mime_type: resolvedMimeType,
      tags_json: JSON.stringify(tags.length > 0 ? tags : ['Autre']),
      contenu_base64: storedInlineContent,
      created_at: now,
      updated_at: now,
    });

    if (!storedInlineContent) {
      await replaceDocumentChunks(documentChunksTableId, documentId, splitBase64IntoChunks(base64), {
        patientId,
        dossierId,
        patientFirstName,
        patientLastName,
        patientDisplayName,
        dossierLabel,
      });
    }

    return buildDocumentPayload({
      id: stringValue(field(created, 'uuid_source') || documentId),
      patientId,
      dossierId: dossierId || null,
      patientFirstName: beneficiary.patientFirstName,
      patientLastName: beneficiary.patientLastName,
      patientDisplayName: beneficiary.patientDisplayName,
      dossierLabel: beneficiary.dossierLabel,
      title,
      fileName,
      mimeType: resolvedMimeType,
      tags: tags.length > 0 ? tags : ['Autre'],
      createdAt: now,
      updatedAt: now,
    }, absoluteUrl, 'nocodb');
  },

  async updateDocument(documentId, updates = {}) {
    const existing = latestRecord(await queryAll(documentsTableId, {
      fields: ['uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet', 'dossier_libelle', 'titre', 'nom_fichier', 'mime_type', 'tags_json', 'created_at', 'updated_at'],
      where: `(uuid_source,eq,${JSON.stringify(String(documentId))})`,
    }));

    if (!existing) {
      return null;
    }

    const currentFileName = stringValue(field(existing, 'nom_fichier')) || 'document.bin';
    const extension = currentFileName.includes('.')
      ? currentFileName.split('.').pop()
      : '';
    const nextTitle = stringValue(updates.title).trim() || stringValue(field(existing, 'titre')) || currentFileName.replace(/\.[^.]+$/, '') || 'Document';
    const nextFileName = extension ? `${nextTitle}.${extension}` : nextTitle;
    const nextTags = asArray(updates.tags).length > 0
      ? asArray(updates.tags).map((tag) => String(tag))
      : safeParseJsonArray(field(existing, 'tags_json'));
    const now = new Date().toISOString();

    await updateRecord(documentsTableId, existing.id, {
      titre: nextTitle,
      nom_fichier: nextFileName,
      tags_json: JSON.stringify(nextTags),
      updated_at: now,
    });

    return buildDocumentPayload({
      id: stringValue(field(existing, 'uuid_source') || existing.id),
      patientId: stringValue(field(existing, 'beneficiaire_id')),
      dossierId: stringValue(field(existing, 'dossier_id')) || null,
      patientFirstName: stringValue(field(existing, 'beneficiaire_prenom')),
      patientLastName: stringValue(field(existing, 'beneficiaire_nom')),
      patientDisplayName: stringValue(field(existing, 'beneficiaire_nom_complet')),
      dossierLabel: stringValue(field(existing, 'dossier_libelle')),
      title: nextTitle,
      fileName: nextFileName,
      mimeType: stringValue(field(existing, 'mime_type')) || 'application/octet-stream',
      tags: nextTags,
      createdAt: stringValue(field(existing, 'created_at')) || now,
      updatedAt: now,
    }, absoluteUrl, 'nocodb');
  },

  async deleteDocument(documentId) {
    const existing = latestRecord(await queryAll(documentsTableId, {
      fields: ['uuid_source'],
      where: `(uuid_source,eq,${JSON.stringify(String(documentId))})`,
    }));
    if (!existing) {
      return false;
    }
    const documentUuid = stringValue(field(existing, 'uuid_source') || documentId);
    const chunks = await listDocumentChunks(documentChunksTableId, documentUuid);
    for (const chunk of chunks) {
      await deleteRecord(documentChunksTableId, chunk.id);
    }
    await deleteRecord(documentsTableId, existing.id);
    return true;
  },

  async listNotePagesByPatient(patientId, filters = {}) {
    const clauses = [
      `(beneficiaire_id,eq,${JSON.stringify(String(patientId))})`,
    ];
    if (filters.scopeType) {
      clauses.push(`(scope_type,eq,${JSON.stringify(String(filters.scopeType))})`);
    }
    if (filters.scopeId) {
      clauses.push(`(scope_id,eq,${JSON.stringify(String(filters.scopeId))})`);
    }
    if (filters.tabKey) {
      clauses.push(`(tab_key,eq,${JSON.stringify(String(filters.tabKey))})`);
    }
    if (filters.pageNumber != null) {
      clauses.push(`(page_number,eq,${Number(filters.pageNumber)})`);
    }

    const records = await queryAll(notePagesTableId, {
      fields: ['uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet', 'dossier_libelle', 'scope_type', 'scope_id', 'tab_key', 'page_number', 'text_content', 'drawing_json', 'layout_kind', 'updated_at'],
      where: clauses.join('~and'),
    });

    return records
      .map((record) => ({
        id: stringValue(field(record, 'uuid_source') || record.id),
        patientId: stringValue(field(record, 'beneficiaire_id')),
        dossierId: stringValue(field(record, 'dossier_id')) || null,
        patientFirstName: stringValue(field(record, 'beneficiaire_prenom')),
        patientLastName: stringValue(field(record, 'beneficiaire_nom')),
        patientDisplayName: stringValue(field(record, 'beneficiaire_nom_complet')),
        dossierLabel: stringValue(field(record, 'dossier_libelle')),
        scopeType: stringValue(field(record, 'scope_type')) || 'legacy',
        scopeId: stringValue(field(record, 'scope_id')) || stringValue(field(record, 'dossier_id')) || stringValue(field(record, 'beneficiaire_id')),
        tabKey: stringValue(field(record, 'tab_key')),
        pageNumber: Number(field(record, 'page_number')) || 0,
        textContent: stringValue(field(record, 'text_content')),
        drawingJson: stringValue(field(record, 'drawing_json')),
        layoutKind: stringValue(field(record, 'layout_kind')) || 'freeform',
        updatedAt: stringValue(field(record, 'updated_at')) || new Date().toISOString(),
      }))
      .sort((a, b) => Number(a.pageNumber) - Number(b.pageNumber))
      .map((notePage) => buildNotePagePayload(notePage, absoluteUrl));
  },

  async createNotePage({ patientId, dossierId, scopeType, scopeId, tabKey, layoutKind, patientFirstName, patientLastName, patientDisplayName, dossierLabel }) {
    const records = await queryAll(notePagesTableId, {
      fields: ['page_number'],
      where: `(beneficiaire_id,eq,${JSON.stringify(String(patientId))})~and(scope_type,eq,${JSON.stringify(String(scopeType || 'legacy'))})~and(scope_id,eq,${JSON.stringify(String(scopeId || dossierId || patientId))})~and(tab_key,eq,${JSON.stringify(String(tabKey))})`,
    });
    const pageNumber = records.length === 0
      ? 0
      : Math.max(...records.map((record) => Number(field(record, 'page_number')) || 0)) + 1;
    const now = new Date().toISOString();
    const createdNotePageId = crypto.randomUUID();
    const beneficiary = normalizeBeneficiaryMetadata({ patientFirstName, patientLastName, patientDisplayName, dossierLabel, dossierId });
    const created = await createRecord(notePagesTableId, {
      uuid_source: createdNotePageId,
      beneficiaire_id: patientId,
      dossier_id: dossierId || null,
      beneficiaire_prenom: beneficiary.patientFirstName,
      beneficiaire_nom: beneficiary.patientLastName,
      beneficiaire_nom_complet: beneficiary.patientDisplayName,
      dossier_libelle: beneficiary.dossierLabel,
      scope_type: scopeType || 'legacy',
      scope_id: scopeId || dossierId || patientId,
      tab_key: tabKey,
      page_number: Number(pageNumber) || 0,
      text_content: '',
      drawing_json: '',
      layout_kind: layoutKind || 'freeform',
      updated_at: now,
    });

    return buildNotePagePayload({
        id: stringValue(field(created, 'uuid_source') || createdNotePageId),
        patientId,
        dossierId: dossierId || null,
        patientFirstName: beneficiary.patientFirstName,
        patientLastName: beneficiary.patientLastName,
        patientDisplayName: beneficiary.patientDisplayName,
        dossierLabel: beneficiary.dossierLabel,
        scopeType: scopeType || 'legacy',
        scopeId: scopeId || dossierId || patientId,
        tabKey,
      pageNumber,
      textContent: '',
      drawingJson: '',
      layoutKind: layoutKind || 'freeform',
      updatedAt: now,
    }, absoluteUrl);
  },

  async upsertNotePage({
    notePageId,
    patientId,
    dossierId,
    scopeType,
    scopeId,
    tabKey,
    pageNumber,
    textContent,
    drawingJson,
    layoutKind,
    patientFirstName,
    patientLastName,
    patientDisplayName,
    dossierLabel,
  }) {
    const where = notePageId
      ? `(uuid_source,eq,${JSON.stringify(String(notePageId))})`
      : `(beneficiaire_id,eq,${JSON.stringify(String(patientId))})~and(scope_type,eq,${JSON.stringify(String(scopeType || 'legacy'))})~and(scope_id,eq,${JSON.stringify(String(scopeId || dossierId || patientId))})~and(tab_key,eq,${JSON.stringify(String(tabKey))})~and(page_number,eq,${Number(pageNumber)})`;
    const existing = latestRecord(await queryAll(notePagesTableId, {
      fields: ['uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaire_prenom', 'beneficiaire_nom', 'beneficiaire_nom_complet', 'dossier_libelle', 'scope_type', 'scope_id', 'tab_key', 'page_number', 'text_content', 'drawing_json', 'layout_kind', 'updated_at'],
      where,
    }));

    const now = new Date().toISOString();
    const beneficiary = normalizeBeneficiaryMetadata({ patientFirstName, patientLastName, patientDisplayName, dossierLabel, dossierId });
    if (existing) {
      await updateRecord(notePagesTableId, existing.id, {
        dossier_id: dossierId || null,
        beneficiaire_prenom: beneficiary.patientFirstName,
        beneficiaire_nom: beneficiary.patientLastName,
        beneficiaire_nom_complet: beneficiary.patientDisplayName,
        dossier_libelle: beneficiary.dossierLabel,
        scope_type: scopeType || 'legacy',
        scope_id: scopeId || dossierId || patientId,
        text_content: stringValue(textContent),
        drawing_json: drawingJson,
        layout_kind: layoutKind || 'freeform',
        updated_at: now,
      });

      return buildNotePagePayload({
        id: stringValue(field(existing, 'uuid_source') || existing.id),
        patientId,
        dossierId: dossierId || null,
        patientFirstName: beneficiary.patientFirstName,
        patientLastName: beneficiary.patientLastName,
        patientDisplayName: beneficiary.patientDisplayName,
        dossierLabel: beneficiary.dossierLabel,
        scopeType: scopeType || 'legacy',
        scopeId: scopeId || dossierId || patientId,
        tabKey,
        pageNumber,
        textContent: stringValue(textContent),
        drawingJson,
        layoutKind: layoutKind || 'freeform',
        updatedAt: now,
      }, absoluteUrl);
    }

    const createdNotePageId = crypto.randomUUID();
    const created = await createRecord(notePagesTableId, {
      uuid_source: createdNotePageId,
      beneficiaire_id: patientId,
      dossier_id: dossierId || null,
      beneficiaire_prenom: beneficiary.patientFirstName,
      beneficiaire_nom: beneficiary.patientLastName,
      beneficiaire_nom_complet: beneficiary.patientDisplayName,
      dossier_libelle: beneficiary.dossierLabel,
      scope_type: scopeType || 'legacy',
      scope_id: scopeId || dossierId || patientId,
      tab_key: tabKey,
      page_number: Number(pageNumber) || 0,
      text_content: stringValue(textContent),
      drawing_json: drawingJson,
      layout_kind: layoutKind || 'freeform',
      updated_at: now,
    });

    return buildNotePagePayload({
      id: stringValue(field(created, 'uuid_source') || createdNotePageId),
      patientId,
      dossierId: dossierId || null,
      patientFirstName: beneficiary.patientFirstName,
      patientLastName: beneficiary.patientLastName,
      patientDisplayName: beneficiary.patientDisplayName,
      dossierLabel: beneficiary.dossierLabel,
      scopeType: scopeType || 'legacy',
      scopeId: scopeId || dossierId || patientId,
      tabKey,
      pageNumber,
      textContent: stringValue(textContent),
      drawingJson,
      layoutKind: layoutKind || 'freeform',
      updatedAt: now,
    }, absoluteUrl);
  },

  async deleteNotePage(notePageId) {
    const existing = latestRecord(await queryAll(notePagesTableId, {
      fields: ['uuid_source'],
      where: `(uuid_source,eq,${JSON.stringify(String(notePageId))})`,
    }));
    if (!existing) {
      return false;
    }
    await deleteRecord(notePagesTableId, existing.id);
    return true;
  },

  async getDocumentContent(documentId) {
    const record = latestRecord(await queryAll(documentsTableId, {
      fields: ['uuid_source', 'beneficiaire_id', 'nom_fichier', 'mime_type', 'contenu_base64'],
      where: `(uuid_source,eq,${JSON.stringify(String(documentId))})`,
    }));

    if (!record) {
      return null;
    }

    const inlineContent = stringValue(field(record, 'contenu_base64'));
    const chunkedContent = inlineContent
      ? inlineContent
      : (await listDocumentChunks(documentChunksTableId, stringValue(field(record, 'uuid_source') || documentId)))
        .map((chunk) => stringValue(field(chunk, 'chunk_base64')))
        .join('');

    return {
      patientId: stringValue(field(record, 'beneficiaire_id')),
      fileName: stringValue(field(record, 'nom_fichier')) || 'document.bin',
      mimeType: normalizeMimeType(
        stringValue(field(record, 'mime_type')),
        stringValue(field(record, 'nom_fichier')),
      ),
      buffer: Buffer.from(chunkedContent, 'base64'),
    };
  },
});

export const createMobileSyncStore = ({ absoluteUrl }) => {
  let adapterPromise;

  const getAdapter = async ({ forceRefresh = false } = {}) => {
    if (!adapterPromise || forceRefresh) {
      adapterPromise = discoverMobileSyncTables()
        .then((tables) => tables
          ? createNocodbStoreAdapter({ absoluteUrl, ...tables })
          : createLocalStoreAdapter({ absoluteUrl }))
        .catch(() => createLocalStoreAdapter({ absoluteUrl }));
    }

    return adapterPromise;
  };

  return {
    schemaSpec: MOBILE_SYNC_SCHEMA_SPEC,

    async getMode({ forceRefresh = false } = {}) {
      const adapter = await getAdapter({ forceRefresh });
      return adapter.mode;
    },

    async getMigrationStatus() {
      const tables = await discoverMobileSyncTables().catch(() => null);
      const localDocuments = await readDocumentStore();
      const localNotePages = await readNotePagesStore();
      const remoteCounts = {
        documents: 0,
        notePages: 0,
      };

      if (tables) {
        remoteCounts.documents = (await queryAll(tables.documentsTableId, {
          fields: ['uuid_source'],
        })).length;
        remoteCounts.notePages = (await queryAll(tables.notePagesTableId, {
          fields: ['uuid_source'],
        })).length;
      }

      return {
        mode: await this.getMode({ forceRefresh: true }),
        nocodbTablesReady: Boolean(tables),
        localCounts: {
          documents: localDocuments.documents.length,
          notePages: localNotePages.notePages.length,
        },
        remoteCounts,
      };
    },

    async getSchemaCheck() {
      const discovered = await discoverMobileSyncTablesDetailed().catch(() => ({
        documentsTable: null,
        notePagesTable: null,
      }));
      const checks = {};
      let isValid = true;

      for (const [key, spec] of Object.entries(MOBILE_SYNC_SCHEMA_SPEC)) {
        const tableRef = key === 'documents'
          ? discovered.documentsTable
          : key === 'documentChunks'
            ? discovered.documentChunksTable
            : discovered.notePagesTable;

        if (!tableRef) {
          checks[key] = {
            tableName: spec.tableName,
            exists: false,
            valid: false,
            missingFields: spec.fields.map(([name, type]) => ({ name, expectedType: type })),
            mismatchedFields: [],
            extraFields: [],
          };
          isValid = false;
          continue;
        }

        const schema = await callNocoTool('getTableSchema', { tableId: String(tableRef.id) });
        const existingFields = asArray(schema?.fields)
          .map((entry) => ({
            name: stringValue(entry?.title),
            type: stringValue(entry?.type),
          }))
          .filter((entry) => entry.name !== 'Id');
        const existingByName = new Map(existingFields.map((entry) => [entry.name, entry.type]));
        const expectedByName = new Map(spec.fields);
        const missingFields = [];
        const mismatchedFields = [];
        const extraFields = [];

        for (const [fieldName, expectedType] of spec.fields) {
          if (!existingByName.has(fieldName)) {
            missingFields.push({ name: fieldName, expectedType });
            continue;
          }

          const actualType = existingByName.get(fieldName);
          if (actualType !== expectedType) {
            mismatchedFields.push({
              name: fieldName,
              expectedType,
              actualType,
            });
          }
        }

        for (const entry of existingFields) {
          if (!expectedByName.has(entry.name)) {
            extraFields.push(entry);
          }
        }

        const valid = missingFields.length === 0 && mismatchedFields.length === 0;
        if (!valid) {
          isValid = false;
        }

        checks[key] = {
          tableName: spec.tableName,
          tableId: String(tableRef.id),
          exists: true,
          valid,
          missingFields,
          mismatchedFields,
          extraFields,
        };
      }

      return {
        valid: isValid,
        checks,
      };
    },

    async migrateLocalToNocodb() {
      const tables = await discoverMobileSyncTables();
      if (!tables) {
        throw new Error('Tables NocoDB mobiles introuvables');
      }

      const nocodbAdapter = createNocodbStoreAdapter({ absoluteUrl, ...tables });
      const localDocuments = await readDocumentStore();
      const localNotePages = await readNotePagesStore();
      const summary = {
        modeBefore: await this.getMode({ forceRefresh: true }),
        documents: {
          total: localDocuments.documents.length,
          migrated: 0,
          failed: 0,
          failures: [],
        },
        notePages: {
          total: localNotePages.notePages.length,
          migrated: 0,
          failed: 0,
          failures: [],
        },
      };

      for (const document of localDocuments.documents) {
        try {
          const fileUrl = localDocumentFileUrl(document);
          if (!fileUrl) {
            throw new Error('Fichier local introuvable dans le store');
          }
          const buffer = await fs.readFile(fileUrl);
          await nocodbAdapter.upsertDocument({
            patientId: stringValue(document.patientId),
            dossierId: stringValue(document.dossierId) || null,
            documentLocalId: stringValue(document.clientDocumentId || document.id),
            title: stringValue(document.title) || stringValue(document.fileName) || 'Document',
            fileName: stringValue(document.fileName) || 'document.bin',
            mimeType: stringValue(document.mimeType) || 'application/octet-stream',
            tags: asArray(document.tags).map((tag) => String(tag)),
            contentBase64: buffer.toString('base64'),
          });
          summary.documents.migrated += 1;
        } catch (error) {
          summary.documents.failed += 1;
          summary.documents.failures.push({
            id: stringValue(document.id),
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }

      for (const notePage of localNotePages.notePages) {
        try {
          await nocodbAdapter.upsertNotePage({
            notePageId: stringValue(notePage.id) || undefined,
            patientId: stringValue(notePage.patientId),
            dossierId: stringValue(notePage.dossierId) || null,
            patientFirstName: stringValue(notePage.patientFirstName),
            patientLastName: stringValue(notePage.patientLastName),
            patientDisplayName: stringValue(notePage.patientDisplayName),
            dossierLabel: stringValue(notePage.dossierLabel),
            scopeType: stringValue(notePage.scopeType) || 'legacy',
            scopeId: stringValue(notePage.scopeId) || stringValue(notePage.dossierId) || stringValue(notePage.patientId),
            tabKey: stringValue(notePage.tabKey),
            pageNumber: Number(notePage.pageNumber) || 0,
            textContent: stringValue(notePage.textContent),
            drawingJson: stringValue(notePage.drawingJson),
            layoutKind: stringValue(notePage.layoutKind) || 'freeform',
          });
          summary.notePages.migrated += 1;
        } catch (error) {
          summary.notePages.failed += 1;
          summary.notePages.failures.push({
            id: stringValue(notePage.id),
            error: error instanceof Error ? error.message : String(error),
          });
        }
      }

      await getAdapter({ forceRefresh: true });

      return {
        ...summary,
        modeAfter: await this.getMode({ forceRefresh: true }),
      };
    },

    async listDocumentsByPatient(patientId, filters) {
      const adapter = await getAdapter();
      return adapter.listDocumentsByPatient(patientId, filters);
    },

    async getDocumentById(documentId) {
      const adapter = await getAdapter();
      return adapter.getDocumentById(documentId);
    },

    async upsertDocument(payload) {
      const adapter = await getAdapter();
      return adapter.upsertDocument(payload);
    },

    async updateDocument(documentId, updates) {
      const adapter = await getAdapter();
      return adapter.updateDocument(documentId, updates);
    },

    async deleteDocument(documentId) {
      const adapter = await getAdapter();
      return adapter.deleteDocument(documentId);
    },

    async listNotePagesByPatient(patientId, filters) {
      const adapter = await getAdapter();
      return adapter.listNotePagesByPatient(patientId, filters);
    },

    async createNotePage(payload) {
      const adapter = await getAdapter();
      return adapter.createNotePage(payload);
    },

    async upsertNotePage(payload) {
      const adapter = await getAdapter();
      return adapter.upsertNotePage(payload);
    },

    async deleteNotePage(notePageId) {
      const adapter = await getAdapter();
      return adapter.deleteNotePage(notePageId);
    },

    async getDocumentContent(documentId) {
      const adapter = await getAdapter();
      return adapter.getDocumentContent(documentId);
    },
  };
};
