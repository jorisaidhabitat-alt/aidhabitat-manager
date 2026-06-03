# Runbook bascule App'Ergo sans impact

Objectif : changer une brique d'hébergement, de DNS, d'image Easypanel ou de
configuration serveur sans casser l'application utilisée par l'équipe.

Ce runbook ne remplace pas une vraie migration staging. Il donne l'ordre des
contrôles à faire avant et après une bascule.

## Règle simple

Ne pas basculer si un contrôle est rouge.

La production doit rester dans son état actuel tant que :

- le backup n'est pas vérifié ;
- le preflight commercial ne passe pas ;
- le build GitHub Actions n'est pas vert ;
- le live check public ne passe pas ;
- le plan de retour arrière n'est pas clair.

## Avant toute bascule

1. Vérifier l'espace disque local si le build PWA est lancé sur le Mac :

```bash
df -h /System/Volumes/Data .
```

Si l'espace est trop juste, afficher les artefacts locaux supprimables :

```bash
npm run cleanup:artifacts
```

Puis supprimer uniquement les artefacts générés si nécessaire :

```bash
npm run cleanup:artifacts -- --apply
```

Les backups NocoDB ne sont pas supprimés par ce script. Les rapports preflight
ne sont inclus que si l'option `--include-reports` est ajoutée.

2. Créer ou sélectionner un backup NocoDB récent :

```bash
node tools/backup-nocodb.mjs
```

3. Lancer le preflight complet avec PWA :

```bash
COMMERCIAL_PREFLIGHT_CHECK_PWA=1 npm run commercial:preflight -- backups/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz tmp/commercial-readiness
```

4. Lancer le contrôle live public :

```bash
npm run release:live-check
```

5. Lancer le build GitHub Actions sans déploiement :

```bash
gh workflow run "Build Flutter Web" \
  --ref main \
  -f api_base_url=https://api.aidhabitat.fr \
  -f upload_artifact=true \
  -f publish_image=false \
  -f image_tag=staging \
  -f deploy_staging=false
```

6. Attendre le résultat :

```bash
gh run watch <run-id> --exit-status
```

## Critères obligatoires

Le preflight doit indiquer :

- backup production vérifié ;
- audit secrets OK ;
- plan de restauration généré ;
- audit stockage objet généré ;
- snapshot staging généré ;
- lots d'import staging valides ;
- contrôles critiques OK ;
- build web OK ;
- build PWA OK ;
- smoke check PWA OK.

Le live check doit indiquer :

- app PWA accessible ;
- API `/api/health/live` OK ;
- API `/api/health/ready` OK ;
- headers CORS/CORP OK.

GitHub Actions doit indiquer :

- test PDF OK ;
- build Flutter web OK ;
- check PWA bundle OK ;
- upload artifact OK ;
- publication image et déploiement désactivés sauf décision explicite.

## Pendant la bascule

Changer une seule chose à la fois :

- DNS ;
- domaine Easypanel ;
- image Docker ;
- variable d'environnement ;
- base NocoDB staging ;
- configuration API.

Après chaque changement, relancer :

```bash
npm run release:live-check
```

Si le live check échoue, revenir immédiatement à la configuration précédente.

## Après la bascule

Relancer :

```bash
npm run release:live-check
npm run check:critical
```

Puis vérifier manuellement dans l'app :

- ouverture de `https://app.aidhabitat.fr` ;
- login ;
- ouverture d'un dossier ;
- ouverture d'un relevé de visite ;
- navigation entre onglets ;
- chargement des notes ;
- espace documents ;
- génération PDF ;
- affichage des images de préconisations ;
- sauvegarde d'un champ simple ;
- synchronisation NocoDB visible.

## Retour arrière

Le retour arrière doit être préparé avant la bascule.

Exemples :

- remettre l'ancien enregistrement DNS ;
- remettre l'ancienne image Easypanel ;
- remettre l'ancienne variable d'environnement ;
- repointer l'app vers l'ancienne API ;
- conserver les anciens chunks NocoDB tant que S3 n'est pas validé ;
- ne jamais supprimer le backup source.

## Ce qui reste interdit sans staging

- migration NocoDB V3 en production ;
- suppression des chunks documents NocoDB ;
- rotation brutale du mot de passe bootstrap local ;
- changement simultané DNS + API + base ;
- migration fichiers S3 sans double lecture ;
- import de lots dans la base production.

## Preuves à conserver

Garder les liens ou chemins :

- rapport preflight `tmp/commercial-readiness/report.md` ;
- URL du run GitHub Actions ;
- sortie `npm run release:live-check` ;
- hash du commit ;
- date et heure de bascule ;
- décision de rollback si besoin.

## État validé au 2026-06-03

Dernière validation complète connue :

- preflight commercial complet avec PWA : OK ;
- live check public : OK ;
- GitHub Actions build Flutter web : OK ;
- commit validé : `c7f9666`;
- aucune écriture NocoDB effectuée par les contrôles.
