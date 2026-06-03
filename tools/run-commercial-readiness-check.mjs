#!/usr/bin/env node
// Preflight commercial non destructif.
//
// Il enchaîne les garde-fous nécessaires avant une migration NocoDB/S3 :
// backup vérifié, plan de restauration, audit stockage, snapshot staging,
// lots d'import staging, contrôles critiques et build web.

import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';

const backupPath = process.argv[2];
const outputDir = process.argv[3] || 'tmp/commercial-readiness';
const overwrite = process.env.COMMERCIAL_PREFLIGHT_OVERWRITE === '1';
const skipBuild = process.env.COMMERCIAL_PREFLIGHT_SKIP_BUILD === '1';

if (!backupPath) {
  console.error('Usage: node tools/run-commercial-readiness-check.mjs <backup.json.gz|backup.json> [output-dir]');
  process.exit(1);
}

const root = process.cwd();
const resolvedBackup = path.resolve(backupPath);
const resolvedOutput = path.resolve(outputDir);
const logsDir = path.join(resolvedOutput, 'logs');
const stagingSnapshot = path.join(resolvedOutput, 'staging-snapshot.json.gz');
const schemaPlanDir = path.join(resolvedOutput, 'staging-schema-plan');
const importBatchesDir = path.join(resolvedOutput, 'staging-import-batches');
const nocodbApiAuditPath = path.join(resolvedOutput, 'nocodb-api-audit.md');
const envSecretsAuditPath = path.join(resolvedOutput, 'env-secrets-audit.md');
const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm';

const fileExists = async (file) => {
  try {
    await readFile(file);
    return true;
  } catch {
    return false;
  }
};

if (await fileExists(path.join(resolvedOutput, 'report.json'))) {
  if (!overwrite) {
    console.error(
      `[commercial-readiness] ÉCHEC: ${resolvedOutput} existe déjà. `
      + 'Définir COMMERCIAL_PREFLIGHT_OVERWRITE=1 pour remplacer.',
    );
    process.exit(1);
  }
  await rm(resolvedOutput, { recursive: true, force: true });
}

await mkdir(logsDir, { recursive: true });

const commands = [];
const addNode = (name, args, env = {}) => {
  commands.push({ name, command: process.execPath, args, env });
};

addNode('verify-production-backup', ['tools/verify-nocodb-backup.mjs', resolvedBackup]);
addNode('audit-env-secrets', ['tools/audit-env-secrets.mjs', envSecretsAuditPath]);
addNode('plan-production-restore', ['tools/plan-nocodb-restore.mjs', resolvedBackup]);
addNode('analyze-production-object-storage', ['tools/analyze-object-storage-readiness.mjs', resolvedBackup]);
addNode('audit-nocodb-api-usage', ['tools/audit-nocodb-api-usage.mjs', nocodbApiAuditPath]);
addNode('create-sanitized-staging-snapshot', ['tools/create-staging-snapshot.mjs', resolvedBackup, stagingSnapshot]);
addNode('verify-staging-snapshot', ['tools/verify-nocodb-backup.mjs', stagingSnapshot]);
addNode('plan-staging-restore', ['tools/plan-nocodb-restore.mjs', stagingSnapshot]);
addNode(
  'export-staging-schema-plan',
  ['tools/export-nocodb-schema-plan.mjs', stagingSnapshot, schemaPlanDir],
  { SCHEMA_PLAN_OVERWRITE: '1' },
);
addNode(
  'export-staging-import-batches',
  ['tools/export-nocodb-import-batches.mjs', stagingSnapshot, importBatchesDir],
  { IMPORT_BATCHES_OVERWRITE: '1' },
);
commands.push({ name: 'validate-staging-import-batches', validateImportBatches: true });
addNode('critical-flow-checks', ['tools/check-critical-flows.mjs']);
if (!skipBuild) {
  commands.push({ name: 'web-build', command: npmCommand, args: ['run', 'build'] });
}

