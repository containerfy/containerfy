# Compose Reference

All Containerfy configuration lives inside the compose file using the standard `x-` extension mechanism. The compose file remains fully valid — `docker compose up` still works locally for development.

## `x-containerfy` Field Reference

```yaml
x-containerfy:
  name: "my-app"                     # [REQUIRED] string, 1-64 chars, [a-zA-Z0-9-]
  version: "1.0.0"                   # [REQUIRED] semver
  identifier: "com.example.myapp"    # [REQUIRED] unique ID (reverse-DNS, GitHub URL, etc.)
  display_name: "My App"             # [OPTIONAL] shown in menu bar, default: name title-cased
  icon: "icon.png"                   # [OPTIONAL] path relative to compose file

  vm:
    cpu:
      min: 2                         # [REQUIRED] 1-16
      recommended: 4                 # [OPTIONAL] >= min, default: min
    memory_mb:
      min: 2048                      # [REQUIRED] 512-32768
      recommended: 4096              # [OPTIONAL] >= min, default: min
    disk_mb: 10240                   # [REQUIRED] >= 1024

  healthcheck:
    url: "http://127.0.0.1:8080/health"  # [REQUIRED] must target 127.0.0.1
    interval_seconds: 10             # [OPTIONAL] 5-60, default: 10
    timeout_seconds: 5               # [OPTIONAL] 1-30, default: 5
    startup_timeout_seconds: 120     # [OPTIONAL] 30-600, default: 120
```

| Field | Required | Description |
|---|---|---|
| `name` | Yes | App name, 1-64 chars, `[a-zA-Z][a-zA-Z0-9-]*` |
| `version` | Yes | Semver string |
| `identifier` | Yes | Unique ID (reverse-DNS or GitHub URL) |
| `display_name` | No | Shown in menu bar (default: `name` title-cased) |
| `icon` | No | Path to icon file, relative to compose file |
| `vm.cpu.min` | Yes | Minimum CPU cores (1-16) |
| `vm.cpu.recommended` | No | Preferred cores, >= min (default: min) |
| `vm.memory_mb.min` | Yes | Minimum memory in MB (512-32768) |
| `vm.memory_mb.recommended` | No | Preferred memory, >= min (default: min) |
| `vm.disk_mb` | Yes | Disk size in MB (>= 1024) |
| `healthcheck.url` | Yes | HTTP URL on `127.0.0.1`; port must match a service `ports:` entry |
| `healthcheck.interval_seconds` | No | Poll interval, 5-60 (default: 10) |
| `healthcheck.timeout_seconds` | No | Request timeout, 1-30 (default: 5) |
| `healthcheck.startup_timeout_seconds` | No | Max wait for first healthy response, 30-600 (default: 120) |

## Validation Rules

Enforced by `containerfy pack` at build time:

| Field | Constraint |
|---|---|
| `name` | `^[a-zA-Z][a-zA-Z0-9-]{0,63}$` (leading alpha required) |
| `version` | Valid semver |
| `cpu.min` | 1-16, `recommended` >= `min` |
| `memory_mb.min` | 512-32768, `recommended` >= `min` |
| `disk_mb` | >= 1024 |
| `healthcheck.url` | Valid HTTP URL, host must be `127.0.0.1`, port must match a host port in some service's `ports:` mapping |
| At least one service | Must have `ports:` (otherwise nothing to expose) |

## Resource Allocation at Runtime

- **CPU**: `min(recommended, hostCores - 1)`, floored at `min`
- **Memory**: use `recommended` if host has 2x that free, otherwise use `min`

## Menu Item Generation

Services with `ports:` automatically become "Open" menu items:
- **Label**: service name, title-cased, hyphens/underscores replaced with spaces (`paperless` → "Paperless")
- **URL**: `http://127.0.0.1:<first host port>`
- Services without `ports:` are internal-only and don't appear in the menu

**Only expose ports for services the end user should see.** Internal services (databases, caches, queues) talk to each other by service name — no `ports:` needed, no port conflicts possible.

## Compose Passthrough Model

Containerfy passes the compose file to `podman compose up` inside the VM **unchanged**. The file is not rewritten, templated, or subset-filtered.

**Containerfy only parses these fields** (everything else is ignored and passed through):

| Field | Why Containerfy reads it |
|---|---|
| `services[*].image` | Pull images via `podman compose` at runtime |
| `services[*].ports` | Set up vsock/TCP port forwarding on the host; generate menu items |
| Top-level `volumes` | Named volumes managed by Podman inside the VM |
| `services[*].env_file` | Bundle referenced `.env` files into `.app` Resources alongside compose file |

### Hard-Rejected Keywords

Caught by `containerfy pack` at build time:

| Keyword | Reason |
|---|---|
| `build:` | No build context in the VM. Pre-built images only. |
| Bind mount volumes (e.g. `./data:/app/data`) | Host paths don't exist inside the VM. Named volumes only. |
| `extends:` | Requires resolving external files that may not be bundled. |
| `profiles:` | All services in the file are always started. No partial-stack support in v1. |
| `network_mode: host` | Service binds to VM network, invisible to vsock port forwarder. Breaks silently. |
| `env_file:` without bundled files | References must resolve inside VM. `containerfy pack` bundles referenced env files automatically; rejects if file not found. |

**Everything else passes through** — `command`, `entrypoint`, `depends_on`, `restart`, `networks`, `configs`, `secrets`, `labels`, `healthcheck`, `deploy`, `logging`, `cap_add`, `privileged`, `user`, `working_dir`, `stdin_open`, `tty`, etc. If Docker Compose supports it, it works.
