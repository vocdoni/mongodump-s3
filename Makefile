SHELL := /bin/bash

.PHONY: build run-once lifecycle up down logs shell lint

build:
	docker build -t do-mongo-weekly-backup:local .

up:
	docker compose up -d --build

down:
	docker compose down

run-once: build
	docker compose run --rm --entrypoint /app/backup.sh backup

# One-shot: install/update the Spaces lifecycle rule that expires old backups.
# Override the window with EXPIRE_DAYS, e.g. `make lifecycle EXPIRE_DAYS=3650`.
lifecycle: build
	docker compose run --rm --entrypoint /app/lifecycle.sh backup

logs:
	docker compose logs -f --tail=200

shell:
	docker compose run --rm --entrypoint /bin/bash backup

lint:
	shellcheck app/*.sh
