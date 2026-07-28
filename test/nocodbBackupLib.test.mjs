import assert from 'node:assert/strict';
import test from 'node:test';

import { REQUIRED_BACKUP_TABLES, verifyBackupData } from '../tools/nocodbBackupLib.mjs';

const backupWith = (counts = {}) => ({
  baseId: 'base-test',
  createdAt: '2026-07-28T00:00:00.000Z',
  tables: REQUIRED_BACKUP_TABLES.map((name) => ({
    name,
    fields: [],
    records: Array.from({ length: counts[name] ?? 0 }, (_, index) => ({ Id: index + 1 })),
  })),
});

test('accepte les tables techniques vides si le coeur métier est sauvegardé', () => {
  const verification = verifyBackupData(backupWith({
    Beneficiaires: 1,
    '📁 dossiers': 1,
  }));

  assert.equal(verification.ok, true);
  assert.deepEqual(verification.failures, []);
});

test('refuse une sauvegarde dont une table métier centrale est vide', () => {
  const verification = verifyBackupData(backupWith({
    Beneficiaires: 1,
    '📁 dossiers': 0,
  }));

  assert.equal(verification.ok, false);
  assert.ok(verification.failures.includes('table critique vide: 📁 dossiers'));
});

test('reconnaît les noms actuels NocoDB avec majuscules et icônes', () => {
  const verification = verifyBackupData({
    baseId: 'base-test',
    createdAt: '2026-07-28T00:00:00.000Z',
    tables: [
      { name: 'Beneficiaires', fields: [], records: [{ Id: 1 }] },
      { name: '📁 Dossiers', fields: [], records: [{ Id: 1 }] },
      { name: 'Mobile_documents', fields: [], records: [] },
      { name: 'Mobile_document_chunks', fields: [], records: [] },
      { name: 'Mobile_note_pages', fields: [], records: [] },
    ],
  });

  assert.equal(verification.ok, true);
  assert.deepEqual(verification.failures, []);
});
