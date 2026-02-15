#!/bin/bash
set -euo pipefail

# AppPod installer — downloads the latest release binary and VM base image.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/containerly/apppod/main/install.sh | bash

REPO="containerly/apppod"
INSTALL_DIR="/usr/local/bin"
BASE_DIR="$HOME/.apppod/base"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
error() { printf '\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    error "AppPod requires Apple Silicon (arm64). Detected: $ARCH"
fi

# Check macOS
OS=$(uname -s)
if [ "$OS" != "Darwin" ]; then
    error "AppPod requires macOS. Detected: $OS"
fi

# Determine latest release tag
info "Fetching latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')
if [ -z "$LATEST" ]; then
    error "Could not determine latest release. Check https://github.com/$REPO/releases"
fi
info "Latest release: $LATEST"

RELEASE_URL="https://github.com/$REPO/releases/download/$LATEST"

# Download binary
info "Downloading apppod binary..."
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$RELEASE_URL/apppod-darwin-arm64" -o "$TMP_DIR/apppod"
chmod +x "$TMP_DIR/apppod"

# Install binary
info "Installing to $INSTALL_DIR/apppod..."
if [ -w "$INSTALL_DIR" ]; then
    cp "$TMP_DIR/apppod" "$INSTALL_DIR/apppod"
else
    sudo cp "$TMP_DIR/apppod" "$INSTALL_DIR/apppod"
fi

# Download VM base artifacts
info "Downloading VM base image..."
mkdir -p "$BASE_DIR"

for file in vm-base.img.lz4 vmlinuz-lts initramfs-lts; do
    info "  Downloading $file..."
    curl -fsSL "$RELEASE_URL/$file" -o "$BASE_DIR/$file"
done

# Verify installation
info "Verifying installation..."
if command -v apppod >/dev/null 2>&1; then
    info "Installation complete!"
    echo ""
    echo "  Binary:     $INSTALL_DIR/apppod"
    echo "  VM base:    $BASE_DIR/"
    echo ""
    echo "  Usage:      apppod pack --compose ./docker-compose.yml"
    echo "  Help:       apppod --help"
    echo ""
else
    echo ""
    echo "Binary installed to $INSTALL_DIR/apppod"
    echo "Make sure $INSTALL_DIR is in your PATH."
    echo ""
fi
