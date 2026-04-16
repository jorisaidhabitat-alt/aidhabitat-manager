import process from 'node:process';

import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });
dotenv.config();

const DEFAULT_BASE_ID = process.env.NOCODB_BASE_ID || '';

const MOBILE_SCHEMA = [
  {
    tableName: process.env.NOCODB_MOBILE_DOCUMENTS_TABLE_NAME || 'mobile_documents',
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
  {
    tableName: process.env.NOCODB_MOBILE_DOCUMENT_CHUNKS_TABLE_NAME || 'mobile_document_chunks',
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
  {
    tableName: process.env.NOCODB_MOBILE_NOTE_PAGES_TABLE_NAME || 'mobile_note_pages',
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
  {
    tableName: process.env.NOCODB_VISIT_RECOMMENDATIONS_TABLE_NAME || 'mobile_visit_recommendations',
    fields: [
      ['uuid_source', 'SingleLineText'],
      ['dossier_id', 'SingleLineText'],
      ['beneficiaire_id', 'SingleLineText'],
      ['beneficiaire_prenom', 'SingleLineText'],
      ['beneficiaire_nom', 'SingleLineText'],
      ['beneficiaire_nom_complet', 'SingleLineText'],
      ['dossier_libelle', 'SingleLineText'],
      ['wiki_item_id', 'SingleLineText'],
      ['wiki_title', 'SingleLineText'],
      ['wiki_image_url', 'LongText'],
      ['wiki_tag', 'SingleLineText'],
      ['note', 'LongText'],
      ['created_at', 'DateTime'],
      ['updated_at', 'DateTime'],
    ],
  },
];

const EXISTING_TABLE_PATCHES = [
  {
    tableName: process.env.NOCODB_DIAGNOSTIC_SANITAIRES_TABLE_NAME || 'diagnostic_sanitaires',
    fields: [
      ['sdb_instances_json', 'LongText'],
      ['wc_instances_json', 'LongText'],
    ],
  },
  {
    tableName: 'beneficiaires',
    fields: [
      ['ville_libre', 'SingleLineText'],
      ['code_postal_libre', 'SingleLineText'],
    ],
  },
];

const TYPE_TO_COLUMN = {
  SingleLineText: {
    uidt: 'SingleLineText',
    dt: 'character varying',
  },
  LongText: {
    uidt: 'LongText',
    dt: 'text',
  },
  DateTime: {
    uidt: 'DateTime',
    dt: 'datetime',
  },
  Number: {
    uidt: 'Number',
    dt: 'integer',
    np: '32',
    ns: '0',
  },
};

const stringValue = (value) => value == null ? '' : String(value);

const normalizeApiRoot = (rawUrl) => {
  if (!rawUrl) {
    return null;
  }

  const parsed = new URL(rawUrl);
  let pathname = parsed.pathname.replace(/\/+$/, '');

  if (pathname.includes('/mcp/')) {
    pathname = pathname.slice(0, pathname.indexOf('/mcp/'));
  }

  pathname = pathname.replace(/\/api\/v[12].*$/, '');

  return `${parsed.origin}${pathname}`;
};

const apiRoot = normalizeApiRoot(process.env.NOCODB_API_URL || process.env.NOCODB_MCP_URL);
const apiToken = stringValue(process.env.NOCODB_API_TOKEN).trim();
const authToken = stringValue(process.env.NOCODB_AUTH_TOKEN).trim();
const authHeaderName = apiToken ? 'xc-token' : 'xc-auth';
const authTokenValue = apiToken || authToken;
const sourceId = stringValue(process.env.NOCODB_SOURCE_ID).trim() || null;
const baseId = stringValue(DEFAULT_BASE_ID).trim();

if (!apiRoot) {
  console.error('NocoDB API introuvable. Configure NOCODB_API_URL ou NOCODB_MCP_URL.');
  process.exit(1);
}

if (!authTokenValue) {
  console.error('Token API NocoDB manquant. Configure NOCODB_API_TOKEN ou NOCODB_AUTH_TOKEN.');
  console.error('Le token MCP existant ne suffit pas pour créer des tables via les endpoints meta.');
  process.exit(1);
}

if (!baseId) {
  console.error('Base NocoDB manquante. Configure NOCODB_BASE_ID.');
  process.exit(1);
}

const requestJson = async (method, path, { body, expectedStatuses = [200] } = {}) => {
  const response = await fetch(`${apiRoot}${path}`, {
    method,
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      [authHeaderName]: authTokenValue,
    },
    body: body == null ? undefined : JSON.stringify(body),
  });

  const text = await response.text();
  let payload = null;

  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }

  if (!expectedStatuses.includes(response.status)) {
    const error = new Error(`HTTP ${response.status} ${method} ${path}`);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }

  return payload;
};

const requestWithFallback = async (method, paths, options = {}) => {
  const attempts = Array.isArray(paths) ? paths : [paths];
  let lastError = null;

  for (const path of attempts) {
    try {
      return await requestJson(method, path, options);
    } catch (error) {
      if (error?.status && ![404, 405].includes(error.status)) {
        throw error;
      }
      lastError = error;
    }
  }

  throw lastError || new Error(`Aucun endpoint NocoDB compatible pour ${method}`);
};

const slugifyColumnName = (name) => stringValue(name)
  .trim()
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, '_')
  .replace(/^_+|_+$/g, '');