const runCommand = (step) => new Promise((resolve) => {
  if (step.validateImportBatches) {
    validateImportBatches()
      .then((summary) => resolve({
        name: step.name,
        ok: true,
        code: 0,
        durationMs: 0,
        logFile: null,
        summary,
      }))
      .catch((error) => resolve({
        name: step.name,
        ok: false,
        code: 1,
        durationMs: 0,
        logFile: null,
        error: error.message,
      }));
    return;
  }

  const startedAt = Date.now();
  const child = spawn(step.command, step.args, {
    cwd: root,
    env: { ...process.env, ...(step.env || {}) },
  });
  let output = '';
  const append = (chunk) => {
    output += chunk.toString();
    if (output.length > 1_000_000) output = output.slice(-1_000_000);
  };
  child.stdout.on('data', append);
  child.stderr.on('data', append);
  child.on('close', async (code) => {
    const durationMs = Date.now() - startedAt;
    const logFile = path.join(logsDir, `${step.name}.log`);
    await writeFile(logFile, output);
    resolve({
      name: step.name,
      ok: code === 0,
      code,
      durationMs,
      logFile: path.relative(resolvedOutput, logFile),
    });
  });
});

async function validateImportBatches() {
  const manifestPath = path.join(importBatchesDir, 'manifest.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  let batches = 0;
  let records = 0;
  const badSystemFields = [];
  const systemFields = ['Id', 'CreatedAt', 'UpdatedAt', 'Id1'];

  for (const table of manifest.tables || []) {
    for (const batch of table.batches || []) {
      batches += 1;
      const batchPath = path.join(importBatchesDir, batch.file);
      const payload = JSON.parse(await readFile(batchPath, 'utf8'));
      if (!Array.isArray(payload)) {
        throw new Error(`${batch.file} ne contient pas un tableau JSON`);
      }
      records += payload.length;
      for (const [index, record] of payload.entries()) {
        for (const field of systemFields) {
          if (Object.prototype.hasOwnProperty.call(record, field)) {
            badSystemFields.push(`${batch.file}[${index}].${field}`);
          }
        }
      }
    }
  }

  if (badSystemFields.length > 0) {
    throw new Error(`champs système interdits dans les lots: ${badSystemFields.slice(0, 5).join(', ')}`);
  }

  return {
    tables: manifest.tables?.length || 0,
    batches,
    records,
  };
}

const report = {
  createdAt: new Date().toISOString(),
  backup: resolvedBackup,
  outputDir: resolvedOutput,
  destructive: false,
  skippedBuild: skipBuild,
  steps: [],
};

for (const command of commands) {
  console.log(`[commercial-readiness] ${command.name}...`);
  const result = await runCommand(command);
  report.steps.push(result);
  if (!result.ok) {
    report.ok = false;
    await writeReports(report);
    console.error(`[commercial-readiness] ÉCHEC: ${command.name}`);
    console.error(`Rapport: ${path.join(resolvedOutput, 'report.md')}`);
    process.exit(1);
  }
}

report.ok = true;
await writeReports(report);

console.log('[commercial-readiness] OK - aucun changement NocoDB effectué');
console.log(JSON.stringify({
  report: path.join(resolvedOutput, 'report.md'),
  steps: report.steps.length,
  build: skipBuild ? 'skipped' : 'checked',
}, null, 2));

async function writeReports(data) {
  await mkdir(resolvedOutput, { recursive: true });
  await writeFile(path.join(resolvedOutput, 'report.json'), JSON.stringify(data, null, 2));

  const lines = [
    '# Commercial Readiness Preflight',
    '',
    `Créé le : ${data.createdAt}`,
    '',
    `Backup : ${data.backup}`,
    '',
    `Résultat : ${data.ok ? 'OK' : 'ÉCHEC'}`,
    '',
    '## Étapes',
    '',
  ];

  for (const step of data.steps) {
    lines.push(`- ${step.ok ? 'OK' : 'ÉCHEC'} | ${step.name} | ${step.durationMs} ms${step.logFile ? ` | ${step.logFile}` : ''}`);
    if (step.summary) lines.push(`  Résumé : ${JSON.stringify(step.summary)}`);
    if (step.error) lines.push(`  Erreur : ${step.error}`);
  }

  lines.push('');
  lines.push('## Conclusion');
  lines.push('');
  lines.push(data.ok
    ? 'Les garde-fous non destructifs sont validés. La prochaine étape reste un vrai import sur base NocoDB staging.'
    : 'Le preflight a échoué. Ne pas migrer tant que l’étape bloquante n’est pas corrigée.');
  lines.push('');

  await writeFile(path.join(resolvedOutput, 'report.md'), `${lines.join('\n')}\n`);
}
