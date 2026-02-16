# Containerfy

Turn any Docker Compose app into a native macOS menu bar app.

Containerfy packages your multi-container application into a single `.app` bundle that end users install like any other Mac app — drag to Applications, double-click, done. No Docker Desktop, no terminal commands, no container knowledge required.

## How It Works

1. **Define** — Add an `x-containerfy` block to your existing `docker-compose.yml` (your file stays valid for local `docker compose up`)
2. **Build** — Run `containerfy pack` to produce a `.app` bundle with all container images pre-loaded
3. **Distribute** — Ship the `.app` directly or use `--signed` to create a notarized `.dmg`
4. **Run** — End users double-click the app. It appears in the menu bar, boots an invisible VM, starts containers, and exposes services on `localhost`

## Install

```bash
curl -fsSL https://containerfy.dev/install.sh | bash
```

## Quick Start

Add an `x-containerfy` block to your compose file. Here's a real-world example — Paperless-ngx, a document management system with five services:

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
  paperless:
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

  broker:
    image: redis:7-alpine

  db:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: paperless
      POSTGRES_USER: paperless
      POSTGRES_PASSWORD: paperless
    volumes:
      - pgdata:/var/lib/postgresql/data

  gotenberg:
    image: gotenberg/gotenberg:8
    command:
      - "gotenberg"
      - "--chromium-disable-javascript=true"

  tika:
    image: apache/tika:latest

volumes:
  data:
  media:
  pgdata:
```

Services with `ports:` become menu bar items automatically ("Open Paperless" at `http://127.0.0.1:8000`). Internal services like the database and Redis have no ports and stay invisible to the end user.

Then build:

```bash
containerfy pack --compose ./docker-compose.yml
```

See the [Getting Started guide](docs/getting-started.md) for the full walkthrough including signed builds and distribution.

## Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4)
- **No Docker required** — the VM runs Podman
- **Xcode Command Line Tools** — only for `--signed` builds (free: `xcode-select --install`)
- **Apple Developer account** — only for `--signed` builds ($99/year, required for notarization)

## Documentation

- [Getting Started](docs/getting-started.md) — full tutorial with Paperless-ngx example
- [Compose Reference](docs/compose-reference.md) — `x-containerfy` fields, validation rules, passthrough model
- [CLI Reference](docs/cli-reference.md) — `containerfy pack` flags, signing setup, bundle layout
- [Architecture](docs/architecture.md) — how it works under the hood
- [Decisions](docs/decisions.md) — locked decisions, resolved questions, V1 scope, risks
- [Development](docs/development.md) — dev setup, building, testing, contributing

## License

[Apache License 2.0](LICENSE)
