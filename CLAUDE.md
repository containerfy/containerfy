# AppPod — Project Context

AppPod packages a Docker Compose application into a native macOS menu bar app with an embedded Linux VM. One-click install for end users — no Docker knowledge required.

## Repo Structure

```
ARCHITECTURE.md   — Design decisions, component specs, locked decisions
ROADMAP.md        — Phased implementation plan with progress tracking
CLAUDE.md         — This file: project context, expert roles, conventions
```

## Tech Stack

- **macOS app**: Swift / AppKit (menu bar `NSStatusItem`), Virtualization.framework
- **CLI (`apppod pack`)**: Go — compose parsing, image handling, ext4 build, signing, DMG packaging
- **VM**: Alpine Linux (aarch64), Docker Engine + Compose v2, shell-based VM agent + socat
- **Host↔VM**: vsock exclusively (control port 1024, data ports 10XXX)

## Expert Roles

Use these perspectives for multi-angle review of changes:

| Role | Focus |
|---|---|
| **PM** | Scope, prioritization, user-facing requirements, milestone tracking |
| **Swift Dev** | macOS app: menu bar, VM lifecycle, port forwarding, health checks, Virtualization.framework, `@MainActor` constraints |
| **Go Dev** | CLI: compose parsing, image pull/save, ext4 builder container, signing/notarization, DMG packaging |
| **Docker/VM Expert** | Alpine image, Docker Engine config, compose passthrough, VM agent, boot sequence, vsock control protocol |
| **Security/Distribution** | Code signing, notarization, Gatekeeper, entitlements, secrets handling, bundle integrity |

## Conventions

- All architecture decisions go in `ARCHITECTURE.md`
- Progress tracked in `ROADMAP.md`
- Squash commits on main
