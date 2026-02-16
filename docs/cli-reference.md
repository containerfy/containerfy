# CLI Reference

The same Swift binary serves dual roles: CLI tool for developers (`containerfy pack`) and GUI app for end users. When invoked with `containerfy pack`, it runs in CLI mode (no NSApplication). Otherwise it launches the menu bar GUI.

## `containerfy pack`

```
containerfy pack [flags]
```

| Flag | Default | Description |
|---|---|---|
| `--compose <path>` | `./docker-compose.yml` | Path to compose file |
| `--output <path>` | `./<name>` (from `x-containerfy.name`) | Output path (produces `.app` or `.app` + `.dmg`) |
| `--signed <keychain-profile>` | *(unsigned)* | Sign `.app`, create `.dmg`, notarize, and staple. Requires a Developer ID certificate. |

### What `pack` Does

1. Parses `docker-compose.yml` — validates `x-containerfy` block, rejects [hard-rejected keywords](compose-reference.md#hard-rejected-keywords)
2. Assembles the `.app` bundle: copies compose file, env files, generates `Info.plist`, embeds itself as the app binary
3. Embeds bundled helper binaries (podman, gvproxy, vfkit) into `.app/Contents/MacOS/`
4. Signs vfkit with required entitlements (virtualization, network.server, network.client)
5. If `--signed`: signs `.app` with Hardened Runtime, creates `.dmg`, submits for notarization, staples ticket

### Unsigned Build (Default)

Produces `.app` only. No signing, no `.dmg`. Useful for local testing. End users will see a Gatekeeper warning.

```bash
containerfy pack --compose ./docker-compose.yml
```

### Signed Build

Auto-detects Developer ID signing identity (prompts if multiple found), signs `.app` with Hardened Runtime and entitlements (`codesign --force --sign <hash> --options runtime --timestamp --deep`), verifies signature (`codesign --verify --deep --strict`), creates compressed `.dmg` with Applications symlink (`hdiutil create -format UDZO`), signs the `.dmg`, submits for notarization (`xcrun notarytool submit --keychain-profile <profile> --wait`), and staples the ticket (`xcrun stapler staple` — non-fatal on failure, Gatekeeper verifies online).

```bash
containerfy pack --compose ./docker-compose.yml --signed <keychain-profile>
```

### One-Time Credential Setup

```bash
xcrun notarytool store-credentials <profile-name>
# Prompts for Apple ID, team ID, and app-specific password
# Credentials are stored in the macOS keychain
```

## `containerfy --help`

Shows available commands. With no arguments, launches the GUI menu bar app.

## `.app` Bundle Layout

The `.app` bundle produced by `containerfy pack`:

```
MyApp.app/Contents/
├── MacOS/
│   ├── Containerfy           # Generic Swift binary (same for all appliances)
│   ├── podman                # Podman CLI (manages machine + compose)
│   ├── gvproxy               # Virtual networking (DHCP, DNS, NAT, port forwarding)
│   └── vfkit                 # Hypervisor (Apple Virtualization.framework)
├── Resources/
│   ├── docker-compose.yml    # Compose file (includes x-containerfy config)
│   └── *.env                 # Any env files referenced by env_file: (if present)
└── Info.plist
```

Entitlements are embedded in the code signature at build time, not shipped as a file.
