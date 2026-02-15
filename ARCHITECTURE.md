# Containerfy Architecture

An open-source tool that packages a Docker Compose application into a native macOS menu bar app with an embedded Linux VM. One-click install for end users — no Docker knowledge, no container runtime on the host.

The developer's only input is a single `docker-compose.yml` with an `x-containerfy` extension block. No separate manifest file.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  macOS Host                                                      │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  <AppName>.app  (Swift · menu bar · generic binary)        │  │
│  │                                                            │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐  │  │
│  │  │ Host         │  │ VM Lifecycle │  │ Menu Bar UI     │  │  │
│  │  │ Validator    │  │ Manager      │  │ (AppKit)        │  │  │
│  │  └──────┬───────┘  └──────┬───────┘  └────────┬────────┘  │  │
│  │         │                 │                    │           │  │
│  │         │          ┌──────┴───────┐   ┌───────┴────────┐  │  │
│  │         │          │ Port         │   │ State Machine  │  │  │
│  │         │          │ Forwarder    │   │ Controller     │  │  │
│  │         │          └──────┬───────┘   └────────────────┘  │  │
│  │         │                 │                                │  │
│  └─────────┼─────────────────┼────────────────────────────────┘  │
│            │        vsock    │                                    │
│            │     ┌───────────┴──────────┐                        │
│            │     │  port 1024: control  │                        │
│            │     │  port 10XXX: data    │                        │
│            │     └───────────┬──────────┘                        │
│  ┌─────────┼─────────────────┼────────────────────────────────┐  │
│  │  Linux VM  (Virtualization.framework · Apple Silicon)      │  │
│  │         │                 │                                 │  │
│  │         │     ┌───────────┴──────────┐                     │  │
│  │         │     │  VM Agent            │                     │  │
│  │         │     │  (shell + socat)     │                     │  │
│  │         │     │  - vsock↔TCP bridge  │                     │  │
│  │         │     │  - health reporter   │                     │  │
│  │         │     │  - log forwarder     │                     │  │
│  │         │     └───────────┬──────────┘                     │  │
│  │         │     ┌───────────┴──────────┐                     │  │
│  │         │     │  Docker Engine       │                     │  │
│  │         │     │  docker compose up   │                     │  │
│  │         │     │    ┌───┐┌───┐┌───┐   │                     │  │
│  │         │     │    │svc││svc││svc│   │                     │  │
│  │         │     │    │ A ││ B ││ C │   │                     │  │
│  │         │     │    └───┘└───┘└───┘   │                     │  │
│  │         │     └──────────────────────┘                     │  │
│  │         │                                                  │  │
│  │  ┌──────┴──────────────────────────────────────────────┐   │  │
│  │  │  /dev/vda (root)     │  /dev/vdb (data - persistent)│   │  │
│  │  │  Alpine + Docker +   │  Docker volumes, app state   │   │  │
│  │  │  images + compose    │  Survives VM recreate        │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ~/Library/Application Support/<AppName>/                        │
│    ├── vm-root.img       (copy of base image)                    │
│    ├── vm-data.img       (persistent data partition)             │
│    └── containerfy.log                                                │
└──────────────────────────────────────────────────────────────────┘
```

**Key constraint:** The macOS app does NOT implement container tooling. The VM is a self-contained appliance. The app only manages VM lifecycle, health checks, port forwarding, and UX.

**Unified binary:** The same Swift binary serves as both the developer CLI (`containerfy pack`) and the end-user GUI app (menu bar). CLI mode is activated when `pack` is the first argument; otherwise the GUI launches. The VM base image serves dual roles: build environment (CLI boots it, Docker inside pulls images, creates ext4) and runtime environment (end user's .app boots it with images pre-loaded).

**Key networking decision:** vsock for all host↔VM communication. No NAT IP discovery, no firewall issues. The VM's NAT adapter exists solely for outbound internet from containers.

---

## Components

### Swift Menu Bar App (generic binary)

The same compiled `.app` binary is used for every appliance. It reads `docker-compose.yml` from its own `Contents/Resources/` at runtime, parses the `x-containerfy` block and service definitions to determine behavior: app name, menu items, port forwarding, health checks, etc.

| Aspect | Decision |
|---|---|
| Framework | AppKit `NSStatusItem` |
| Min target | macOS 14.0 (VM pause/resume, stable vsock, Virtualization.framework maturity) |
| Entitlements | `com.apple.security.virtualization`, `com.apple.security.hypervisor` |
| Hardened Runtime | Required — `--options runtime` for notarized builds |
| Sandbox | No — Virtualization.framework requires unsandboxed execution |
| Distribution | Signed `.app` in `.dmg`, notarized via `containerfy pack`, not App Store |

**State machine:**

```
Stopped → ValidatingHost → InsufficientResources → Stopped (retry/quit)
                         → StartingVM → WaitingForHealth → Running
                                      → Error
                         → WaitingForHealth → Stopping → Stopped
                                            → Error
