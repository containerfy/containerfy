# Development

## Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4)
- **Xcode Command Line Tools** — `xcode-select --install` (free)
- **No Docker required** — podman machine eliminates Docker Desktop dependency

For signed/notarized builds only:
- **Apple Developer account** ($99/year, required for notarization)

## Setup

```bash
git clone https://github.com/anthropics/containerfy.git
cd containerfy
```

### Bootstrap Helper Binaries

Download pinned versions of podman, gvproxy, and vfkit to `.build/debug/`:

```bash
bash bootstrap.sh
```

These are the binaries that get bundled into `.app` bundles by `containerfy pack`.

### Build

```bash
swift build
```

The binary is at `.build/debug/Containerfy`. It serves as both the CLI (`containerfy pack`) and the GUI (menu bar app).

### Install Locally

```bash
bash install.sh
```

This copies the built binary to `/usr/local/bin/containerfy`.

## Running Tests

### End-to-End Tests

The `e2e/` directory contains an end-to-end test that exercises the full pack-and-run cycle:

```bash
bash e2e/run.sh
```

This uses the compose file at `e2e/docker-compose.yml`.

## Release Process

Releases are built by CI (`.github/workflows/release.yml`). The workflow builds the binary, creates a GitHub release, and publishes artifacts.

## Contributing

- Squash commits on main
- Develop on macOS — Swift + Virtualization.framework requires a Mac (no devcontainer)
- Architecture decisions go in [`docs/decisions.md`](decisions.md)
- Run `bootstrap.sh` after cloning to get helper binaries
