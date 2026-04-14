# Visit Report Offline Architecture

## Objectif

Faire du relevé de visite un flux `local-first` :

1. l'UI enregistre immédiatement en local
2. chaque bloc du relevé alimente une queue de synchronisation
3. la synchronisation pousse ensuite vers l'API Express existante
4. NocoDB reste le backend final, pas la source immédiate de l'UI

## Sections métier

- `beneficiary`
- `context`
- `housing`
- `sanitaires`
- `measurements`
- `summary`

## Fichiers préparés

- [services/visitReportMappers.ts](/Users/aidhabitat/Downloads/aid'habitat-manager/services/visitReportMappers.ts)
- [services/visitReportLocalStore.ts](/Users/aidhabitat/Downloads/aid'habitat-manager/services/visitReportLocalStore.ts)
- [services/visitReportSyncQueue.ts](/Users/aidhabitat/Downloads/aid'habitat-manager/services/visitReportSyncQueue.ts)

## Rôle de chaque fichier

### `visitReportMappers.ts`

Construit un snapshot métier local à partir d'un `Dossier` déjà chargé dans l'app.

### `visitReportLocalStore.ts`

Stocke localement :

- le snapshot du relevé par `dossierId + patientId`
- l'état de sync de chaque section
- la queue des opérations à synchroniser

### `visitReportSyncQueue.ts`

Relit la queue locale et appelle les routes déjà en place :

- `PATCH /api/beneficiaires/:patientId`
- `PATCH /api/dossiers/:dossierId`
- `PATCH /api/logements/by-beneficiary/:beneficiaryId`
- `PUT /api/diagnostic-sanitaires/:dossierId`
- `PUT /api/mesures/:dossierId`
- `PUT /api/observations/:dossierId`

## Ordre de branchement recommandé

1. Charger un snapshot local à l'ouverture du relevé.
2. Si aucun snapshot local n'existe, le construire depuis le `Dossier` courant.
3. Quand un bloc change, enregistrer la section via `saveVisitReportSectionLocal(...)`.
4. Déclencher ensuite `flushVisitReportSyncQueue()` en arrière-plan si le réseau est disponible.
5. Afficher un statut discret par bloc :
   - `Enregistré`
   - `En attente`
   - `Erreur de sync`

## Point bloquant métier restant

Le bloc `context` n'est pas encore complètement mappé vers NocoDB :

- `Transports en commun`
- `Continence`
- `Cognition`
- `Communication`
- `Autonomie évaluée`

Ces champs doivent être ajoutés dans [server/index.mjs](/Users/aidhabitat/Downloads/aid'habitat-manager/server/index.mjs) avant une bascule offline complète.
