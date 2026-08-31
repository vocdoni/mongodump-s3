# MongoDB Weekly Backups to S3-Compatible Storage

A small, production-practical container that runs `mongodump` on a MongoDB cluster, encrypts the archive with a passphrase, and uploads the encrypted artifact plus `.sha256` and `.metadata.json` sidecars to any S3-compatible storage (including DigitalOcean Spaces). It reports retention state without deleting backups.

## What It Does
- Runs `mongodump --archive --gzip` against a MongoDB URI, piped straight into encryption so the plaintext dump never touches disk.
- Encrypts the archive using `gpg` symmetric AES-256.
- Uploads `mongo-<timestamp>.archive.gz.gpg`, `.sha256`, and `.metadata.json` sidecars to S3-compatible storage. The sidecars are uploaded **before** the archive, so an archive that exists is always restorable.
- Reports how many backups exist for the current month prefix; deletion is disabled.
- Logs duration, encryption mode, encrypted size, checksum, and uploaded object keys.

## Requirements
- Docker + Docker Compose.
- MongoDB connection string (`MONGO_URI`).
- S3-compatible bucket and access keys (least-privilege recommended).

## Quickstart
1. Copy env example and fill values:

```bash
cp .env.example .env
```

2. Build and start:

```bash
docker compose up -d --build
```

3. Check logs:

```bash
docker compose logs -f --tail=200
```

## Configuration
Required env vars:
- `MONGO_URI`
- `SPACE_NAME`
- `SPACE_ENDPOINT`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `BACKUP_PASSPHRASE` or `BACKUP_PASSPHRASE_FILE` (recommended from a secret store)

