# AppPod Roadmap

Each phase is a shippable checkpoint. Phases 0-3 built the Swift app. Phase 4 added a Go CLI (now superseded). Phase 5 unified everything into a single Swift binary. Phases 6-7 follow.

---

## Phase 0 — Skeleton ✅

Get something running end-to-end. Proof that the architecture works.

- [x] Swift menu bar app: empty shell with status icon, state machine, quit
- [x] Hardcoded VM boot: Alpine + Docker from a manually-built root image
- [x] vsock control channel: HEALTH handshake
- [x] Proof-of-life: app boots VM, gets READY, shows "Running"

## Phase 1 — Core VM Lifecycle ✅

Full VM lifecycle management and host validation.

- [x] VM lifecycle manager: create, start, stop, restart, destroy
- [x] Dual-disk model: root + data partition handling
- [x] First-launch decompression (lz4)
- [x] Sleep/wake: pause/resume (macOS 14)
- [x] Host validation (hard fail + soft warn)
- [x] Graceful shutdown: vsock SHUTDOWN → `docker compose down` → ACPI poweroff → force kill
- [x] State persistence file for crash recovery (`state.json` in Application Support)

## Phase 2 — Port Forwarding + Health ✅

Make containers reachable from the host and monitor their health.

- [x] Port forwarder: vsock↔TCP for all compose `ports:`
- [x] Health monitor: HTTP polling, startup timeout, failure detection
- [x] Disk usage monitoring (DISK protocol command)
- [x] Error recovery: auto-restart on health failure
- [x] Port conflict detection with clear error messages

## Phase 3 — Menu Bar UX ✅

Full dynamic menu bar driven by the compose file.

- [x] Dynamic menu from compose: Open items from services with ports
- [x] Status icon per state (stopped, starting, running, error)
- [x] Logs window (batch fetch)
- [x] Preferences: launch at login
- [x] Remove App Data menu item (cleanup `~/Library/Application Support/<AppName>/`)

## Phase 4 — Go CLI (`apppod pack`) ✅ *(superseded by Phase 5)*

Developer-facing CLI that produces a distributable `.app` bundle. Go CLI and `cli/` directory removed in Phase 5.

- [x] Compose parser: validate `x-apppod`, reject hard-rejected keywords
- [x] Builder container Dockerfile (Alpine arm64 + Docker-in-Docker)
- [x] ext4 creation script: Alpine bootstrap + Docker Engine + packages
- [x] Image preloading via Docker-in-Docker (pull directly into root filesystem)
- [x] VM agent scripts + OpenRC service files
- [x] Sparse image + `resize2fs -M` auto-sizing
- [x] Kernel/initramfs extraction + virtio module verification
- [x] lz4 compression
- [x] .app bundle assembly
- [x] CLI reference flags: `--compose`, `--output`, `--unsigned`
- [x] `env_file:` bundling (detect references, copy files, reject if missing)
- [x] Docker availability check (`docker info`) before any work
- [x] `--platform linux/arm64` pinned on all `docker pull` invocations
- [x] Healthcheck URL port cross-validation against service ports
- [x] `Info.plist` generation (CFBundleIdentifier, CFBundleName, LSUIElement, etc.)
- [x] Progress reporting (step counter for multi-minute operations)

## Phase 5 — Unified Swift CLI + Pre-built VM Base ✅

Eliminate Go CLI and Docker requirement. One Swift binary, one command.

- [x] CI workflow: build VM base image + Swift binary, publish as GitHub release
- [x] Install script (curl | bash) for developer setup
- [x] CLI mode in Swift binary (`apppod pack` via argv detection)
- [x] Extend ComposeConfig.swift with build-time validation (x-apppod, images, env_files, hard-reject keywords)
- [x] VM-based builder: boot VM via Virtualization.framework, pull images inside, create ext4 via shared directories
- [x] .app bundle assembly in Swift (port from Go bundle.go)
- [x] VM agent: BUILD + PACK command handlers, VirtIO shared directory mounting
- [x] Remove Go CLI (cli/ directory), move VM files to vm/
- [x] Update ARCHITECTURE.md for single-language architecture

## Phase 6 — Signing + Distribution ✅

Single `--signed <keychain-profile>` flag. Auto-detects signing identity, signs `.app`, creates `.dmg`, notarizes, staples. Thin wrapper around Apple's standard CLI tools.

- [x] `--signed <keychain-profile>` flag (unsigned is the default)
- [x] Auto-detect signing identity (`security find-identity`), prompt if multiple
- [x] codesign with Hardened Runtime (`--options runtime`, `--timestamp`, `--deep`)
- [x] Entitlements (`com.apple.security.virtualization` + `com.apple.security.hypervisor`)
- [x] Signature verification (`codesign --verify --deep --strict`)
- [x] DMG creation with Applications symlink (`hdiutil create -format UDZO`)
- [x] DMG signing
- [x] Notarization via keychain profile (`xcrun notarytool submit --wait`)
- [x] Stapling (`xcrun stapler staple`, non-fatal on failure)

## Phase 7 — Polish + Hardening

Production readiness and end-to-end validation.

- [ ] Crash recovery (detect stale state file, offer reset)
- [ ] Memory pressure / OOM handling
- [ ] End-to-end test: `apppod pack` → launch → health → open → stop

---

## Recommended Next Steps

**Phase 7 (Polish + Hardening)** is the natural next phase — crash recovery, memory pressure handling, and end-to-end validation now that signing and distribution are in place.
