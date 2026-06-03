#!/usr/bin/env bash
# Wrapper backup quotidien :
#   1. dump NocoDB → fichier .json.gz local
#   2. upload off-site via rclone (n'importe quelle destination : S3, Drive,
#      Backblaze, Hetzner, SCP, Dropbox, etc. — cf. https://rclone.org)
#   3. vérification du dump
#   4. purge des backups locaux > RETENTION_DAYS jours
#
# Variables d'environnement attendues :
#   NOCODB_API_URL, NOCODB_API_TOKEN, NOCODB_BASE_ID  (passées au dump script)
#   BACKUP_DIR             (défaut: ./backups)
#   RETENTION_DAYS         (défaut: 30)
#   RCLONE_REMOTE          (ex: "backblaze:aidhabitat-backups")
#                          Si vide → upload désactivé, seul le dump local est fait
#   ALERT_WEBHOOK          (optionnel) URL appelée si échec — peut pointer
#                          sur un Slack/Discord/Mattermost webhook
#
# Exit non-zero si le dump OU l'upload échoue. À chaîner avec `set -e` côté cron.
#
# Cron suggéré (host EasyPanel) :
#   0 3 * * * /opt/aidhabitat/tools/backup-and-upload.sh >> /var/log/nocodb-backup.log 2>&1

set -euo pipefail

cd "$(dirname "$0")/.."

LOG_PREFIX="[backup-wrapper $(date -u +%Y-%m-%dT%H:%M:%SZ)]"
echo "$LOG_PREFIX démarrage"

# 1. Dump NocoDB local
if ! node tools/backup-nocodb.mjs; then
  echo "$LOG_PREFIX ÉCHEC dump NocoDB" >&2
  [ -n "${ALERT_WEBHOOK:-}" ] && curl -sf -X POST -H 'Content-Type: application/json' \
    -d '{"text":"⚠️ Backup NocoDB aid'\''habitat : ÉCHEC du dump local"}' \
    "$ALERT_WEBHOOK" >/dev/null || true
  exit 1
fi

# 2. Vérification du dernier dump avant tout upload.
BACKUP_DIR="${BACKUP_DIR:-./backups}"
LATEST=$(ls -1t "$BACKUP_DIR"/aidhabitat-*.json.gz 2>/dev/null | head -n 1 || true)
if [ -z "$LATEST" ]; then
  echo "$LOG_PREFIX ÉCHEC: aucun fichier de backup trouvé dans $BACKUP_DIR" >&2
  exit 1
fi

if ! node tools/verify-nocodb-backup.mjs "$LATEST"; then
  echo "$LOG_PREFIX ÉCHEC vérification backup" >&2
  [ -n "${ALERT_WEBHOOK:-}" ] && curl -sf -X POST -H 'Content-Type: application/json' \
    -d '{"text":"⚠️ Backup NocoDB aid'\''habitat : dump créé mais vérification ÉCHEC"}' \
    "$ALERT_WEBHOOK" >/dev/null || true
  exit 1
fi

# 3. Upload off-site (si rclone configuré)
if [ -n "${RCLONE_REMOTE:-}" ]; then
  echo "$LOG_PREFIX upload $LATEST → $RCLONE_REMOTE"
  if ! rclone copy "$LATEST" "$RCLONE_REMOTE" --progress; then
    echo "$LOG_PREFIX ÉCHEC upload rclone" >&2
    [ -n "${ALERT_WEBHOOK:-}" ] && curl -sf -X POST -H 'Content-Type: application/json' \
      -d '{"text":"⚠️ Backup NocoDB aid'\''habitat : dump OK mais upload off-site ÉCHEC"}' \
      "$ALERT_WEBHOOK" >/dev/null || true
    exit 1
  fi

  # 4. Purge côté remote (garde N derniers jours).
  # rclone delete avec --min-age = supprime ce qui est PLUS VIEUX que N jours.
  RETENTION_DAYS="${RETENTION_DAYS:-30}"
  echo "$LOG_PREFIX purge remote > ${RETENTION_DAYS} jours"
  rclone delete "$RCLONE_REMOTE" --min-age "${RETENTION_DAYS}d" \
    --include 'aidhabitat-*.json.gz' || \
    echo "$LOG_PREFIX warn: purge remote a échoué (non bloquant)" >&2
else
  echo "$LOG_PREFIX RCLONE_REMOTE non défini, upload off-site désactivé"
fi

echo "$LOG_PREFIX terminé OK"
