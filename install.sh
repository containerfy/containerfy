#!/bin/bash
set -euo pipefail

# Containerfy installer — downloads the latest release tarball (containerfy + podman + gvproxy + vfkit).
#
# Usage:
#   curl -fsSL https://containerfy.dev/install.sh | bash

REPO="containerfy/containerfy"
LIB_DIR="/usr/local/lib/containerfy"
BIN_LINK="/usr/local/bin/containerfy"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
error() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    error "Containerfy requires Apple Silicon (arm64). Detected: $ARCH"
fi

# Check macOS
OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
    error "Containerfy requires macOS. Detected: $OS"
fi

# Determine latest release tag
info "Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
if [ -z "$LATEST" ]; then
    error "Could not determine latest release. Check https://github.com/$REPO/releases"
fi
info "Latest release: $LATEST"

RELEASE_URL="https://github.com/$REPO/releases/download/$LATEST"

# Download tarball
info "Downloading containerfy-darwin-arm64.tar.gz..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$RELEASE_URL/containerfy-darwin-arm64.tar.gz" -o "$TMP_DIR/containerfy.tar.gz"
tar -xzf "$TMP_DIR/containerfy.tar.gz" -C "$TMP_DIR"

# Install to /usr/local/lib/containerfy/
info "Installing to $LIB_DIR/..."
if [ -w "/usr/local/lib" ] || [ -w "$LIB_DIR" ]; then
    mkdir -p "$LIB_DIR"
    cp "$TMP_DIR/containerfy/containerfy" "$LIB_DIR/containerfy"
    cp "$TMP_DIR/containerfy/podman"      "$LIB_DIR/podman"
    cp "$TMP_DIR/containerfy/gvproxy"     "$LIB_DIR/gvproxy"
    cp "$TMP_DIR/containerfy/vfkit"       "$LIB_DIR/vfkit"
    chmod +x "$LIB_DIR"/*
else
    sudo mkdir -p "$LIB_DIR"
    sudo cp "$TMP_DIR/containerfy/containerfy" "$LIB_DIR/containerfy"
    sudo cp "$TMP_DIR/containerfy/podman"      "$LIB_DIR/podman"
    sudo cp "$TMP_DIR/containerfy/gvproxy"     "$LIB_DIR/gvproxy"
    sudo cp "$TMP_DIR/containerfy/vfkit"       "$LIB_DIR/vfkit"
    sudo chmod +x "$LIB_DIR"/*
fi

# Create symlink
info "Creating symlink $BIN_LINK → $LIB_DIR/containerfy..."
if [ -w "/usr/local/bin" ]; then
    ln -sf "$LIB_DIR/containerfy" "$BIN_LINK"
else
    sudo ln -sf "$LIB_DIR/containerfy" "$BIN_LINK"
fi

# Verify installation
info "Verifying installation..."
if command -v containerfy >/dev/null 2>&1; then
    info "Installation complete!"
    echo ""
    echo "  Binary:     $LIB_DIR/containerfy"
    echo "  Symlink:    $BIN_LINK"
    echo "  podman:     $LIB_DIR/podman"
    echo "  gvproxy:    $LIB_DIR/gvproxy"
    echo "  vfkit:      $LIB_DIR/vfkit"
    echo ""
    echo "  Usage:      containerfy pack --compose ./docker-compose.yml"
    echo "  Help:       containerfy --help"
    echo ""
else
    echo ""
    echo "Binaries installed to $LIB_DIR/"
    echo "Symlink created at $BIN_LINK"
    echo "Make sure /usr/local/bin is in your PATH."
    echo ""
fi
