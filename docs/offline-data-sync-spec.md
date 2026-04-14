# Spécification Initiale du Modèle Local et de la Synchronisation

## Objectif

Cette spécification décrit une première architecture offline-first pour la future application mobile Flutter, à partir du contrat réel de l'application actuelle.

Le principe cible est strict:

- l'utilisateur lit et écrit d'abord en local
- aucune saisie métier ne dépend d'une connexion immédiate
- la synchronisation distante intervient ensuite de manière différée

## Contraintes héritées du système actuel

Le modèle actuel mélange plusieurs réalités techniques:

- des entités métier exposées par l'API Express/NocoDB
- des documents stockés dans Supabase Storage
- des notes et dessins stockés dans Supabase
- plusieurs formes d'identifiants: id numérique, `uuid_source`, id synthétique, id temporaire `temp-*`

La cible mobile doit masquer cette complexité derrière un modèle local cohérent.

## Principe d'architecture

Chaîne cible:

`UI -> repository local -> SQLite -> sync queue -> remote adapters`

et non plus:

`UI -> API distante`

## Règles structurantes

### Règle 1

Toute modification utilisateur est validée localement avant tout appel réseau.

### Règle 2

Toute écriture crée ou met à jour une opération dans une file de synchronisation.

### Règle 3

Les fichiers locaux ne sont supprimés qu'après confirmation d'upload distant.

### Règle 4

Chaque entité métier locale possède un identifiant local stable, distinct des identifiants distants si nécessaire.

## Entités locales à embarquer

## 1. AppSession

Usage:

- session mobile persistée
- profil utilisateur courant
- droits et périmètre de visibilité

Champs recommandés:

- `id`
- `user_email`
- `display_name`
- `role`
- `ergo_record_id`
- `ergo_label`
- `establishment_id`
- `establishment_label`
- `session_token`
- `refreshable_until`
- `last_validated_at`

## 2. DossierLocal

Table centrale de l'application mobile.

Champs recommandés:

- `local_id`
- `remote_dossier_id`
- `remote_dossier_numeric_id`
- `patient_local_id`
- `housing_local_id`
- `ergo_label`
- `status`
- `visit_date`
- `compte_anah`
- `nature_accompagnement`
- `envoi_rapport`
- `personnes_presentes_visite`
- `medical_context_json`
- `autonomy_json`
- `created_at`
- `updated_at`
- `remote_updated_at`
- `sync_state`
- `sync_error`
- `last_synced_at`

Remarque:

- `remote_dossier_id` doit porter la valeur métier stable actuellement utilisée côté app, généralement le `uuid_source` quand il existe

## 3. PatientLocal

Champs recommandés:

- `local_id`
- `remote_patient_id`
- `remote_beneficiaire_numeric_id`
- `first_name`
- `last_name`
- `address`
- `city`
- `city_id`
- `zip_code`
- `phone`
- `email`
- `birth_date_mr`
- `birth_date_mme`
- `family_situation`
- `occupation_status`
- `number_people`
- `income_category`
- `fiscal_revenue`
- `apa`
- `invalidity`
- `invalidity_txt`
- `home_help`
- `home_help_txt`
- `dependence_txt`
- `trusted_name`
- `trusted_phone`
- `trusted_email`
- `numero_secu_monsieur`
- `numero_secu_madame`
- `caisse_retraite_principale`
- `caisses_retraite_complementaires`
- `photo_url`
- `updated_at`
- `remote_updated_at`
- `sync_state`

## 4. HousingLocal

Champs recommandés:

- `local_id`
- `remote_housing_id`
- `remote_housing_numeric_id`
- `patient_local_id`
- `year_construction`
- `year_habitation`
- `surface`
- `levels`
- `typology`
- `basement`
- `basement_desc`
- `rdc`
- `rdc_desc`
- `floor`
- `floor_desc`
- `garage`
- `veranda`
- `balcon`
- `terrasse`
- `jardin`
- `heating_main`
- `heating_details_json`
- `easy_access`
- `comments`
- `access_observation`
- `volets_json`
- `cheminement_json`
- `porte_garage_id`
- `porte_garage_label`
- `portail_id`
- `portail_label`
- `updated_at`
- `remote_updated_at`
- `sync_state`

## 5. DiagnosticSanitairesLocal

Champs recommandés:

- `local_id`
- `remote_id`
- `dossier_local_id`
- `remote_dossier_id`
- tous les champs métiers du formulaire salle de bain et WC
- `updated_at`
- `remote_updated_at`
- `sync_state`

## 6. MesuresAnthropometriquesLocal

