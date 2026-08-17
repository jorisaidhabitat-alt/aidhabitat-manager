#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { AUTONOMY_ITEMS } from '../shared/autonomyContract.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) => readFile(path.join(root, relativePath), 'utf8');

const extractDartStringList = (source, constantName) => {
  const expression = new RegExp(`const\\s+${constantName}\\s*=\\s*\\[([\\s\\S]*?)\\];`);
  const body = source.match(expression)?.[1];
  assert.ok(body, `Liste Dart introuvable: ${constantName}`);
  return [...body.matchAll(/'([^']+)'/g)].map((match) => match[1]);
};

const [
  dartTypes,
  helpers,
  api,
  web,
  syncRepository,
  syncEngine,
  apiWorkflow,
  webWorkflow,
  integrityWorkflow,
] = await Promise.all([
  read('aid_habitat_app/lib/models/types.dart'),
  read('server/helpers.mjs'),
  read('server/index.mjs'),
  read('components/pages/dossier/visit-report/VisitReportView.tsx'),
  read('aid_habitat_app/lib/services/sync_repository.dart'),
  read('aid_habitat_app/lib/services/sync_engine.dart'),
  read('.github/workflows/build-deploy-api.yml'),
  read('.github/workflows/flutter-web-build.yml'),
  read('.github/workflows/sync-integrity.yml'),
]);

assert.deepEqual(
  extractDartStringList(dartTypes, 'kAutonomyItemNames'),
  AUTONOMY_ITEMS,
  'Flutter et le contrat API/Web n’utilisent pas les mêmes libellés ou le même ordre',
);

for (const [label, source] of [
  ['server/helpers.mjs', helpers],
  ['server/index.mjs', api],
]) {
  assert.match(source, /shared\/autonomyContract\.js/,
    `${label} doit importer le contrat autonomie partagé`);
  assert.doesNotMatch(source, /const\s+AUTONOMY_ITEMS\s*=\s*\[/,
    `${label} ne doit pas redéclarer la liste autonomie`);
  assert.match(source, /normalizeAutonomyChecklist\(entry\?\.autonomy\)/,
    `${label} doit relire l’autonomie par nom`);
  assert.match(source, /autonomyChecklistToMap\(autonomy\?\.checklist\)/,
    `${label} doit sauvegarder l’autonomie avec le contrat partagé`);
}

assert.match(web, /shared\/autonomyContract\.js/,
  'La Web App doit importer le contrat autonomie partagé');
assert.doesNotMatch(web, /const\s+AUTONOMY_DEFAULT_ITEMS\s*=\s*\[/,
  'La Web App ne doit pas redéclarer la liste autonomie');

for (const entity of [
  'patient',
  'housing',
  'contexte_de_vie',
  'diagnostic_sanitaires',
  'mesures_anthropometriques',
  'observations_synthese',
  'visit_recommendations',
  'note_page',
  'document',
]) {
  assert.ok(
    syncRepository.includes(`'${entity}' =>`),
    `Entité offline sans liaison sync_state: ${entity}`,
  );
}

assert.match(syncEngine, /_remoteSessionPreparer/,
  'Le moteur de synchronisation doit restaurer la session avant le drain offline');
assert.match(syncEngine, /_scheduleRetry\(\)/,
  'Le moteur de synchronisation doit conserver un retry automatique');

assert.match(apiWorkflow, /npm run test:sync-contract/,
  'Le déploiement API doit être bloqué par les contrats de synchronisation');
assert.match(webWorkflow, /test_sync_critical\.sh/,
  'Le build Web doit vérifier la file offline et les fusions distantes');
assert.match(integrityWorkflow, /npm run test:sync-contract/,
  'La CI doit vérifier le contrat API/Web/NocoDB');
assert.match(integrityWorkflow, /test_sync_critical\.sh/,
  'La CI doit vérifier les scénarios critiques iPad');

console.log(`Contrats de synchronisation vérifiés (${AUTONOMY_ITEMS.length} éléments autonomie).`);
