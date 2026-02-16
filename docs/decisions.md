# Decisions

## V1 Scope

### In

- Apple Silicon, macOS 14+
- Single appliance per `.app` (1:1)
- Podman + Compose v2 in Fedora CoreOS VM (via `podman machine`)
- Full Compose passthrough — all features work except: `build:`, bind mount volumes, `extends:`, `profiles:`
- All config in one `docker-compose.yml` via `x-containerfy` extension
- Menu items auto-generated from services with `ports:`
- gvproxy port forwarding, HTTP health polling
- Menu bar: status icon, Open (per exposed service), Restart, Stop, Logs, Quit
- Persistent data (podman machine disk), launch at login
- Host validation (hard fail + soft warn)
- Sleep/wake recovery, crash recovery
- Unified Swift CLI to package `.app` bundles (no Docker required, bundles podman/gvproxy/vfkit)

### Out (v2+)

- Intel Macs, macOS 12-13
- Image building on user machines (`build:`)
- Multiple appliances, auto-update, App Store
- GPU passthrough, SSH access, snapshot/rollback
- Windows/Linux host, HTTPS termination
- Custom menu labels per service (v2: via compose `labels:`)
- Custom URL paths per service (v2: via compose `labels:`)
- `profiles:` support (partial-stack selection)

## Locked Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Config format | `x-containerfy` in `docker-compose.yml` | Single file. Standard compose extension mechanism. File stays valid for local `docker compose up`. |
| Container runtime in VM | Podman + Compose v2 (via `podman machine`) | Compose compatibility. Eliminates need for custom VM image — uses Fedora CoreOS default. |
| Host-VM communication | gvproxy + vfkit (managed by podman machine) | Deterministic networking. Port forwarding, DNS, DHCP handled by gvproxy. |
| Storage model | Single disk (podman machine managed) | Podman machine handles disk provisioning and lifecycle. |
| Health checks | HTTP GET polling through port forwarder | Tests full chain end-to-end. Stateless, debuggable (just curl it). |
| Menu item generation | Auto from services with `ports:` | Zero config. Service name = label. Encourages clean appliance design (don't expose internal services). |
| VM management | Shell out to `podman machine` CLI | No custom VM code. Leverages Podman's mature vfkit/gvproxy/ignition stack. |
| macOS app language | Swift, AppKit NSStatusItem | Native menu bar control. No SwiftUI quirks. |
| CLI language | Swift (unified binary) | Same binary for CLI (`containerfy pack`) and GUI. One language, one toolchain. VM-based build eliminates Docker requirement. |
| Build system (Swift) | SPM, no .xcodeproj | Merge-friendly, scriptable, CI-native. |
| Helper binaries | Bundled podman/gvproxy/vfkit in .app | Self-contained distribution. No system podman dependency for end users. |
| Min macOS | 14.0 | VM pause/resume for sleep/wake, stable vsock, mature Virtualization.framework. 13 lacks clean suspend and isn't worth the workarounds. |
| Compose passthrough | Pass full compose file to Docker Compose in VM | Avoids fragile allowlist. Only parse what Containerfy needs (images, ports, volumes). Reject only what can't work. |

## Resolved Questions

| Question | Decision | Rationale |
|---|---|---|
| **Build bootstrapping** | `bootstrap.sh` + podman machine; no Docker required on dev machine | `bootstrap.sh` downloads pinned podman/gvproxy/vfkit. `containerfy pack` bundles them into `.app`. Developer installs one binary via `install.sh`. |
| **Update mechanism** | Manual re-download in v1; no data migration system | Developer publishes a new `.dmg`. User drags new `.app` over old one. Podman machine data persists separately. Data migration is the developer's responsibility (container entrypoints). |
| **Sleep/wake** | Bumped min macOS to 14; podman machine handles VM suspend/resume | Eliminates manual VM lifecycle complexity. macOS 13 isn't worth the workarounds. |
| **Volume disk growth** | Developer sets `disk_mb` conservatively; no auto-resize | No runtime resize complexity. `disk_mb` maps to `podman machine init --disk-size`. |
| **Log streaming** | `podman compose logs` in v1 | Logs window shows recent lines via `podman compose logs --tail`. |
| **Quit vs Stop** | Quit = Stop VM + exit process | Simpler model. No "app running with VM stopped" state. Fewer states to manage. |
| **`env_file:` handling** | `containerfy pack` bundles referenced env files into `.app` Resources | Common in real-world compose files. Silent runtime failure if missing. Reject at pack time if file not found. |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Sleep/wake** — VM clock skew, stale connections after resume | Health checks fail, containers misbehave | Podman machine handles VM suspend/resume. Auto-restart if health fails. |
| **Disk corruption** — force-quit, power loss, kernel panic | VM won't boot | Podman machine manages disk images. `podman machine rm` + `init` recovers from corruption. |
| **Port conflicts** — another app on the same port | App can't start | Test-bind ports before forwarding. Hard error with clear message. No auto-reassign in v1 (breaks compose contract). |
| **Virtualization.framework edge cases** — vfkit crashes, gvproxy hangs | Crashes, hangs | Pin macOS 14+ (stable generation). Podman machine handles vfkit/gvproxy lifecycle. `podman machine rm` + `init` recovers. |
| **Memory pressure / OOM** — macOS jetsam kills entire app process | Data loss, app crash | Validate available memory before VM creation. Allocate conservatively. Jetsam kills the process — no runtime handling possible. Crash recovery on next launch detects stale state file and offers reset. |
| **First-launch VM download** — Fedora CoreOS image download on first `podman machine init` | User thinks app is hung | Show progress. Subsequent launches reuse cached image. |
| **Download size** — Fedora CoreOS VM image ~700 MB | Friction for first launch | Downloaded once, cached by podman. Advise developers to use slim container images. |
| **Notarization dependency** — Apple's notarization service availability, processing delays, policy changes | Developers can't ship signed builds during outages | Default is unsigned — signing only runs with `--signed`. Notarization is async (Apple side) — CLI polls with timeout. Document manual `xcrun notarytool` fallback if automation fails. |
| **Secrets visible in bundle** — environment variables in `docker-compose.yml` are readable inside the `.app` | Credentials exposed if bundle is shared or inspected | Document clearly: compose file is not encrypted. Advise developers to use runtime secret injection (container entrypoints that read from mounted volumes) rather than hardcoding secrets in environment variables. v2 scope for encrypted secrets support. |
