# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small bash-only Docker container that runs `mongodump --archive --gzip` against a MongoDB URI, encrypts the archive with `gpg` symmetric AES-256, and uploads it plus `.sha256` and `.metadata.json` sidecars to one or two S3-compatible storage targets (DigitalOcean Spaces, and optionally a second provider for redundancy). The backup script's `RETENTION` is **report-only** — it never deletes. Actual deletion of old backups is a **server-side Spaces lifecycle rule** (age-based, `EXPIRE_DAYS`) applied once by `app/lifecycle.sh`, independent of the job. There is no application code beyond the shell scripts in `app/`; the Dockerfile just adds `awscli`, `gnupg`, `cron`, and MongoDB database tools to `debian:bookworm-slim`.

## Commands

```bash
make build      # docker build -t do-mongo-weekly-backup:local .
make up         # build + start cron container (requires .env)
make run-once   # one-off backup run, bypassing cron
make lifecycle  # apply/update the Spaces expiration rule (EXPIRE_DAYS, default 365)
make logs       # follow container logs
make lint       # shellcheck app/*.sh — the only "test" this repo has
```

Lint is the only static check; run `make lint` (or `shellcheck app/<file>.sh`) after touching any script. There is no CI and no test suite.

Local one-off restore (no docker): `S3_OBJECT_KEY=... ./app/restore.sh` with the required env vars — requires `aws`, `gpg`, and `mongorestore` on the host.

## Architecture

Four scripts in `app/`, no shared sourced file — `log`, `fail`, `require_env`, `target_var` (plus `add_target` / `aws_target` in `backup.sh` and `lifecycle.sh`), the `AWS_S3_FORCE_PATH_STYLE` → `AWS_CONFIG_FILE` translation, and the passphrase-file handling are **duplicated** across `backup.sh`, `restore.sh`, and `lifecycle.sh`. Change all copies if you change one.

- **`entrypoint.sh`** — snapshots the container environment to `/etc/mongo-backup.env` (0600), writes `/etc/cron.d/mongo-backup` from `CRON_SCHEDULE` (uses `CRON_TZ=${TZ}` so cron fires in the configured timezone), optionally runs a backup when `RUN_ON_START=true`, then runs `cron -f` supervised. Requires `CRON_SCHEDULE`; exits 1 without it.
- **`backup.sh`** — the whole pipeline: resolve + validate storage targets → validate env → write passphrase to a `mktemp -d` workdir (0600, `trap cleanup EXIT`) → `mongodump | gpg` streamed → sha256 → upload three objects **to every target** → per target, list objects under the current month prefix and log the count vs `RETENTION` (no deletion).
- **`restore.sh`** — inverse: pick one target with `RESTORE_SOURCE` (`primary`|`secondary`, default `primary`) → download object by `S3_OBJECT_KEY` → verify sha256 against the sidecar (fails hard if the sidecar is missing unless `RESTORE_VERIFY_CHECKSUM=false`) → `gpg --decrypt | mongorestore --archive --gzip` streamed, no intermediate plaintext file.
- **`lifecycle.sh`** — one-shot admin helper, **not** part of the scheduled job. Applies, to **every configured target**, a Spaces lifecycle rule (`ID=expire-old-mongo-backups`, `Filter.Prefix=backups/`, `Expiration.Days=EXPIRE_DAYS`, default 365) via `put-bucket-lifecycle-configuration`, then reads it back with `get-bucket-lifecycle-configuration`. Re-run to change the window (same `ID` replaces in place). May need a full-access/owner Spaces key — a scoped read/write key can be denied `PutBucketLifecycleConfiguration`.

### Conventions that must be preserved

