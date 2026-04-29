// Resync des champs « dénormalisés » de bénéficiaire (`beneficiaire_prenom`,
// `beneficiaire_nom`, `beneficiaire_nom_complet`, `dossier_libelle`)
// dans les 4 tables `mobile_*` qui les stockent par défaut au moment
// de l'écriture :
//
//   - mobile_documents
//   - mobile_document_chunks
//   - mobile_note_pages
//   - mobile_visit_recommendations
//
// Pourquoi c'est nécessaire : ces champs sont snapshottés à l'upload
// pour éviter une jointure côté UI (perf), mais ils restent stale si
// l'ergo renomme le bénéficiaire après coup. Cette resync remet tout
// au carré sans toucher aux liens FK (`beneficiaire_id` UUID).
//
// Idempotent — si tout est déjà à jour, aucun PATCH n'est envoyé.
//
// Utilisation :
//   - Auto : appelé par `app.patch('/api/beneficiaires/:patientId', …)`
//     dans server/index.mjs après la mise à jour des champs nom/prenom.
//   - Manuel (backfill complet) : `tools/resync-legacy-names.mjs --apply`.

import 'dotenv/config';

const stringValue = (v) => (v == null || v === 'null' ? '' : String(v).trim());

const buildHeaders = (token) => ({
  'xc-token': token,
  'Content-Type': 'application/json',
});

