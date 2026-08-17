import assert from 'node:assert/strict';
import test from 'node:test';

import {
  AUTONOMY_ITEMS,
  canonicalAutonomyItemName,
  parseChecklistDone,
} from './helpers.mjs';

test('le libellé historique des tâches ménagères reste compatible', () => {
  assert.equal(
    canonicalAutonomyItemName('Tâches ménagères.domestiques'),
    'Tâches ménagères',
  );
  assert.equal(AUTONOMY_ITEMS[7], 'Tâches ménagères');
});

test('la lecture NocoDB conserve la coche par occupant', () => {
  const autonomy = [
    { name: 'Communication', checked: false },
    { name: 'Tâches ménagères.domestiques', checked: true },
    { name: 'Escaliers', checked: false },
  ];
  const parsed = parseChecklistDone({
    fields: {
      occupants_json: JSON.stringify([
        { autonomyDone: true, autonomy, attention: [], humanHelp: [] },
      ]),
    },
  });

  assert.equal(parsed.checklist[7].name, 'Tâches ménagères');
  assert.equal(parsed.checklist[7].checked, true);
  assert.equal(parsed.occupants[0].autonomy[7].checked, true);
  assert.equal(parsed.occupants[0].autonomy[0].checked, false);
});

test('la colonne de synthèse utilise le libellé canonique', () => {
  const parsed = parseChecklistDone({
    fields: { autonomie_menage: 'Oui' },
  });

  assert.equal(parsed.checklist[7].name, 'Tâches ménagères');
  assert.equal(parsed.checklist[7].checked, true);
});