const buildColumnDefinition = (title, type) => {
  const template = TYPE_TO_COLUMN[type];
  if (!template) {
    throw new Error(`Type de colonne non supporté: ${type}`);
  }

  return {
    title,
    column_name: slugifyColumnName(title),
    ...template,
  };
};

const buildCreateTablePayload = (spec) => ({
  title: spec.tableName,
  table_name: spec.tableName,
  ...(sourceId ? { source_id: sourceId } : {}),
  columns: [
    {
      title: 'Id',
      column_name: 'id',
      uidt: 'Number',
      dt: 'integer',
      np: '32',
      ns: '0',
      pk: true,
      rqd: true,
    },
    ...spec.fields.map(([name, type]) => buildColumnDefinition(name, type)),
  ],
});

const listTables = async () => {
  const payload = await requestWithFallback('GET', [
    `/api/v2/meta/bases/${encodeURIComponent(baseId)}/tables`,
    `/api/v1/db/meta/projects/${encodeURIComponent(baseId)}/tables`,
  ], {
    expectedStatuses: [200],
  });

  if (Array.isArray(payload)) {
    return payload;
  }

  if (Array.isArray(payload?.list)) {
    return payload.list;
  }

  if (Array.isArray(payload?.tables)) {
    return payload.tables;
  }

  return [];
};

const getTableSchema = async (tableId) => requestWithFallback('GET', [
  `/api/v2/meta/tables/${encodeURIComponent(tableId)}`,
  `/api/v1/db/meta/tables/${encodeURIComponent(tableId)}`,
], {
  expectedStatuses: [200],
});

const createTable = async (spec) => requestWithFallback('POST', [
  `/api/v2/meta/bases/${encodeURIComponent(baseId)}/tables`,
  `/api/v1/db/meta/projects/${encodeURIComponent(baseId)}/tables`,
], {
  body: buildCreateTablePayload(spec),
  expectedStatuses: [200, 201],
});

const createColumn = async (tableId, fieldName, fieldType) => requestWithFallback('POST', [
  `/api/v2/meta/tables/${encodeURIComponent(tableId)}/columns`,
  `/api/v1/db/meta/tables/${encodeURIComponent(tableId)}/columns`,
], {
  body: buildColumnDefinition(fieldName, fieldType),
  expectedStatuses: [200, 201],
});

const summarizeError = (error) => {
  if (error?.payload?.message) {
    return `${error.message}: ${error.payload.message}`;
  }

  if (typeof error?.payload === 'string' && error.payload.trim()) {
    return `${error.message}: ${error.payload.trim()}`;
  }

  return error?.message || String(error);
};

