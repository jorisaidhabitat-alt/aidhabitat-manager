#!/usr/bin/env node
// Audit local des secrets et variables d'environnement.
//
// Aucun réseau, aucune écriture hors rapport optionnel. Les valeurs des
// variables ne sont jamais imprimées.

import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const outputPath = process.argv[2] || '';
const root = process.cwd();

const REQUIRED_ENV = [
  'NOCODB_API_URL',
  'NOCODB_API_TOKEN',
  'NOCODB_BASE_ID',
];

const RECOMMENDED_ENV = [
  'NOCODB_FORCE_REST',
  'NOCODB_MCP_URL',
];

const ALLOWED_LOCAL_ENV_FILES = new Set([
  '.env.local',
]);

const SENSITIVE_NAME_RE = /(TOKEN|SECRET|PASSWORD|PRIVATE|CREDENTIAL|API_KEY|AUTH)/i;
const SECRET_VALUE_RE = [
  /NOCODB_API_TOKEN\s*=\s*[^\s"'`]{16,}/i,
  /NOCODB_AUTH_TOKEN\s*=\s*[^\s"'`]{16,}/i,
  /(?:password|passwd|pwd)\s*[:=]\s*["'][^"']{8,}["']/i,
  /(?:api[_-]?key|secret|token)\s*[:=]\s*["'][^"']{16,}["']/i,
  /-----BEGIN (?:RSA |EC |OPENSSH |)PRIVATE KEY-----/,
];

const SKIP_DIRS = new Set([
  '.git',
  'node_modules',
  'tmp',
  'dist',
  'build',
  '.dart_tool',
  '.vercel',
]);

const SKIP_FILE_PATTERNS = [
  /(^|\/)pdf(?:\.worker)?\.min\.js$/,
  /\.min\.js$/,
];

const TEXT_EXTENSIONS = new Set([
  '.js',
  '.mjs',
  '.cjs',
  '.ts',
  '.tsx',
  '.dart',
  '.json',
  '.md',
  '.yml',
  '.yaml',
  '.sh',
  '.txt',
  '.html',
  '.css',
  '.env',
  '',
]);

const readIfExists = async (file) => {
  try {
    return await readFile(file, 'utf8');
  } catch {
    return '';
  }
};

const parseEnvFile = (source) => {
  const env = {};
  for (const line of source.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) continue;
    env[match[1]] = match[2].trim();
  }
  return env;
};

async function collectFiles(currentDir) {
  const files = [];
  const entries = await readdir(currentDir, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) {
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      files.push(...await collectFiles(path.join(currentDir, entry.name)));
      continue;
    }
    if (!entry.isFile()) continue;
    const full = path.join(currentDir, entry.name);
    const relative = path.relative(root, full);
    const ext = entry.name.startsWith('.env') ? '.env' : path.extname(entry.name);
    if (!TEXT_EXTENSIONS.has(ext)) continue;
    files.push(relative);
  }
  return files;
}

const runGitLsFiles = async () => {
  const { spawn } = await import('node:child_process');
  return new Promise((resolve) => {
    const child = spawn('git', ['ls-files'], { cwd: root });
    let stdout = '';
    child.stdout.on('data', (chunk) => { stdout += chunk.toString(); });
    child.on('close', () => {
      resolve(new Set(stdout.split(/\r?\n/).filter(Boolean)));
    });
    child.on('error', () => resolve(new Set()));
  });
};

const trackedFiles = await runGitLsFiles();
const envLocal = parseEnvFile(await readIfExists(path.join(root, '.env.local')));
const envSources = { ...envLocal, ...process.env };

const missingRequired = REQUIRED_ENV.filter((name) => !String(envSources[name] || '').trim());
const missingRecommended = RECOMMENDED_ENV.filter((name) => !String(envSources[name] || '').trim());

const envFiles = (await collectFiles(root)).filter((file) => path.basename(file).startsWith('.env'));
const trackedEnvFiles = envFiles.filter((file) => trackedFiles.has(file));
const forbiddenTrackedEnvFiles = trackedEnvFiles.filter((file) => !ALLOWED_LOCAL_ENV_FILES.has(file));

