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
- plan de restauration production ;
- audit stockage objet production ;
- audit dépendances NocoDB API ;
- création d'un snapshot staging anonymisé ;
- vérification du snapshot staging ;
- plan de restauration staging ;
- export des lots d'import staging ;
- validation des lots JSON ;
- contrôle des flux critiques ;
- build web.

## Sorties

Dans le dossier choisi :

- `report.md` : résumé lisible ;
- `report.json` : résultat structuré ;
- `logs/` : sortie détaillée de chaque étape ;
- `nocodb-api-audit.md` et `nocodb-api-audit.json` : dépendances API NocoDB ;
- `staging-snapshot.json.gz` : snapshot staging généré ;
- `staging-import-batches/` : lots d'import staging.

## Interprétation

Si le preflight échoue, ne pas migrer.

Si le preflight passe, cela ne veut pas dire que la migration est terminée.
Cela veut dire que l'on peut passer à l'étape suivante : créer une vraie base
NocoDB staging et tester l'import dessus.

## Option rapide

Pour éviter le build web pendant un test purement data :

```bash
COMMERCIAL_PREFLIGHT_SKIP_BUILD=1 npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

Ne pas utiliser cette option pour valider une migration complète.
