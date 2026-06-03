import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const read = (relativePath) => readFileSync(path.join(root, relativePath), 'utf8');

const checks = [
  {
    name: 'VAD web exposes the Synthese tab',
    file: 'components/pages/dossier/visit-report/VisitReportView.tsx',
    assert: (source) => source.includes("'Synthèse'") && source.includes("case 'Synthèse':"),
  },
  {
    name: 'Legacy VAD locations are normalized silently',
    file: 'components/pages/dossier/visit-report/VisitReportView.tsx',
    assert: (source) => source.includes("location.activeTab === 'Observations'") && source.includes("location.activeTab === 'Logement'"),
  },
  {
    name: 'VAD releves queue covers sanitaires, mesures and synthese',
    file: 'services/dataService.ts',
    assert: (source) => [
      "'diagnostic_sanitaires'",
      "'mesures_anthropometriques'",
      "'observations_synthese'",
      'queueReleveAfterTemporaryFailure',
    ].every((needle) => source.includes(needle)),
  },
  {
    name: 'Visit recommendations saves are queued before remote sync',
    file: 'services/dataService.ts',
    assert: (source) => {
      const start = source.indexOf('export const saveVisitRecommendations = async');
      const end = source.indexOf('const fetchVisitRecommendationsRemote', start);
      const body = source.slice(start, end);
      return [
        'readVisitRecommendationsCacheMap()',
        'readVisitRecommendationsQueueMap()',
        "syncStatus: 'pending'",
        'scheduleQueuedVisitRecommendationsSync()',
      ].every((needle) => body.includes(needle));
    },
  },
  {
    name: 'Queued VAD releves wait for a local session before flushing',
    file: 'services/releveSync.ts',
    assert: (source) => {
      const start = source.indexOf('export const flushPendingReleves = async');
      const end = source.indexOf('export const registerPendingRelevesSync', start);
      return source.slice(start, end).includes('if (!getSessionToken()) return;');
    },
  },
  {
    name: 'Flutter sync state bindings cover VAD and recommendations entities',
    file: 'aid_habitat_app/lib/services/sync_repository.dart',
    assert: (source) => [
      "'contexte_de_vie' =>",
      "'diagnostic_sanitaires' =>",
      "'mesures_anthropometriques' =>",
      "'observations_synthese' =>",
      "'visit_recommendations' =>",
    ].every((needle) => source.includes(needle)),
  },
  {
    name: 'API exposes split live and ready healthchecks',
    file: 'server/index.mjs',
    assert: (source) => source.includes("app.get('/api/health/live'") && source.includes("app.get('/api/health/ready'"),
  },
  {
    name: 'API warmup does not block server listen',
    file: 'server/index.mjs',
    assert: (source) => source.includes('void warmupRuntime();') && !source.includes('await warmupRuntime();'),
  },
  {
    name: 'Root web build no longer references a missing index.css',
    file: 'index.html',
    assert: (source) => !source.includes('/index.css'),
  },
  {
    name: 'Flutter web workflow defaults to the production API',
    file: '.github/workflows/flutter-web-build.yml',
    assert: (source) => (
      source.includes('default: "https://api.aidhabitat.fr"')
      && !source.includes('default: "https://apps-aidhabitat-api-staging.z5avx1.easypanel.host"')
    ),
  },
  {
    name: 'Flutter web workflow runs the PDF smoke test',
    file: '.github/workflows/flutter-web-build.yml',
    assert: (source) => source.includes('npm run test:pdf'),
  },
  {
    name: 'Flutter web workflow checks the generated PWA bundle',
    file: '.github/workflows/flutter-web-build.yml',
    assert: (source) => source.includes('npm run release:web-check -- --dir aid_habitat_app/build/web'),
  },
  {
    name: 'Package exposes the live stack release check',
    file: 'package.json',
    assert: (source) => source.includes('"release:live-check": "node tools/check-live-stack.mjs"'),
  },
  {
    name: 'Package exposes the safe local artifacts cleanup',
    file: 'package.json',
    assert: (source) => source.includes('"cleanup:artifacts": "node tools/cleanup-local-artifacts.mjs"'),
  },
  {
    name: 'Package exposes the quick release smoke check',
    file: 'package.json',
    assert: (source) => source.includes('"release:smoke": "node tools/run-release-smoke.mjs"'),
  },
  {
    name: 'Package exposes the GitHub Actions HEAD check',
    file: 'package.json',
    assert: (source) => source.includes('"release:ci-check": "node tools/check-github-actions-head.mjs"'),
  },
];

const failures = [];

for (const check of checks) {
  const source = read(check.file);
  if (!check.assert(source)) {
    failures.push(`${check.name} (${check.file})`);
  }
}

if (failures.length > 0) {
  console.error('Critical flow checks failed:');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log(`Critical flow checks passed (${checks.length}/${checks.length}).`);
