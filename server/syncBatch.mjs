const DEFAULT_MAX_OPERATIONS = 3;
const DEFAULT_MAX_BATCH_BYTES = 1024 * 1024;
const DEFAULT_MAX_OPERATION_BYTES = 256 * 1024;

const ALLOWED_OPERATIONS = [
  { method: 'PATCH', path: /^\/api\/dossiers\/[^/?#]+$/ },
  { method: 'PATCH', path: /^\/api\/beneficiaires\/[^/?#]+$/ },
  {
    method: 'PATCH',
    path: /^\/api\/logements\/by-beneficiary\/[^/?#]+$/,
  },
  { method: 'PUT', path: /^\/api\/mesures\/[^/?#]+$/ },
  { method: 'PUT', path: /^\/api\/observations\/[^/?#]+$/ },
  {
    method: 'PUT',
    path: /^\/api\/diagnostic-sanitaires\/[^/?#]+$/,
  },
];

const byteLength = (value) => Buffer.byteLength(JSON.stringify(value), 'utf8');

const isPlainObject = (value) =>
  value != null && typeof value === 'object' && !Array.isArray(value);

export const validateSyncBatchPayload = (
  payload,
  {
    maxOperations = DEFAULT_MAX_OPERATIONS,
    maxBatchBytes = DEFAULT_MAX_BATCH_BYTES,
    maxOperationBytes = DEFAULT_MAX_OPERATION_BYTES,
  } = {},
) => {
  if (!isPlainObject(payload) || !Array.isArray(payload.operations)) {
    throw new TypeError('Le lot de synchronisation est invalide');
  }
  if (payload.operations.length === 0) {
    throw new TypeError('Le lot de synchronisation est vide');
  }
  if (payload.operations.length > maxOperations) {
    throw new TypeError(`Le lot dépasse ${maxOperations} opérations`);
  }
  if (byteLength(payload) > maxBatchBytes) {
    throw new TypeError('Le lot de synchronisation est trop volumineux');
  }

  const ids = new Set();
  return payload.operations.map((rawOperation) => {
    if (!isPlainObject(rawOperation)) {
      throw new TypeError('Une opération du lot est invalide');
    }
    const id = String(rawOperation.id || '').trim();
    const method = String(rawOperation.method || '').trim().toUpperCase();
    const requestPath = String(rawOperation.path || '').trim();
    const body = rawOperation.body;

    if (!id || id.length > 100 || ids.has(id)) {
      throw new TypeError('Identifiant d’opération absent ou dupliqué');
    }
    ids.add(id);

    if (!isPlainObject(body)) {
      throw new TypeError(`Corps JSON invalide pour l’opération ${id}`);
    }
    if (byteLength(body) > maxOperationBytes) {
      throw new TypeError(`Opération ${id} trop volumineuse`);
    }
    const isAllowed = ALLOWED_OPERATIONS.some(
      (allowed) => allowed.method === method && allowed.path.test(requestPath),
    );
    if (!isAllowed) {
      throw new TypeError(`Route non autorisée pour l’opération ${id}`);
    }

    return { id, method, path: requestPath, body };
  });
};

const parseResponseBody = (text) => {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch (_) {
    return { error: 'Réponse interne non JSON' };
  }
};

export const executeSyncBatch = async ({
  operations,
  origin,
  sessionToken,
  fetchImpl = fetch,
  operationTimeoutMs = 65_000,
}) => {
  const results = [];

  // Traitement volontairement séquentiel : le lot réduit les connexions
  // mobiles sans transformer le retour en ligne en rafale vers NocoDB.
  for (const operation of operations) {
    try {
      const response = await fetchImpl(new URL(operation.path, origin), {
        method: operation.method,
        headers: {
          'Content-Type': 'application/json',
          'X-App-Session': sessionToken,
          'X-Sync-Batch-Internal': '1',
        },
        body: JSON.stringify(operation.body),
        signal: AbortSignal.timeout(operationTimeoutMs),
      });
      const responseText = await response.text();
      results.push({
        id: operation.id,
        status: response.status,
        body: parseResponseBody(responseText),
        retryAfter: response.headers.get('retry-after') || null,
      });
    } catch (_) {
      results.push({
        id: operation.id,
        status: 503,
        body: { error: 'Service temporairement indisponible' },
        retryAfter: null,
      });
    }
  }

  return results;
};

export const createConcurrencyGate = (maxConcurrent = 2) => {
  let active = 0;
  const waiters = [];

  const release = () => {
    active -= 1;
    waiters.shift()?.();
  };

  return async (task) => {
    if (active >= maxConcurrent) {
      await new Promise((resolve) => waiters.push(resolve));
    }
    active += 1;
    try {
      return await task();
    } finally {
      release();
    }
  };
};
