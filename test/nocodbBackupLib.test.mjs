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