Running → Stopping → Stopped
Running → Error → StartingVM (auto-restart)
                → Stopped (user stop)
Error → Stopped (user stop)
Any state → Stopped (quit — Quit always means Stop+Exit)
```

All transitions are `@MainActor`-isolated. `VZVirtualMachineDelegate` callbacks dispatch to `@MainActor` before touching state. Transitions are guarded: "if current state is X, move to Y; otherwise ignore and log."

**Menu bar renders dynamically from compose file:**
- Status icon reflects current state
- "Open" items auto-generated from services with `ports:` — service name becomes the label (title-cased, hyphens → spaces), first host port becomes the URL
- Restart / Stop / View Logs / Preferences / Quit (Quit = Stop VM + exit)

**VM lifecycle manager** wraps `VZVirtualMachine`:
- Creates VM config from `x-containerfy` block (CPU, memory, disks, vsock, NAT)
- First launch: decompresses root image, creates data image
- Subsequent launches: reuses existing disk images
- Graceful shutdown: vsock SHUTDOWN → ACPI poweroff → force kill after timeout
- `VZVirtualMachine` must operate on main thread — all VM ops are `@MainActor`-isolated
- `VZVirtualMachineDelegate` callbacks fire on arbitrary queues — always dispatch to `@MainActor` before state mutation
- Disk I/O (lz4 decompression, image creation) runs on background Tasks — never block main thread

**Host validator** runs before VM creation — pure function, no side effects:
- Hard fail: insufficient memory, disk, wrong arch, old macOS, no VZ support
- Soft warn: below recommended CPU cores
- Each failure carries a `guidance` string so users see what to do, not just what's wrong

**Port forwarder:**
- Binds `127.0.0.1:<port>` on host for each compose `ports:` mapping
- Tunnels TCP traffic through vsock to the VM agent's socat bridges
- Test-binds ports before starting; errors with "Port X already in use" if occupied
- TCP only — UDP port mappings in compose are warned at pack time (vsock is stream-oriented)
- Port conflict detection: test-bind before forwarding, hard error with "Port X already in use by <process>"
- After sleep/wake resume: tear down and rebuild all vsock data connections

**Health monitor:**
- HTTP GET polling through the port forwarder to the developer-defined health URL
- Tests the full chain: Docker → container → app → vsock → host
- 2s interval during startup (120s timeout), 10s interval once running
- 3 consecutive failures → Error state
- Periodic `DISK` query — menu bar warning when data disk exceeds ~90% usage

### Swift CLI (`containerfy pack`) — Developer-Facing

The same Swift binary serves dual roles: CLI tool for developers and GUI app for end users. When invoked with `containerfy pack`, it runs in CLI mode (no NSApplication). Otherwise it launches the menu bar GUI.

```
containerfy pack \
  --compose ./docker-compose.yml \
  --output ./MyApp \
  --signed myprofile
