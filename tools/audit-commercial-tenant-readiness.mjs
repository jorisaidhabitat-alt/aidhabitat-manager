#!/usr/bin/env node
// Audit non destructif de préparation multi-organisation / commercialisation.
//
// Usage :
//   node tools/audit-commercial-tenant-readiness.mjs [schema-full.json] [report.md]

import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const schemaPath = process.argv[2] || '';
const reportPath = process.argv[3] || 'tmp/commercial-tenant-readiness.md';

const root = process.cwd();

const KEY_REMOTE_TABLES = [
  'Beneficiaires',
  '📁 dossiers',
  'Logements',
  '👨‍👩‍👧 contexte_de_vie',
  '📋 informations_administratives',
  '🚿 diagnostic_sanitaires',
  '📏 mesures_anthropometriques',
  '📝 observations',
  'mobile_documents',
  'mobile_document_chunks',
  'mobile_note_pages',
  'mobile_visit_photos',
  'mobile_visit_recommendations',
  '👷🏻‍♀️ ergotherapeutes',
  'etablissements',
];

const KEY_LOCAL_TABLES = [
  'app_users',
  'user_access_scopes',
  'patients',
  'housings',
  'dossiers',
  'documents',
  'note_pages',
  'sync_operations',
  'contexte_de_vie',
  'diagnostic_sanitaires',
  'mesures_anthropometriques',
  'observations_synthese',
  'visit_recommendations',
];

const TENANT_FIELD_PATTERNS = [
  /organisation/i,
  /organization/i,
  /^org_/i,
  /tenant/i,
  /client_id/i,
  /structure/i,
  /workspace/i,
];

const readText = async (file) => readFile(path.join(root, file), 'utf8');

const tableSchema = (entry) => entry.schema || entry.table || entry;

const parseSchema = async () => {
  if (!schemaPath) return null;
  const raw = await readFile(path.resolve(schemaPath), 'utf8');
  return JSON.parse(raw);
};

const hasTenantField = (columns) => (
  columns.some((column) => TENANT_FIELD_PATTERNS.some((pattern) => pattern.test(String(column.title || column.column_name || ''))))
);

const extractCreateTableBlocks = (source, tableName) => {
  const pattern = new RegExp(`CREATE TABLE\\s+${tableName}\\s*\\(([\\s\\S]*?)\\n\\s*\\)`, 'gm');
  return [...source.matchAll(pattern)].map((match) => match[1] || '');
};

const localTableHasTenantField = (block) => (
  TENANT_FIELD_PATTERNS.some((pattern) => pattern.test(block))
);

const schema = await parseSchema();
const localDbSource = await readText('aid_habitat_app/lib/services/local_database.dart');
const helpersSource = await readText('server/helpers.mjs');
const documentsRoutesSource = await readText('server/routes/documents.mjs');
const authServiceSource = await readText('aid_habitat_app/lib/services/auth_service.dart');

const lines = [];
const add = (line = '') => lines.push(line);

add('# Audit commercial multi-organisation');
add();
add(`Date : ${new Date().toISOString()}`);
add('Mode : lecture seule, aucun appel réseau, aucune modification NocoDB.');
add();

add('## Résumé');
add();
add('- L’app possède déjà une logique utilisateur, rôles `ADMIN` / `ERGO`, scopes locaux et contrôle par dossier.');
add("- L’app possède déjà une base locale offline et une file de synchronisation.");
add("- Les fichiers lourds sont encore majoritairement portés par NocoDB/chunks, ce qui reste à migrer vers stockage objet.");
add("- La vraie séparation commerciale multi-client n’est pas encore un invariant transversal.");
add();

