# AppPod Roadmap

Each phase is a shippable checkpoint. Phases are sequential — later phases build on earlier ones.

---

## Phase 0 — Skeleton

Get something running end-to-end. Proof that the architecture works.

- [ ] Swift menu bar app: empty shell with status icon, state machine, quit
- [ ] Hardcoded VM boot: Alpine + Docker from a manually-built root image
- [ ] vsock control channel: HEALTH handshake
- [ ] Proof-of-life: app boots VM, gets READY, shows "Running"

## Phase 1 — Core VM Lifecycle

Full VM lifecycle management and host validation.

- [ ] VM lifecycle manager: create, start, stop, restart, destroy
- [ ] Dual-disk model: root + data partition handling
- [ ] First-launch decompression (lz4)
- [ ] Sleep/wake: pause/resume (macOS 14)
- [ ] Host validation (hard fail + soft warn)

## Phase 2 — Port Forwarding + Health

Make containers reachable from the host and monitor their health.

- [ ] Port forwarder: vsock↔TCP for all compose `ports:`
- [ ] Health monitor: HTTP polling, startup timeout, failure detection
- [ ] Disk usage monitoring (DISK protocol command)
- [ ] Error recovery: auto-restart on health failure

## Phase 3 — Menu Bar UX

Full dynamic menu bar driven by the compose file.

- [ ] Dynamic menu from compose: Open items from services with ports
- [ ] Status icon per state (stopped, starting, running, error)
- [ ] Logs window (batch fetch)
- [ ] Preferences: launch at login

## Phase 4 — Go CLI (`apppod pack`)

Developer-facing CLI that produces a distributable `.app` bundle.

- [ ] Compose parser: validate `x-apppod`, reject hard-rejected keywords
- [ ] Image pull + save (`docker pull` / `docker save`)
- [ ] Builder container: create ext4 root image
- [ ] Kernel/initramfs extraction
- [ ] lz4 compression
- [ ] .app bundle assembly
- [ ] CLI reference flags: `--compose`, `--output`, `--unsigned`

## Phase 5 — Signing + Distribution

Code signing, notarization, and DMG packaging.

- [ ] Interactive signing identity selection
- [ ] codesign integration
- [ ] DMG creation (hdiutil)
- [ ] Notarization submission + stapling
- [ ] `--unsigned` flag

## Phase 6 — Polish + Hardening

Production readiness and end-to-end validation.

- [ ] Crash recovery
- [ ] Graceful shutdown sequence
- [ ] Port conflict detection with clear errors
- [ ] Memory pressure / OOM handling
- [ ] End-to-end test: `apppod pack` → launch → health → open → stop