Champs recommandés:

- `local_id`
- `remote_id`
- `dossier_local_id`
- `remote_dossier_id`
- `debout_hauteur_coude`
- `assis_hauteur_assise`
- `assis_profondeur_genoux`
- `assis_hauteur_coudes`
- `observations`
- `updated_at`
- `remote_updated_at`
- `sync_state`

## 7. ObservationsSyntheseLocal

Champs recommandés:

- `local_id`
- `remote_id`
- `dossier_local_id`
- `remote_dossier_id`
- `beneficiaire_local_id`
- `observation_equipements`
- `projet_souhait_usage`
- `resume_preconisations`
- `updated_at`
- `remote_updated_at`
- `sync_state`

## 8. NotePageLocal

Cette table remplace le comportement web actuel basé sur `patient_notes`.

Champs recommandés:

- `local_id`
- `patient_local_id`
- `remote_patient_id`
- `tab_key`
- `page_number`
- `text_content`
- `drawing_local_path`
- `drawing_remote_path`
- `drawing_remote_url`
- `updated_at`
- `remote_updated_at`
- `sync_state`

Clé logique recommandée:

- unicité sur `patient_local_id + tab_key + page_number`

## 9. PlanLocal

Champs recommandés:

- `local_id`
- `dossier_local_id`
- `remote_dossier_id`
- `local_file_path`
- `remote_path`
- `remote_url`
- `version`
- `updated_at`
- `sync_state`

## 10. DocumentLocal

Champs recommandés:

- `local_id`
- `remote_document_id`
- `patient_local_id`
- `remote_patient_id`
- `title`
- `file_name`
- `file_ext`
- `mime_type`
- `tag_json`
- `local_file_path`
- `remote_file_path`
- `remote_public_url`
- `size_bytes`
- `captured_at`
- `created_at`
- `updated_at`
- `sync_state`
- `pending_delete`

## 11. Reference tables

Référentiels à embarquer localement:

- communes
- epci
- situations
- dependances
- porteGarage
- portail
- ergos
- etablissements

Rôle:

- auto-complétion commune
- sélecteurs formulaires
- travail hors ligne sans perte d'ergonomie

## 12. SyncOperation

Table clé de la stratégie offline-first.

Champs recommandés:

- `id`
- `entity_type`
- `entity_local_id`
- `operation_type`
- `payload_json`
- `depends_on_operation_id`
- `priority`
- `attempt_count`
- `status`
- `last_error`
- `created_at`
- `updated_at`
- `scheduled_at`
- `completed_at`

Valeurs `entity_type` recommandées:

- `patient`
- `dossier`
- `housing`
- `diagnostic_sanitaires`
- `mesures`
- `observations`
- `note_page`
- `plan`
- `document`

Valeurs `operation_type` recommandées:

- `create`
- `update`
- `upsert`
- `upload_file`
- `rename`
- `delete`

## États de synchronisation

Chaque entité locale devrait partager un état commun.

Valeurs recommandées:

- `local_only`
- `pending_sync`
- `syncing`
- `synced`
- `sync_error`
- `conflict`

Sens:

- `local_only`: créé localement, aucune contrepartie distante encore connue
- `pending_sync`: modifié localement et en attente d'envoi
- `syncing`: tentative en cours
- `synced`: cohérent avec le distant
- `sync_error`: dernière tentative échouée
- `conflict`: divergence nécessitant résolution

## Règle d'identité

## Problème actuel

Le système actuel utilise:

- ids NocoDB numériques internes
- `uuid_source`
- ids synthétiques pour l'app
- ids temporaires `temp-*`

## Règle cible

La future app mobile doit toujours manipuler:

- `local_id` comme identifiant primaire interne
- `remote_*` pour toutes les références distantes

Exemple:

- un nouveau bénéficiaire créé hors ligne reçoit immédiatement `patient_local_id`
- tant qu'il n'est pas synchronisé, `remote_patient_id` est nul
- après sync, l'app stocke la correspondance locale/distance

## Granularité des opérations de sync

## Création d'un bénéficiaire avec dossier

Opérations recommandées:

1. `create patient`
2. `create dossier`
3. `create housing` si nécessaire

Dépendances:

- l'opération 2 dépend de l'opération 1
- l'opération 3 dépend de l'existence distante du patient

## Mise à jour d'un relevé de visite

Opérations recommandées:

- `update patient`
- `update dossier`
- `upsert housing`
- `upsert diagnostic_sanitaires`
- `upsert mesures`
- `upsert observations`
- `upsert note_page`
- `upload plan`

