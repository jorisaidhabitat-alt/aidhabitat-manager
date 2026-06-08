# Stabilité data/sync App'Ergo

Objectif : vérifier que la base métier NocoDB et la synchronisation restent fiables en production Easypanel.

Commande :

```bash
npm run data:stability-check
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
- Présence des scripts backup, vérification et plan de restauration

## Règle d'exploitation

Si l'audit échoue, ne pas déployer et ne pas migrer le schéma.

Si l'audit passe avec alertes, la prod n'est pas bloquée, mais les alertes doivent être lues avant une migration.

À lancer :

- Avant un changement de schéma NocoDB
- Après un déploiement Easypanel
- Après une erreur 502 ou une lenteur inhabituelle
- Avant une opération de backup/restauration

## Seuils

- Alerte latence : 3000 ms
- Échec latence : 8000 ms
- Timeout : 15000 ms

Ces seuils peuvent être ajustés avec :

```bash
npm run data:stability-check -- --warn-latency-ms 2500 --fail-latency-ms 7000 --timeout-ms 12000
```
