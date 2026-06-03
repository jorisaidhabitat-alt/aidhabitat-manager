# Preflight commercial

Objectif : vérifier que les garde-fous minimum sont bons avant une migration
NocoDB, une bascule stockage objet ou un test staging.

Le preflight est non destructif :

- aucun appel d'écriture vers NocoDB ;
- aucune modification de production ;
- génération locale de fichiers dans `tmp/` ;
- rapport final en Markdown et JSON.

## Lancer le preflight

```bash
npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

Si le dossier de rapport existe déjà :

```bash
COMMERCIAL_PREFLIGHT_OVERWRITE=1 npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

## Étapes contrôlées

- vérification du backup production ;
- audit secrets et variables d'environnement ;
- plan de restauration production ;
- audit stockage objet production ;
- audit dépendances NocoDB API ;
- création d'un snapshot staging anonymisé ;
- vérification du snapshot staging ;
- plan de restauration staging ;
- export du plan schéma staging ;
- export des lots d'import staging ;
- validation des lots JSON ;
- contrôle des flux critiques ;
- build web.
- contrôle optionnel du bundle PWA Flutter.

## Sorties

Dans le dossier choisi :

- `report.md` : résumé lisible ;
- `report.json` : résultat structuré ;
- `logs/` : sortie détaillée de chaque étape ;
- `env-secrets-audit.md` et `env-secrets-audit.json` : secrets/env ;
- `nocodb-api-audit.md` et `nocodb-api-audit.json` : dépendances API NocoDB ;
- `staging-snapshot.json.gz` : snapshot staging généré ;
- `staging-schema-plan/` : plan de recréation des tables/colonnes ;
- `staging-import-batches/` : lots d'import staging.

## Contrôle PWA

Après un build Flutter web :

```bash
npm run build:pwa
npm run release:web-check -- --dir aid_habitat_app/build/web
```

Pour vérifier une URL déjà en ligne :

```bash
npm run release:web-check -- --url https://app.aidhabitat.fr
```

Ce contrôle vérifie le HTML, le manifest App'Ergo, les icônes, PDF.js local,
SQLite web, le service worker Flutter et les fichiers principaux du bundle.

Pour vérifier rapidement toute la stack publique :

```bash
npm run release:live-check
```

Ce contrôle vérifie `https://app.aidhabitat.fr`, le bundle PWA, puis
`https://api.aidhabitat.fr/api/health/live` et `/api/health/ready` avec les
headers CORS/CORP attendus. Il est utile juste avant et juste après une bascule
DNS ou Easypanel.

Pour staging :

```bash
npm run release:live-check -- --app-url https://apps-aidhabitat-web-staging.z5avx1.easypanel.host --api-url https://apps-aidhabitat-api-staging.z5avx1.easypanel.host
```

Pour inclure automatiquement le build Flutter PWA et le contrôle du bundle dans
le preflight :

```bash
COMMERCIAL_PREFLIGHT_CHECK_PWA=1 npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

À utiliser avant une migration ou un changement d'hébergement. Le mode par
défaut reste plus rapide pour les vérifications data quotidiennes.

Le mode PWA vérifie qu'il reste au moins 450 Mo libres avant de lancer le build
Flutter. Le seuil peut être ajusté si besoin :

```bash
COMMERCIAL_PREFLIGHT_CHECK_PWA=1 COMMERCIAL_PREFLIGHT_MIN_PWA_FREE_MB=700 npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

## Interprétation

Si le preflight échoue, ne pas migrer.

Si le preflight passe, cela ne veut pas dire que la migration est terminée.
Cela veut dire que l'on peut passer à l'étape suivante : créer une vraie base
NocoDB staging et tester l'import dessus.

Les avertissements doivent être relus même si le preflight passe. Le cas connu
actuel est le mot de passe bootstrap local : il doit être rotaté avec la
procédure `docs/bootstrap-password-transition.md`, sans casser le login offline.

## Option rapide

Pour éviter le build web pendant un test purement data :

```bash
COMMERCIAL_PREFLIGHT_SKIP_BUILD=1 npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

Ne pas utiliser cette option pour valider une migration complète.

Pour une validation complète avant migration :

```bash
COMMERCIAL_PREFLIGHT_CHECK_PWA=1 npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```
