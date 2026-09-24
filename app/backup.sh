#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "Missing required env var: ${name}"
  fi
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

first_line_or_unknown() {
  local output="$1"
  if [[ -n "$output" ]]; then
    printf '%s' "$output" | head -n 1
  else
    printf 'unknown'
  fi
}

# Reads "<PREFIX>_<NAME>". PRIMARY falls back to the legacy unprefixed name so a
# deployment configured before multi-target support keeps working untouched.
target_var() {
  local prefix="$1" name="$2"
  local prefixed="${prefix}_${name}"
  local value="${!prefixed:-}"
  if [[ -z "$value" && "$prefix" == "PRIMARY" ]]; then
    value="${!name:-}"
  fi
  printf '%s' "$value"
}

# Storage targets, parallel arrays. This resolution is duplicated in restore.sh
# and lifecycle.sh -- change all copies.
target_labels=()
target_buckets=()
target_endpoints=()
target_keys=()
target_secrets=()
target_pathstyles=()

add_target() {
  local label="$1" prefix="$2" required="$3"
  local bucket endpoint key secret pathstyle
  bucket="$(target_var "$prefix" SPACE_NAME)"
  endpoint="$(target_var "$prefix" SPACE_ENDPOINT)"
  key="$(target_var "$prefix" AWS_ACCESS_KEY_ID)"
  secret="$(target_var "$prefix" AWS_SECRET_ACCESS_KEY)"
  pathstyle="$(target_var "$prefix" AWS_S3_FORCE_PATH_STYLE)"

  if [[ -z "${bucket}${endpoint}${key}${secret}" ]]; then
    if [[ "$required" == "true" ]]; then
      fail "Missing storage config for ${label} target: ${prefix}_SPACE_NAME, ${prefix}_SPACE_ENDPOINT, ${prefix}_AWS_ACCESS_KEY_ID, ${prefix}_AWS_SECRET_ACCESS_KEY"
    fi
    return 0
  fi

  # Half-configured is always fatal: silently uploading one copy when two were
  # intended is exactly the failure this feature exists to prevent.
  local missing=""
  [[ -n "$bucket" ]] || missing+=" ${prefix}_SPACE_NAME"
  [[ -n "$endpoint" ]] || missing+=" ${prefix}_SPACE_ENDPOINT"
  [[ -n "$key" ]] || missing+=" ${prefix}_AWS_ACCESS_KEY_ID"
  [[ -n "$secret" ]] || missing+=" ${prefix}_AWS_SECRET_ACCESS_KEY"
  if [[ -n "$missing" ]]; then
    fail "Incomplete storage config for ${label} target, missing:${missing}"
  fi

  target_labels+=("$label")
  target_buckets+=("$bucket")
  target_endpoints+=("$endpoint")
  target_keys+=("$key")
  target_secrets+=("$secret")
  target_pathstyles+=("${pathstyle:-false}")
}

require_env "MONGO_URI"

# Validated before mongodump runs so a typo'd secondary key does not waste a
# full dump. Secondary is opt-in: unset means single-target, as before.
add_target primary PRIMARY true
add_target secondary SECONDARY false
target_list="${target_labels[*]}"

RETENTION="${RETENTION:-6}"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-1800}"
HOST_NAME="$(hostname -s)"
EXTRA_MONGODUMP_ARGS="${EXTRA_MONGODUMP_ARGS:-}"
MONGO_TLS_CA_FILE="${MONGO_TLS_CA_FILE:-}"
BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-}"

if ! [[ "$RETENTION" =~ ^[0-9]+$ ]] || [[ "$RETENTION" -lt 1 ]]; then
  fail "RETENTION must be a positive integer"
fi

if [[ -z "$BACKUP_PASSPHRASE" && -z "$BACKUP_PASSPHRASE_FILE" ]]; then
  fail "Set BACKUP_PASSPHRASE or BACKUP_PASSPHRASE_FILE"
fi

SPACE_PREFIX="$(date -u +%Y/%m)"
BASE_PREFIX="backups/${SPACE_PREFIX}"

export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""

start_epoch="$(date -u +%s)"
created_at_utc="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

encryption_mode="gpg-symmetric-aes256"
log "Starting backup (prefix=${BASE_PREFIX}, retention=${RETENTION}, encryption_mode=${encryption_mode}, targets=${target_list// /, })"