const main = async () => {
  console.log(`Base cible: ${baseId}`);
  console.log(`API: ${apiRoot}`);
  console.log(`Authentification: ${authHeaderName}`);

  const initialTables = await listTables();
  const report = [];

  for (const spec of MOBILE_SCHEMA) {
    let table = initialTables.find((entry) =>
      stringValue(entry?.title).trim().toLowerCase() === spec.tableName.toLowerCase());

    if (!table) {
      console.log(`Creation de la table ${spec.tableName}...`);
      try {
        await createTable(spec);
      } catch (error) {
        console.error(`Echec creation table ${spec.tableName}: ${summarizeError(error)}`);
        if (!sourceId) {
          console.error('Si votre base a plusieurs sources, renseigne NOCODB_SOURCE_ID puis relance.');
        }
        throw error;
      }

      const refreshedTables = await listTables();
      table = refreshedTables.find((entry) =>
        stringValue(entry?.title).trim().toLowerCase() === spec.tableName.toLowerCase());
    }

    if (!table?.id) {
      throw new Error(`Table ${spec.tableName} introuvable apres creation.`);
    }

    const schema = await getTableSchema(String(table.id));
    const columns = Array.isArray(schema?.columns)
      ? schema.columns
      : Array.isArray(schema?.fields)
        ? schema.fields
        : [];
    const byName = new Map(
      columns.map((column) => [stringValue(column?.title).trim(), stringValue(column?.uidt || column?.type).trim()])
    );
    const missing = [];
    const mismatched = [];

    for (const [fieldName, fieldType] of spec.fields) {
      const actualType = byName.get(fieldName);
      if (!actualType) {
        missing.push([fieldName, fieldType]);
        continue;
      }
      if (actualType !== fieldType) {
        mismatched.push({ fieldName, expected: fieldType, actual: actualType });
      }
    }

    for (const [fieldName, fieldType] of missing) {
      console.log(`Ajout colonne ${spec.tableName}.${fieldName} (${fieldType})...`);
      await createColumn(String(table.id), fieldName, fieldType);
    }

    report.push({
      tableName: spec.tableName,
      tableId: String(table.id),
      created: !initialTables.some((entry) =>
        stringValue(entry?.title).trim().toLowerCase() === spec.tableName.toLowerCase()),
      addedColumns: missing.map(([fieldName]) => fieldName),
      mismatched,
    });
  }

  for (const spec of EXISTING_TABLE_PATCHES) {
    const table = (await listTables()).find((entry) =>
      stringValue(entry?.title).trim().toLowerCase() === spec.tableName.toLowerCase());

    if (!table?.id) {
      console.warn(`Table existante introuvable pour patch: ${spec.tableName}`);
      continue;
    }

    const schema = await getTableSchema(String(table.id));
    const columns = Array.isArray(schema?.columns)
      ? schema.columns
      : Array.isArray(schema?.fields)
        ? schema.fields
        : [];
    const byName = new Map(
      columns.map((column) => [stringValue(column?.title).trim(), stringValue(column?.uidt || column?.type).trim()])
    );
    const missing = [];
    const mismatched = [];

    for (const [fieldName, fieldType] of spec.fields) {
      const actualType = byName.get(fieldName);
      if (!actualType) {
        missing.push([fieldName, fieldType]);
        continue;
      }
      if (actualType !== fieldType) {
        mismatched.push({ fieldName, expected: fieldType, actual: actualType });
      }
    }

    for (const [fieldName, fieldType] of missing) {
      console.log(`Ajout colonne ${spec.tableName}.${fieldName} (${fieldType})...`);
      await createColumn(String(table.id), fieldName, fieldType);
    }

    report.push({
      tableName: spec.tableName,
      tableId: String(table.id),
      created: false,
      addedColumns: missing.map(([fieldName]) => fieldName),
      mismatched,
    });
  }

  console.log('\nEtat final:');
  for (const entry of report) {
    console.log(`- ${entry.tableName} (${entry.tableId})`);
    console.log(`  creee: ${entry.created ? 'oui' : 'non'}`);
    console.log(`  colonnes ajoutees: ${entry.addedColumns.length > 0 ? entry.addedColumns.join(', ') : 'aucune'}`);
    console.log(`  colonnes incompatibles: ${entry.mismatched.length > 0 ? entry.mismatched.map((item) => `${item.fieldName}(${item.actual}!=${item.expected})`).join(', ') : 'aucune'}`);
  }

  const hasMismatch = report.some((entry) => entry.mismatched.length > 0);
  if (hasMismatch) {
    process.exitCode = 2;
  }
};

main().catch((error) => {
  console.error(`Bootstrap NocoDB impossible: ${summarizeError(error)}`);
  process.exit(1);
});