Optional env vars:
- `CRON_SCHEDULE` (required only when using `entrypoint.sh` cron mode)
- `TZ` (default `Etc/UTC`)
- `RETENTION` (default `6`)
- `BACKUP_TIMEOUT` (default `1800`; seconds before `mongodump`/`gpg` are killed so a hang fails fast instead of pinning CPU until the next run)
- `EXPIRE_DAYS` (default `365` ≈ 12 months; used only by `app/lifecycle.sh` / `make lifecycle` to set the Spaces lifecycle expiration window — see [Automatic Deletion of Old Backups](#automatic-deletion-of-old-backups))
- `EXTRA_MONGODUMP_ARGS` (default empty; example `--db mydb`)
- `AWS_S3_FORCE_PATH_STYLE` (default `false`; set `true` for MinIO-style endpoints that require path-style addressing)
- `MONGO_TLS_CA_FILE` (default empty)
- `BACKUP_PASSPHRASE_FILE` (default empty; if set, takes precedence over `BACKUP_PASSPHRASE`)
- `RUN_ON_START` (default `false`)

Restore-only env vars:
- `S3_OBJECT_KEY` (required by `restore.sh`; example `backups/<YYYY>/<MM>/mongo-<timestamp>.archive.gz.gpg`)
- `RESTORE_VERIFY_CHECKSUM` (default `true`; fail restore if checksum sidecar is missing or mismatched)
- `EXTRA_MONGORESTORE_ARGS` (default empty; appended to `mongorestore`)

Restore **merges** into the target cluster by default — existing documents with matching `_id`s are kept, not replaced. For a clean disaster-recovery restore pass `EXTRA_MONGORESTORE_ARGS=--drop`, which drops each collection before restoring it.

## DigitalOcean Scheduled Job
If you run this as a DigitalOcean App Platform scheduled job:
- Use command: `/app/backup.sh`
- Do not rely on container-internal cron for scheduling.
- Configure `BACKUP_PASSPHRASE` as an encrypted App Platform secret.

## Schedule Examples
These drive the container-internal cron (`entrypoint.sh`) only. A DigitalOcean scheduled job ignores `CRON_SCHEDULE` and uses the app spec's own schedule instead.

- Europe/Rome (DST-aware with `TZ=Europe/Rome`), daily at 03:15:

```
TZ=Europe/Rome
CRON_SCHEDULE=15 3 * * *
```

- UTC, daily at 03:15:

```
TZ=Etc/UTC
CRON_SCHEDULE=15 3 * * *
```

## Object Layout
Objects are written to:

```
s3://<SPACE_NAME>/backups/<YYYY>/<MM>/mongo-<timestamp>.archive.gz.gpg
s3://<SPACE_NAME>/backups/<YYYY>/<MM>/mongo-<timestamp>.archive.gz.gpg.sha256
s3://<SPACE_NAME>/backups/<YYYY>/<MM>/mongo-<timestamp>.metadata.json
```

`<YYYY>/<MM>` is based on the backup time in UTC. `<timestamp>` is UTC in `YYYYMMDDTHHMMSSZ` format, so lexicographic order matches time order.

## Restore Example
Use the restore helper to download, checksum-verify, decrypt, and restore an archive:

```bash
docker compose run --rm \
  -e S3_OBJECT_KEY="backups/<YYYY>/<MM>/mongo-<timestamp>.archive.gz.gpg" \
  --entrypoint /app/restore.sh \
  backup
```

For one-off local usage inside an environment with `aws`, `gpg`, and `mongorestore` installed:

```bash
S3_OBJECT_KEY="backups/<YYYY>/<MM>/mongo-<timestamp>.archive.gz.gpg" \
MONGO_URI="<RESTORE_MONGO_URI>" \
SPACE_NAME="<SPACE_NAME>" \
SPACE_ENDPOINT="<SPACE_ENDPOINT>" \
AWS_ACCESS_KEY_ID="<KEY>" \
AWS_SECRET_ACCESS_KEY="<SECRET>" \
BACKUP_PASSPHRASE_FILE="./backup_passphrase.txt" \
  ./app/restore.sh
```

Local backup, encrypt it, then restore to remote (two-step):

1. Create a local backup file with `mongodump`:

```bash
mongodump --uri "<SOURCE_MONGO_URI>" --archive=backup.archive.gz --gzip
```

2. Encrypt and restore that local backup into the remote cluster:

```bash
gpg --batch --yes --pinentry-mode loopback \
  --symmetric --cipher-algo AES256 \
  --passphrase-file ./backup_passphrase.txt \
  --output backup.archive.gz.gpg \
  backup.archive.gz

gpg --batch --yes --pinentry-mode loopback \
  --passphrase-file ./backup_passphrase.txt \
  --decrypt backup.archive.gz.gpg \
| mongorestore --uri "<REMOTE_MONGO_URI>" --archive --gzip
```

## MongoDB TLS Notes
- Many managed MongoDB services use TLS by default. Your `MONGO_URI` should include TLS parameters (for example `tls=true`).
- If your driver tools need a CA cert file, mount it into the container and set `MONGO_TLS_CA_FILE` to that path. Example:

```
MONGO_TLS_CA_FILE=/certs/ca.pem
```

Mount example (compose):

```
volumes:
  - ./certs/ca.pem:/certs/ca.pem:ro
```

## Automatic Deletion of Old Backups
Deletion is handled **server-side by a DigitalOcean Spaces lifecycle rule**, not by the backup job — so no destructive code ever runs against production, and there is no path that can wrongly delete a fresh backup. DO expires objects itself based on each object's `LastModified` age.

Apply (or change) the rule with the one-shot helper:

```bash
make lifecycle                    # uses EXPIRE_DAYS from .env (default 365 ≈ 12 months)
make lifecycle EXPIRE_DAYS=730    # override to 24 months
```

Or run the raw AWS CLI equivalent against the regional endpoint:

```bash
aws --endpoint-url "$SPACE_ENDPOINT" s3api put-bucket-lifecycle-configuration \
  --bucket "$SPACE_NAME" \
  --lifecycle-configuration '{"Rules":[{"ID":"expire-old-mongo-backups","Status":"Enabled","Filter":{"Prefix":"backups/"},"Expiration":{"Days":365}}]}'
```

Notes:
- The rule is scoped to `Prefix: backups/`, so each archive and its `.sha256` / `.metadata.json` sidecars expire together; nothing else in the bucket is touched.
- It applies to **existing** objects immediately (age is measured from `LastModified`), not just new ones.
- `app/lifecycle.sh` reads the rule back after applying it and logs the result — Spaces has been known to silently no-op, so always confirm it landed.
- Setting a bucket lifecycle is a bucket-admin operation. A scoped read/write key may return `AccessDenied` for `PutBucketLifecycleConfiguration`; if so, run the helper once with a full-access/owner Spaces key.
- Verify at any time: `aws --endpoint-url "$SPACE_ENDPOINT" s3api get-bucket-lifecycle-configuration --bucket "$SPACE_NAME"`.

## Retention and Naming Strategy
- The backup script's `RETENTION` value is **report-only** and independent of deletion: the script lists matching `.archive.gz.gpg` objects and logs how many exist versus `RETENTION`, but never deletes anything. Actual deletion is governed solely by `EXPIRE_DAYS` via the [Spaces lifecycle rule](#automatic-deletion-of-old-backups).
- The year/month segments are always based on the UTC backup time (e.g. `2026/05`).
- The report is scoped to the current month segment (`backups/<YYYY>/<MM>`).
- Source host information is stored in each backup's metadata sidecar.

## Security
### Least-Privilege Spaces Credentials
Create a scoped Spaces access key with permissions limited to the specific bucket and prefix. Example IAM-style policy (adjust bucket, host tag, and month pattern as needed):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::your-space-name"
      ],
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "backups/????/??/*"
          ]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::your-space-name/backups/????/??/*"
      ]
    }
  ]
}
```

### Secret Handling
- Do not hardcode credentials.
- Prefer DigitalOcean App Platform encrypted secrets for scheduled jobs.
- For Docker runtime, prefer Docker secrets or `env_file` and keep `.env` out of version control.
- Use a long random passphrase and rotate it with overlap so older backups remain restorable.

## Troubleshooting
- **Cron not running**: Ensure `CRON_SCHEDULE` is set and valid, and leave it unquoted in `.env`. Check logs with `docker compose logs -f`. If cron itself dies the container now exits rather than idling silently.
- **Scheduled run reports a missing env var**: The entrypoint snapshots the container environment to `/etc/mongo-backup.env` (mode 0600) because cron does not inherit it. Variables whose names are not valid shell identifiers are skipped.
- **Authentication failed (Spaces)**: Verify `SPACE_ENDPOINT`, `SPACE_NAME`, and Spaces access keys.
- **GPG decryption failed**: Verify `BACKUP_PASSPHRASE` or `BACKUP_PASSPHRASE_FILE` and ensure the restore key matches the backup key used at creation time.
- **`gpg: removing stale lockfile` in a loop / `Too many open files`**: gpg's dotlock spins forever on container overlay filesystems. Both scripts run gpg with a private per-run `GNUPGHOME` and `--lock-never`, which avoids it; if you see this, you are running an old build — rebuild.
- **Mongo TLS issues**: Add `tls=true` in `MONGO_URI` or provide a CA file via `MONGO_TLS_CA_FILE`.
- **Checksum verification failed during restore**: Ensure the `.sha256` sidecar matches the encrypted archive object. Do not bypass verification unless you have independently verified integrity.
- **Retention report count looks wrong**: Verify UTC month and object naming format are consistent.

## Shellcheck
If you have `shellcheck` locally, run:

```bash
make lint
```

## Cost Note
Storage costs for Spaces are external. This container only runs weekly and does not maintain local backups.

## License
MIT
