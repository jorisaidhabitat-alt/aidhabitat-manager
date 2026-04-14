# Scripts

## `bootstrapNocodbMobileSchema.mjs`

Crée ou complète les tables NocoDB attendues par la synchronisation mobile:

- `mobile_documents`
- `mobile_document_chunks`
- `mobile_note_pages`

Variables d'environnement attendues:

- `NOCODB_API_TOKEN` ou `NOCODB_AUTH_TOKEN`
- `NOCODB_BASE_ID` facultatif, défaut `pskgbjythubfzv9`
- `NOCODB_API_URL` facultatif, sinon dérivé de `NOCODB_MCP_URL`
- `NOCODB_SOURCE_ID` facultatif si la base contient plusieurs sources
