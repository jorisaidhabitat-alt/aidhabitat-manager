import {
  VisitReportBeneficiarySection,
  VisitReportContextSection,
  VisitReportOfflineSections,
  VisitReportSectionKey,
  VisitReportSyncOperation,
} from '../types';
import {
  upsertDiagnosticSanitaires,
  upsertMesuresAnthropometriques,
  upsertObservationsSynthese,
  updateBeneficiaryRemote,
  updateDossier,
  updateHousing,
} from './dataService';
import {
  listVisitReportSyncOperations,
  markVisitReportOperationFailed,
  markVisitReportOperationProcessing,
  markVisitReportOperationSynced,
} from './visitReportLocalStore';

type SyncHandler<K extends VisitReportSectionKey> = (
  operation: VisitReportSyncOperation<VisitReportOfflineSections[K]>,
) => Promise<void>;

const syncBeneficiarySection: SyncHandler<'beneficiary'> = async (operation) => {
  const payload = operation.payload as VisitReportBeneficiarySection;
  const patientUpdates = payload.patient || {};
  const dossierUpdates = payload.dossier || {};

  if (Object.keys(patientUpdates).length > 0) {
    const patientResult = await updateBeneficiaryRemote(operation.patientId, patientUpdates);
    if (!patientResult.success) {
      throw new Error(patientResult.error || 'Synchronisation bénéficiaire impossible');
    }
  }

  if (Object.keys(dossierUpdates).length > 0) {
    const dossierResult = await updateDossier(operation.dossierId, dossierUpdates);
    if (!dossierResult.success) {
      throw new Error(dossierResult.error || 'Synchronisation dossier impossible');
    }
  }
};

const syncContextSection: SyncHandler<'context'> = async (operation) => {
  const payload = operation.payload as VisitReportContextSection;
  const result = await updateDossier(operation.dossierId, {
    medicalContext: payload.medicalContext,
    autonomy: payload.autonomy,
  });

  if (!result.success) {
    throw new Error(result.error || 'Synchronisation contexte impossible');
  }
};

const syncHousingSection: SyncHandler<'housing'> = async (operation) => {
  const result = await updateHousing(operation.patientId, undefined, operation.payload);
  if (!result.success) {
    throw new Error(result.error || 'Synchronisation logement impossible');
  }
};

const syncSanitairesSection: SyncHandler<'sanitaires'> = async (operation) => {
  const result = await upsertDiagnosticSanitaires(operation.dossierId, operation.payload);
  if (!result.success) {
    throw new Error(result.error || 'Synchronisation sanitaires impossible');
  }
};

const syncMeasurementsSection: SyncHandler<'measurements'> = async (operation) => {
  const result = await upsertMesuresAnthropometriques(operation.dossierId, operation.payload);
  if (!result.success) {
    throw new Error(result.error || 'Synchronisation mesures impossible');
  }
};

const syncSummarySection: SyncHandler<'summary'> = async (operation) => {
  const result = await upsertObservationsSynthese(operation.dossierId, operation.patientId, operation.payload);
  if (!result.success) {
    throw new Error(result.error || 'Synchronisation synthèse impossible');
  }
};

const SYNC_HANDLERS: { [K in VisitReportSectionKey]: SyncHandler<K> } = {
  beneficiary: syncBeneficiarySection,
  context: syncContextSection,
  housing: syncHousingSection,
  sanitaires: syncSanitairesSection,
  measurements: syncMeasurementsSection,
  summary: syncSummarySection,
};

let flushPromise: Promise<void> | null = null;
let onlineListenerRegistered = false;

export const flushVisitReportSyncQueue = async (): Promise<void> => {
  if (flushPromise) {
    return flushPromise;
  }

  flushPromise = (async () => {
    const operations = listVisitReportSyncOperations()
      .filter((operation) => operation.status === 'pending' || operation.status === 'failed')
      .sort((left, right) => new Date(left.createdAt).getTime() - new Date(right.createdAt).getTime());

    for (const operation of operations) {
      const handler = SYNC_HANDLERS[operation.sectionKey] as SyncHandler<typeof operation.sectionKey>;
      if (!handler) continue;

      markVisitReportOperationProcessing(operation.id);
      try {
        await handler(operation as never);
        markVisitReportOperationSynced(operation.id);
      } catch (error) {
        const message = error instanceof Error ? error.message : 'Erreur de synchronisation inconnue';
        markVisitReportOperationFailed(operation.id, message);
      }
    }
  })().finally(() => {
    flushPromise = null;
  });

  return flushPromise;
};

export const registerVisitReportSyncListeners = () => {
  if (onlineListenerRegistered || typeof window === 'undefined') {
    return;
  }
  onlineListenerRegistered = true;
  window.addEventListener('online', () => {
    void flushVisitReportSyncQueue();
  });
};