```

What it does:
1. Parses `docker-compose.yml` — validates `x-containerfy` block, rejects hard-rejected keywords (see Compose Passthrough Model)
2. Boots the pre-built VM base image using Virtualization.framework
3. Docker inside the VM pulls all referenced images (`--platform linux/arm64`)
4. VM agent creates ext4 root image from its own rootfs + pulled images, shrinks (`resize2fs -M`), compresses with lz4
5. Artifacts transferred to host via VirtIO shared directories
6. Swift assembles the .app bundle: copies artifacts, compose file, env files, generates Info.plist, embeds itself as the app binary
7. If `--signed`: signs `.app` with Hardened Runtime, creates `.dmg`, submits for notarization, staples ticket

**Build requirements:**
- No Docker required on the developer's machine. The VM has Docker embedded.
- VM base image must be installed at `~/.containerfy/base/` (installed via `install.sh` or Homebrew)
- Xcode Command Line Tools (`xcode-select --install`) for signing and notarization (only needed with `--signed`). Free.
- Apple Developer account ($99/year) for the signing certificate (only needed with `--signed`). Required for notarized distribution — unsigned apps are blocked by Gatekeeper.

**Installation:**
```bash
curl -fsSL https://raw.githubusercontent.com/containerly/containerfy/main/install.sh | bash
```

This downloads the binary to `/usr/local/bin/containerfy` and the VM base image to `~/.containerfy/base/`.

**The .app bundle layout produced by the CLI:**
```
MyApp.app/Contents/
├── MacOS/Containerfy              # Generic Swift binary (same for all appliances)
├── Resources/
│   ├── docker-compose.yml    # Compose file (includes x-containerfy config)
│   ├── *.env                 # Any env files referenced by env_file: (if present)
│   ├── vmlinuz-lts           # Linux kernel
│   ├── initramfs-lts         # Initramfs
│   └── vm-root.img.lz4      # Compressed root disk with preloaded images
└── Info.plist
```

Entitlements are embedded in the code signature at build time, not shipped as a file.

### CLI Reference

```
containerfy pack [flags]
```

| Flag | Default | Description |
|---|---|---|
| `--compose` | `./docker-compose.yml` | Path to compose file |
| `--output` | `./<name>` (from `x-containerfy.name`) | Output path (produces `.app` or `.app` + `.dmg`) |
| `--signed <keychain-profile>` | | Sign `.app`, create `.dmg`, notarize, and staple. Requires a Developer ID certificate. |

**Unsigned build** (default): produces `.app` only. No signing, no `.dmg`. Useful for local testing. End users will see a Gatekeeper warning.

**Signed build** (`--signed <profile>`): auto-detects Developer ID signing identity (prompts if multiple found), signs `.app` with Hardened Runtime and entitlements (`codesign --force --sign <hash> --options runtime --timestamp --deep`), verifies signature (`codesign --verify --deep --strict`), creates compressed `.dmg` with Applications symlink (`hdiutil create -format UDZO`), signs the `.dmg`, submits for notarization (`xcrun notarytool submit --keychain-profile <profile> --wait`), and staples the ticket (`xcrun stapler staple` — non-fatal on failure, Gatekeeper verifies online).

**One-time credential setup:**
```bash
xcrun notarytool store-credentials <profile-name>
# Prompts for Apple ID, team ID, and app-specific password
# Credentials are stored in the macOS keychain
```

```
containerfy --help
```

Shows available commands. With no arguments, launches the GUI menu bar app.

### Linux VM Image

Alpine Linux (aarch64), minimal, with Docker Engine and preloaded container images.

**Two-disk model:**
- **Root disk** (`vm-root.img`): Alpine + Docker + images + compose. Replaceable on app update.
- **Data disk** (`vm-data.img`): Docker volumes and app state. Persistent across updates. Created on first launch.

Docker's `data-root` is configured to `/data/docker` (on the data disk), so all mutable state — volumes, containers, layers — lives on the persistent partition.

**Docker daemon config** (`/etc/docker/daemon.json` on root disk):
```json
{
  "data-root": "/data/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": false
}
```
Log rotation prevents unbounded growth on the data partition. `live-restore: false` ensures containers stop if dockerd crashes (agent detects and reports failure).

**VM agent** is a small shell script + socat, managed by OpenRC:
- Listens on vsock port 1024 for control commands (line-based text protocol)
- Runs socat bridges: vsock data ports ↔ container TCP ports (wrapped in respawn loops — restart on crash)
- Reports readiness ("READY" handshake) after dockerd and services are up
- Agent itself runs as an OpenRC service with `respawn` — not a bare `&` background process

**Control protocol** (vsock port 1024):
```
→ HEALTH          ← OK|FAIL:<reason>
→ DISK            ← DISK:<used_mb>/<total_mb>
→ LOGS:<lines>    ← LOGS:<byte_count>\n<log data>
→ SHUTDOWN        ← ACK
→ BUILD:<images>  ← BUILD_START, PULLING:<img>, PULLED:<img>, BUILD_IMAGES_DONE
→ PACK            ← PACK_START, PACK_STEP:<step>, PACK_DONE
```

BUILD and PACK are used during `containerfy pack` (build mode). BUILD pulls images into Docker inside the VM. PACK creates the ext4 root image from the running VM's filesystem + pulled images, shrinks and compresses it, then writes artifacts to the VirtIO shared output directory.

**Boot sequence inside VM** (OpenRC dependency chain):
1. Mount root and data partitions, fsck
2. Start dockerd (wait for `docker info` to succeed)
3. Start VM agent (vsock listener + socat bridges)
4. `docker compose up -d` (images already loaded, no pull)

OpenRC dependency chain: `mount /data` → `dockerd` → `vm-agent` (which runs `docker compose up -d` after verifying `docker info` succeeds).

---

## `docker-compose.yml` with `x-containerfy`

All Containerfy configuration lives inside the compose file using the standard `x-` extension mechanism. The compose file remains fully valid — `docker compose up` still works locally for development.

### Example: Paperless-ngx

A self-hosted document management system with OCR. Five services, but only the web UI is user-facing — the rest communicate internally over the compose network.

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

This produces a single menu item: **"Open Paperless"** → `http://127.0.0.1:8000`. The broker, database, Gotenberg, and Tika are invisible to the end user — they have no `ports:` and communicate by service name over the compose network.

