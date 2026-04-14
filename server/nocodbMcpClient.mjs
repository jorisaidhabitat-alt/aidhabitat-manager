import process from 'node:process';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local' });
dotenv.config();

const MCP_URL = process.env.NOCODB_MCP_URL || 'https://apps-nocodb.z5avx1.easypanel.host/mcp/ncsmc7qy3dpge8j1';
const MCP_TOKEN = process.env.NOCODB_MCP_TOKEN || 'lRGWxsf8Oj4F5MrbRmAVGxzJeRyYd-yq';
const API_TOKEN = process.env.NOCODB_API_TOKEN || '';
const AUTH_TOKEN = process.env.NOCODB_AUTH_TOKEN || '';
const BASE_ID = process.env.NOCODB_BASE_ID || 'pskgbjythubfzv9';

let clientPromise;
let transportRef;

const parseToolPayload = (result) => {
  const textItem = result?.content?.find((item) => item.type === 'text');
  if (!textItem?.text) {
    return null;
  }

  try {
    return JSON.parse(textItem.text);
  } catch {
    return textItem.text;
  }
};

const stringValue = (value) => value == null ? '' : String(value);

const normalizeApiRoot = (rawUrl) => {
  if (!rawUrl) {
    return '';
  }

  const parsed = new URL(rawUrl);
  let pathname = parsed.pathname.replace(/\/+$/, '');

  if (pathname.includes('/mcp/')) {
    pathname = pathname.slice(0, pathname.indexOf('/mcp/'));
  }

  pathname = pathname.replace(/\/api\/v[12].*$/, '');
  return `${parsed.origin}${pathname}`;
};

const API_ROOT = normalizeApiRoot(process.env.NOCODB_API_URL || MCP_URL);
const REST_AUTH_HEADER = API_TOKEN ? 'xc-token' : 'xc-auth';
const REST_AUTH_VALUE = API_TOKEN || AUTH_TOKEN;

const toMcpRecord = (row) => ({
  id: String(row?.Id ?? row?.id ?? ''),
  fields: Object.fromEntries(
    Object.entries(row || {}).filter(([key]) => key !== 'Id' && key !== 'id')
  ),
});

const parseListPayload = (payload) => {
  if (Array.isArray(payload)) {
    return payload;
  }

  if (Array.isArray(payload?.list)) {
    return payload.list;
  }

  if (Array.isArray(payload?.records)) {
    return payload.records;
  }

  if (Array.isArray(payload?.tables)) {
    return payload.tables;
  }

  return [];
};

const serializeFields = (fields) => {
  if (!Array.isArray(fields) || fields.length === 0) {
    return null;
  }

  const normalized = fields.map((value) => String(value)).filter(Boolean);
  if (!normalized.includes('Id')) {
    normalized.unshift('Id');
  }

  return normalized.join(',');
};

const serializeSort = (sort) => {
  if (!Array.isArray(sort) || sort.length === 0) {
    return null;
  }

  return sort
    .map((entry) => {
      const field = stringValue(entry?.field).trim();
      if (!field) return null;
      const direction = stringValue(entry?.description).trim().toLowerCase();
      return direction === 'desc' ? `-${field}` : field;
    })
    .filter(Boolean)
    .join(',');
};

const normalizeWhereForRest = (where) => {
  const source = stringValue(where).trim();
  if (!source) {
    return null;
  }

  return source.replace(/"((?:\\.|[^"\\])*)"/g, (_match, value) =>
    value.replace(/\\"/g, '"').replace(/\\\\/g, '\\')
  );
};

const buildRestUrl = (path, query = {}) => {
  const url = new URL(path, API_ROOT);

  Object.entries(query).forEach(([key, value]) => {
    if (value == null || value === '') return;
    url.searchParams.set(key, String(value));
  });

  return url;
};

