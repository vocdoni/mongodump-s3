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

require_env "SPACE_NAME"
require_env "SPACE_ENDPOINT"
require_env "AWS_ACCESS_KEY_ID"
require_env "AWS_SECRET_ACCESS_KEY"

EXPIRE_DAYS="${EXPIRE_DAYS:-365}"
AWS_S3_FORCE_PATH_STYLE="${AWS_S3_FORCE_PATH_STYLE:-false}"

if ! [[ "$EXPIRE_DAYS" =~ ^[0-9]+$ ]] || [[ "$EXPIRE_DAYS" -lt 1 ]]; then
  fail "EXPIRE_DAYS must be a positive integer"
fi

export AWS_EC2_METADATA_DISABLED=true
export AWS_PAGER=""

workdir="$(mktemp -d)"
rules_path="${workdir}/lifecycle.json"

cleanup() {
  rm -rf "${workdir}"
}
trap cleanup EXIT

# The AWS CLI ignores AWS_S3_FORCE_PATH_STYLE (an SDK/Terraform setting); it
# only takes path-style addressing from its config file.
if [[ "$AWS_S3_FORCE_PATH_STYLE" == "true" ]]; then
  export AWS_CONFIG_FILE="${workdir}/aws-config"
  printf '[default]\ns3 =\n    addressing_style = path\n' >"${AWS_CONFIG_FILE}"
fi

# Scope to Prefix "backups/" so the archive and its .sha256 / .metadata.json
# sidecars expire together and anything else in the bucket is untouched.
# Filter.Prefix (not the deprecated top-level Prefix) is the modern form.
cat >"${rules_path}" <<JSON
{
  "Rules": [
    {
      "ID": "expire-old-mongo-backups",
      "Status": "Enabled",
      "Filter": { "Prefix": "backups/" },
      "Expiration": { "Days": ${EXPIRE_DAYS} }
    }
  ]
}
JSON

log "Applying lifecycle rule (bucket=${SPACE_NAME}, prefix=backups/, expire_days=${EXPIRE_DAYS})"
aws --endpoint-url "${SPACE_ENDPOINT}" s3api put-bucket-lifecycle-configuration \
  --bucket "${SPACE_NAME}" \
  --lifecycle-configuration "file://${rules_path}"

# Read back and log it — Spaces has been reported to silently no-op, so
# verifying the rule actually landed is part of the run.
log "Reading back lifecycle configuration"
aws --endpoint-url "${SPACE_ENDPOINT}" s3api get-bucket-lifecycle-configuration \
  --bucket "${SPACE_NAME}"

log "Lifecycle rule applied successfully"