if (schema) {
  const tables = (schema.tables || []).map(tableSchema);
  const byTitle = new Map(tables.map((table) => [table.title, table]));
  const remoteRows = KEY_REMOTE_TABLES.map((title) => {
    const table = byTitle.get(title);
    if (!table) return { title, status: 'missing', tenant: false };
    const columns = table.columns || [];
    return {
      title,
      status: 'present',
      tenant: hasTenantField(columns),
      columns: columns.length,
    };
  });

  add('## NocoDB');
  add();
  add(`Schéma analysé : \`${schemaPath}\``);
  add();
  add('| Table sensible | Statut | Champ organisation/client | Colonnes |');
  add('| --- | --- | --- | ---: |');
  for (const row of remoteRows) {
    add(`| ${row.title} | ${row.status} | ${row.tenant ? 'oui' : 'non'} | ${row.columns ?? 0} |`);
  }
  add();
  const missingTenant = remoteRows.filter((row) => row.status === 'present' && !row.tenant);
  if (missingTenant.length > 0) {
    add('Constat : ces tables doivent recevoir un champ `organisation_id` ou équivalent avant usage multi-client :');
    for (const row of missingTenant) add(`- ${row.title}`);
    add();
  }
}

add('## Base locale offline');
add();
add('| Table locale | Champ organisation/client |');
add('| --- | --- |');
for (const table of KEY_LOCAL_TABLES) {
  const blocks = extractCreateTableBlocks(localDbSource, table);
  const ok = blocks.some((block) => localTableHasTenantField(block));
  add(`| ${table} | ${ok ? 'oui' : 'non'} |`);
}
add();

add('## Accès et confidentialité');
add();
const checks = [
  {
    label: 'Contrôle serveur par dossier',
    ok: /canAccessDossierRecord/.test(helpersSource) && /resolveBeneficiaryAccess/.test(helpersSource),
    detail: '`canAccessDossierRecord` et `resolveBeneficiaryAccess` existent.',
  },
  {
    label: 'Contrôle par organisation',
    ok: /organisationId|organizationId|tenantId|clientId|organisation_id|organization_id|tenant_id|client_id/.test(helpersSource),
    detail: "Aucune couche d'autorisation organisationnelle explicite détectée côté serveur.",
  },
  {
    label: 'Endpoints publics documents',
    ok: !/router\.get\('\/public\/documents/.test(documentsRoutesSource),
    detail: "`/public/documents/:documentId/content` expose un contenu via UUID document, sans session.",
  },
  {
    label: 'Endpoints publics notes',
    ok: !/router\.get\('\/public\/note-pages/.test(documentsRoutesSource),
    detail: "`/public/note-pages/:notePageId/preview` expose une preview via UUID note, sans session.",
  },
  {
    label: 'Bootstrap password local',
    ok: !/bootstrapPassword\s*=\s*'AidHabitat!Local'/.test(authServiceSource),
    detail: "Un mot de passe bootstrap local existe encore pour les comptes seed.",
  },
];

add('| Point | État | Détail |');
add('| --- | --- | --- |');
for (const check of checks) {
  add(`| ${check.label} | ${check.ok ? 'OK' : 'À traiter'} | ${check.detail} |`);
}
add();

add('## Première feuille de route');
add();
add('1. Ajouter `organisations` dans NocoDB staging : `id`, `nom`, `statut`, `created_at`.');
add('2. Ajouter `organisation_id` aux tables sensibles staging, sans modifier la prod.');
add("3. Rattacher Aid'Habitat à une organisation par défaut, puis backfill tous les dossiers existants.");
add('4. Ajouter `organisation_id` dans SQLite local : `app_users`, `patients`, `dossiers`, `documents`, `note_pages`, `sync_operations`.');
add("5. Étendre l'auth serveur : chaque session doit porter `organisationId` + rôle.");
add("6. Filtrer tous les endpoints serveur par `organisationId` avant d'écrire ou lire des données.");
add('7. Remplacer les endpoints publics documents/notes par URLs signées courtes ou accès authentifié.');
add('8. Ajouter les colonnes S3 dans `mobile_documents`, puis tester la double lecture sur staging.');
add('9. Exécuter les flux critiques sur staging avant toute propagation production.');
add();

add('## Décision recommandée');
add();
add("Commencer par le modèle `organisations` + `organisation_id` en staging. C'est la fondation qui évite de mélanger les dossiers Aid'Habitat avec ceux de futurs clients.");

await writeFile(path.resolve(reportPath), `${lines.join('\n')}\n`);

console.log('[commercial-tenant-readiness] OK');
console.log(JSON.stringify({ report: path.resolve(reportPath), schema: schemaPath || null }, null, 2));
