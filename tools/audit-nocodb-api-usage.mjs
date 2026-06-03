#!/usr/bin/env node
// Audit statique des dépendances NocoDB/API.
//
// Aucun réseau, aucune écriture. Le but est de rendre visible le niveau de
// dépendance actuel à `/api/v2` avant toute migration NocoDB V3.

import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const outputPath = process.argv[2] || '';
const root = process.cwd();

const INCLUDE_DIRS = [
  'server',
  'tools',
  'scripts',
  'services',
  'components',
  'aid_habitat_app/lib',
  'aid_habitat_app/test',
];

const SKIP_DIRS = new Set([
  'node_modules',
  '.git',
  'tmp',
  'dist',
  'build',
  '.dart_tool',
  '.next',
]);

const SKIP_FILES = new Set([
  'tools/audit-nocodb-api-usage.mjs',
]);

const EXTENSIONS = new Set([
  '.js',
  '.mjs',
  '.cjs',
  '.ts',
  '.tsx',
  '.dart',
  '.sh',
  '.md',
  '.json',
]);

const PATTERNS = [
  { key: 'apiV2', label: '/api/v2', regex: /\/api\/v2\b/g, migrationRisk: 'high' },
  { key: 'apiV1', label: '/api/v1', regex: /\/api\/v1\b/g, migrationRisk: 'medium' },
  { key: 'apiV3', label: '/api/v3', regex: /\/api\/v3\b/g, migrationRisk: 'info' },
  { key: 'callNocoTool', label: 'callNocoTool', regex: /\bcallNocoTool\b/g, migrationRisk: 'medium' },
  { key: 'xcToken', label: 'xc-token', regex: /\bxc-token\b/g, migrationRisk: 'medium' },
  { key: 'nocodbEnv', label: 'NOCODB_* env', regex: /\bNOCODB_[A-Z0-9_]+\b/g, migrationRisk: 'info' },
];

const fileExists = async (file) => {
  try {
    await readdir(file);
    return true;
  } catch {
    return false;
  }
};

async function collectFiles(dir) {
  const full = path.join(root, dir);
  if (!(await fileExists(full))) return [];
  const files = [];

  async function walk(current) {
    const entries = await readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue;
        await walk(path.join(current, entry.name));
        continue;
      }
      if (!entry.isFile()) continue;
      const ext = path.extname(entry.name);
      if (!EXTENSIONS.has(ext)) continue;
      files.push(path.join(current, entry.name));
    }
  }

  await walk(full);
  return files;
}

const classifyPath = (relativePath) => {
  if (relativePath.startsWith('server/')) return 'runtime-server';
  if (relativePath.startsWith('aid_habitat_app/lib/')) return 'runtime-flutter';
  if (relativePath.startsWith('components/') || relativePath.startsWith('services/')) return 'runtime-web';
  if (relativePath.startsWith('tools/') || relativePath.startsWith('scripts/')) return 'tooling';
  return 'other';
};

const files = (await Promise.all(INCLUDE_DIRS.map(collectFiles))).flat();
const findings = [];
const totals = Object.fromEntries(PATTERNS.map((pattern) => [pattern.key, 0]));

  for (const file of files) {
  const relativePath = path.relative(root, file);
  if (SKIP_FILES.has(relativePath)) continue;
  const source = await readFile(file, 'utf8').catch(() => '');
  if (!source) continue;
  const lines = source.split(/\r?\n/);

  for (const [lineIndex, line] of lines.entries()) {
    for (const pattern of PATTERNS) {
      const matches = [...line.matchAll(pattern.regex)];
      if (matches.length === 0) continue;
      totals[pattern.key] += matches.length;
      findings.push({
        file: relativePath,
        line: lineIndex + 1,
        area: classifyPath(relativePath),
        kind: pattern.key,
        label: pattern.label,
        migrationRisk: pattern.migrationRisk,
        count: matches.length,
        excerpt: line.trim().slice(0, 220),
      });
    }
  }
}

const runtimeApiV2 = findings.filter((finding) =>
  finding.kind === 'apiV2' && finding.area.startsWith('runtime'),
);
const toolingApiV2 = findings.filter((finding) =>
  finding.kind === 'apiV2' && finding.area === 'tooling',
);

const riskLevel = runtimeApiV2.length > 0
  ? 'high'
  : toolingApiV2.length > 0
    ? 'medium'
    : 'low';

const uniqueRuntimeV2Files = [...new Set(runtimeApiV2.map((finding) => finding.file))].sort();
const uniqueToolingV2Files = [...new Set(toolingApiV2.map((finding) => finding.file))].sort();

const report = {
  createdAt: new Date().toISOString(),
  destructive: false,
  riskLevel,
  summary: {
    scannedFiles: files.length,
    findings: findings.length,
    totals,
    runtimeApiV2Files: uniqueRuntimeV2Files.length,
    toolingApiV2Files: uniqueToolingV2Files.length,
  },
  recommendation: riskLevel === 'high'
    ? 'Ne pas migrer NocoDB V3 en production avant validation sur staging et adaptation des endpoints runtime /api/v2.'
    : 'Migration moins risquée, mais à tester sur staging avant production.',
  runtimeApiV2Files: uniqueRuntimeV2Files,
  toolingApiV2Files: uniqueToolingV2Files,
  findings,
};

const markdown = [
  '# Audit usages NocoDB API',
  '',
  `Créé le : ${report.createdAt}`,
  '',
  `Risque migration V3 : ${riskLevel}`,
  '',
  `Fichiers scannés : ${report.summary.scannedFiles}`,
  '',
  `Occurrences /api/v2 runtime : ${runtimeApiV2.length}`,
  '',
  `Occurrences /api/v2 tooling : ${toolingApiV2.length}`,
  '',
  '## Recommandation',
  '',
  report.recommendation,
  '',
  '## Fichiers runtime avec /api/v2',
  '',
  ...(uniqueRuntimeV2Files.length ? uniqueRuntimeV2Files.map((file) => `- ${file}`) : ['- Aucun']),
  '',
  '## Fichiers tooling avec /api/v2',
  '',
  ...(uniqueToolingV2Files.length ? uniqueToolingV2Files.map((file) => `- ${file}`) : ['- Aucun']),
  '',
  '## Totaux',
  '',
  ...Object.entries(totals).map(([key, value]) => `- ${key}: ${value}`),
  '',
].join('\n');

if (outputPath) {
  const resolvedOutput = path.resolve(outputPath);
  await mkdir(path.dirname(resolvedOutput), { recursive: true });
  await writeFile(resolvedOutput, markdown);
  await writeFile(resolvedOutput.replace(/\.md$/i, '.json'), JSON.stringify(report, null, 2));
}

console.log('[nocodb-api-audit] OK - aucun changement effectué');
console.log(JSON.stringify({
  riskLevel,
  scannedFiles: report.summary.scannedFiles,
  findings: report.summary.findings,
  apiV2: totals.apiV2,
  runtimeApiV2Files: uniqueRuntimeV2Files.length,
  toolingApiV2Files: uniqueToolingV2Files.length,
  report: outputPath ? path.resolve(outputPath) : null,
}, null, 2));
