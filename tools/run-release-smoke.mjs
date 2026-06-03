#!/usr/bin/env node
// Smoke release non destructif.
//
// Regroupe les vérifications rapides à lancer au quotidien ou juste avant une
// intervention légère : garde-fous code, stack publique, nettoyage dry-run.

import { spawn } from 'node:child_process';
import process from 'node:process';

const args = new Set(process.argv.slice(2));
const skipLive = args.has('--skip-live');
const skipCleanup = args.has('--skip-cleanup');

const steps = [
  {
    name: 'critical-flow-checks',
    command: process.execPath,
    args: ['tools/check-critical-flows.mjs'],
  },
];

if (!skipLive) {
  steps.push({
    name: 'live-stack-check',
    command: process.execPath,
    args: ['tools/check-live-stack.mjs'],
  });
}

if (!skipCleanup) {
  steps.push({
    name: 'cleanup-artifacts-dry-run',
    command: process.execPath,
    args: ['tools/cleanup-local-artifacts.mjs'],
  });
}

const runStep = (step) => new Promise((resolve) => {
  const startedAt = Date.now();
  const child = spawn(step.command, step.args, {
    cwd: process.cwd(),
    env: process.env,
  });
  let output = '';
  const append = (chunk) => {
    output += chunk.toString();
    if (output.length > 50_000) output = output.slice(-50_000);
  };
  child.stdout.on('data', append);
  child.stderr.on('data', append);
  child.on('close', (code) => {
    resolve({
      ...step,
      ok: code === 0,
      code,
      durationMs: Date.now() - startedAt,
      output,
    });
  });
});

const results = [];

for (const step of steps) {
  console.log(`[release-smoke] ${step.name}...`);
  const result = await runStep(step);
  results.push(result);
  if (!result.ok) {
    console.error(`[release-smoke] ÉCHEC: ${step.name}`);
    console.error(result.output.trim());
    process.exit(1);
  }
}

console.log('[release-smoke] OK');
console.log(JSON.stringify({
  steps: results.map((result) => ({
    name: result.name,
    durationMs: result.durationMs,
  })),
}, null, 2));