workdir="$(mktemp -d)"
encrypted_archive_path="${workdir}/mongo.archive.gz.gpg"
checksum_path="${encrypted_archive_path}.sha256"
metadata_path="${encrypted_archive_path}.metadata.json"
passphrase_file_path="${BACKUP_PASSPHRASE_FILE}"

cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

# gpg aborts outright when it cannot create its home directory, which happens on
# platforms that hand the process an unwritable HOME (App Platform, non-root).
export GNUPGHOME="${workdir}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

# The AWS CLI ignores AWS_S3_FORCE_PATH_STYLE (an SDK/Terraform setting); it
# only takes path-style addressing from its config file. Written unconditionally
# and selected per target, since the two providers may disagree about it.
path_style_config="${workdir}/aws-config"
printf '[default]\ns3 =\n    addressing_style = path\n' >"${path_style_config}"

# Runs the AWS CLI against target index $1. Credentials are passed per call
# rather than exported so one target's key can never reach the other's endpoint.
aws_target() {
  local index="$1"
  shift
  local config="/dev/null"
  if [[ "${target_pathstyles[$index]}" == "true" ]]; then
    config="${path_style_config}"
  fi
  AWS_ACCESS_KEY_ID="${target_keys[$index]}" \
    AWS_SECRET_ACCESS_KEY="${target_secrets[$index]}" \
    AWS_CONFIG_FILE="${config}" \
    aws --endpoint-url "${target_endpoints[$index]}" "$@"
}

if [[ -z "$passphrase_file_path" ]]; then
  passphrase_file_path="${workdir}/backup_passphrase.txt"
  umask 077
  printf '%s' "$BACKUP_PASSPHRASE" >"$passphrase_file_path"
  unset BACKUP_PASSPHRASE
else
  [[ -r "$passphrase_file_path" ]] || fail "BACKUP_PASSPHRASE_FILE is not readable: ${passphrase_file_path}"
fi

read -r -a extra_args <<<"${EXTRA_MONGODUMP_ARGS}"

mongodump_args=(
  --uri "${MONGO_URI}"
  --archive
  --gzip
)

if [[ -n "$MONGO_TLS_CA_FILE" ]]; then
  if [[ ! -f "$MONGO_TLS_CA_FILE" ]]; then
    fail "MONGO_TLS_CA_FILE does not exist: ${MONGO_TLS_CA_FILE}"
  fi
  mongodump_args+=(--tls --tlsCAFile "${MONGO_TLS_CA_FILE}")
fi

