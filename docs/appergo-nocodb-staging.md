# App Ergo Staging NocoDB

Base staging dédiée à App'Ergo :

- Nom NocoDB : `App Ergo Staging`
- Base ID : `p7jzofcton1tabh`
- Base production à ne pas toucher : `pskgbjythubfzv9` (`Application Ergo`)
- Ne pas utiliser : `nocodb_test` / `apps-nocodb-test`, réservé au CRM interne

## Snapshot importé

Snapshot anonymisé généré depuis le backup production du 2026-06-03 :

- 28 tables
- 1563 lignes importées
- 3 bénéficiaires/dossiers anonymisés
- 391 chunks documents
- 112 pages de notes
- 26 documents

Tous les totaux importés correspondent aux totaux attendus.

## Schéma validé

Validation finale du 2026-06-03 :

- 28 tables staging
- 1563 / 1563 lignes importées
- 24 / 24 relations recréées
- 6 / 6 lookups recréés
- 3 / 3 formules recréées
- 0 mismatch de volume de données

## Commandes utiles

Créer/patcher le schéma staging :

```bash
NOCODB_BASE_ID=p7jzofcton1tabh \
NOCODB_RESTORE_ALLOW_APPLY=1 \
NOCODB_RESTORE_TARGET=staging \
NOCODB_STAGING_REQUEST_DELAY_MS=350 \
npm run staging:bootstrap-schema -- \
  tmp/nocodb-test-staging-run/staging-schema-plan \
  tmp/nocodb-test-staging-run/staging-import-batches-full-10 \
  --apply \
  --write-map tmp/nocodb-test-staging-run/app-ergo-staging-table-map.json
```

Importer les lots staging :

```bash
NOCODB_BASE_ID=p7jzofcton1tabh \
NOCODB_RESTORE_ALLOW_APPLY=1 \
NOCODB_RESTORE_TARGET=staging \
NOCODB_RESTORE_BATCH_DELAY_MS=500 \
NOCODB_RESTORE_MAX_RETRIES=6 \
DOTENV_CONFIG_PATH=.env.local \
node -r dotenv/config tools/import-nocodb-batches.mjs \
  tmp/nocodb-test-staging-run/staging-import-batches-full-10 \
  tmp/nocodb-test-staging-run/app-ergo-staging-table-map.json \
  --apply
```

Reconstruire les relations staging :

```bash
NOCODB_BASE_ID=p7jzofcton1tabh \
NOCODB_RESTORE_ALLOW_APPLY=1 \
NOCODB_RESTORE_TARGET=staging \
NOCODB_RESTORE_MAX_RETRIES=8 \
NOCODB_RESTORE_REQUEST_DELAY_MS=2000 \
npm run staging:rebuild-relations -- \
  tmp/nocodb-test-staging-run/schema-full/prod-full-schema.json \
  --apply
```

Reconstruire les lookups et formules staging :

```bash
NOCODB_BASE_ID=p7jzofcton1tabh \
NOCODB_RESTORE_ALLOW_APPLY=1 \
NOCODB_RESTORE_TARGET=staging \
NOCODB_RESTORE_MAX_RETRIES=8 \
NOCODB_RESTORE_REQUEST_DELAY_MS=1000 \
npm run staging:rebuild-derived -- \
  tmp/nocodb-test-staging-run/schema-full/prod-full-schema.json \
  --apply
```

## Notes

Certaines anciennes colonnes simples ont été renommées en `_legacy` avant de
créer les vraies relations/lookups/formules. Cela permet de conserver les
valeurs importées tout en redonnant aux champs principaux le même type que la
production.
