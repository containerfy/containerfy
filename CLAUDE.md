# Containerfy — Project Context

Containerfy packages a Docker Compose application into a native macOS menu bar app with an embedded Linux VM. One-click install for end users — no Docker knowledge required.

## Repo Structure

```
ARCHITECTURE.md   — Design decisions, component specs, locked decisions
README.md         — Public-facing project overview and usage guide
CLAUDE.md         — This file: project context, expert roles, conventions
Sources/Containerfy/   — Swift source (19 files: GUI + CLI in one binary)
vm/               — VM base image build (Dockerfile, rootfs, build-image.sh)
Resources/        — Entitlements.plist
Package.swift     — SPM config
install.sh        — Developer install script (curl | bash)
.github/workflows/release.yml — CI: build + publish releases
```

## Tech Stack

- **macOS app + CLI**: Swift / AppKit (menu bar `NSStatusItem`), Virtualization.framework — single binary serves both roles
- **VM**: Alpine Linux (aarch64), Docker Engine + Compose v2, shell-based VM agent + socat
- **Host↔VM**: vsock exclusively (control port 1024, data ports 10XXX)
- **Build**: VM-based — CLI boots pre-built VM, Docker inside pulls images, creates ext4 (no Docker required on host)

## Expert Roles

Use these perspectives for multi-angle review of changes:

| Role | Focus |
|---|---|
| **PM** | Scope, prioritization, user-facing requirements, milestone tracking |
| **Swift Dev** | macOS app + CLI: menu bar, VM lifecycle, port forwarding, health checks, Virtualization.framework, `@MainActor` constraints, pack command, compose validation, bundle assembly |
| **Docker/VM Expert** | Alpine image, Docker Engine config, compose passthrough, VM agent, boot sequence, vsock control protocol |
| **Security/Distribution** | Code signing, notarization, Gatekeeper, entitlements, secrets handling, bundle integrity |

## Conventions

- All architecture decisions go in `ARCHITECTURE.md`
- Project status tracked in `README.md`
- Squash commits on main
- **Develop on macOS** — Swift + Virtualization.framework requires a Mac (no devcontainer)
- **No Docker required for developers** — VM-based build eliminates Docker Desktop dependency
- **CI builds VM base image** — developers install binary + base image via `install.sh`