### Menu item generation rules

Services with `ports:` automatically become "Open" menu items:
- **Label**: service name, title-cased, hyphens/underscores → spaces (`paperless` → "Paperless")
- **URL**: `http://127.0.0.1:<first host port>`
- Services without `ports:` are internal-only and don't appear in the menu

**Only expose ports for services the end user should see.** Internal services (databases, caches, queues) talk to each other by service name — no `ports:` needed, no port conflicts possible.

### `x-containerfy` field reference

```yaml
x-containerfy:
  name: "my-app"                     # [REQUIRED] string, 1-64 chars, [a-zA-Z0-9-]
  version: "1.0.0"                   # [REQUIRED] semver
  identifier: "com.example.myapp"    # [REQUIRED] unique ID (reverse-DNS, GitHub URL, etc.)
  display_name: "My App"             # [OPTIONAL] shown in menu bar, default: name title-cased
  icon: "icon.png"                   # [OPTIONAL] path relative to compose file

  vm:
    cpu:
      min: 2                         # [REQUIRED] 1-16
      recommended: 4                 # [OPTIONAL] >= min, default: min
    memory_mb:
      min: 2048                      # [REQUIRED] 512-32768
      recommended: 4096              # [OPTIONAL] >= min, default: min
    disk_mb: 10240                   # [REQUIRED] >= 1024

  healthcheck:
    url: "http://127.0.0.1:8080/health"  # [REQUIRED] must target 127.0.0.1
    interval_seconds: 10             # [OPTIONAL] 5-60, default: 10
    timeout_seconds: 5               # [OPTIONAL] 1-30, default: 5
    startup_timeout_seconds: 120     # [OPTIONAL] 30-600, default: 120
```

**Validation rules** (enforced by `containerfy pack` at build time):

| Field | Constraint |
|---|---|
| `name` | `^[a-zA-Z][a-zA-Z0-9-]{0,63}$` (leading alpha required) |
| `version` | Valid semver |
| `cpu.min` | 1-16, `recommended` >= `min` |
| `memory_mb.min` | 512-32768, `recommended` >= `min` |
| `disk_mb` | >= 1024 |
| `healthcheck.url` | Valid HTTP URL, host must be `127.0.0.1`, port must match a host port in some service's `ports:` mapping |
| At least one service | Must have `ports:` (otherwise nothing to expose) |

**Resource allocation at runtime:**
- CPU: `min(recommended, hostCores - 1)`, floored at `min`
- Memory: use `recommended` if host has 2x that free, otherwise use `min`

---

## Compose Passthrough Model

Containerfy passes the compose file to `docker compose up` inside the VM **unchanged**. The file is not rewritten, templated, or subset-filtered.

