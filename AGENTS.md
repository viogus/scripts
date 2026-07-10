# scripts — Project Guide

## FHS Compliance (MANDATORY)

All file paths must follow [FHS 3.0](https://refspecs.linuxfoundation.org/FHS_3.0/index.html):

| Type | Path | Example |
|------|------|---------|
| Binaries | `/usr/local/bin/` | `/usr/local/bin/snell-server` |
| Configs | `/usr/local/etc/<service>/` | `/usr/local/etc/frp/frps.toml` |
| Init scripts (systemd) | `/etc/systemd/system/` | `/etc/systemd/system/snell.service` |
| Init scripts (OpenRC) | `/etc/init.d/` | `/etc/init.d/snell` |
| Runtime data (pids) | `/run/` | `/run/snell.pid` |
| Logs | `/var/log/` | `/var/log/snell.log` |

Never put binaries, configs, or data in `/usr/local/<service>/` — split by type, not by service.

## Alpine / OpenRC

- Init dependency: `depend() { need networking }` — not `need net`
- Package manager: `apk add --no-cache`

## Script Conventions

- Shebang: `#!/usr/bin/env bash`
- `set -euo pipefail` required
- Version fallback MUST warn to stderr (`>&2`)
- Color vars: `RED GREEN YELLOW CYAN BLUE RESET`
- Print helpers: `print_ok print_info print_error print_warn`
- `detect_init()` returns `systemd` or `openrc`
- `detect_os()` returns `debian` `rhel` or `alpine`
