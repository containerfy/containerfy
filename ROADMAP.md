# AppPod Roadmap

Each phase is a shippable checkpoint. Phases 0-3 are sequential (Swift app). Phases 4-5 (Go CLI) can be developed in parallel starting from Phase 1. Phase 6 requires all prior phases.

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

## Phase 4 — Go CLI (`apppod pack`) ✅

Developer-facing CLI that produces a distributable `.app` bundle.

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

## Phase 5 — Signing + Distribution

Code signing, notarization, and DMG packaging.

- [ ] Interactive signing identity selection
- [ ] codesign integration
- [ ] Hardened Runtime (`--options runtime`, `--timestamp`)
- [ ] Entitlements file with `com.apple.security.virtualization` + `com.apple.security.hypervisor`
- [ ] Remove `com.apple.security.get-task-allow` from release builds
- [ ] DMG creation (hdiutil)
- [ ] Notarization submission + stapling
- [ ] Notarization credential management (keychain profile default, env vars for CI)
- [ ] Pre-submission validation (`codesign --verify` + `spctl --assess`)
- [ ] Stapler retry with backoff (propagation delay)
- [ ] `--unsigned` flag

## Phase 6 — Polish + Hardening

Production readiness and end-to-end validation.

- [ ] Crash recovery (detect stale state file, offer reset)
- [ ] Memory pressure / OOM handling
- [ ] End-to-end test: `apppod pack` → launch → health → open → stop

---

## Recommended Next Steps

**Phase 5 (Signing + Distribution)** is the natural next phase — codesign, notarization, hardened runtime, and DMG packaging for distributable `.app` bundles.

**Phase 6 (Polish + Hardening)** follows once signing is in place, providing end-to-end validation and crash recovery UX.