**Containerfy only parses these fields** (everything else is ignored and passed through):

| Field | Why Containerfy reads it |
|---|---|
| `services[*].image` | Preload images into root disk at build time (no pull at runtime) |
| `services[*].ports` | Set up vsock↔TCP port forwarding on the host; generate menu items |
| Top-level `volumes` | Provision named volumes on the persistent data disk |
| `services[*].env_file` | Bundle referenced `.env` files into root image alongside compose file |

**Hard-rejected keywords** (caught by `containerfy pack` at build time):

| Keyword | Reason |
|---|---|
| `build:` | No Docker daemon on the host, no build context in the VM. Pre-built images only. |
| Bind mount volumes (e.g. `./data:/app/data`) | Host paths don't exist inside the VM. Named volumes only. |
| `extends:` | Requires resolving external files that may not be bundled. |
| `profiles:` | All services in the file are always started. No partial-stack support in v1. |
| `network_mode: host` | Service binds to VM network, invisible to vsock port forwarder. Breaks silently. |
| `env_file:` without bundled files | References must resolve inside VM. `containerfy pack` bundles referenced env files automatically; rejects if file not found. |

**Everything else passes through** — `command`, `entrypoint`, `depends_on`, `restart`, `networks`, `configs`, `secrets`, `labels`, `healthcheck`, `deploy`, `logging`, `cap_add`, `privileged`, `user`, `working_dir`, `stdin_open`, `tty`, etc. If Docker Compose supports it, it works.

---

## V1 Scope

**In:**
- Apple Silicon, macOS 14+
- Single appliance per `.app` (1:1)
- Docker Engine + Compose v2 in VM
- Full Docker Compose passthrough — all features work except: `build:`, bind mount volumes, `extends:`, `profiles:`
- All config in one `docker-compose.yml` via `x-containerfy` extension
- Menu items auto-generated from services with `ports:`
- vsock port forwarding, HTTP health polling
- Menu bar: status icon, Open (per exposed service), Restart, Stop, Logs, Quit
- Persistent data (dual-disk), launch at login
- Host validation (hard fail + soft warn)
- Sleep/wake recovery, crash recovery
- Unified Swift CLI to package `.app` bundles (no Docker required)

**Hard-rejected Compose keywords** (see Compose Passthrough Model):
- `build:`, bind mount volumes, `extends:`, `profiles:`

**Out (v2+):**
- Intel Macs, macOS 12-13
- Image building on user machines (`build:`)
- Multiple appliances, auto-update, App Store
- GPU passthrough, SSH access, snapshot/rollback
- Windows/Linux host, HTTPS termination
- Custom menu labels per service (v2: via compose `labels:`)
- Custom URL paths per service (v2: via compose `labels:`)
- `profiles:` support (partial-stack selection)

---

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Sleep/wake** — VM clock skew, stale connections after resume | Health checks fail, containers misbehave | macOS 14 native `pause()`/`resume()` eliminates most issues. Re-establish vsock after resume, auto-restart if health fails within 15s. ext4 journaling handles edge cases. |
| **Disk corruption** — force-quit, power loss, kernel panic | VM won't boot | ext4 journaling + fsck on boot. Root image is rebuildable from compressed source in `.app` bundle. Data image is separate and preserved. |
| **Port conflicts** — another app on the same port | App can't start | Test-bind ports before forwarding. Hard error with clear message. No auto-reassign in v1 (breaks compose contract). |
| **Virtualization.framework edge cases** — vsock reconnection, memory reclaim, delegate timing | Crashes, hangs | Pin macOS 14+ (stable generation). Wrap all VZ calls in do/catch. "Hard reset" path: destroy and recreate VM object. Log all VZ delegate callbacks. |
| **Memory pressure / OOM** — macOS jetsam kills entire app process | Data loss, app crash | Validate available memory before VM creation. Allocate conservatively. Jetsam kills the process — no runtime handling possible. Crash recovery on next launch detects stale state file and offers reset. |
| **First-launch decompression** — 2-4 GB image takes 20-60s | User thinks app is hung | Show "Preparing first launch..." progress. Use lz4 (3x faster than gzip). Background thread with cancellation. |
| **Download size** — .app bundle can be 500 MB - 2 GB | Friction for distribution | Alpine base (~150 MB with Docker). Advise developers to use slim images. lz4 compression. |
| **Notarization dependency** — Apple's notarization service availability, processing delays, policy changes | Developers can't ship signed builds during outages | Default is unsigned — signing only runs with `--signed`. Notarization is async (Apple side) — CLI polls with timeout. Document manual `xcrun notarytool` fallback if automation fails. |
| **Secrets visible in bundle** — environment variables in `docker-compose.yml` are readable inside the `.app` | Credentials exposed if bundle is shared or inspected | Document clearly: compose file is not encrypted. Advise developers to use runtime secret injection (container entrypoints that read from mounted volumes) rather than hardcoding secrets in environment variables. v2 scope for encrypted secrets support. |

