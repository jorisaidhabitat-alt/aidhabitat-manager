#!/usr/bin/env node
// Smoke check non destructif d'un bundle App'Ergo web.
//
// Vérifie les fichiers indispensables Flutter web, soit depuis un dossier local
// `build/web`, soit depuis une URL publique/staging.

import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const args = process.argv.slice(2);

const usage = () => {
  console.error('Usage: node tools/check-web-release.mjs --dir <build/web> | --url <https://app.example.fr>');
  process.exit(1);
};

const readArg = (name) => {
  const index = args.indexOf(name);
  if (index === -1) return '';
  return args[index + 1] || '';
};

const dir = readArg('--dir');
const url = readArg('--url');

if ((!dir && !url) || (dir && url)) usage();

const mode = dir ? 'dir' : 'url';
const source = dir ? path.resolve(dir) : new URL(url.endsWith('/') ? url : `${url}/`).toString();
const failures = [];
const checked = [];

const normalizeAssetPath = (assetPath) => assetPath.replace(/^\/+/, '');
const stripHtmlComments = (source) => source.replace(/<!--[\s\S]*?-->/g, '');

async function fetchText(assetPath) {
  const normalized = normalizeAssetPath(assetPath);
  if (mode === 'dir') {
    return readFile(path.join(source, normalized), 'utf8');
  }

  const target = new URL(normalized, source);
  const response = await fetch(target, { redirect: 'follow' });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} ${response.statusText}`);
  }
  return response.text();
}

async function fetchBytes(assetPath) {
  const normalized = normalizeAssetPath(assetPath);
  if (mode === 'dir') {
    return readFile(path.join(source, normalized));
  }

  const target = new URL(normalized, source);
  const response = await fetch(target, { redirect: 'follow' });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} ${response.statusText}`);
  }
  return Buffer.from(await response.arrayBuffer());
}

async function checkText(assetPath, predicate, label = assetPath) {
  try {
    const text = await fetchText(assetPath);
    if (!predicate(text)) {
      failures.push(`${label}: contenu inattendu`);
      return '';
    }
    checked.push(label);
    return text;
  } catch (error) {
    failures.push(`${label}: ${error.message}`);
    return '';
  }
}

async function checkBytes(assetPath, minBytes, label = assetPath) {
  try {
    const bytes = await fetchBytes(assetPath);
    if (bytes.length < minBytes) {
      failures.push(`${label}: trop petit (${bytes.length} octets)`);
      return;
    }
    checked.push(label);
  } catch (error) {
    failures.push(`${label}: ${error.message}`);
  }
}

async function checkUnavailable(assetPath, label = assetPath) {
  const normalized = normalizeAssetPath(assetPath);
  if (mode === 'dir') {
    try {
      await readFile(path.join(source, normalized));
      failures.push(`${label}: doit être absent`);
    } catch (error) {
      if (error.code !== 'ENOENT') {
        failures.push(`${label}: ${error.message}`);
        return;
      }
      checked.push(`${label}-absent`);
    }
    return;
  }

  try {
    const target = new URL(normalized, source);
    const response = await fetch(target, { redirect: 'manual' });
    if (response.status !== 404 && response.status !== 410) {
      failures.push(`${label}: HTTP ${response.status}, 404/410 attendu`);
      return;
    }
    checked.push(`${label}-disabled`);
  } catch (error) {
    failures.push(`${label}: ${error.message}`);
  }
}

async function checkLiveSecurityHeaders() {
  if (mode !== 'url') return;

  try {
    const response = await fetch(source, { redirect: 'follow' });
    const csp = response.headers.get('content-security-policy') || '';
    const reportOnly = response.headers.get('content-security-policy-report-only') || '';
    const requiredDirectives = [
      "default-src 'self'",
      "object-src 'none'",
      "script-src-attr 'none'",
      "connect-src 'self' https://api.aidhabitat.fr",
      "upgrade-insecure-requests",
    ];

    if (!response.ok) {
      failures.push(`security-headers: HTTP ${response.status}`);
      return;
    }
    if (!csp || requiredDirectives.some((directive) => !csp.includes(directive))) {
      failures.push('security-headers: CSP bloquante absente ou incomplète');
      return;
    }
    if (reportOnly) {
      failures.push('security-headers: CSP encore présente en Report-Only');
      return;
    }
    checked.push('content-security-policy-enforced');
  } catch (error) {
    failures.push(`security-headers: ${error.message}`);
  }
}

const indexHtml = await checkText('index.html', (text) => (
  text.includes("<title>App'Ergo</title>")
  && text.includes('flutter_bootstrap.js')
  && text.includes('pdfjs/pdf.min.js')
  && text.includes('retireLegacyPwa')
  && !text.includes('rel="manifest"')
), 'index.html');

await checkText('flutter_bootstrap.js', (text) => (
  text.includes('main.dart.js')
  && text.includes('_flutter.loader.load')
  && /_flutter\.loader\.load\(\s*\);/.test(text)
), 'flutter_bootstrap.js');

await checkUnavailable('flutter_service_worker.js', 'flutter_service_worker.js');
await checkUnavailable('manifest.json', 'manifest.json');
await checkLiveSecurityHeaders();

await checkText('version.json', (text) => {
  try {
    const version = JSON.parse(text);
    return typeof version.frameworkVersion === 'string' || typeof version.app_name === 'string';
  } catch {
    return false;
  }
}, 'version.json');

await Promise.all([
  checkBytes('main.dart.js', 500_000, 'main.dart.js'),
  checkBytes('flutter.js', 8_000, 'flutter.js'),
  checkBytes('sqlite3.wasm', 100_000, 'sqlite3.wasm'),
  checkBytes('sqflite_sw.js', 1_000, 'sqflite_sw.js'),
  checkBytes('favicon.png', 500, 'favicon.png'),
  checkBytes('pdfjs/pdf.min.js', 100_000, 'pdfjs/pdf.min.js'),
  checkBytes('pdfjs/pdf.worker.min.js', 500_000, 'pdfjs/pdf.worker.min.js'),
  checkBytes('icons/Icon-192.png', 1_000, 'icons/Icon-192.png'),
  checkBytes('icons/Icon-512.png', 1_000, 'icons/Icon-512.png'),
  checkBytes('icons/Icon-maskable-192.png', 1_000, 'icons/Icon-maskable-192.png'),
  checkBytes('icons/Icon-maskable-512.png', 1_000, 'icons/Icon-maskable-512.png'),
]);

const indexWithoutComments = stripHtmlComments(indexHtml);
if (
  indexHtml
  && !indexWithoutComments.includes('https://unpkg.com/')
  && !indexWithoutComments.includes('cdn.jsdelivr.net')
) {
  checked.push('no-cdn-reference');
} else if (indexHtml) {
  failures.push('index.html: référence CDN détectée');
}

if (failures.length > 0) {
  console.error('[web-release-check] ÉCHEC');
  console.error(JSON.stringify({
    source,
    checked: checked.length,
    failures,
  }, null, 2));
  process.exit(1);
}

console.log('[web-release-check] OK');
console.log(JSON.stringify({
  source,
  checked: checked.length,
}, null, 2));
