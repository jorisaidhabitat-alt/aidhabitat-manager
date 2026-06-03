# Snapshot staging léger

Objectif : préparer une base de test utilisable sans cloner durablement toute
la production et sans modifier NocoDB.

Le snapshot staging sert à tester :

- migration NocoDB V3 sur clone ;
- migration fichiers vers stockage objet ;
- génération PDF ;
- notes et documents ;
- flux critiques de l'application.

## Générer un snapshot

À partir d'un backup vérifié :

```bash
npm run staging:snapshot -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/staging-snapshot.json.gz
```

Par défaut, le script :

- sélectionne 3 bénéficiaires avec données liées ;
- conserve les référentiels utiles ;
- conserve les documents/chunks rattachés ;
- anonymise les informations personnelles ;
- ne contacte pas NocoDB ;
- ne modifie aucune base.

## Ajuster le nombre de dossiers

```bash
STAGING_BENEFICIARY_LIMIT=5 npm run staging:snapshot -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/staging-5.json.gz
```

La limite maximale volontaire est 10 bénéficiaires pour éviter de recréer un
clone trop lourd.

## Garder les vraies données

Uniquement si le staging est strictement privé et sécurisé :

```bash
STAGING_KEEP_REAL_PERSONAL_DATA=1 npm run staging:snapshot -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/staging-real.json.gz
```

Recommandation : ne pas utiliser cette option pour les tests ordinaires.

## Ce que le script ne fait pas

- Il ne crée pas les tables NocoDB.
- Il ne restaure pas les records.
- Il ne remplace pas un vrai test de restauration.
- Il ne supprime rien en production.

## Utilisation recommandée

1. Générer un backup production.
2. Vérifier le backup.
3. Générer le snapshot staging.
4. Exporter les lots d'import staging.
5. Créer une base NocoDB staging vide.
6. Recréer les tables et colonnes.
7. Importer les lots dans staging.
8. Pointer une app staging vers cette base.
9. Tester les flux critiques avant toute migration production.

## Préparer les lots d'import

```bash
npm run staging:export-import-batches -- tmp/staging-snapshot.json.gz tmp/staging-import-batches
```

Le script produit :

- un `manifest.json` global ;
- un `schema.json` par table ;
- des fichiers `batch-*.json` directement compatibles avec le bulk insert NocoDB v2 ;
- un `README.md` dans le dossier de sortie.

Par sécurité, le dossier de sortie ne sera pas remplacé s'il existe déjà.
Pour le remplacer :

```bash
IMPORT_BATCHES_OVERWRITE=1 npm run staging:export-import-batches -- tmp/staging-snapshot.json.gz tmp/staging-import-batches
```

Les champs système NocoDB (`Id`, `CreatedAt`, `UpdatedAt`) sont exclus des
payloads d'import car ils ne doivent pas être forcés dans une base neuve.

## Critère de réussite

Le staging est utile si l'on retrouve :

- au moins 2 ou 3 bénéficiaires ;
- un relevé complet ;
- des notes ;
- des documents PDF/images ;
- des chunks documents ;
- les référentiels nécessaires ;
- la génération PDF fonctionnelle.
