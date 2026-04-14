# NocoDB Mobile Sync Schema

Le backend Express bascule automatiquement sur NocoDB si les tables suivantes existent:

- `mobile_documents`
- `mobile_document_chunks`
- `mobile_note_pages`
- `mobile_visit_recommendations`

Sans ces tables, il reste sur le fallback local existant, sans changer le contrat API.

## Table `mobile_documents`

Champs attendus:

- `uuid_source` : `SingleLineText`
- `beneficiaire_id` : `SingleLineText`
- `dossier_id` : `SingleLineText`
- `client_document_id` : `SingleLineText`
- `titre` : `SingleLineText`
- `nom_fichier` : `SingleLineText`
- `mime_type` : `SingleLineText`
- `tags_json` : `LongText`
- `contenu_base64` : `LongText`
- `created_at` : `DateTime`
- `updated_at` : `DateTime`

Usage:

- `beneficiaire_id` : identifiant applicatif du bénéficiaire
- `client_document_id` : identifiant local Flutter, pour rendre l’upload idempotent
- `contenu_base64` : contenu binaire du document encodé en base64

Limite pratique:

- rester sous `5 MB` par document
- au-delà de la limite `LongText`, le backend stocke automatiquement le contenu dans `mobile_document_chunks`

## Table `mobile_note_pages`

Champs attendus:

- `uuid_source` : `SingleLineText`
- `beneficiaire_id` : `SingleLineText`
- `dossier_id` : `SingleLineText`
- `beneficiaire_prenom` : `SingleLineText`
- `beneficiaire_nom` : `SingleLineText`
- `beneficiaire_nom_complet` : `SingleLineText`
- `dossier_libelle` : `SingleLineText`
- `scope_type` : `SingleLineText`
- `scope_id` : `SingleLineText`
- `tab_key` : `SingleLineText`
- `page_number` : `Number`
- `text_content` : `LongText`
- `drawing_json` : `LongText`
- `layout_kind` : `SingleLineText`
- `updated_at` : `DateTime`

Usage:

- clé logique: `beneficiaire_id + scope_type + scope_id + tab_key + page_number`
- `beneficiaire_nom` et `beneficiaire_nom_complet` servent au tri et au regroupement visuel dans NocoDB
- `drawing_json` : payload JSON du dessin `scribble`

## Table `mobile_document_chunks`

Champs attendus:

- `uuid_source` : `SingleLineText`
- `document_uuid_source` : `SingleLineText`
- `chunk_index` : `Number`
- `chunk_base64` : `LongText`
- `updated_at` : `DateTime`

Usage:

- utilisée quand `contenu_base64` dépasse la limite `LongText` de NocoDB
- clé logique: `document_uuid_source + chunk_index`

## Table `mobile_visit_recommendations`

Champs attendus:

- `uuid_source` : `SingleLineText`
- `dossier_id` : `SingleLineText`
- `beneficiaire_id` : `SingleLineText`
- `beneficiaire_prenom` : `SingleLineText`
- `beneficiaire_nom` : `SingleLineText`
- `beneficiaire_nom_complet` : `SingleLineText`
- `dossier_libelle` : `SingleLineText`
- `wiki_item_id` : `SingleLineText`
- `wiki_title` : `SingleLineText`
- `wiki_image_url` : `LongText`
- `wiki_tag` : `SingleLineText`
- `note` : `LongText`
- `created_at` : `DateTime`
- `updated_at` : `DateTime`

Usage:

- une ligne par préconisation du relevé de visite
- reliée au dossier et au bénéficiaire par `dossier_id` et `beneficiaire_id`
- permet de sortir les `Préconisations` du fichier local serveur
- `wiki_item_id` conserve le lien avec la bibliothèque d’images

## Contrat API inchangé

Les routes restent:

- `GET /api/documents/:patientId`
- `POST /api/documents`
- `GET /api/note-pages/:patientId`
- `PUT /api/note-pages`

Ajouts utiles:

- `GET /api/mobile-sync/schema`
- `GET /api/mobile-sync/schema-check`
- `GET /api/mobile-sync/migration-status`
- `POST /api/mobile-sync/migrate`
- `GET /api/mobile-documents/:documentId/content`

## Vérification

Pour vérifier le mode actif:

- appeler `GET /api/mobile-sync/schema`
- lire `data.mode`

Valeurs possibles:

- `nocodb`
- `local`

Pour vérifier la conformité exacte du schéma:

- appeler `GET /api/mobile-sync/schema-check`
- lire `data.valid`
- inspecter `missingFields`, `mismatchedFields` et `extraFields`

## Migration des données locales existantes

Une fois les tables créées:

1. appeler `GET /api/mobile-sync/schema-check`
2. vérifier `valid: true`
3. appeler `GET /api/mobile-sync/migration-status`
4. vérifier `nocodbTablesReady: true`
5. lancer `POST /api/mobile-sync/migrate`
6. recontrôler `GET /api/mobile-sync/migration-status`

Résultat attendu:

- `modeAfter: nocodb`
- `failed: 0` sur `documents` et `notePages`

La migration est idempotente:

- les documents utilisent `client_document_id` ou l’identifiant local existant
- les notes utilisent `beneficiaire_id + scope_type + scope_id + tab_key + page_number`

## Bootstrap automatisé

Le dépôt inclut maintenant un bootstrap idempotent:

- `npm run nocodb:bootstrap-mobile-schema`

Variables requises pour créer les tables via l'API meta NocoDB:

- `NOCODB_API_TOKEN` ou `NOCODB_AUTH_TOKEN`
- `NOCODB_BASE_ID` facultatif, défaut `pskgbjythubfzv9`
- `NOCODB_API_URL` facultatif, sinon dérivé de `NOCODB_MCP_URL`
- `NOCODB_SOURCE_ID` facultatif si la base contient plusieurs sources

Important:

- le `NOCODB_MCP_TOKEN` seul ne suffit pas pour créer des tables
- le script crée les tables si elles n'existent pas
- le script ajoute les colonnes manquantes si une table existe déjà
- le script ne modifie pas les colonnes déjà présentes avec un type différent
