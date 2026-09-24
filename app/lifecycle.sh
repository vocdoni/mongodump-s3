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
# Duplicated in backup.sh and restore.sh -- change all copies.
target_var() {
  local prefix="$1" name="$2"
  local prefixed="${prefix}_${name}"
  local value="${!prefixed:-}"
  if [[ -z "$value" && "$prefix" == "PRIMARY" ]]; then
    value="${!name:-}"
  fi
  printf '%s' "$value"
}

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

# The rule is applied to every configured bucket: a secondary without expiry
# grows forever and quietly doubles the storage bill.
add_target primary PRIMARY true
add_target secondary SECONDARY false

EXPIRE_DAYS="${EXPIRE_DAYS:-365}"

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

failed_labels=""

for index in "${!target_labels[@]}"; do
  label="${target_labels[$index]}"
  bucket="${target_buckets[$index]}"
  log "Applying lifecycle rule to ${label} target (bucket=${bucket}, prefix=backups/, expire_days=${EXPIRE_DAYS})"
  if ! aws_target "$index" s3api put-bucket-lifecycle-configuration \
    --bucket "${bucket}" \
    --lifecycle-configuration "file://${rules_path}"; then
    failed_labels+="${failed_labels:+, }${label}"
    log "ERROR: could not apply lifecycle rule to ${label} target (bucket=${bucket})"
    continue
  fi

  # Read back and log it -- Spaces has been reported to silently no-op, so
  # verifying the rule actually landed is part of the run.
  log "Reading back lifecycle configuration for ${label} target"
  if ! aws_target "$index" s3api get-bucket-lifecycle-configuration --bucket "${bucket}"; then
    failed_labels+="${failed_labels:+, }${label}"
    log "ERROR: could not read back lifecycle rule for ${label} target (bucket=${bucket})"
  fi
done

if [[ -n "$failed_labels" ]]; then
  fail "lifecycle rule not confirmed for target(s): ${failed_labels}"
fi

log "Lifecycle rule applied successfully to: ${target_labels[*]}"
