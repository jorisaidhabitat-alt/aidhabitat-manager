# Plan d'exécution commercialisation App'Ergo

Objectif : préparer App'Ergo à accueillir plusieurs structures clientes sans
mélanger les dossiers, tout en gardant l'app Aid'Habitat stable.

## Point de départ

Déjà en place :

- PWA App'Ergo fonctionnelle.
- Auth locale/offline côté app.
- Synchronisation NocoDB.
- Base staging dédiée : `App Ergo Staging` (`p7jzofcton1tabh`).
- Socle multi-organisation en staging : table `organisations`,
  `organisation_id` sur les tables sensibles, backfill `org_aidhabitat`.
- Socle multi-organisation local : `organisation_id` dans SQLite offline.
- Backup, restore plan, staging snapshot et scripts d'import.
- Base locale chiffrée sur iOS/macOS/Android.

À construire avant commercialisation :

- séparation stricte par organisation cliente ;
- stockage objet pour PDF/images/scans ;
- suppression des accès publics permanents aux fichiers ;
- sauvegardes automatisées vérifiées ;
- gestion des utilisateurs par organisation.

## Principe directeur

Ne pas partir sur une grosse migration brutale.

Ordre sûr :

1. Tester sur `App Ergo Staging`.
2. Valider les flux critiques.
3. Ajouter les garde-fous serveur.
4. Seulement ensuite propager en production.

## Phase 1 - Séparation multi-organisation

But : chaque dossier doit appartenir à une organisation, par exemple
`Aid'Habitat`, puis demain une autre structure cliente.

Ajouté en staging :

- table `organisations` ;
- champ `organisation_id` sur les tables sensibles ;
- backfill de toutes les données existantes vers l'organisation Aid'Habitat.

Ajouté côté app locale :

- `organisation_id` dans les tables SQLite sensibles ;
- scope local `organisation_id` pour les utilisateurs ;
- `organisationId` dans le modèle utilisateur.

Tables prioritaires :

- `Beneficiaires`
- `📁 dossiers`
- `Logements`
- `👨‍👩‍👧 contexte_de_vie`
- `📋 informations_administratives`
- `🚿 diagnostic_sanitaires`
- `📏 mesures_anthropometriques`
- `📝 observations`
- `mobile_documents`
- `mobile_document_chunks`
- `mobile_note_pages`
- `mobile_visit_photos`
- `mobile_visit_recommendations`
- `👷🏻‍♀️ ergotherapeutes`
- `etablissements`

Critère de validation :

- un utilisateur Aid'Habitat ne lit que les dossiers Aid'Habitat ;
- un futur utilisateur d'une autre structure ne lit aucun dossier Aid'Habitat ;
- les notes, documents, photos et rapports suivent le même filtre.

## Phase 2 - Stockage fichiers

But : sortir les fichiers lourds de NocoDB.

Approche :

- garder NocoDB comme base métier ;
- stocker PDF/images/scans dans un stockage objet S3 ;
- conserver les chunks NocoDB comme fallback temporaire ;
- lire en priorité depuis S3 si `object_key` existe.

Colonnes prévues dans `mobile_documents` :

- `storage_provider`
- `object_key`
- `object_size_bytes`
- `object_sha256`
- `object_synced_at`
- `legacy_nocodb_chunks_kept`

Critère de validation :

- upload offline local immédiat conservé ;
- sync réseau vers S3 sans perte ;
- génération PDF retrouve les images ;
- fallback NocoDB fonctionne si S3 est indisponible.

## Phase 3 - Confidentialité fichiers

Point actuel à traiter :

- `/public/documents/:documentId/content`
- `/public/note-pages/:notePageId/preview`

Ces URLs sont pratiques, mais pas idéales commercialement car elles exposent le
contenu via identifiant document/note.

Cible :

- accès authentifié par défaut ;
- URLs signées et temporaires si besoin de preview ou partage ;
- durée courte ;
- logs d'accès.

## Phase 4 - Sauvegardes et restauration

Minimum commercialisable :

- backup quotidien NocoDB ;
- backup stockage objet ;
- rétention 30 jours minimum ;
- test de restauration mensuel ;
- alerte si backup échoue.

Commande de contrôle :

```bash
npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

Audit multi-organisation :

```bash
npm run commercial:tenant-audit -- \
  tmp/nocodb-test-staging-run/schema-full/staging-full-schema-final.json \
  tmp/commercial-tenant-readiness.md
```

## Ce qu'on ne fait pas maintenant

- Migration NocoDB V3 en production.
- Suppression des chunks NocoDB existants.
- Multi-client en production sans test staging.
- Dépendance exclusive à S3 sans fallback.
- Stockage de clés S3 dans le frontend.

## Prochaine action recommandée

Adapter le serveur pour que chaque session porte `organisationId`, puis filtrer
toutes les lectures/écritures sensibles par organisation.
