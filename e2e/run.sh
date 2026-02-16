#!/bin/bash
set -euo pipefail

# End-to-end test for Containerfy.
# Builds the binary, packs a test .app, verifies the bundle, launches it,
# waits for the VM + compose services, curls the served port, then shuts down.
#
# Requirements: Swift toolchain, port 8080 free.
# Usage: bash e2e/run.sh [--app <path-to-existing.app>]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_SUPPORT="$HOME/Library/Application Support/Containerfy"
STATE_FILE="$APP_SUPPORT/state.json"
MACHINE_NAME="containerfy-test-app"

VM_TIMEOUT=300    # seconds — first launch pulls container images inside VM
PORT_TIMEOUT=120  # seconds — compose services start and expose port
POLL_INTERVAL=2

info()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
pass()  { printf '\033[1;32m  ✓\033[0m %s\n' "$1"; }
fail()  { printf '\033[1;31m  ✗\033[0m %s\n' "$1"; exit 1; }

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
APP=""
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP="$2"
            SKIP_BUILD=true
            shift 2
            ;;
        *)
            echo "Usage: bash e2e/run.sh [--app <path-to-existing.app>]"
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------
# Cleanup trap — always runs on exit
# ------------------------------------------------------------------
TMPDIR_TEST=""

cleanup() {
    info "Cleaning up..."

    # Kill the app by process name
    pkill -f "TestApp.app/Contents/MacOS/Containerfy" 2>/dev/null || true

    # Stop and remove the test podman machine
    if command -v podman &>/dev/null; then
        podman machine stop "$MACHINE_NAME" 2>/dev/null || true
        podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
    fi

    # Remove temp dir
    if [ -n "$TMPDIR_TEST" ] && [ -d "$TMPDIR_TEST" ]; then
        rm -rf "$TMPDIR_TEST"
    fi
}
trap cleanup EXIT

# ==================================================================
# Phase 1: Pre-flight
# ==================================================================
info "Pre-flight checks..."

if lsof -i :8080 -sTCP:LISTEN >/dev/null 2>&1; then
    fail "Port 8080 is already in use — free it before running this test"
fi
pass "Port 8080 is free"

# Clean app state
if [ -d "$APP_SUPPORT" ]; then
    echo "  Removing stale Application Support data..."
    rm -rf "$APP_SUPPORT"
fi

# Clean stale test machine (if podman is available on system)
if command -v podman &>/dev/null; then
    if podman machine inspect "$MACHINE_NAME" &>/dev/null; then
        echo "  Removing stale test machine..."
        podman machine stop "$MACHINE_NAME" 2>/dev/null || true
        podman machine rm -f "$MACHINE_NAME" 2>/dev/null || true
    fi
fi

# ==================================================================
# Phases 2–5: Bootstrap, Build, Pack, Verify (skip with --app)
# ==================================================================
if [ "$SKIP_BUILD" = true ]; then
    info "Using provided app: $APP"
    if [ ! -d "$APP" ]; then
        fail "App not found: $APP"
    fi
else
    # Phase 2: Bootstrap
    info "Bootstrapping helper binaries..."
    cd "$REPO_ROOT"
    bash bootstrap.sh

    # Phase 3: Build
    info "Building Containerfy binary (swift build)..."
    swift build 2>&1
    BINARY="$REPO_ROOT/.build/debug/Containerfy"
    if [ ! -x "$BINARY" ]; then
        fail "Binary not found at $BINARY"
    fi
    pass "Binary built: $BINARY"

    # Phase 4: Pack
    TMPDIR_TEST="$(mktemp -d)"
    COMPOSE_FILE="$TMPDIR_TEST/docker-compose.yml"
    OUTPUT_DIR="$TMPDIR_TEST/TestApp"

    cp "$SCRIPT_DIR/docker-compose.yml" "$COMPOSE_FILE"

    info "Running containerfy pack..."
    "$BINARY" pack --compose "$COMPOSE_FILE" --output "$OUTPUT_DIR"
    APP="$OUTPUT_DIR.app"
    pass "Pack completed: $APP"

    # Phase 5: Verify bundle
    info "Verifying bundle: $APP"

    assert_exists() {
        if [ ! -e "$1" ]; then
            fail "Missing: $1"
        fi
    }

    assert_executable() {
        if [ ! -x "$1" ]; then
            fail "Not executable: $1"
        fi
    }

    assert_plist_contains() {
        local file="$1" key="$2" value="$3"
        if ! /usr/libexec/PlistBuddy -c "Print :$key" "$file" 2>/dev/null | grep -q "$value"; then
            fail "Info.plist key $key does not contain '$value'"
        fi
    }

    # Binary
    assert_exists     "$APP/Contents/MacOS/Containerfy"
    assert_executable "$APP/Contents/MacOS/Containerfy"
    pass "Contents/MacOS/Containerfy exists and is executable"

    # podman binary
    assert_exists     "$APP/Contents/MacOS/podman"
    assert_executable "$APP/Contents/MacOS/podman"
    pass "Contents/MacOS/podman exists and is executable"

    # gvproxy binary
    assert_exists     "$APP/Contents/MacOS/gvproxy"
    assert_executable "$APP/Contents/MacOS/gvproxy"
    pass "Contents/MacOS/gvproxy exists and is executable"

    # vfkit binary + entitlements
    assert_exists     "$APP/Contents/MacOS/vfkit"
    assert_executable "$APP/Contents/MacOS/vfkit"
    pass "Contents/MacOS/vfkit exists and is executable"

    VFKIT_ENTITLEMENTS="$(codesign -d --entitlements - "$APP/Contents/MacOS/vfkit" 2>/dev/null)"
    assert_entitlement() {
        if ! echo "$VFKIT_ENTITLEMENTS" | grep -q "$1"; then
            fail "vfkit missing entitlement: $1"
        fi
    }
    assert_entitlement "com.apple.security.virtualization"
    assert_entitlement "com.apple.security.network.server"
    assert_entitlement "com.apple.security.network.client"
    pass "vfkit has correct entitlements (virtualization, network.server, network.client)"

    # Compose file
    assert_exists "$APP/Contents/Resources/docker-compose.yml"
    pass "Contents/Resources/docker-compose.yml exists"

    # Info.plist
    assert_exists "$APP/Contents/Info.plist"
    assert_plist_contains "$APP/Contents/Info.plist" "CFBundleIdentifier" "com.containerfy.test-app"
    assert_plist_contains "$APP/Contents/Info.plist" "CFBundleName"       "test-app"
    assert_plist_contains "$APP/Contents/Info.plist" "CFBundleVersion"    "0.1.0"
    pass "Info.plist contains expected metadata"

    # Codesign verification
    if codesign --verify --deep --strict "$APP" 2>/dev/null; then
        pass "codesign --verify passes"
    else
        fail "codesign --verify failed"
    fi
