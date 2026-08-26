#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

CRON_SCHEDULE="${CRON_SCHEDULE:-}"
TZ="${TZ:-Etc/UTC}"
RUN_ON_START="${RUN_ON_START:-false}"

if [[ -z "$CRON_SCHEDULE" ]]; then
  log "ERROR: CRON_SCHEDULE is required"
  exit 1
fi

cron_file="/etc/cron.d/mongo-backup"
env_file="/etc/mongo-backup.env"
log_file="/var/log/cron.log"

# cron builds each job's environment from /etc/passwd plus the assignments in
# the crontab file; the container environment is NOT inherited. Snapshot it so
# the job can source MONGO_URI, the Spaces keys and the passphrase. Keep the
# secrets in this file rather than in the crontab line, which is world-readable.
# Built from printenv rather than `export -p` so that names which are not valid
# shell identifiers (Docker allows them, bash cannot source them) are skipped
# instead of emitting a line that breaks the file -- a source failure would make
# the `&&` below skip the backup entirely.
log "Snapshotting environment for cron jobs"
touch "${env_file}"
chmod 0600 "${env_file}"
while IFS='=' read -r name _; do
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  printf 'export %s=%q\n' "$name" "${!name}"
done <<<"$(printenv)" >"${env_file}"

log "Configuring cron (TZ=${TZ}, schedule=${CRON_SCHEDULE})"

cat >"${cron_file}" <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=${TZ}
TZ=${TZ}
${CRON_SCHEDULE} root { . ${env_file} && /app/backup.sh; } >>${log_file} 2>&1
CRON

chmod 0644 "${cron_file}"
touch "${log_file}"

if [[ "$RUN_ON_START" == "true" ]]; then
  log "RUN_ON_START=true, running backup immediately"
  # Deliberately not fatal: exiting here would combine with restart:unless-stopped
  # into a tight mongodump retry loop against production. Let the schedule back off.
  /app/backup.sh >>"${log_file}" 2>&1 || log "ERROR: initial backup failed, continuing to cron"
fi

log "Starting cron"
cron -f >>"${log_file}" 2>&1 &
cron_pid=$!

log "Tailing cron logs"
tail -F "${log_file}" &
tail_pid=$!

# Supervise cron: without this the container stays "up" on a dead cron and
# silently stops taking backups.
wait "${cron_pid}" || true
log "ERROR: cron exited, stopping container"
kill "${tail_pid}" 2>/dev/null || true
exit 1
