# Getting Started

## Install

```bash
curl -fsSL https://containerfy.dev/install.sh | bash
```

This downloads the `containerfy` binary to `/usr/local/bin/`.

## Define Your App

Add an `x-containerfy` block to your compose file. The compose file remains fully valid — `docker compose up` still works locally for development.

Here's a real-world example — Paperless-ngx, a document management system with five services:

```yaml
x-containerfy:
  name: "paperless"
  version: "2.14.0"
  identifier: "github.com/paperless-ngx/paperless-ngx"
  display_name: "Paperless"
  icon: "icon.png"
  vm:
    cpu:
        min: 2
        recommended: 4
    memory_mb:
        min: 2048
        recommended: 4096
    disk_mb: 16384
  healthcheck:
    url: "http://127.0.0.1:8000"

services:
  paperless:                           # → menu item: "Open Paperless"
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    ports:
      - "8000:8000"
    depends_on:
      - db
      - broker
      - gotenberg
      - tika
    environment:
      PAPERLESS_REDIS: redis://broker:6379
      PAPERLESS_DBHOST: db
      PAPERLESS_TIKA_ENABLED: 1
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://gotenberg:3000
      PAPERLESS_TIKA_ENDPOINT: http://tika:9998
    volumes:
      - data:/usr/src/paperless/data
      - media:/usr/src/paperless/media

  broker:                              # internal — no ports, no menu item
    image: redis:7-alpine

  db:                                  # internal — no ports, no menu item
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: paperless
      POSTGRES_USER: paperless
      POSTGRES_PASSWORD: paperless
    volumes:
      - pgdata:/var/lib/postgresql/data

  gotenberg:                           # internal — document conversion
    image: gotenberg/gotenberg:8
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"

  tika:                                # internal — OCR processing
    image: apache/tika:latest

volumes:
  data:
  media:
  pgdata:
```

This produces a single menu item: **"Open Paperless"** at `http://127.0.0.1:8000`. The broker, database, Gotenberg, and Tika are invisible to the end user — they have no `ports:` and communicate by service name over the compose network.

Services with `ports:` become menu bar items automatically. Internal services like the database and Redis have no ports and stay invisible to the end user.

## Build

**Unsigned** (for local testing):
```bash
containerfy pack --compose ./docker-compose.yml
```

**Signed + notarized** (for distribution):
```bash
containerfy pack --compose ./docker-compose.yml --signed <keychain-profile>
```

Signed builds produce a `.dmg` with the `.app` inside, notarized and stapled — ready for users to download and install without Gatekeeper warnings.

See [CLI Reference](cli-reference.md) for all flags and signing setup.

## Distribute

Ship the `.app` directly (unsigned, for testing) or the `.dmg` (signed, for production). End users drag to Applications, double-click, done. No Docker Desktop, no terminal commands, no container knowledge required.

The app appears in the menu bar, boots an invisible VM, starts containers, and exposes services on `localhost`.

## Next Steps

- [Compose Reference](compose-reference.md) — `x-containerfy` fields, validation rules, passthrough model
- [CLI Reference](cli-reference.md) — `containerfy pack` flags, signing setup, bundle layout
- [Architecture](architecture.md) — how it works under the hood
