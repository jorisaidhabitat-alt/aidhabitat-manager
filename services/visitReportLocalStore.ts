import {
  VisitReportOfflineSections,
  VisitReportOfflineSnapshot,
  VisitReportSectionKey,
  VisitReportSectionRecord,
  VisitReportSyncOperation,
} from '../types';

const VISIT_REPORT_SNAPSHOTS_KEY = 'aidhabitat.visit_report.snapshots';
const VISIT_REPORT_QUEUE_KEY = 'aidhabitat.visit_report.sync_queue';

const readJson = <T,>(key: string, fallbackValue: T): T => {
  if (typeof window === 'undefined') return fallbackValue;
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return fallbackValue;
    const parsed = JSON.parse(raw);
    return (parsed ?? fallbackValue) as T;
  } catch {
    return fallbackValue;
  }
};

const writeJson = (key: string, value: unknown) => {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Ignore local quota issues for now. The sync layer will surface persistence issues later.
  }
};

const createLocalId = (): string => {
  if (typeof globalThis !== 'undefined' && globalThis.crypto?.randomUUID) {
    return globalThis.crypto.randomUUID();
  }
  return `local-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
};

type SnapshotMap = Record<string, VisitReportOfflineSnapshot>;

const buildSnapshotKey = (dossierId: string, patientId: string): string => `${dossierId}::${patientId}`;
const buildEntityKey = (dossierId: string, sectionKey: VisitReportSectionKey): string => `${dossierId}::${sectionKey}`;

export const listVisitReportSnapshots = (): VisitReportOfflineSnapshot[] => (
  Object.values(readJson<SnapshotMap>(VISIT_REPORT_SNAPSHOTS_KEY, {}))
);

export const getVisitReportSnapshot = (
  dossierId: string,
  patientId: string,
): VisitReportOfflineSnapshot | null => {
  const snapshots = readJson<SnapshotMap>(VISIT_REPORT_SNAPSHOTS_KEY, {});
  return snapshots[buildSnapshotKey(dossierId, patientId)] || null;
};

export const upsertVisitReportSnapshot = (snapshot: VisitReportOfflineSnapshot): VisitReportOfflineSnapshot => {
  const snapshots = readJson<SnapshotMap>(VISIT_REPORT_SNAPSHOTS_KEY, {});
  snapshots[buildSnapshotKey(snapshot.dossierId, snapshot.patientId)] = snapshot;
  writeJson(VISIT_REPORT_SNAPSHOTS_KEY, snapshots);
  return snapshot;
};

export const saveVisitReportSectionLocal = <K extends VisitReportSectionKey>(
  dossierId: string,
  patientId: string,
  sectionKey: K,
  payload: VisitReportOfflineSections[K],
): VisitReportOfflineSnapshot => {
  const now = new Date().toISOString();
  const current = getVisitReportSnapshot(dossierId, patientId) || {
    dossierId,
    patientId,
    updatedAt: now,
    sections: {},
  };

  const sectionRecord: VisitReportSectionRecord<VisitReportOfflineSections[K]> = {
    sectionKey,
    payload,
    updatedAt: now,
    syncState: 'pending_sync',
    lastError: null,
  };

  const nextSnapshot: VisitReportOfflineSnapshot = {
    ...current,
    updatedAt: now,
    sections: {
      ...current.sections,
      [sectionKey]: sectionRecord,
    },
  };

  upsertVisitReportSnapshot(nextSnapshot);
  enqueueVisitReportSyncOperation(dossierId, patientId, sectionKey, payload);
  return nextSnapshot;
};

export const listVisitReportSyncOperations = (): VisitReportSyncOperation[] => (
  readJson<VisitReportSyncOperation[]>(VISIT_REPORT_QUEUE_KEY, [])
);

const writeVisitReportSyncOperations = (operations: VisitReportSyncOperation[]) => {
  writeJson(VISIT_REPORT_QUEUE_KEY, operations);
};

export const enqueueVisitReportSyncOperation = <K extends VisitReportSectionKey>(
  dossierId: string,
  patientId: string,
  sectionKey: K,
  payload: VisitReportOfflineSections[K],
): VisitReportSyncOperation<VisitReportOfflineSections[K]> => {
  const now = new Date().toISOString();
  const operations = listVisitReportSyncOperations();
  const entityKey = buildEntityKey(dossierId, sectionKey);
  const existingIndex = operations.findIndex(
    (operation) => operation.entityKey === entityKey && operation.status !== 'processing',
  );

  const nextOperation: VisitReportSyncOperation<VisitReportOfflineSections[K]> = {
    id: existingIndex >= 0 ? operations[existingIndex].id : createLocalId(),
    dossierId,
    patientId,
    sectionKey,
    entityKey,
    operation: 'upsert',
    payload,
    status: 'pending',
    createdAt: existingIndex >= 0 ? operations[existingIndex].createdAt : now,
    updatedAt: now,
    attemptCount: existingIndex >= 0 ? operations[existingIndex].attemptCount : 0,
    lastError: null,
  };

  if (existingIndex >= 0) {
    operations[existingIndex] = nextOperation;
  } else {
    operations.push(nextOperation);
  }

  writeVisitReportSyncOperations(operations);
  return nextOperation;
};

export const markVisitReportOperationProcessing = (operationId: string) => {
  const operations = listVisitReportSyncOperations().map((operation) => (
    operation.id === operationId
      ? {
        ...operation,
        status: 'processing' as const,
        updatedAt: new Date().toISOString(),
      }
      : operation
  ));
  writeVisitReportSyncOperations(operations);
};

export const markVisitReportOperationFailed = (operationId: string, errorMessage: string) => {
  const now = new Date().toISOString();
  const operations = listVisitReportSyncOperations().map((operation) => (
    operation.id === operationId
      ? {
        ...operation,
        status: 'failed' as const,
        updatedAt: now,
        lastError: errorMessage,
        attemptCount: operation.attemptCount + 1,
      }
      : operation
  ));
  writeVisitReportSyncOperations(operations);

  const snapshots = readJson<SnapshotMap>(VISIT_REPORT_SNAPSHOTS_KEY, {});
  for (const snapshot of Object.values(snapshots)) {
    const section = snapshot.sections[operations.find((item) => item.id === operationId)?.sectionKey as VisitReportSectionKey];
    if (!section) continue;
    section.syncState = 'sync_error';
    section.lastError = errorMessage;
    section.updatedAt = now;
  }
  writeJson(VISIT_REPORT_SNAPSHOTS_KEY, snapshots);
};

export const markVisitReportOperationSynced = (operationId: string) => {
  const now = new Date().toISOString();
  const operations = listVisitReportSyncOperations();
  const operation = operations.find((entry) => entry.id === operationId);
  if (!operation) return;

  writeVisitReportSyncOperations(operations.filter((entry) => entry.id !== operationId));

  const snapshots = readJson<SnapshotMap>(VISIT_REPORT_SNAPSHOTS_KEY, {});
  const snapshot = snapshots[buildSnapshotKey(operation.dossierId, operation.patientId)];
  const section = snapshot?.sections?.[operation.sectionKey];
  if (section) {
    section.syncState = 'synced';
    section.lastError = null;
    section.lastSyncedAt = now;
    section.updatedAt = now;
    snapshot.updatedAt = now;
    writeJson(VISIT_REPORT_SNAPSHOTS_KEY, snapshots);
  }
};
