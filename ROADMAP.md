# AppPod Roadmap

Each phase is a shippable checkpoint. Phases 0-3 are sequential (Swift app). Phases 4-5 (Go CLI) can be developed in parallel starting from Phase 1. Phase 6 requires all prior phases.

---

## Phase 0 — Skeleton ✅

Get something running end-to-end. Proof that the architecture works.

- [x] Swift menu bar app: empty shell with status icon, state machine, quit
- [x] Hardcoded VM boot: Alpine + Docker from a manually-built root image
- [x] vsock control channel: HEALTH handshake
- [x] Proof-of-life: app boots VM, gets READY, shows "Running"

## Phase 1 — Core VM Lifecycle ← **next**

Full VM lifecycle management and host validation.

- [ ] VM lifecycle manager: create, start, stop, restart, destroy
- [ ] Dual-disk model: root + data partition handling
- [ ] First-launch decompression (lz4)
- [ ] Sleep/wake: pause/resume (macOS 14)
- [ ] Host validation (hard fail + soft warn)
- [ ] Graceful shutdown: vsock SHUTDOWN → `docker compose down` → ACPI poweroff → force kill
- [ ] State persistence file for crash recovery (`state.json` in Application Support)

## Phase 2 — Port Forwarding + Health

Make containers reachable from the host and monitor their health.

- [ ] Port forwarder: vsock↔TCP for all compose `ports:`
- [ ] Health monitor: HTTP polling, startup timeout, failure detection
- [ ] Disk usage monitoring (DISK protocol command)
- [ ] Error recovery: auto-restart on health failure
- [ ] Port conflict detection with clear error messages

## Phase 3 — Menu Bar UX

Full dynamic menu bar driven by the compose file.

- [ ] Dynamic menu from compose: Open items from services with ports
- [ ] Status icon per state (stopped, starting, running, error)
- [ ] Logs window (batch fetch)
- [ ] Preferences: launch at login
- [ ] Remove App Data menu item (cleanup `~/Library/Application Support/<AppName>/`)

## Phase 4 — Go CLI (`apppod pack`)

Developer-facing CLI that produces a distributable `.app` bundle.

- [ ] Compose parser: validate `x-apppod`, reject hard-rejected keywords
- [ ] Image pull + save (`docker pull` / `docker save`)
- [x] Builder container Dockerfile (Alpine arm64 + e2fsprogs + docker)
- [x] ext4 creation script: Alpine bootstrap + Docker Engine + packages
- [ ] Docker-in-Docker image preloading (privileged builder, `docker load`)
- [x] VM agent scripts + OpenRC service files
- [ ] Dynamic image sizing (base + image tars + 25% headroom)
- [ ] Kernel/initramfs extraction + virtio module verification
- [ ] lz4 compression
- [ ] .app bundle assembly
- [ ] CLI reference flags: `--compose`, `--output`, `--unsigned`
- [ ] `env_file:` bundling (detect references, copy files, reject if missing)
- [x] Docker availability check (`docker info`) before any work
- [ ] `--platform linux/arm64` pinned on all `docker pull` invocations
- [ ] Healthcheck URL port cross-validation against service ports
- [ ] `Info.plist` generation (CFBundleIdentifier, CFBundleName, LSUIElement, etc.)
- [ ] Progress reporting (step counter for multi-minute operations)

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

**Phase 1 (Core VM Lifecycle)** is the natural next phase — it builds directly on the Phase 0 skeleton with dual-disk model, lz4 decompression, sleep/wake, graceful shutdown, host validation, and crash recovery.

**Phase 4 (Go CLI)** can proceed in parallel since its foundation (builder Dockerfile, ext4 script, VM agent, Docker check) is already in place from Phase 0.
