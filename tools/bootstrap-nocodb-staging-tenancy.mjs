#!/usr/bin/env node
// Ajoute le socle multi-organisation dans une base NocoDB staging.
//
// Par défaut : dry-run, aucune écriture.
// Écriture réelle uniquement avec :
//   --apply
//   NOCODB_RESTORE_ALLOW_APPLY=1
//   NOCODB_RESTORE_TARGET=staging
//   NOCODB_BASE_ID différent de la production

import process from 'node:process';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local', quiet: true });

const apply = process.argv.includes('--apply');

const API_URL = String(process.env.NOCODB_API_URL || '').trim().replace(/\/+$/, '');
const API_TOKEN = String(process.env.NOCODB_API_TOKEN || '').trim();
const BASE_ID = String(process.env.NOCODB_BASE_ID || '').trim();
const ALLOW_APPLY = process.env.NOCODB_RESTORE_ALLOW_APPLY === '1';
const RESTORE_TARGET = String(process.env.NOCODB_RESTORE_TARGET || '').trim().toLowerCase();
const MAX_RETRIES = Math.min(8, Math.max(0, Number(process.env.NOCODB_RESTORE_MAX_RETRIES) || 4));
const REQUEST_DELAY_MS = Math.max(0, Number(process.env.NOCODB_RESTORE_REQUEST_DELAY_MS) || 0);
const BATCH_SIZE = Math.min(100, Math.max(1, Number(process.env.NOCODB_TENANCY_BATCH_SIZE) || 50));

const PROD_BASE_ID = 'pskgbjythubfzv9';
const ORGANISATIONS_TABLE_TITLE = 'organisations';
const DEFAULT_ORGANISATION_ID = String(process.env.NOCODB_DEFAULT_ORGANISATION_ID || 'org_aidhabitat').trim();
const DEFAULT_ORGANISATION_NAME = String(process.env.NOCODB_DEFAULT_ORGANISATION_NAME || "Aid'Habitat").trim();

const TENANT_TABLES = [
  'Beneficiaires',
  '📁 dossiers',
  'Logements',
  '👨‍👩‍👧 contexte_de_vie',
  '📋 informations_administratives',
  '🚿 diagnostic_sanitaires',
  '📏 mesures_anthropometriques',
  '📝 observations',
  'mobile_documents',
  'mobile_document_chunks',
  'mobile_note_pages',
  'mobile_visit_photos',
  'mobile_visit_recommendations',
  '👷🏻‍♀️ ergotherapeutes',
  'etablissements',
];

const fail = (message) => {
  console.error(`[bootstrap-nocodb-staging-tenancy] ÉCHEC: ${message}`);
  process.exit(1);
};

if (apply) {
  if (!ALLOW_APPLY) fail('écriture refusée: définir NOCODB_RESTORE_ALLOW_APPLY=1');
  if (RESTORE_TARGET !== 'staging') fail('écriture refusée: définir NOCODB_RESTORE_TARGET=staging');
  if (!API_URL || !API_TOKEN || !BASE_ID) {
    fail('écriture refusée: NOCODB_API_URL, NOCODB_API_TOKEN et NOCODB_BASE_ID requis');
  }
  if (BASE_ID === PROD_BASE_ID) {
    fail('écriture refusée: NOCODB_BASE_ID correspond à la production');
  }
}