const restRequest = async (method, path, { query, body, expectedStatuses = [200] } = {}) => {
  if (!API_ROOT || !REST_AUTH_VALUE) {
    throw new Error('REST NocoDB non configuré');
  }

  const response = await fetch(buildRestUrl(path, query), {
    method,
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      [REST_AUTH_HEADER]: REST_AUTH_VALUE,
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
    const error = new Error(`NocoDB REST ${method} ${path} failed with ${response.status}`);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }

  return payload;
};

const callRestTool = async (name, args = {}) => {
  switch (name) {
    case 'getBaseInfo':
      return restRequest('GET', `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}`);
    case 'getTablesList':
      return parseListPayload(
        await restRequest('GET', `/api/v2/meta/bases/${encodeURIComponent(BASE_ID)}/tables`)
      );
    case 'getTableSchema': {
      const payload = await restRequest('GET', `/api/v2/meta/tables/${encodeURIComponent(String(args.tableId))}`);
      return {
        ...payload,
        fields: Array.isArray(payload?.columns)
          ? payload.columns.map((column) => ({
            title: column.title,
            type: column.uidt || column.type,
          }))
          : [],
      };
    }
    case 'queryRecords': {
      const page = Number(args.page) > 0 ? Number(args.page) : 1;
      const pageSize = Number(args.pageSize) > 0 ? Number(args.pageSize) : 25;
      const payload = await restRequest('GET', `/api/v2/tables/${encodeURIComponent(String(args.tableId))}/records`, {
        query: {
          page,
          limit: pageSize,
          offset: (page - 1) * pageSize,
          where: normalizeWhereForRest(args.where),
          fields: serializeFields(args.fields),
          sort: serializeSort(args.sort),
        },
      });

      const records = parseListPayload(payload).map(toMcpRecord);
      const pageInfo = payload?.pageInfo || {};
      const totalRows = Number(pageInfo.totalRows) || 0;
      const currentPage = Number(pageInfo.page) || page;
      const resolvedPageSize = Number(pageInfo.pageSize) || pageSize;
      const next = typeof pageInfo.isLastPage === 'boolean'
        ? !pageInfo.isLastPage
        : currentPage * resolvedPageSize < totalRows;

      return { records, next };
    }
    case 'createRecords': {
      const records = Array.isArray(args.records) ? args.records : [];
      const created = [];

      for (const record of records) {
        const payload = await restRequest('POST', `/api/v2/tables/${encodeURIComponent(String(args.tableId))}/records`, {
          body: record?.fields || {},
          expectedStatuses: [200, 201],
        });
        created.push(toMcpRecord(payload));
      }

      return created;
    }
    case 'updateRecords': {
      const records = Array.isArray(args.records) ? args.records : [];
      if (records.length === 0) return [];

      const payload = await restRequest('PATCH', `/api/v2/tables/${encodeURIComponent(String(args.tableId))}/records`, {
        body: records.map((record) => ({
          Id: Number(record.id),
          ...(record.fields || {}),
        })),
        expectedStatuses: [200],
      });

      return Array.isArray(payload) ? payload.map(toMcpRecord) : [toMcpRecord(payload)];
    }
    case 'deleteRecords': {
      const records = Array.isArray(args.records) ? args.records : [];
      const deleted = [];

      for (const record of records) {
        const payload = await restRequest('DELETE', `/api/v2/tables/${encodeURIComponent(String(args.tableId))}/records`, {
          body: { Id: Number(record.id) },
          expectedStatuses: [200],
        });
        deleted.push(toMcpRecord(payload));
      }

      return deleted;
    }
    default:
      throw new Error(`Fallback REST non implémenté pour ${name}`);
  }
};

const canUseRestFallback = (name) => (
  Boolean(API_ROOT && REST_AUTH_VALUE)
  && [
    'getBaseInfo',
    'getTablesList',
    'getTableSchema',
    'queryRecords',
    'createRecords',
    'updateRecords',
    'deleteRecords',
  ].includes(name)
);

const isRecoverableMcpError = (error) => {
  const message = `${error?.message || ''} ${error?.stack || ''}`.toLowerCase();
  return message.includes('connection closed')
    || message.includes('deadline has elapsed')
    || message.includes('timed out')
    || message.includes('transport closed');
};

const createClient = async () => {
  const transport = new StdioClientTransport({
    command: 'npx',
    args: [
      'mcp-remote',
      MCP_URL,
      '--header',
      `xc-mcp-token: ${MCP_TOKEN}`,
    ],
    cwd: process.cwd(),
    env: {
      ...process.env,
      npm_config_cache: `${process.cwd()}/.npm-cache`,
    },
    stderr: process.env.DEBUG_NOCODB_MCP ? 'inherit' : 'pipe',
  });

  if (!process.env.DEBUG_NOCODB_MCP && transport.stderr) {
    transport.stderr.on('data', () => {
      // Silence proxy noise during normal local development.
    });
  }

  const client = new Client(
    { name: 'aid-habitat-nocodb-proxy', version: '0.1.0' },
    { capabilities: {} }
  );

  await client.connect(transport);
  transportRef = transport;
  return client;
};

export const getMcpClient = async () => {
  if (!clientPromise) {
    clientPromise = createClient().catch((error) => {
      clientPromise = undefined;
      throw error;
    });
  }

  return clientPromise;
};

export const callNocoTool = async (name, args = {}) => {
  if (process.env.NOCODB_FORCE_REST === '1' && canUseRestFallback(name)) {
    return callRestTool(name, args);
  }

  try {
    const client = await getMcpClient();
    const result = await client.callTool({ name, arguments: args });
    return parseToolPayload(result);
  } catch (error) {
    if (!canUseRestFallback(name) || !isRecoverableMcpError(error)) {
      throw error;
    }

    await closeMcpClient().catch(() => undefined);
    return callRestTool(name, args);
  }
};

export const closeMcpClient = async () => {
  if (transportRef) {
    await transportRef.close().catch(() => undefined);
    transportRef = undefined;
  }
  clientPromise = undefined;
};