const fetchJson = async (url, init = {}) => {
  const res = await fetch(url, init);
  if (!res.ok) {
    throw new Error(
      `${res.status} ${res.statusText} on ${url} :: ${await res
        .text()
        .catch(() => '')}`,
    );
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
};

const queryAll = async ({ apiUrl, tableId, token, where = '' }) => {
  const all = [];
  let offset = 0;
  const headers = buildHeaders(token);
  while (true) {
    const w = where ? `&where=${encodeURIComponent(where)}` : '';
    const url = `${apiUrl}/api/v2/tables/${tableId}/records?limit=1000&offset=${offset}${w}`;
    const r = await fetchJson(url, { headers });
    const list = r.list || [];
    all.push(...list);
    if (list.length < 1000) break;
    offset += 1000;
  }
  return all;
};

const updateRecords = async ({ apiUrl, tableId, token, records }) => {
  if (records.length === 0) return 0;
  const headers = buildHeaders(token);
  const BATCH = 50;
  let updated = 0;
  for (let i = 0; i < records.length; i += BATCH) {
    const slice = records.slice(i, i + BATCH);
    await fetchJson(`${apiUrl}/api/v2/tables/${tableId}/records`, {
      method: 'PATCH',
      headers,
      body: JSON.stringify(slice),
    });
    updated += slice.length;
  }
  return updated;
};

// Tables impactées + nom du champ id dénormalisé qu'elles exposent.
// Toutes utilisent `beneficiaire_id` comme clé legacy + 4 champs
// dénormalisés (vérifié via inspect-nocodb-schema.mjs).
const TARGETS = [
  { name: 'mobile_documents' },
  { name: 'mobile_document_chunks' },
  { name: 'mobile_note_pages' },
  { name: 'mobile_visit_recommendations' },
];

const resolveTableIds = async ({ apiUrl, baseId, token }) => {
  const meta = await fetchJson(`${apiUrl}/api/v2/meta/bases/${baseId}/tables`, {
    headers: buildHeaders(token),
  });
  const tables = (meta.list || meta).filter((t) => t && t.id);
  const out = {};
  for (const t of TARGETS) {
    const tbl = tables.find(
      (x) => String(x.title).toLowerCase() === t.name.toLowerCase(),
    );
    if (tbl) out[t.name] = String(tbl.id);
  }
  return out;
};

/**
 * Resynchronise les champs dénormalisés pour UN bénéficiaire identifié
 * par son UUID legacy (`patient_id` côté dossier / `beneficiaire_id`
 * côté tables mobile_*).
 *
 * Renvoie un objet `{ tableName: count, total }` listant le nombre de
 * lignes mises à jour par table. Si tout est déjà à jour, total = 0
 * (aucun PATCH envoyé, c'est idempotent).
 */
export async function resyncBeneficiaireDenormalizedNames({
  beneficiaireUuid,
  prenom,
  nom,
  dossierLabel = '',
  apiUrl,
  baseId,
  token,
  tableIds = null, // optionnel : pré-résolu, sinon on lit le schéma
}) {
  if (!beneficiaireUuid || typeof beneficiaireUuid !== 'string') {
    throw new Error('beneficiaireUuid manquant');
  }
  const cleanPrenom = stringValue(prenom);
  const cleanNom = stringValue(nom);
  const cleanFull = `${cleanPrenom} ${cleanNom}`.replace(/\s+/g, ' ').trim();
  const cleanLabel = stringValue(dossierLabel) || cleanFull;

  const ids = tableIds || (await resolveTableIds({ apiUrl, baseId, token }));
  const stats = { total: 0 };

  for (const t of TARGETS) {
    const tableId = ids[t.name];
    if (!tableId) {
      stats[t.name] = 0;
      continue;
    }
    // Lit toutes les lignes de la table où le bénéficiaire match.
    // ⚠️ NE PAS quoter l'UUID avec JSON.stringify : NocoDB v2 traite les
    // doubles guillemets COMME PARTIE DE LA VALEUR et ne match plus rien.
    // Les UUIDs ne contiennent que [0-9a-f-] donc pas besoin d'échappement.
    const records = await queryAll({
      apiUrl,
      tableId,
      token,
      where: `(beneficiaire_id,eq,${beneficiaireUuid})`,
    });

    // Ne PATCHe QUE les lignes dont au moins un des 3 (4 pour les
    // tables qui ont `dossier_libelle`) champs dénormalisés diffère
    // de la valeur canonique. Évite des centaines de PATCH inutiles.
    const toUpdate = [];
    for (const r of records) {
      const curPrenom = stringValue(r.beneficiaire_prenom);
      const curNom = stringValue(r.beneficiaire_nom);
      const curFull = stringValue(r.beneficiaire_nom_complet);
      const curLabel = stringValue(r.dossier_libelle);
      const drifted =
        curPrenom !== cleanPrenom ||
        curNom !== cleanNom ||
        curFull !== cleanFull ||
        // Pour les tables qui ont `dossier_libelle`, on ne resynchronise
        // que si on a une valeur canonique non-vide ET qu'elle diffère.
        // Sinon (cleanLabel=''), on ignore ce champ pour ne pas l'écraser.
        (cleanLabel && curLabel !== cleanLabel);
      if (!drifted) continue;

      const patch = {
        Id: r.Id,
        beneficiaire_prenom: cleanPrenom,
        beneficiaire_nom: cleanNom,
        beneficiaire_nom_complet: cleanFull,
      };
      // Ne touche `dossier_libelle` que si on a une valeur canonique.
      if (cleanLabel) patch.dossier_libelle = cleanLabel;
      toUpdate.push(patch);
    }

    const n = await updateRecords({
      apiUrl,
      tableId,
      token,
      records: toUpdate,
    });
    stats[t.name] = n;
    stats.total += n;
  }

  return stats;
}

/**
 * Backfill complet : itère TOUS les bénéficiaires du base et appelle
 * `resyncBeneficiaireDenormalizedNames` pour chacun. Utilisé une fois
 * pour rattraper les données stale existantes — ensuite c'est le hook
 * PATCH qui maintient à jour automatiquement.
 *
 * `dossiersBeneficiaireMap` (optionnel) : Map<beneficiaireUuid, dossierLabel>
 * pour le `dossier_libelle`. Si non fourni, le label = nom complet.
 */
export async function resyncAll({
  apiUrl,
  baseId,
  token,
  dossiersBeneficiaireMap = null,
  log = console.log,
}) {
  const meta = await fetchJson(`${apiUrl}/api/v2/meta/bases/${baseId}/tables`, {
    headers: buildHeaders(token),
  });
  const tables = (meta.list || meta).filter((t) => t && t.id);
  const tableIds = await resolveTableIds({ apiUrl, baseId, token });

  // On a besoin de UUID legacy (patient_id) → on lit la table dossiers
  // pour récupérer les pairs (patient_id ↔ beneficiaires_id ↔ nom/prenom).
  const dossiersTbl = tables.find((t) => t.title === 'dossiers');
  const benefTbl = tables.find((t) => t.title === 'beneficiaires');
  if (!dossiersTbl || !benefTbl) {
    throw new Error('Tables dossiers ou beneficiaires introuvables');
  }
  const [allDossiers, allBenefs] = await Promise.all([
    queryAll({ apiUrl, tableId: dossiersTbl.id, token }),
    queryAll({ apiUrl, tableId: benefTbl.id, token }),
  ]);
  // Map beneficiaires.Id → {prenom, nom}
  const benefById = new Map();
  for (const b of allBenefs) {
    benefById.set(String(b.Id), {
      prenom: stringValue(b.prenom),
      nom: stringValue(b.nom),
    });
  }

  const summary = { totalUpdated: 0, perBeneficiary: [] };

  for (const d of allDossiers) {
    const patientUuid = stringValue(d.patient_id);
    if (!patientUuid) continue;
    // Le lien `beneficiaires_id` peut venir comme array, object, string.
    const linkRaw = d.beneficiaires_id;
    let benefIdNum = null;
    if (Array.isArray(linkRaw) && linkRaw.length > 0) {
      benefIdNum = linkRaw[0]?.Id ?? linkRaw[0];
    } else if (typeof linkRaw === 'object' && linkRaw) {
      benefIdNum = linkRaw.Id;
    } else if (linkRaw) {
      benefIdNum = linkRaw;
    }
    const benefInfo = benefById.get(String(benefIdNum));
    if (!benefInfo) {
      log(`  ⚠️ dossier patient_id=${patientUuid.slice(0, 8)}…  bénéficiaire (Id=${benefIdNum}) introuvable`);
      continue;
    }
    const dossierLabel = dossiersBeneficiaireMap?.get(patientUuid) || '';
    try {
      const stats = await resyncBeneficiaireDenormalizedNames({
        beneficiaireUuid: patientUuid,
        prenom: benefInfo.prenom,
        nom: benefInfo.nom,
        dossierLabel,
        apiUrl,
        baseId,
        token,
        tableIds,
      });
      const fullName = `${benefInfo.prenom} ${benefInfo.nom}`.trim();
      log(`  • ${fullName.padEnd(25)} (${patientUuid.slice(0, 8)}…) → ${stats.total} ligne(s) mise(s) à jour`);
      summary.totalUpdated += stats.total;
      summary.perBeneficiary.push({ patientUuid, fullName, stats });
    } catch (err) {
      log(`  ❌ ${patientUuid.slice(0, 8)}… : ${err.message}`);
    }
  }

  return summary;
}
