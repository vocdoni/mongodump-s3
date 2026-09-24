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

# Reads "<PREFIX>_<NAME>". PRIMARY falls back to the legacy unprefixed name so a
# deployment configured before multi-target support keeps working untouched.
# Duplicated in backup.sh and lifecycle.sh -- change all copies.
target_var() {
  local prefix="$1" name="$2"
  local prefixed="${prefix}_${name}"
  local value="${!prefixed:-}"
  if [[ -z "$value" && "$prefix" == "PRIMARY" ]]; then
    value="${!name:-}"
  fi
  printf '%s' "$value"
}

require_env "MONGO_URI"
require_env "S3_OBJECT_KEY"

# backup.sh writes identical object keys to every target, so restoring from the
# secondary copy is a one-variable switch.
RESTORE_SOURCE="${RESTORE_SOURCE:-primary}"
case "$RESTORE_SOURCE" in
  primary) source_prefix="PRIMARY" ;;
  secondary) source_prefix="SECONDARY" ;;
  *) fail "RESTORE_SOURCE must be 'primary' or 'secondary', got: ${RESTORE_SOURCE}" ;;
esac

SPACE_NAME="$(target_var "$source_prefix" SPACE_NAME)"
SPACE_ENDPOINT="$(target_var "$source_prefix" SPACE_ENDPOINT)"
AWS_ACCESS_KEY_ID="$(target_var "$source_prefix" AWS_ACCESS_KEY_ID)"
AWS_SECRET_ACCESS_KEY="$(target_var "$source_prefix" AWS_SECRET_ACCESS_KEY)"
AWS_S3_FORCE_PATH_STYLE="$(target_var "$source_prefix" AWS_S3_FORCE_PATH_STYLE)"
AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-false}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

for storage_var in SPACE_NAME SPACE_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if [[ -z "${!storage_var}" ]]; then
    fail "Missing storage config for ${RESTORE_SOURCE} source: ${source_prefix}_${storage_var}"
  fi
done

BACKUP_PASSPHRASE="${BACKUP_PASSPHRASE:-}"
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-}"
RESTORE_VERIFY_CHECKSUM="${RESTORE_VERIFY_CHECKSUM:-true}"
EXTRA_MONGORESTORE_ARGS="${EXTRA_MONGORESTORE_ARGS:-}"

if [[ -z "$BACKUP_PASSPHRASE" && -z "$BACKUP_PASSPHRASE_FILE" ]]; then
  fail "Set BACKUP_PASSPHRASE or BACKUP_PASSPHRASE_FILE"
fi

export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""

workdir="$(mktemp -d)"
encrypted_archive_path="${workdir}/restore.archive.gz.gpg"
checksum_path="${encrypted_archive_path}.sha256"
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
# only takes path-style addressing from its config file.
if [[ "$AWS_S3_FORCE_PATH_STYLE" == "true" ]]; then
  export AWS_CONFIG_FILE="${workdir}/aws-config"
  printf '[default]\ns3 =\n    addressing_style = path\n' >"${AWS_CONFIG_FILE}"
fi

if [[ -z "$passphrase_file_path" ]]; then
  passphrase_file_path="${workdir}/backup_passphrase.txt"
  umask 077
  printf '%s' "$BACKUP_PASSPHRASE" >"$passphrase_file_path"
  unset BACKUP_PASSPHRASE
else
  [[ -r "$passphrase_file_path" ]] || fail "BACKUP_PASSPHRASE_FILE is not readable: ${passphrase_file_path}"
fi

log "Starting restore (source=${RESTORE_SOURCE}, bucket=${SPACE_NAME}, endpoint=${SPACE_ENDPOINT}, object_key=${S3_OBJECT_KEY})"

log "Downloading encrypted archive"
aws --endpoint-url "${SPACE_ENDPOINT}" \
  s3 cp "s3://${SPACE_NAME}/${S3_OBJECT_KEY}" "${encrypted_archive_path}" >/dev/null

if [[ "$RESTORE_VERIFY_CHECKSUM" == "true" ]]; then
  log "Downloading checksum"
  if aws --endpoint-url "${SPACE_ENDPOINT}" \
    s3 cp "s3://${SPACE_NAME}/${S3_OBJECT_KEY}.sha256" "${checksum_path}" >/dev/null; then
    expected_sha256="$(awk '{print $1}' "${checksum_path}")"
    actual_sha256="$(sha256sum "${encrypted_archive_path}" | awk '{print $1}')"
    if [[ "$expected_sha256" != "$actual_sha256" ]]; then
      fail "Checksum verification failed for ${S3_OBJECT_KEY}"
    fi
    log "Checksum verified (sha256=${actual_sha256})"
  else
    fail "Checksum sidecar not found for ${S3_OBJECT_KEY}; set RESTORE_VERIFY_CHECKSUM=false to bypass"
  fi
else
  log "Checksum verification disabled"
fi

read -r -a extra_restore_args <<<"${EXTRA_MONGORESTORE_ARGS}"

mongorestore_args=(
  --archive
  --gzip
  --uri "${MONGO_URI}"
)

if [[ ${#extra_restore_args[@]} -gt 0 ]]; then
  mongorestore_args+=("${extra_restore_args[@]}")
fi

# --lock-never: private per-run GNUPGHOME (above) means no lock is needed, and
# gpg's dotlock otherwise spins forever on container overlay filesystems.
log "Decrypting archive and running mongorestore"
if ! gpg --batch --yes --pinentry-mode loopback --lock-never \
  --passphrase-file "${passphrase_file_path}" \
  --decrypt "${encrypted_archive_path}" \
  | mongorestore "${mongorestore_args[@]}"; then
  fail "Restore failed"
fi

log "Restore completed successfully"
