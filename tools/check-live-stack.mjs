#!/usr/bin/env node
// Vérification live non destructive de la stack App'Ergo.
//
// À lancer avant/après une bascule DNS, un changement Easypanel ou une
// migration d'hébergement. Tous les contrôles sont en lecture seule.

import { spawn } from 'node:child_process';
import process from 'node:process';

const args = process.argv.slice(2);

const readArg = (name, fallback) => {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  return args[index + 1] || fallback;
};

const hasFlag = (name) => args.includes(name);

const appUrl = readArg('--app-url', process.env.AIDHABITAT_APP_URL || 'https://app.aidhabitat.fr');
const apiUrl = readArg('--api-url', process.env.AIDHABITAT_API_URL || 'https://api.aidhabitat.fr');
const skipReady = hasFlag('--skip-ready');
const timeoutMs = Number(readArg('--timeout-ms', process.env.AIDHABITAT_LIVE_CHECK_TIMEOUT_MS || '15000'));

const appBase = new URL(appUrl.endsWith('/') ? appUrl : `${appUrl}/`);
const apiBase = new URL(apiUrl.endsWith('/') ? apiUrl : `${apiUrl}/`);
const failures = [];
const checks = [];

const mark = (name, details = {}) => {
  checks.push({ name, ...details });
};

const fail = (name, message) => {
  failures.push(`${name}: ${message}`);
};

async function fetchWithTimeout(url, init = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, {
      redirect: 'follow',
      ...init,
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

async function checkJsonEndpoint(pathname, expectedStatus, { required = true } = {}) {
  const url = new URL(pathname, apiBase);
  const name = `api:${pathname}`;
  try {
    const response = await fetchWithTimeout(url, {
      headers: {
        Origin: appBase.origin,
      },
    });
    if (!response.ok) {
      const message = `HTTP ${response.status} ${response.statusText}`;
      if (required) fail(name, message);
      else mark(name, { skipped: true, reason: message });
      return;
    }

    const json = await response.json();
    if (json?.success !== true || json?.status !== expectedStatus) {
      fail(name, `JSON inattendu ${JSON.stringify(json).slice(0, 180)}`);
      return;
    }

    const allowOrigin = response.headers.get('access-control-allow-origin') || '';
    const corp = response.headers.get('cross-origin-resource-policy') || '';
    if (allowOrigin !== appBase.origin && allowOrigin !== '*') {
      fail(name, `CORS inattendu (${allowOrigin || 'absent'})`);
      return;
    }
    if (corp !== 'cross-origin') {
      fail(name, `Cross-Origin-Resource-Policy inattendu (${corp || 'absent'})`);
      return;
    }

    mark(name, {
      status: json.status,
      cors: allowOrigin,
      corp,
    });
  } catch (error) {
    fail(name, error.name === 'AbortError' ? `timeout ${timeoutMs} ms` : error.message);
  }
}

async function runWebReleaseCheck() {
  const name = 'app:pwa-release-check';
  return new Promise((resolve) => {
    const child = spawn(process.execPath, ['tools/check-web-release.mjs', '--url', appBase.toString()], {
      cwd: process.cwd(),
      env: process.env,
    });
    let output = '';
    const append = (chunk) => {
      output += chunk.toString();
      if (output.length > 20_000) output = output.slice(-20_000);
    };
    child.stdout.on('data', append);
    child.stderr.on('data', append);
    child.on('close', (code) => {
      if (code === 0) {
        mark(name, { url: appBase.toString() });
      } else {
        fail(name, output.trim() || `exit ${code}`);
      }
      resolve();
    });
  });
}

await runWebReleaseCheck();
await checkJsonEndpoint('/api/health/live', 'live');
if (!skipReady) {
  await checkJsonEndpoint('/api/health/ready', 'ready');
}

if (failures.length > 0) {
  console.error('[live-stack-check] ÉCHEC');
  console.error(JSON.stringify({
    appUrl: appBase.toString(),
    apiUrl: apiBase.toString(),
    checks,
    failures,
  }, null, 2));
  process.exit(1);
}

console.log('[live-stack-check] OK');
console.log(JSON.stringify({
  appUrl: appBase.toString(),
  apiUrl: apiBase.toString(),
  checks,
}, null, 2));
