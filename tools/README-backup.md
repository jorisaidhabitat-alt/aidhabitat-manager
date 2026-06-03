# Backup quotidien NocoDB

Script de sauvegarde automatique de toutes les tables NocoDB du projet
aid'habitat. Pensé pour tourner en cron sur l'hôte EasyPanel (ou n'importe
quelle machine Linux avec accès au NocoDB).

## Architecture

```
tools/
├── backup-nocodb.mjs         ← Node script, dump → fichier .json.gz local
├── verify-nocodb-backup.mjs  ← Vérifie qu'un dump est lisible et cohérent
├── backup-and-upload.sh      ← Wrapper bash : dump + vérification + upload
├── Dockerfile.backup         ← Job cron conteneurisé optionnel
└── README-backup.md          ← Ce fichier
```

## Ce qui est sauvegardé

Toutes les tables de la base NocoDB `NOCODB_BASE_ID`, schéma + records. Vu
le 2026-05-15 sur la base de prod : **28 tables, ≈60 MB compressé** par
backup. Pour comparaison : `mobile_document_chunks` (photos chunkées)
représente ~90 % du volume.

Format JSON :
```json
{
  "version": 1,
  "createdAt": "2026-05-15T03:00:00.000Z",
  "baseId": "pskgbjythubfzv9",
  "tables": [
    {
      "id": "...",
      "name": "beneficiaires",
      "fields": [{ "id", "name", "type", "required" }, ...],
      "records": [{ Id, ...columns }, ...]
    },
    ...
  ]
}
```

## Setup rapide (3 commandes)

### 1. Configurer rclone (off-site upload)

`rclone` permet d'uploader vers à peu près n'importe quel stockage cloud
(S3, Backblaze B2, Google Drive, Dropbox, OneDrive, Hetzner Storage Box,
SCP, FTP…). Suivre la doc interactive :

```bash
apt install rclone   # ou: brew install rclone
rclone config         # créer un remote nommé p.ex. "backblaze"
```

Recommandation budget : **Backblaze B2** — 0,006 $/GB/mois (= 0,01 $/mois
pour 1 GB de backups). Pas de frais d'egress en lecture vers un autre
cloud. Plus simple et moins cher qu'AWS S3.

### 2. Définir les variables d'environnement

Dans `/etc/environment` ou un fichier sourcé par le cron :

```bash
export NOCODB_API_URL="https://apps-nocodb.z5avx1.easypanel.host"
export NOCODB_API_TOKEN="<ton-token-NocoDB>"
export NOCODB_BASE_ID="pskgbjythubfzv9"
export BACKUP_DIR="/var/backups/nocodb"
export RETENTION_DAYS=30
export RCLONE_REMOTE="backblaze:aidhabitat-backups"
# Optionnel — webhook Slack/Discord/Mattermost en cas d'échec :
export ALERT_WEBHOOK="https://hooks.slack.com/services/..."
```

### 3. Ajouter le cron

```bash
crontab -e
# Tous les jours à 3h du matin :
0 3 * * * /opt/aidhabitat-manager/tools/backup-and-upload.sh >> /var/log/nocodb-backup.log 2>&1
```

Test immédiat sans attendre 3h du matin :

```bash
/opt/aidhabitat-manager/tools/backup-and-upload.sh
```

## Vérification du backup

Après chaque sauvegarde importante, vérifier que le fichier est lisible :

```bash
node tools/verify-nocodb-backup.mjs /var/backups/nocodb/aidhabitat-YYYY-MM-DD_HH-MM-SS.json.gz
```

Le script vérifie :

- gzip lisible ;
- JSON parseable ;
- tables critiques présentes ;
- tables critiques non vides ;
- cohérence de base entre `mobile_documents` et `mobile_document_chunks`.

## Restauration

Le format est du JSON brut, restaurable manuellement (mais long) via
l'API NocoDB ou un script ad-hoc. Pour un sinistre majeur (perte
complète de NocoDB), le plus rapide :

1. Décompresser le backup : `gunzip aidhabitat-2026-05-15_03-00-00.json.gz`
2. Recréer les tables NocoDB (schéma via UI ou import du JSON)
3. Réimporter les records via `POST /api/v2/tables/{id}/records` (max
   1000 records par requête)