const findings = [];
const warnings = [];
for (const file of trackedFiles) {
  if (file.includes('node_modules/') || file.startsWith('tmp/')) continue;
  if (SKIP_FILE_PATTERNS.some((pattern) => pattern.test(file))) continue;
  const ext = path.extname(file);
  if (!TEXT_EXTENSIONS.has(ext) && !path.basename(file).startsWith('.env')) continue;
  const source = await readIfExists(path.join(root, file));
  if (!source) continue;
  const lines = source.split(/\r?\n/);
  for (const [index, line] of lines.entries()) {
    if (
      file === 'aid_habitat_app/lib/services/auth_service.dart'
      && line.includes('static const String bootstrapPassword')
      && /['"][^'"]{8,}['"]/.test(line)
    ) {
      warnings.push({
        file,
        line: index + 1,
        reason: 'hardcoded-bootstrap-password',
        excerpt: 'bootstrapPassword=***',
      });
      continue;
    }
    if (line.includes('<') && line.includes('>')) continue;
    if (!SENSITIVE_NAME_RE.test(line) && !SECRET_VALUE_RE.some((regex) => regex.test(line))) continue;
    for (const regex of SECRET_VALUE_RE) {
      if (regex.test(line)) {
        findings.push({
          file,
          line: index + 1,
          reason: 'possible-secret-value',
          excerpt: line.replace(/=.*/, '=***').replace(/:.*/, ':***').slice(0, 160),
        });
        break;
      }
    }
  }
}

const gitignore = await readIfExists(path.join(root, '.gitignore'));
const gitignoreChecks = {
  envLocalIgnored: gitignore.includes('.env.local') || gitignore.includes('.env.*'),
  tmpIgnored: /^tmp\/?$/m.test(gitignore),
  backupsIgnored: /^backups\/?$/m.test(gitignore),
};

const failures = [];
if (missingRequired.length > 0) failures.push(`variables requises manquantes: ${missingRequired.join(', ')}`);
if (forbiddenTrackedEnvFiles.length > 0) failures.push(`fichiers env suivis par git: ${forbiddenTrackedEnvFiles.join(', ')}`);
if (findings.length > 0) failures.push(`secrets potentiels suivis par git: ${findings.length}`);
if (!gitignoreChecks.envLocalIgnored) failures.push('.env.local non ignoré');
if (!gitignoreChecks.tmpIgnored) failures.push('tmp/ non ignoré');
if (!gitignoreChecks.backupsIgnored) failures.push('backups/ non ignoré');

const report = {
  createdAt: new Date().toISOString(),
  destructive: false,
  ok: failures.length === 0,
  failures,
  summary: {
    requiredEnv: REQUIRED_ENV.length,
    missingRequired,
    recommendedEnv: RECOMMENDED_ENV.length,
    missingRecommended,
    trackedFiles: trackedFiles.size,
    trackedEnvFiles,
    forbiddenTrackedEnvFiles,
    possibleSecretFindings: findings.length,
    warnings: warnings.length,
    gitignoreChecks,
  },
  findings,
  warnings,
};

const markdown = [
  '# Audit secrets et environnement',
  '',
  `Créé le : ${report.createdAt}`,
  '',
  `Résultat : ${report.ok ? 'OK' : 'ÉCHEC'}`,
  '',
  '## Variables',
  '',
  `Variables requises manquantes : ${missingRequired.length ? missingRequired.join(', ') : 'aucune'}`,
  '',
  `Variables recommandées manquantes : ${missingRecommended.length ? missingRecommended.join(', ') : 'aucune'}`,
  '',
  '## Git',
  '',
  `Fichiers env suivis : ${trackedEnvFiles.length ? trackedEnvFiles.join(', ') : 'aucun'}`,
  '',
  `Findings secrets potentiels : ${findings.length}`,
  '',
  `Avertissements : ${warnings.length}`,
  '',
  ...(warnings.length
    ? [
        '## Avertissements',
        '',
        ...warnings.map((warning) => [
          `- ${warning.reason} : ${warning.file}:${warning.line}`,
          `  - Extrait masqué : ${warning.excerpt}`,
          '  - Action recommandée : préparer une rotation via variable de build avant de supprimer la valeur du code.',
        ].join('\n')),
        '',
      ]
    : []),
  '## .gitignore',
  '',
  ...Object.entries(gitignoreChecks).map(([key, value]) => `- ${key}: ${value ? 'OK' : 'manquant'}`),
  '',
].join('\n');

if (outputPath) {
  const resolvedOutput = path.resolve(outputPath);
  await mkdir(path.dirname(resolvedOutput), { recursive: true });
  await writeFile(resolvedOutput, markdown);
  await writeFile(resolvedOutput.replace(/\.md$/i, '.json'), JSON.stringify(report, null, 2));
}

if (!report.ok) {
  console.error('[env-secrets-audit] ÉCHEC');
  console.error(JSON.stringify({
    failures,
    report: outputPath ? path.resolve(outputPath) : null,
  }, null, 2));
  process.exit(1);
}

console.log('[env-secrets-audit] OK - aucun secret affiché');
console.log(JSON.stringify({
  missingRequired,
  missingRecommended,
  possibleSecretFindings: findings.length,
  warnings: warnings.length,
  trackedEnvFiles,
  report: outputPath ? path.resolve(outputPath) : null,
}, null, 2));
