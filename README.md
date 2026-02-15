# Containerfy

Turn any Docker Compose app into a native macOS menu bar app.

Containerfy packages your multi-container application into a single `.app` bundle that end users install like any other Mac app — drag to Applications, double-click, done. No Docker Desktop, no terminal commands, no container knowledge required. Under the hood, an embedded Alpine Linux VM runs Docker Engine with your images pre-loaded, communicating with the host over vsock. The developer writes a standard `docker-compose.yml`, adds a small config block, runs one command, and ships a signed `.dmg`.

## How It Works

1. **Define** — Add an `x-containerfy` block to your existing `docker-compose.yml` (your file stays valid for local `docker compose up`)
2. **Build** — Run `containerfy pack` to produce a `.app` bundle with all container images pre-loaded
3. **Distribute** — Ship the `.app` directly or use `--signed` to create a notarized `.dmg`
4. **Run** — End users double-click the app. It appears in the menu bar, boots an invisible VM, starts containers, and exposes services on `localhost`

The VM is powered by Apple's Virtualization.framework (Apple Silicon native). All host-VM communication uses vsock — no NAT, no firewall rules, no DNS tricks.

## Quick Start

### Install

```bash
curl -fsSL https://raw.githubusercontent.com/containerfy/containerfy/main/install.sh | bash
```

This installs the `containerfy` binary to `/usr/local/bin/` and the VM base image to `~/.containerfy/base/`.

### Define your app

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

### Build

**Unsigned** (for local testing):
```bash
containerfy pack --compose ./docker-compose.yml
```

**Signed + notarized** (for distribution):
```bash
containerfy pack --compose ./docker-compose.yml --signed <keychain-profile>
```

Signed builds produce a `.dmg` with the `.app` inside, notarized and stapled — ready for users to download and install without Gatekeeper warnings.

## CLI Reference

```
containerfy pack [flags]
```

| Flag | Default | Description |
|---|---|---|
| `--compose <path>` | `./docker-compose.yml` | Path to compose file |
| `--output <path>` | `./<name>` from `x-containerfy` | Output directory (produces `.app` or `.app` + `.dmg`) |
| `--signed <keychain-profile>` | *(unsigned)* | Sign, create `.dmg`, notarize, and staple |

**One-time setup for signed builds:**
```bash
xcrun notarytool store-credentials <profile-name>
# Prompts for Apple ID, team ID, and app-specific password
```

## x-containerfy Reference

| Field | Required | Description |
|---|---|---|
| `name` | Yes | App name, 1-64 chars, `[a-zA-Z][a-zA-Z0-9-]*` |
| `version` | Yes | Semver string |
| `identifier` | Yes | Unique ID (reverse-DNS or GitHub URL) |
| `display_name` | No | Shown in menu bar (default: `name` title-cased) |
| `icon` | No | Path to icon file, relative to compose file |
| `vm.cpu.min` | Yes | Minimum CPU cores (1-16) |
| `vm.cpu.recommended` | No | Preferred cores, >= min (default: min) |
| `vm.memory_mb.min` | Yes | Minimum memory in MB (512-32768) |
| `vm.memory_mb.recommended` | No | Preferred memory, >= min (default: min) |
| `vm.disk_mb` | Yes | Disk size in MB (>= 1024) |
| `healthcheck.url` | Yes | HTTP URL on `127.0.0.1`; port must match a service `ports:` entry |
| `healthcheck.interval_seconds` | No | Poll interval, 5-60 (default: 10) |
| `healthcheck.timeout_seconds` | No | Request timeout, 1-30 (default: 5) |
| `healthcheck.startup_timeout_seconds` | No | Max wait for first healthy response, 30-600 (default: 120) |

### Compose passthrough

Containerfy passes your compose file to `docker compose up` inside the VM **unchanged**. It only parses `services[*].image` (to preload images), `services[*].ports` (for port forwarding and menu items), top-level `volumes` (for data disk provisioning), and `services[*].env_file` (to bundle env files).

**Hard-rejected keywords** (caught at build time):

| Keyword | Reason |
|---|---|
| `build:` | No build context in the VM — use pre-built images |
| Bind mount volumes | Host paths don't exist inside the VM — use named volumes |
| `extends:` | External file resolution not supported |
| `profiles:` | All services are always started |
| `network_mode: host` | Breaks vsock port forwarding |

Everything else — `command`, `entrypoint`, `depends_on`, `restart`, `networks`, `healthcheck`, `deploy`, `cap_add`, `privileged`, etc. — passes through to Docker Compose as-is.

## Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4)
- **No Docker required** — the VM has Docker embedded
- **Xcode Command Line Tools** — only for `--signed` builds (free: `xcode-select --install`)
- **Apple Developer account** — only for `--signed` builds ($99/year, required for notarization)

## Status

Phases 0 through 6 are complete: VM lifecycle, port forwarding, health monitoring, dynamic menu bar UI, the unified Swift CLI, and code signing with notarization. See [ARCHITECTURE.md](ARCHITECTURE.md) for design details and internals.

## License

[Apache License 2.0](LICENSE)
