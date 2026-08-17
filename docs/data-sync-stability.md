# Stabilité data/sync App'Ergo

Objectif : vérifier que la base métier NocoDB et la synchronisation restent fiables en production Easypanel.

Commande :

```bash
npm run data:stability-check
```

Contrats de synchronisation API/Web et scénarios critiques iPad :

```bash
npm run test:sync-contract
bash aid_habitat_app/tool/test_sync_critical.sh
```

Avec vérification d'un backup existant :

```bash
npm run data:stability-check -- --backup backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
```

Le rapport est écrit dans `tmp/data-sync-stability/report.md` et `tmp/data-sync-stability/report.json`.

## Ce qui est contrôlé

- App web prod : `https://app.aidhabitat.fr`
- API prod : `https://api.aidhabitat.fr/api/health/live` et `/ready`
- Connexion REST NocoDB via `.env.local`
- Présence des tables métier critiques
- Présence des colonnes essentielles de sync, notes, documents, bénéficiaires, dossiers et communes
- Latence des lectures NocoDB et détection des 502/5xx
- Cohérence échantillonnée `mobile_documents` / `mobile_document_chunks`
- Cohérence échantillonnée `mobile_note_pages`
- Cohérence des listes autonomie multi-occupants et de leurs colonnes de synthèse
- Conservation des opérations offline et des gros payloads après redémarrage
- Reprise automatique après erreur réseau ou expiration de session
- Push local avant pull distant au retour de la connexion
- Protection des saisies locales `pendingSync`/`conflict` contre un écrasement distant
- Contrat unique des libellés autonomie entre Flutter, API et Web
- Présence des scripts backup, vérification et plan de restauration

## Règle d'exploitation

Si l'audit échoue, ne pas déployer et ne pas migrer le schéma.

Si l'audit passe avec alertes, la prod n'est pas bloquée, mais les alertes doivent être lues avant une migration.

À lancer :

- Avant un changement de schéma NocoDB
- Après un déploiement Easypanel
- Après une erreur 502 ou une lenteur inhabituelle
- Avant une opération de backup/restauration

Les workflows GitHub `Sync Integrity`, `Build & Deploy API` et
`Build Flutter Web` exécutent ces contrôles avant publication. Une panne du
serveur peut retarder la transmission, mais ne doit jamais supprimer la file
locale : la donnée reste sur l'iPad puis est envoyée avant le prochain pull.

## Contrat de reprise après une journée hors ligne

- Une panne DNS, TLS, réseau, API ou NocoDB conserve chaque opération locale
  dans la file et ne déclenche ni déconnexion ni fenêtre bloquante.
- Le moteur réessaie indéfiniment avec un délai plafonné ; le nombre d'échecs
  successifs ne peut plus arrêter la synchronisation.
- Au retour du service, le jeton d'accès expiré est renouvelé depuis le
  Keychain sans redemander le mot de passe. Un changement de mot de passe ou
  une révocation réelle demande seulement une reconnexion distante non
  bloquante ; l'utilisateur reste dans son dossier.
- Les modifications locales sont toujours envoyées avant le pull NocoDB afin
  qu'une copie distante plus ancienne ne puisse pas écraser le travail terrain.
- Les erreurs transitoires restent silencieuses. Le bandeau rouge est réservé
  aux erreurs métier permanentes qui nécessitent réellement une intervention.

## Régulation du retour en ligne

- Les écritures JSON légères sont regroupées par trois dans un seul appel
  mobile vers `/api/sync/batch` : dossier, bénéficiaire, logement, contexte de
  vie, mesures, observations et diagnostic sanitaires.
- Le serveur traite les opérations d'un lot dans l'ordre et renvoie un statut
  indépendant pour chacune. Une erreur partielle ne valide jamais les autres
  données à tort et ne supprime rien de la file locale.
- Deux lots au maximum sont traités simultanément côté API. L'application
  limite également le travail à trois groupes et espace leurs traitements pour
  éviter une rafale après plusieurs heures hors ligne.
- Les documents, photos, dessins, préconisations et rapports restent hors lot :
  ils sont volumineux ou coûteux et conservent leur reprise dédiée.
- Une génération de rapport reste en attente tant qu'une donnée du dossier
  n'est pas confirmée distante. Elle ne peut donc pas produire un PDF à partir
  d'un état NocoDB incomplet.

## Seuils

- Alerte latence : 3000 ms
- Échec latence : 8000 ms
- Timeout : 15000 ms

Ces seuils peuvent être ajustés avec :

```bash
npm run data:stability-check -- --warn-latency-ms 2500 --fail-latency-ms 7000 --timeout-ms 12000
```