fi

if [ ! -d "$APP" ]; then
    fail "App bundle not found: $APP"
fi

# ==================================================================
# Phase 6: Launch
# ==================================================================
info "Launching $APP..."
open "$APP"

# Give the app a moment to register
sleep 2

APP_PID=$(pgrep -f "TestApp.app/Contents/MacOS/Containerfy" || true)
if [ -n "$APP_PID" ]; then
    pass "App launched (PID $APP_PID)"
else
    echo "  Warning: could not determine app PID"
fi

# ==================================================================
# Phase 7: Wait for running state
# ==================================================================
info "Waiting for app to reach 'running' state (timeout ${VM_TIMEOUT}s)..."

wait_for_state() {
    local timeout="$1"
    local elapsed=0

    while [ $elapsed -lt "$timeout" ]; do
        if [ -f "$STATE_FILE" ]; then
            local state
            state=$(python3 -c "
import json, sys
try:
    with open('$STATE_FILE') as f:
        d = json.load(f)
    print(d.get('vmState', ''))
except:
    print('')
" 2>/dev/null)

            if [ "$state" = "running" ]; then
                return 0
            elif [ "$state" = "error" ]; then
                echo "  App entered error state!"
                python3 -c "
import json
with open('$STATE_FILE') as f:
    d = json.load(f)
print(json.dumps(d, indent=2))
" 2>/dev/null || true
                return 1
            fi
            echo "  state=$state (${elapsed}s)..."
        else
            echo "  waiting for state file (${elapsed}s)..."
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    return 1
}

if wait_for_state "$VM_TIMEOUT"; then
    pass "App is running"
else
    fail "App did not reach 'running' state within ${VM_TIMEOUT}s"
fi

# ==================================================================
# Phase 8: Wait for port
# ==================================================================
info "Waiting for http://127.0.0.1:8080 to respond (timeout ${PORT_TIMEOUT}s)..."

wait_for_port() {
    local timeout="$1"
    local elapsed=0

    while [ $elapsed -lt "$timeout" ]; do
        if curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080 2>/dev/null | grep -q "200"; then
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        if [ $((elapsed % 10)) -eq 0 ]; then
            echo "  waiting (${elapsed}s)..."
        fi
    done

    return 1
}

if wait_for_port "$PORT_TIMEOUT"; then
    pass "Port 8080 is responding"
else
    fail "Port 8080 did not respond within ${PORT_TIMEOUT}s"
fi

# ==================================================================
# Phase 9: Verify response
# ==================================================================
info "Verifying HTTP response..."
RESPONSE=$(curl -s http://127.0.0.1:8080)

if echo "$RESPONSE" | grep -qi "welcome to nginx"; then
    pass "Response contains nginx welcome page"
else
    echo "  Response body:"
    echo "$RESPONSE" | head -20
    fail "Response does not contain 'Welcome to nginx'"
fi

# ==================================================================
# Phase 10: Shutdown
# ==================================================================
info "Shutting down app..."

osascript -e 'quit app "test-app"' 2>/dev/null || true

SHUTDOWN_TIMEOUT=60
elapsed=0
while [ $elapsed -lt $SHUTDOWN_TIMEOUT ]; do
    if ! pgrep -f "TestApp.app/Contents/MacOS/Containerfy" >/dev/null 2>&1; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ $elapsed -ge $SHUTDOWN_TIMEOUT ]; then
    echo "  Graceful shutdown timed out, force killing..."
    pkill -9 -f "TestApp.app/Contents/MacOS/Containerfy" 2>/dev/null || true
    sleep 2
fi

pass "App shut down"

# ==================================================================
# Phase 11: Verify clean exit
# ==================================================================
info "Verifying clean exit..."
sleep 2

if [ ! -f "$STATE_FILE" ]; then
    pass "state.json removed (clean exit)"
else
    echo "  state.json still exists:"
    python3 -c "
import json
with open('$STATE_FILE') as f:
    print(json.dumps(json.load(f), indent=2))
" 2>/dev/null || true
    fail "state.json was not removed on exit"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
info "All E2E checks passed!"
