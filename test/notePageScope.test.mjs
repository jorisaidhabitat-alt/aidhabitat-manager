import assert from 'node:assert/strict';
import test from 'node:test';

import {
  normalizeNotePageScope,
  selectCanonicalNotePages,
} from '../server/notePageScope.mjs';

test('normalizes quick notes to the dossier scope', () => {
  assert.deepEqual(
    normalizeNotePageScope({
      patientId: 'patient-69',
      dossierId: 'airtable:dossier-62',
      scopeType: 'dossier_detail',
      scopeId: 'patient-69',
      tabKey: 'notes_rapides',
    }),
    {
      scopeType: 'dossier_detail',
      scopeId: 'airtable:dossier-62',
    },
  );
});

test('does not rewrite visit report scopes', () => {
  assert.deepEqual(
    normalizeNotePageScope({
      patientId: 'patient-69',
      dossierId: 'airtable:dossier-62',
      scopeType: 'visit_report',
      scopeId: 'patient-69',
      tabKey: 'Contexte de vie',
    }),
    {
      scopeType: 'visit_report',
      scopeId: 'patient-69',
    },
  );
});

test('selects the dossier-scoped quick note instead of a newer duplicate', () => {
  const selected = selectCanonicalNotePages(
    [
      {
        id: 'canonical',
        scopeType: 'dossier_detail',
        scopeId: 'airtable:dossier-62',
        tabKey: 'notes_rapides',
        pageNumber: 0,
        updatedAt: '2026-07-27T14:53:29Z',
      },
      {
        id: 'duplicate',
        scopeType: 'dossier_detail',
        scopeId: 'patient-69',
        tabKey: 'notes_rapides',
        pageNumber: 0,
        updatedAt: '2026-07-28T07:48:54Z',
      },
      {
        id: 'visit-note',
        scopeType: 'visit_report',
        scopeId: 'patient-69',
        tabKey: 'Contexte de vie',
        pageNumber: 0,
        updatedAt: '2026-07-28T08:00:00Z',
      },
    ],
    {
      patientId: 'patient-69',
      dossierId: 'airtable:dossier-62',
    },
  );

  assert.deepEqual(
    selected.map((notePage) => notePage.id).sort(),
    ['canonical', 'visit-note'],
  );
});
