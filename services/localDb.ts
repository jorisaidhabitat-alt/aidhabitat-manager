import Dexie, { type Table } from 'dexie';

export type ReleveEnAttenteType =
  | 'diagnostic_sanitaires'
  | 'mesures_anthropometriques'
  | 'observations_synthese';

export interface ReleveEnAttente {
  id?: number;
  type: ReleveEnAttenteType;
  dossierId: string;
  payload: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
}

class AidHabitatLocalDb extends Dexie {
  releves_attente!: Table<ReleveEnAttente, number>;

  constructor() {
    super('aidhabitat_local');
    this.version(1).stores({
      releves_attente: '++id,&[dossierId+type],dossierId,type,updatedAt,createdAt',
    });
  }
}

export const localDb = new AidHabitatLocalDb();

export const upsertReleveEnAttente = async (
  type: ReleveEnAttenteType,
  dossierId: string,
  payload: Record<string, unknown>,
) => {
  const existing = await localDb.releves_attente
    .where('[dossierId+type]')
    .equals([dossierId, type])
    .first();

  const now = new Date().toISOString();
  if (existing?.id) {
    await localDb.releves_attente.update(existing.id, {
      payload,
      updatedAt: now,
    });
    return existing.id;
  }

  return localDb.releves_attente.add({
    type,
    dossierId,
    payload,
    createdAt: now,
    updatedAt: now,
  });
};