- **Storage targets**: `PRIMARY_*` (with fallback to the legacy unprefixed `SPACE_NAME` /
  `SPACE_ENDPOINT` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — the live DO app spec relies on
  this, don't drop it) and an optional `SECONDARY_*`. A half-configured target is fatal; targets are
  validated before `mongodump` runs. Credentials are passed per `aws` call via `aws_target`, never
  exported, so a key cannot reach the wrong endpoint. `backup.sh` attempts **all** targets and then
  exits 1 if any failed — degraded redundancy must turn the job red, not pass quietly.

- **Object key layout** (identical in every target, which is what makes `RESTORE_SOURCE` a one-var switch): `s3://<bucket>/backups/<YYYY>/<MM>/mongo-<timestamp>.archive.gz.gpg` + `.sha256` + sibling `mongo-<timestamp>.metadata.json`. Timestamps are UTC `YYYYMMDDTHHMMSSZ` so lexicographic order matches time order. `backup.sh` derives the month prefix at start, the filename stamp later — a backup spanning a month boundary writes under the start month.
- **Upload order is load-bearing**: sidecars go up before the archive, per target. `restore.sh` refuses an archive with no `.sha256`, so a partial upload must never leave the archive as the orphan. Don't reorder these.
- **Cron gets no environment for free.** `entrypoint.sh` must snapshot the env to a file that the cron job sources; cron builds job environments from `/etc/passwd` plus crontab assignments only. Removing that snapshot silently breaks every scheduled backup while `make run-once` keeps working.
- **`GNUPGHOME` is set to the workdir** in both scripts — gpg aborts fatally when HOME is unwritable, which is the case for non-root App Platform runs.
- **Passphrase handling**: `BACKUP_PASSPHRASE_FILE` wins over `BACKUP_PASSPHRASE`; the env var is materialized to a temp file and `unset` after. Keep it that way — nothing logs or embeds the passphrase.
- **Metadata sidecar** (`schema_version: 1`) records versions, size, checksum, duration. Any format change should bump `schema_version`.
- AWS CLI quirks: `AWS_EC2_METADATA_DISABLED=true` and `AWS_PAGER=""` are exported in both scripts (avoid IMDS hangs and pager blocking). `AWS_S3_FORCE_PATH_STYLE` is **not** read by the AWS CLI — it is an SDK/Terraform setting — so both scripts translate it into a generated `AWS_CONFIG_FILE` in the workdir. Don't "simplify" it back to an export.
- Extra args are split with plain `read -r -a` (whitespace split, no quoting support) — a known limitation, don't silently change the splitting semantics.

## Deployment notes

Runs either as a long-lived cron container (`docker compose up`) or as a DigitalOcean App Platform scheduled job with command `/app/backup.sh` (container cron unused in that mode). Restoration happens via `docker compose run --rm --entrypoint /app/restore.sh backup -e S3_OBJECT_KEY=...` — see README for the full matrix of restore paths.

On App Platform the job's `run_command` (`/app/backup.sh`) **overrides the Dockerfile ENTRYPOINT**, so `entrypoint.sh` and its cron never run there — only `backup.sh` executes, once per DO schedule. `CRON_SCHEDULE` is therefore irrelevant to the DO deployment.

### Reading a DO scheduled-job's logs

`doctl apps logs` does not work for this component (`--type run` → websocket 1011, `--type deploy` → `NoSuchKey`, `--type build` → task skipped), and the API's `historic_urls` is empty — the log proxy only serves a **live** pod. To see output, poll for a live pod across the run window:

```bash
TOKEN=$(sed -n 's/^ *access-token: *//p' "$HOME/Library/Application Support/doctl/config.yaml" | head -1 | tr -d '" ')
APP=<app-uuid>   # saas-backend-lts = d0c4e9ed-ddc9-45c2-9690-2b1e58ba84ff
URL=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.digitalocean.com/v2/apps/$APP/components/mongodump-s3/logs?type=RUN&follow=true&tail_lines=500" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("live_url") or d.get("url"))')
curl -sf --retry 70 --retry-delay 3 --retry-all-errors --max-time 280 "$URL"
```
