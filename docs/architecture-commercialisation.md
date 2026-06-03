# Architecture commercialisable Aid'Habitat

Objectif : préparer App'Ergo à accueillir plus d'utilisateurs, plus de dossiers,
plus d'images et plus de PDF sans fragiliser l'app utilisée aujourd'hui.

## État actuel vérifié

Audit lecture seule du 2026-06-03 :

- NocoDB production : 28 tables.
- `mobile_documents` : 71 documents.
- `mobile_document_chunks` : 1069 chunks.
- `mobile_note_pages` : 301 pages de notes.
- Backup complet NocoDB testé : 68 MB compressés, environ 14 secondes.

Conclusion : le système actuel fonctionne et se sauvegarde, mais les fichiers
PDF/images sont stockés dans NocoDB sous forme de chunks. C'est acceptable pour
l'usage interne actuel, mais ce n'est pas l'architecture idéale à grande échelle.

## Recommandation

Ne pas migrer NocoDB V3 en production maintenant.

Priorité :

1. Stabiliser l'app actuelle.
2. Prouver les sauvegardes et la restauration.
3. Créer un environnement staging léger.
4. Déplacer progressivement les gros fichiers vers un stockage objet.
5. Tester NocoDB V3 uniquement sur une base clone.

## Cible technique

### Données métier

PostgreSQL dédié pour NocoDB.

À conserver dans NocoDB/PostgreSQL :

- bénéficiaires ;
- dossiers ;
- relevés de visite ;
- notes JSON ;
- recommandations ;
- métadonnées documents ;
- utilisateurs et référentiels.

### Fichiers lourds

Stockage objet compatible S3.

À déplacer progressivement hors NocoDB :

- PDF ;
- images ;
- scans ;
- documents importés ;
- previews volumineuses.

NocoDB garderait uniquement les métadonnées :

- bénéficiaire ;
- dossier ;
- nom de fichier ;
- type MIME ;
- taille ;
- clé objet S3 ;
- hash ;
- date de synchronisation.

## Sauvegardes

Minimum commercialisable :

- backup quotidien NocoDB ;
- upload off-site ;
- rétention 30 jours minimum ;
- vérification automatique du backup ;
- test de restauration régulier.

Scripts existants :

- `tools/backup-nocodb.mjs` : dump complet.
- `tools/backup-and-upload.sh` : dump + upload rclone.
- `tools/verify-nocodb-backup.mjs` : vérification d'un dump.
- `tools/plan-nocodb-restore.mjs` : plan de restauration non destructif.
- `tools/analyze-object-storage-readiness.mjs` : audit fichiers lourds.
- `tools/create-staging-snapshot.mjs` : snapshot staging léger.
- `tools/export-nocodb-import-batches.mjs` : lots d'import staging.
- `tools/run-commercial-readiness-check.mjs` : preflight global non destructif.
- `tools/audit-nocodb-api-usage.mjs` : audit dépendances NocoDB API.

Exemple :

```bash
node tools/backup-nocodb.mjs
node tools/verify-nocodb-backup.mjs backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
node tools/plan-nocodb-restore.mjs backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
node tools/analyze-object-storage-readiness.mjs backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
node tools/create-staging-snapshot.mjs backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/staging-snapshot.json.gz
node tools/export-nocodb-import-batches.mjs tmp/staging-snapshot.json.gz tmp/staging-import-batches
node tools/run-commercial-readiness-check.mjs backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
node tools/audit-nocodb-api-usage.mjs tmp/nocodb-api-audit.md
```

La vérification prouve que le fichier est exploitable. Le plan de restauration
prouve qu'on sait estimer l'effort de récupération sans toucher à la production.
L'audit stockage objet chiffre ce qui devra sortir progressivement de NocoDB.

Le preflight global doit passer avant toute opération sensible. Il ne modifie
pas NocoDB : il orchestre les vérifications, génère un staging local, prépare
les lots d'import, valide leur forme, lance les contrôles critiques et le build.
L'audit API rend visibles les dépendances `/api/v2` avant une éventuelle V3.

## Migration fichiers

Document dédié : `docs/object-storage-migration.md`.

Stratégie : double lecture temporaire. Si un fichier a une `object_key`, l'app
pourra le lire depuis le stockage objet. Sinon elle gardera le fallback actuel
via `mobile_document_chunks`. Cette approche évite une bascule brutale.

## Staging

Document dédié : `docs/staging-snapshot.md`.

Créer une base de test légère, pas un clone complet durable.

Contenu recommandé :

- 2 ou 3 bénéficiaires ;
- 1 relevé complet ;
- notes rapides ;
- notes de visite ;
- photos ;
- PDF ;
- communes ;
- caisses ;
- un rapport généré.

But : tester les migrations et évolutions sans toucher à la production.

## Migration NocoDB V3

La migration V3 est cohérente à moyen terme, mais secondaire.

Raison : le code utilise encore beaucoup `/api/v2`. Une migration V3 directe
peut casser les filtres, les scripts ou certains comportements API.

Le niveau de risque doit être relu avec :

```bash
npm run nocodb:api-audit -- tmp/nocodb-api-audit.md
```

Ordre recommandé :

1. Base staging.
2. Migration V3 sur staging.
3. Tests des flux critiques.
4. Adaptation progressive du code API si nécessaire.
5. Migration production uniquement après preuve.

## Risques maîtrisés

Risques évités par cette stratégie :

- casser la production avec une migration V3 prématurée ;
- saturer Easypanel avec un clone complet durable ;
- croire à une sauvegarde qui n'a jamais été vérifiée ;
- mélanger données métier et fichiers lourds à grande échelle ;
- perdre des PDF/images pendant une bascule stockage.

## Prochaine décision externe

À choisir avant la phase stockage objet :

- fournisseur S3 compatible ;
- volume estimé mensuel ;
- rétention des fichiers ;
- politique RGPD ;
- budget serveur ;
- niveau de séparation prod/staging.
