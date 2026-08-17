import assert from 'node:assert/strict';
import test from 'node:test';

import {
  AUTONOMY_ITEMS,
  autonomyChecklistToMap,
  normalizeAutonomyChecklist,
} from './autonomyContract.js';

test('une liste reçue dans le désordre est reliée par nom', () => {
  const shuffled = [
    { name: 'Communication', checked: true },
    { name: 'Tâches ménagères.domestiques', checked: true },
    { name: 'Escaliers', checked: false },
  ];

  const normalized = normalizeAutonomyChecklist(shuffled);
  assert.deepEqual(normalized.map((item) => item.name), AUTONOMY_ITEMS);
  assert.equal(normalized.find((item) => item.name === 'Communication')?.checked, true);
  assert.equal(normalized.find((item) => item.name === 'Tâches ménagères')?.checked, true);
  assert.equal(normalized.find((item) => item.name === 'Déplacements/transferts')?.checked, false);
});

test('une liste partielle nommée ne décale jamais les autres valeurs', () => {
  const normalized = normalizeAutonomyChecklist([
    { name: 'Repas (y compris courses)', checked: true },
  ]);

  assert.equal(normalized[6].checked, true);
  assert.equal(normalized[0].checked, false);
  assert.equal(normalized[7].checked, false);
});

test('le mapping de sauvegarde utilise les libellés canoniques', () => {
  const map = autonomyChecklistToMap([
    { name: 'Tâches ménagères.domestiques', checked: true },
  ]);

  assert.equal(map.get('Tâches ménagères'), true);
  assert.equal(map.has('Tâches ménagères.domestiques'), false);
});
