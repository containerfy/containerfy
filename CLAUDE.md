# Containerfy — Project Context

Containerfy packages a Docker Compose application into a native macOS menu bar app with an embedded Linux VM. One-click install for end users — no Docker knowledge required.

## Repo Structure

```
README.md              — Public-facing project overview (slim billboard)
CLAUDE.md              — This file: project context, expert roles, conventions
docs/                  — All documentation (getting started, references, architecture, decisions, dev guide)
Sources/Containerfy/   — Swift entry point
Sources/ContainerfyCore/ — Swift source (GUI + CLI in one binary)
Resources/             — Entitlements.plist
Package.swift          — SPM config
bootstrap.sh           — Downloads pinned podman/gvproxy/vfkit to .build/debug/
install.sh             — Developer install script (curl | bash)
e2e/                   — End-to-end test (run.sh + docker-compose.yml)
.github/workflows/release.yml — CI: build + publish releases
```

## Tech Stack

- **macOS app + CLI**: Swift / AppKit (menu bar `NSStatusItem`) — single binary serves both roles
- **VM**: Fedora CoreOS (aarch64) via `podman machine` (vfkit + gvproxy under the hood)
- **Container runtime**: Podman + Compose v2 inside the VM
- **Networking**: gvproxy (DHCP, DNS, NAT, port forwarding between host and VM)
- **Build**: `containerfy pack` runs `podman machine init` + `podman compose` to pull images; bundles podman/gvproxy/vfkit in .app

## Expert Roles

Use these perspectives for multi-angle review of changes:

| Role | Focus |
|---|---|
| **PM** | Scope, prioritization, user-facing requirements, milestone tracking |
| **Swift Dev** | macOS app + CLI: menu bar, VM lifecycle, port forwarding, health checks, Virtualization.framework, `@MainActor` constraints, pack command, compose validation, bundle assembly |
| **Podman/VM Expert** | Fedora CoreOS VM, podman machine lifecycle, compose passthrough, gvproxy networking, vfkit hypervisor |
| **Security/Distribution** | Code signing, notarization, Gatekeeper, entitlements, secrets handling, bundle integrity |

## Conventions

- Architecture decisions go in `docs/decisions.md`
- Documentation lives in `docs/` — see README.md for the index
- Squash commits on main
- **Develop on macOS** — Swift + Virtualization.framework requires a Mac (no devcontainer)
- **No Docker required for developers** — podman machine eliminates Docker Desktop dependency
- **Bootstrap helper binaries** — `bootstrap.sh` downloads pinned podman/gvproxy/vfkit to `.build/debug/`
