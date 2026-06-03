#!/usr/bin/env node
// Nettoyage local conservateur des artefacts générés par les builds/tests.
//
// Dry-run par défaut. Aucun backup NocoDB n'est supprimé.

import { readdir, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const args = new Set(process.argv.slice(2));
const apply = args.has('--apply');
const includeReports = args.has('--include-reports');
const includeBuilds = !args.has('--no-builds');
const root = process.cwd();

const usage = () => {
  console.log([
    'Usage: npm run cleanup:artifacts -- [--apply] [--include-reports] [--no-builds]',
    '',
    'Par défaut, le script affiche seulement ce qui serait supprimé.',
    '',
    'Options:',
    '  --apply            Supprime réellement les artefacts listés.',
    '  --include-reports  Inclut les rapports temporaires de preflight dans tmp/.',
    '  --no-builds        Ne cible pas dist/ ni aid_habitat_app/build.',
  ].join('\n'));
};

if (args.has('--help') || args.has('-h')) {
  usage();
  process.exit(0);
}

const exists = async (target) => {
  try {
    await stat(target);
    return true;
  } catch {
    return false;
  }
};

async function sizeBytes(target) {
  const info = await stat(target).catch(() => null);
  if (!info) return 0;
  if (!info.isDirectory()) return info.size;
  const entries = await readdir(target, { withFileTypes: true }).catch(() => []);
  let total = 0;
  for (const entry of entries) {
    total += await sizeBytes(path.join(target, entry.name));
  }
  return total;
}

const formatBytes = (bytes) => {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB'];
  let value = bytes / 1024;
  for (const unit of units) {
    if (value < 1024) return `${value.toFixed(value >= 10 ? 0 : 1)} ${unit}`;
    value /= 1024;
  }
  return `${value.toFixed(1)} TB`;
};

async function collectTmpTargets() {
  const tmpDir = path.join(root, 'tmp');
  const entries = await readdir(tmpDir, { withFileTypes: true }).catch(() => []);
  const targets = [];
  for (const entry of entries) {
    const name = entry.name;
    const fullPath = path.join(tmpDir, name);
    if (name.startsWith('backups')) continue;
    if (name.endsWith('.json.gz')) continue;
    if (name.startsWith('commercial-readiness-')) {
      if (includeReports) targets.push(fullPath);
      continue;
    }
    if (
      name.startsWith('staging-import-batches')
      || name.startsWith('staging-schema-plan')
      || name.startsWith('test-report-')
    ) {
      targets.push(fullPath);
    }
  }
  return targets;
}

const targets = [];
if (includeBuilds) {
  targets.push(path.join(root, 'dist'));
  targets.push(path.join(root, 'aid_habitat_app', 'build'));
}
targets.push(path.join(root, '.npm-cache'));
targets.push(...await collectTmpTargets());

const uniqueTargets = [...new Set(targets)]
  .filter((target) => path.relative(root, target) && !path.relative(root, target).startsWith('..'));

const found = [];
for (const target of uniqueTargets) {
  if (!await exists(target)) continue;
  const relative = path.relative(root, target);
  found.push({
    path: target,
    relative,
    bytes: await sizeBytes(target),
  });
}

found.sort((a, b) => b.bytes - a.bytes);

if (found.length === 0) {
  console.log('[cleanup-artifacts] Aucun artefact ciblé trouvé.');
  process.exit(0);
}

const totalBytes = found.reduce((sum, item) => sum + item.bytes, 0);

console.log(`[cleanup-artifacts] Mode : ${apply ? 'APPLY' : 'DRY-RUN'}`);
console.log(`[cleanup-artifacts] Cibles : ${found.length}`);
console.log(`[cleanup-artifacts] Espace concerné : ${formatBytes(totalBytes)}`);
for (const item of found) {
  console.log(`- ${formatBytes(item.bytes)}\t${item.relative}`);
}

if (!apply) {
  console.log('');
  console.log('Relancer avec --apply pour supprimer. Ajouter --include-reports pour inclure les rapports preflight.');
  process.exit(0);
}

for (const item of found) {
  await rm(item.path, { recursive: true, force: true });
}

console.log(`[cleanup-artifacts] Supprimé : ${formatBytes(totalBytes)}`);