Regroupement recommandé:

- conserver des opérations techniques séparées
- mais les grouper visuellement dans l'UI sous une seule bannière de statut par dossier

## Documents

Opérations recommandées:

1. créer entrée locale document
2. stocker fichier local
3. créer `upload_file` dans la queue
4. après succès upload, créer ou mettre à jour la metadata distante
5. marquer `synced`

## Notes et dessins

Opérations recommandées:

- la note texte et le dessin doivent rester représentés comme une seule page logique
- l'upload du dessin ne doit pas bloquer la conservation du texte local

## Ordre de synchronisation recommandé

Ordre global:

1. authentification et validation de session
2. téléchargement des références
3. push des créations locales
4. push des mises à jour de données structurées
5. upload des pièces jointes
6. pull des mises à jour distantes
7. résolution de conflits éventuels

Pourquoi:

- les enregistrements distants doivent exister avant certaines pièces jointes
- les pièces sont plus lourdes et plus fragiles réseau

## Politique de conflits recommandée

Version initiale pragmatique:

- empêcher au maximum les modifications concurrentes sur un même dossier terrain
- utiliser `updated_at` distant comme garde-fou
- en cas d'écart, passer l'entité en `conflict`

Pour la v1 mobile:

- conflit visible
- lecture des deux versions
- choix manuel ou relance de sync

Je déconseille une fusion automatique champ par champ dans la première version.

## Téléchargement initial

Au premier login connecté:

1. authentifier l'utilisateur
2. télécharger les références métier
3. télécharger les dossiers accessibles à cet utilisateur
4. télécharger les sous-entités nécessaires
5. télécharger les métadonnées de documents et notes
6. télécharger les médias nécessaires selon une politique sélective

Politique média recommandée:

- ne pas précharger tous les fichiers volumineux
- ne télécharger que les vignettes ou les fichiers récemment consultés
- conserver le plein fichier après consultation

## Cycle d'une saisie locale

Exemple pour un champ du bénéficiaire:

1. l'utilisateur modifie un champ
2. la valeur est écrite en SQLite
3. l'entité passe en `pending_sync`
4. une `SyncOperation` est créée ou fusionnée
5. l'UI montre `à synchroniser`
6. à la reprise réseau, la queue pousse la modification
7. si succès, l'entité passe en `synced`
8. si échec, l'entité passe en `sync_error`

## Stratégie d'agrégation des opérations

Pour éviter une queue trop bavarde, il faut fusionner certaines opérations.

Fusion recommandée:

- plusieurs updates successifs d'un même bénéficiaire deviennent une seule opération `update patient`
- plusieurs updates logement deviennent une seule opération `upsert housing`
- plusieurs frappes texte d'une même note deviennent une seule opération logique par page

Ne pas fusionner:

- uploads de fichiers différents
- delete explicite
- opérations portant sur des entités distinctes

## Indicateurs UI recommandés

Chaque dossier mobile devrait afficher:

- `Synchronisé`
- `En attente`
- `Synchronisation en cours`
- `Erreur de synchronisation`
- `Conflit`

Chaque document ou note locale devrait afficher:

- présence locale
- upload en attente
- upload réussi
- upload échoué

## Recommandation d'implémentation Flutter

Technologies recommandées:

- `drift` pour SQLite
- `path_provider` pour les fichiers locaux
- `connectivity_plus` uniquement comme indice réseau, pas comme vérité métier
- stockage sécurisé pour la session applicative

Couche logicielle recommandée:

- `repositories/`
- `local_datasources/`
- `remote_datasources/`
- `sync/`

## Décisions de v1

Pour réduire le risque, je recommande pour la première version mobile:

- pas de suppression distante automatique des dossiers
- pas de fusion automatique des conflits
- pas de sync temps réel websocket
- pas de dépendance à un réseau permanent

## Décisions de migration serveur

L'existant peut être conservé au départ, mais certaines évolutions serveur seront rapidement utiles:

- exposer des `updated_at` fiables partout
- clarifier les ids stables renvoyés au mobile
- prévoir des endpoints de sync plus compacts à terme
- éviter à terme les accès mobiles directs dispersés entre API Express et Supabase

## Conclusion

La cible mobile viable n'est pas une simple transposition de l'UI React. C'est un changement de modèle:

- source de vérité locale
- synchronisation différée
- correspondance explicite entre ids locaux et ids distants
- gestion robuste des pièces jointes

Cette spécification est suffisante pour lancer le prochain chantier:

- définition du schéma SQLite concret
- implémentation des repositories Flutter
- premier moteur de synchronisation