if [[ ${#extra_args[@]} -gt 0 ]]; then
  mongodump_args+=("${extra_args[@]}")
fi

# Streamed rather than dump-then-encrypt: peak disk is the encrypted size
# instead of twice it, and the plaintext archive never lands on disk.
# pipefail makes a mongodump failure fail the pipeline, so a truncated dump is
# never uploaded.
#
# --lock-never: each run gets a private, empty GNUPGHOME (above), so there is no
# concurrent access to guard. Without it, gpg's link()-based dotlock spins
# forever on container overlay filesystems (reads back its own lock, calls it
# stale, unlinks, retries) leaking an fd each pass until EMFILE kills the run.
#
# Both stages are wrapped in `timeout` so an unreachable Mongo or a wedged gpg
# fails fast instead of pinning CPU until the next scheduled run stacks on top.
# Two separate `timeout` calls (not one around a `bash -c` pipeline) keep
# MONGO_URI out of a re-quoted shell string.
log "Running mongodump, encrypting on the fly"
if ! timeout "${BACKUP_TIMEOUT}" mongodump "${mongodump_args[@]}" \
  | timeout "${BACKUP_TIMEOUT}" gpg --batch --yes --pinentry-mode loopback --lock-never \
    --symmetric --cipher-algo AES256 \
    --passphrase-file "${passphrase_file_path}" \
    --output "${encrypted_archive_path}"; then
  fail "mongodump or gpg encryption failed"
fi

stamp="$(date -u +"%Y%m%dT%H%M%SZ")"
archive_name="mongo-${stamp}.archive.gz.gpg"
object_key="${BASE_PREFIX}/${archive_name}"
checksum_key="${object_key}.sha256"
metadata_key="${BASE_PREFIX}/mongo-${stamp}.metadata.json"

encrypted_sha256="$(sha256sum <"${encrypted_archive_path}" | awk '{print $1}')"
encrypted_size_bytes="$(wc -c <"${encrypted_archive_path}" | tr -d ' ')"
# Name the sidecar after the uploaded object rather than the temp path so it
# stays usable with `sha256sum -c` after a download.
printf '%s  %s\n' "${encrypted_sha256}" "${archive_name}" >"${checksum_path}"

mongodump_version="$(first_line_or_unknown "$(mongodump --version 2>/dev/null || true)")"
gpg_version="$(first_line_or_unknown "$(gpg --version 2>/dev/null || true)")"
current_epoch="$(date -u +%s)"
duration_seconds="$((current_epoch - start_epoch))"

cat >"${metadata_path}" <<JSON
{
  "schema_version": 1,
  "created_at_utc": "$(json_escape "${created_at_utc}")",
  "host_name": "$(json_escape "${HOST_NAME}")",
  "base_prefix": "$(json_escape "${BASE_PREFIX}")",
  "object_key": "$(json_escape "${object_key}")",
  "checksum_key": "$(json_escape "${checksum_key}")",
  "metadata_key": "$(json_escape "${metadata_key}")",
  "encryption_mode": "${encryption_mode}",
  "encrypted_size_bytes": ${encrypted_size_bytes},
  "encrypted_sha256": "${encrypted_sha256}",
  "duration_seconds": ${duration_seconds},
  "mongodump_version": "$(json_escape "${mongodump_version}")",
  "gpg_version": "$(json_escape "${gpg_version}")"
}
JSON

log "Backup artifact details: encryption_mode=${encryption_mode}, encrypted_size_bytes=${encrypted_size_bytes}, encrypted_sha256=${encrypted_sha256}, duration_seconds=${duration_seconds}"
log "Backup object keys: archive_key=${object_key}, checksum_key=${checksum_key}, metadata_key=${metadata_key}"

uploaded_labels=""
failed_labels=""

for index in "${!target_labels[@]}"; do
  label="${target_labels[$index]}"
  bucket="${target_buckets[$index]}"
  log "Uploading to ${label} target (bucket=${bucket}, endpoint=${target_endpoints[$index]})"

  # Sidecars first, archive last: restore.sh refuses an archive whose .sha256 is
  # missing, so a partial upload must never leave the archive as the orphan.
  # Held per target, so a target that fails halfway never exposes an orphan.
  if aws_target "$index" s3 cp "${checksum_path}" "s3://${bucket}/${checksum_key}" >/dev/null \
    && aws_target "$index" s3 cp "${metadata_path}" "s3://${bucket}/${metadata_key}" >/dev/null \
    && aws_target "$index" s3 cp "${encrypted_archive_path}" "s3://${bucket}/${object_key}" >/dev/null; then
    uploaded_labels+="${uploaded_labels:+, }${label}"
    log "Upload to ${label} target completed"
  else
    failed_labels+="${failed_labels:+, }${label}"
    log "ERROR: upload to ${label} target failed (bucket=${bucket})"
    continue
  fi

  # Best-effort: the backup is already safely uploaded at this point, so a failing
  # list (transient error, or a key without ListBucket) must not fail the run.
  log "Reporting retention policy for ${label} target"
  if keys_raw="$(aws_target "$index" s3api list-objects-v2 \
    --bucket "${bucket}" \
    --prefix "${BASE_PREFIX}/mongo-" \
    --query 'Contents[].Key' \
    --output text 2>&1)"; then
    if [[ -z "$keys_raw" || "$keys_raw" == "None" ]]; then
      archive_count="0"
    else
      archive_keys="$(printf '%s\n' "$keys_raw" | tr '\t' '\n' | grep -E '\.archive\.gz\.gpg$' || true)"
      archive_count="$(printf '%s\n' "$archive_keys" | grep -c . || true)"
    fi
    log "Retention report (${label}): found ${archive_count} archive(s), configured retention is ${RETENTION}, deletion disabled"
  else
    log "WARNING: retention report unavailable for ${label} target (list-objects-v2 failed); upload itself succeeded"
  fi
done

end_epoch="$(date -u +%s)"
total_duration_seconds="$((end_epoch - start_epoch))"
if [[ -n "$failed_labels" ]]; then
  log "Backup stored on: ${uploaded_labels:-none}"
  fail "storage target(s) failed: ${failed_labels} (duration_seconds=${total_duration_seconds})"
fi

log "Backup completed successfully (targets=${uploaded_labels}, duration_seconds=${total_duration_seconds})"
