#!/bin/bash
set -euo pipefail

# Downloads pinned podman, gvproxy, and vfkit binaries into .build/debug/
# so that local `swift build && .build/debug/Containerfy pack` works.
#
# Run once after cloning the repo:
#   bash bootstrap.sh

PODMAN_VERSION="5.8.0"
GVPROXY_VERSION="0.8.8"
VFKIT_VERSION="0.6.3"

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$REPO_ROOT/.build/debug"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

mkdir -p "$DEST"

# podman-remote
if [ ! -x "$DEST/podman" ]; then
    info "Downloading podman-remote v${PODMAN_VERSION}..."
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    curl -fSL "https://github.com/containers/podman/releases/download/v${PODMAN_VERSION}/podman-remote-release-darwin_arm64.zip" \
        -o "$TMP/podman.zip"
    unzip -o -q "$TMP/podman.zip" -d "$TMP/podman-extract"
    PODMAN_BIN=$(find "$TMP/podman-extract" -name podman -type f | head -1)
    cp "$PODMAN_BIN" "$DEST/podman"
    chmod +x "$DEST/podman"
    rm -rf "$TMP"
    trap - EXIT
else
    info "podman v${PODMAN_VERSION} (cached)"
fi

# gvproxy
if [ ! -x "$DEST/gvproxy" ]; then
    info "Downloading gvproxy v${GVPROXY_VERSION}..."
    curl -fSL "https://github.com/containers/gvisor-tap-vsock/releases/download/v${GVPROXY_VERSION}/gvproxy-darwin" \
        -o "$DEST/gvproxy"
    chmod +x "$DEST/gvproxy"
else
    info "gvproxy v${GVPROXY_VERSION} (cached)"
fi

# vfkit
if [ ! -x "$DEST/vfkit" ]; then
    info "Downloading vfkit v${VFKIT_VERSION}..."
    curl -fSL "https://github.com/crc-org/vfkit/releases/download/v${VFKIT_VERSION}/vfkit-unsigned" \
        -o "$DEST/vfkit"
    chmod +x "$DEST/vfkit"
else
    info "vfkit v${VFKIT_VERSION} (cached)"
fi

info "Helper binaries ready in $DEST/"
ls -lh "$DEST/podman" "$DEST/gvproxy" "$DEST/vfkit"