Un vrai script `tools/restore-nocodb.mjs` reste à écrire avant toute
commercialisation. En attendant, `tools/verify-nocodb-backup.mjs` permet
au minimum de prouver que le dump est lisible et exploitable.

## Variables d'environnement

| Variable | Obligatoire | Défaut | Description |
|---|---|---|---|
| `NOCODB_API_URL` | ✅ | — | URL de l'instance NocoDB (sans `/api/v2/...`) |
| `NOCODB_API_TOKEN` | ✅ | — | Token API avec accès lecture sur la base |
| `NOCODB_BASE_ID` | ✅ | — | ID de la base à backuper (`pskgbjythubfzv9`) |
| `BACKUP_DIR` | — | `./backups` | Dossier local où stocker les `.json.gz` |
| `RETENTION_DAYS` | — | `30` | Nombre de jours de rétention (local ET remote) |
| `PAGE_SIZE` | — | `200` | Records par page lors du dump (max 1000) |
| `RCLONE_REMOTE` | — | (vide) | Remote rclone pour upload — vide = pas d'upload |
| `ALERT_WEBHOOK` | — | (vide) | URL HTTP appelée si échec (Slack/Discord/etc.) |

## Déploiement EasyPanel (alternative au cron host)

Au lieu d'un cron host, on peut packager comme container EasyPanel
dédié. Le fichier existe déjà :

```bash
docker build -f tools/Dockerfile.backup -t aidhabitat-nocodb-backup .
```

Puis monter `RCLONE_CONFIG` en volume + les env vars NocoDB en secrets
EasyPanel.

## Audit & monitoring

- **Log** : chaque run écrit dans `/var/log/nocodb-backup.log` (stdout
  + stderr du wrapper). Format `[backup-wrapper TIMESTAMP] …`.
- **Alerte** : si `ALERT_WEBHOOK` est défini, un POST JSON est envoyé en
  cas d'échec dump OU upload. Format `{"text": "⚠️ ..."}` compatible
  Slack/Mattermost.
- **Test de récupération** : à faire trimestriellement — décompresser un
  backup, parser le JSON, vérifier que la table principale (`dossiers`,
  `beneficiaires`) a > 0 records.

## Coûts estimés

| Stockage | Tarif | Mensuel pour 30 backups × 60 MB = 1.8 GB |
|---|---|---|
| Backblaze B2 | 0,006 $/GB/mois | **0,011 $/mois** (~12 centimes/an) |
| AWS S3 (Standard) | 0,023 $/GB/mois | 0,041 $/mois |
| Hetzner Storage Box | 3 €/mo flat (1 TB) | 3 €/mois |
| Google Drive (perso) | 15 GB gratuit | 0 € si tu as de la place |

→ Backblaze B2 reste imbattable pour ce volume.

## Points d'attention

1. **NOCODB_API_TOKEN doit être en LECTURE SEULE** sur la base. Pas
   besoin de droits écriture pour backuper — limite l'exposition si le
   token fuite.

2. **Stockage off-site obligatoire**. Un backup sur le même VPS
   EasyPanel ne protège pas contre une perte totale du VPS (crash disque,
   piratage, suppression accidentelle du volume Docker). Le `RCLONE_REMOTE`
   doit pointer sur un service tiers.

3. **Rotation des tokens NocoDB** : si tu changes
   `NOCODB_API_TOKEN`, mets à jour la config cron immédiatement, sinon
   les backups silencieux échouent à la prochaine exécution. La règle
   `ALERT_WEBHOOK` est précisément là pour ça.

4. **Rétention 30 jours** : ajustable via `RETENTION_DAYS`. 7-14 jours
   suffisent si tu veux limiter le coût stockage ; 90 jours si tu veux
   pouvoir remonter à un état d'il y a 3 mois.

5. **Pas un backup binaire** : ce backup capture le contenu API de
   NocoDB, pas le fichier SQLite/PG sous-jacent. Si NocoDB a une
   corruption interne (rare), elle peut être présente dans le backup
   aussi. Pour un backup "machine state" complet, ajouter en plus un
   snapshot du volume Docker NocoDB côté EasyPanel (mais ça c'est de la
   maintenance infra, pas un cron applicatif).