---

## Locked Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Config format | `x-containerfy` in `docker-compose.yml` | Single file. Standard compose extension mechanism. File stays valid for local `docker compose up`. |
| Container runtime in VM | Docker Engine + Compose v2 | Compose compatibility. VM is opaque — Docker overhead is irrelevant. |
| Host↔VM communication | vsock exclusively | Deterministic. No NAT IP discovery, no DNS, no firewall. Works identically on every Mac. |
| Storage model | Dual-disk (root + data) | Root is replaceable on update. Data survives. Most important decision for maintainability. |
| Health checks | HTTP GET polling through port forwarder | Tests full chain end-to-end. Stateless, debuggable (just curl it). |
| Menu item generation | Auto from services with `ports:` | Zero config. Service name = label. Encourages clean appliance design (don't expose internal services). |
| Control protocol | Line-based text over vsock | No serialization deps. Readable with socat for debugging. |
| macOS app language | Swift, AppKit NSStatusItem | Native menu bar control. No SwiftUI quirks. |
| CLI language | Swift (unified binary) | Same binary for CLI (`containerfy pack`) and GUI. One language, one toolchain. VM-based build eliminates Docker requirement. |
| Build system (Swift) | SPM, no .xcodeproj | Merge-friendly, scriptable, CI-native. |
| Compression | lz4 | 3x faster decompression than gzip. Acceptable size tradeoff for first-launch UX. |
| Min macOS | 14.0 | VM pause/resume for sleep/wake, stable vsock, mature Virtualization.framework. 13 lacks clean suspend and isn't worth the workarounds. |
| Compose passthrough | Pass full compose file to Docker Compose in VM | Avoids fragile allowlist. Only parse what Containerfy needs (images, ports, volumes). Reject only what can't work. |

---

## Resolved Questions

| Question | Decision | Rationale |
|---|---|---|
| **Build bootstrapping** | VM-based build; no Docker required on dev machine | CLI boots a pre-built VM base image, Docker inside the VM pulls app images and creates the ext4 root disk. Developer installs one binary + base image via `install.sh`. |
| **Update mechanism** | Manual re-download in v1; no data migration system | Developer publishes a new `.dmg`. User drags new `.app` over old one. App detects root image mismatch and re-decompresses. Data migration is the developer's responsibility (container entrypoints). |
| **Sleep/wake** | Bumped min macOS to 14; use native `VZVirtualMachine.pause()`/`resume()` | Eliminates vsock reconnection uncertainty. Clean suspend/resume. macOS 13 isn't worth the workarounds. |
| **Volume disk growth** | Alert user at threshold (~90%); no auto-resize | VM agent monitors disk usage and reports via control protocol. Menu bar shows warning. No runtime resize complexity. Developer sets `disk_mb` conservatively. |
| **Log streaming** | Batch-fetch only in v1 (`LOGS:<lines>` → response) | Logs window shows recent lines, refreshes on demand or timer. Real-time tailing deferred to v2. |
| **Quit vs Stop** | Quit = Stop VM + exit process | Simpler model. No "app running with VM stopped" state. Fewer states to manage. |
| **`env_file:` handling** | `containerfy pack` bundles referenced env files into root image | Common in real-world compose files. Silent runtime failure if missing. Reject at pack time if file not found. |
| **Control protocol scope** | HEALTH, DISK, LOGS, SHUTDOWN for runtime; BUILD, PACK for build mode | Add VERSION/STATUS/RESTART in v2 if needed. Avoids speculative complexity. |
