#!/usr/bin/env node
// Vérifie que le commit courant a déjà un build GitHub Actions réussi.
//
// Lecture seule. Nécessite GitHub CLI (`gh`) authentifié.

import { spawn } from 'node:child_process';
import process from 'node:process';

const args = process.argv.slice(2);

const readArg = (name, fallback = '') => {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  return args[index + 1] || fallback;
};

const workflow = readArg('--workflow', 'Build Flutter Web');
const branch = readArg('--branch', 'main');
const explicitSha = readArg('--sha', '');
const limit = Number(readArg('--limit', '20'));

const run = (command, commandArgs) => new Promise((resolve) => {
  const child = spawn(command, commandArgs, {
    cwd: process.cwd(),
    env: process.env,
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
  child.stderr.on('data', (chunk) => { stderr += chunk.toString(); });
  child.on('close', (code) => resolve({ code, stdout, stderr }));
  child.on('error', (error) => resolve({ code: 1, stdout: '', stderr: error.message }));
});

async function resolveHeadSha() {
  if (explicitSha) return explicitSha;
  const result = await run('git', ['rev-parse', 'HEAD']);
  if (result.code !== 0) {
    throw new Error(`git rev-parse HEAD a échoué: ${result.stderr.trim()}`);
  }
  return result.stdout.trim();
}

const headSha = await resolveHeadSha();
const ghResult = await run('gh', [
  'run',
  'list',
  '--workflow',
  workflow,
  '--branch',
  branch,
  '--limit',
  String(limit),
  '--json',
  'databaseId,headSha,headBranch,status,conclusion,createdAt,url',
]);

if (ghResult.code !== 0) {
  console.error('[github-actions-head-check] ÉCHEC');
  console.error(ghResult.stderr.trim() || 'GitHub CLI indisponible ou non authentifié.');
  process.exit(1);
}

let runs = [];
try {
  runs = JSON.parse(ghResult.stdout);
} catch (error) {
  console.error('[github-actions-head-check] ÉCHEC');
  console.error(`Réponse gh illisible: ${error.message}`);
  process.exit(1);
}

const exactRuns = runs.filter((runInfo) => runInfo.headSha === headSha);
const successfulRun = exactRuns.find((runInfo) => (
  runInfo.status === 'completed' && runInfo.conclusion === 'success'
));

if (!successfulRun) {
  console.error('[github-actions-head-check] ÉCHEC');
  console.error(JSON.stringify({
    expectedSha: headSha,
    workflow,
    branch,
    matchingRuns: exactRuns,
    latestRun: runs[0] || null,
  }, null, 2));
  process.exit(1);
}

console.log('[github-actions-head-check] OK');
console.log(JSON.stringify({
  sha: headSha,
  workflow,
  branch,
  run: {
    id: successfulRun.databaseId,
    createdAt: successfulRun.createdAt,
    url: successfulRun.url,
  },
}, null, 2));
