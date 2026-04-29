// Backfill manuel : re-synchronise pour TOUS les bénéficiaires les
// champs dénormalisés (`beneficiaire_prenom` / `beneficiaire_nom` /
// `beneficiaire_nom_complet` / `dossier_libelle`) dans les 4 tables
// `mobile_*` qui les stockent (mobile_documents, mobile_document_chunks,
// mobile_note_pages, mobile_visit_recommendations).
//
// Sert UNE FOIS pour rattraper le legacy stale ; ensuite le hook
// PATCH /api/beneficiaires/:id maintient automatiquement à jour
// (cf. resyncLegacyNames.mjs et server/index.mjs).
//
// Usage :
//   node tools/resync-legacy-names.mjs           # dry-run (lecture seule)
//   node tools/resync-legacy-names.mjs --apply   # exécution réelle
//
// Idempotent : ne PATCHe que les lignes dont au moins un champ
// dénormalisé diffère de la valeur canonique côté `beneficiaires`.

import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { resyncAll } from '../server/resyncLegacyNames.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const envLocalPath = path.resolve(__dirname, '../.env.local');
if (fs.existsSync(envLocalPath) && !process.env.NOCODB_API_URL) {
  for (const line of fs.readFileSync(envLocalPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (m) process.env[m[1]] = m[2].trim();
  }
}

const APPLY = process.argv.includes('--apply');

const apiUrl = process.env.NOCODB_API_URL?.replace(/\/$/, '');
const baseId = process.env.NOCODB_BASE_ID;
const token = process.env.NOCODB_API_TOKEN;

if (!apiUrl || !baseId || !token) {
  console.error('NOCODB_API_URL / NOCODB_API_TOKEN / NOCODB_BASE_ID requis');
  process.exit(1);
}

console.log(
  `🔄 Resync des noms legacy (${APPLY ? 'APPLY' : 'DRY-RUN'})…\n`,
);

if (!APPLY) {
  console.log('🚧 Dry-run : aucune modif réelle ne sera effectuée.');
  console.log('   La fonction `resyncBeneficiaireDenormalizedNames` est');
  console.log('   idempotente — les PATCHes ne touchent QUE les lignes');
  console.log('   stale (la fonction ne supporte pas un mode dry-run');
  console.log('   séparé, donc on simule en désactivant le PATCH).\n');
  // Patche le module pour intercepter les fetch() et bloquer les PATCH.
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    if (init.method === 'PATCH') {
      // Compte les payloads sans les envoyer.
      const body = init.body || '[]';
      const payload = (() => {
        try {
          return JSON.parse(body);
        } catch {
          return [];
        }
      })();
      const count = Array.isArray(payload) ? payload.length : 1;
      console.log(
        `   [DRY-RUN] PATCH bloqué → ${count} ligne(s) auraient été update`,
      );
      // Réponse synthétique 200.
      return new Response(JSON.stringify({}), { status: 200 });
    }
    return originalFetch(url, init);
  };
}

const summary = await resyncAll({ apiUrl, baseId, token });

console.log('\n━'.repeat(50));
console.log(`Total mis à jour : ${summary.totalUpdated} ligne(s)`);
console.log(`Bénéficiaires scannés : ${summary.perBeneficiary.length}`);
console.log('━'.repeat(50));

if (!APPLY && summary.totalUpdated > 0) {
  console.log(
    '\nRelance avec --apply pour exécuter la resync (idempotente).',
  );
}