const headers = {
  'xc-token': API_TOKEN,
  'Content-Type': 'application/json',
  Accept: 'application/json',
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const isRetryable = (status, text) => (
  status === 429
  || status === 500
  || status === 502
  || status === 503
  || status === 504
  || /ERR_BASE_NOT_FOUND/i.test(text)
);

const requestOnce = async (method, requestPath, body) => {
  const response = await fetch(`${API_URL}${requestPath}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let payload;
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    payload = text;
  }
  if (!response.ok) {
    throw new Error(`${method} ${requestPath} ${response.status}: ${text.slice(0, 800)}`);
  }
  return payload;
};

const request = async (method, requestPath, body) => {
  let lastError = null;
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt += 1) {
    try {
      const payload = await requestOnce(method, requestPath, body);
      if (REQUEST_DELAY_MS > 0) await sleep(REQUEST_DELAY_MS);
      return payload;
    } catch (error) {
      lastError = error;
      const message = String(error?.message || '');
      const status = Number(message.match(/\s(\d{3}):/)?.[1] || 0);
      if (attempt >= MAX_RETRIES || !isRetryable(status, message)) break;
      const backoff = Math.min(10_000, 700 * (2 ** attempt));
      console.warn(`[bootstrap-nocodb-staging-tenancy] retry ${attempt + 1}/${MAX_RETRIES} dans ${backoff}ms: ${message.slice(0, 180)}`);
      await sleep(backoff);
    }
  }
  throw lastError;
};

const listTables = async () => {
  const payload = await request('GET', `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`);
  return Array.isArray(payload?.list) ? payload.list : Array.isArray(payload) ? payload : [];
};

const getTable = async (tableId) => request('GET', `/api/v2/meta/tables/${encodeURIComponent(tableId)}`);

const findColumn = (table, title) => (
  (table?.columns || []).find((column) => String(column.title).trim() === title)
);

const createOrganisationsTable = async () => request(
  'POST',
  `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`,
  {
    title: ORGANISATIONS_TABLE_TITLE,
    table_name: 'organisations',
    columns: [
      {
        title: 'organisation_id',
        column_name: 'organisation_id',
        uidt: 'SingleLineText',
        dt: 'character varying',
      },
      {
        title: 'nom',
        column_name: 'nom',
        uidt: 'SingleLineText',
        dt: 'character varying',
      },
      {
        title: 'statut',
        column_name: 'statut',
        uidt: 'SingleLineText',
        dt: 'character varying',
      },
    ],
  },
);

const createOrganisationColumn = async (tableId) => request(
  'POST',
  `/api/v2/meta/tables/${encodeURIComponent(tableId)}/columns`,
  {
    title: 'organisation_id',
    column_name: 'organisation_id',
    uidt: 'SingleLineText',
    dt: 'character varying',
  },
);

const fetchRecords = async (tableId) => {
  const records = [];
  let offset = 0;
  const limit = 1000;
  for (;;) {
    const payload = await request(
      'GET',
      `/api/v2/tables/${encodeURIComponent(tableId)}/records?limit=${limit}&offset=${offset}`,
    );
    const list = Array.isArray(payload?.list) ? payload.list : [];
    records.push(...list);
    if (list.length < limit) break;
    offset += limit;
  }
  return records;
};

const createRecord = async (tableId, record) => request(
  'POST',
  `/api/v2/tables/${encodeURIComponent(tableId)}/records`,
  record,
);

const updateRecords = async (tableId, records) => {
  let updated = 0;
  for (let index = 0; index < records.length; index += BATCH_SIZE) {
    const batch = records.slice(index, index + BATCH_SIZE);
    if (apply) {
      await request('PATCH', `/api/v2/tables/${encodeURIComponent(tableId)}/records`, batch);
    }
    updated += batch.length;
  }
  return updated;
};

const tables = await listTables();
const tableByTitle = new Map(tables.map((table) => [table.title, table]));
const missingTables = TENANT_TABLES.filter((title) => !tableByTitle.has(title));

const existingOrgTable = tableByTitle.get(ORGANISATIONS_TABLE_TITLE) || null;
const planned = {
  createOrganisationsTable: !existingOrgTable,
  ensureOrganisationRecord: true,
  addOrganisationColumnTo: [],
  backfillTables: [],
  missingTables,
};

for (const title of TENANT_TABLES) {
  const tableRef = tableByTitle.get(title);
  if (!tableRef) continue;
  const table = await getTable(tableRef.id);
  const hasColumn = Boolean(findColumn(table, 'organisation_id'));
  if (!hasColumn) planned.addOrganisationColumnTo.push(title);

  const records = await fetchRecords(tableRef.id);
  const toUpdate = records.filter((row) => !String(row.organisation_id || '').trim());
  planned.backfillTables.push({ title, records: records.length, toUpdate: toUpdate.length });
}

if (!apply) {
  console.log('[bootstrap-nocodb-staging-tenancy] dry-run OK - aucun changement NocoDB effectué');
  console.log(JSON.stringify({
    mode: 'dry-run',
    targetBaseId: BASE_ID || null,
    defaultOrganisationId: DEFAULT_ORGANISATION_ID,
    defaultOrganisationName: DEFAULT_ORGANISATION_NAME,
    ...planned,
  }, null, 2));
  process.exit(0);
}

let organisationsTable = existingOrgTable;
if (!organisationsTable) {
  organisationsTable = await createOrganisationsTable();
  console.log(`[bootstrap-nocodb-staging-tenancy] table créée ${ORGANISATIONS_TABLE_TITLE}`);
}

let organisationsSchema = await getTable(organisationsTable.id);
for (const column of ['organisation_id', 'nom', 'statut']) {
  if (!findColumn(organisationsSchema, column)) {
    await request('POST', `/api/v2/meta/tables/${encodeURIComponent(organisationsTable.id)}/columns`, {
      title: column,
      column_name: column,
      uidt: 'SingleLineText',
      dt: 'character varying',
    });
    console.log(`[bootstrap-nocodb-staging-tenancy] colonne créée organisations.${column}`);
    organisationsSchema = await getTable(organisationsTable.id);
  }
}

const organisationRecords = await fetchRecords(organisationsTable.id);
const existingOrganisation = organisationRecords.find((row) => (
  String(row.organisation_id || '').trim() === DEFAULT_ORGANISATION_ID
));
if (!existingOrganisation) {
  await createRecord(organisationsTable.id, {
    organisation_id: DEFAULT_ORGANISATION_ID,
    nom: DEFAULT_ORGANISATION_NAME,
    statut: 'active',
  });
  console.log(`[bootstrap-nocodb-staging-tenancy] organisation créée ${DEFAULT_ORGANISATION_ID}`);
}

const summary = [];
for (const title of TENANT_TABLES) {
  const tableRef = tableByTitle.get(title);
  if (!tableRef) {
    summary.push({ title, skipped: 'table_missing', updated: 0 });
    continue;
  }

  let table = await getTable(tableRef.id);
  if (!findColumn(table, 'organisation_id')) {
    await createOrganisationColumn(table.id);
    console.log(`[bootstrap-nocodb-staging-tenancy] colonne créée ${title}.organisation_id`);
    table = await getTable(table.id);
  }

  const records = await fetchRecords(table.id);
  const updates = records
    .filter((row) => !String(row.organisation_id || '').trim())
    .map((row) => ({ Id: row.Id, organisation_id: DEFAULT_ORGANISATION_ID }));
  const updated = await updateRecords(table.id, updates);
  console.log(`[bootstrap-nocodb-staging-tenancy] backfill ${title}: ${updated}/${records.length}`);
  summary.push({ title, records: records.length, updated });
}

console.log('[bootstrap-nocodb-staging-tenancy] terminé');
console.log(JSON.stringify({
  mode: 'apply',
  targetBaseId: BASE_ID,
  defaultOrganisationId: DEFAULT_ORGANISATION_ID,
  tables: summary,
}, null, 2));
