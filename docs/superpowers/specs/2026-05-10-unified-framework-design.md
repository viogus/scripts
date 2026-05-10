# Unified Script Framework Design

## Goal

Replace 7 standalone shell scripts (~6800 lines) with a single framework (`lib/framework.sh`) driven by declarative per-service config files (`services/*.conf`). All service operations (install, update, uninstall, status, config) share one code path. Adding a new service is writing a 20-line `.conf` instead of copying 500+ lines of shell.

## Architecture

```
menu.sh                     # Single entry point (the only UI)
lib/framework.sh            # Shared framework: install/update/uninstall/status/config
lib/svc-utils.sh            # Low-level utilities: detect_init, svc_*, get_ip, colors
services/                   # Service definitions (declarative .conf files)
├── anytls.conf
├── hysteria2.conf
├── ss-2022.conf
├── snell.conf
├── shadowtls.conf
└── vless.conf
```

**menu.sh** scans `services/*.conf`, generates the menu, and delegates to framework.sh.

## Config Schema

Each service is a `.conf` file sourced by framework.sh. Fields:

```bash
# ---- Identity ----
SERVICE="anytls"              # internal name (no spaces)
DISPLAY="AnyTLS"              # user-facing display name
MENU_ORDER=5                  # menu position

# ---- Download ----
SOURCE="github"               # github | direct_url | script
GITHUB_REPO="anytls/anytls-go"
BINARY_NAME="anytls-server"
ARCHIVE_FORMAT="zip"          # zip | tar.xz

# ---- Paths ----
BIN_PATH="/usr/local/bin/anytls-server"
CONF_DIR="/usr/local/etc/anytls"
CONF_FILE="/usr/local/etc/anytls/config.yaml"
CLIENT_FILE="/usr/local/etc/anytls/anytls.txt"

# ---- Config template ----
PORT_RANGE="2000-65000"       # random port range
PASS_TYPE="uuid"              # uuid | base64 | random
CONF_TEMPLATE="listen: 0.0.0.0:{port}\npassword: {pass}\n"
CLIENT_URL_FMT="anytls://{pass}@{ip}:{port}/?insecure=1#AT_Proxy"
CLIENT_SURGE_FMT="Proxy-AnyTLS = anytls, {ip}, {port}, password={pass}"

# ---- Service ----
COMMAND_ARGS="-l 0.0.0.0:{port} -p {pass}"
COMMAND_USER="nobody"
EXTRA_DEPS=""                 # extra apk/apt packages

# ---- Dependencies (optional) ----
DEPENDS_ON=""                 # service name this depends on
BACKEND_PORT_FROM=""          # read backend port from this service's config
```

### Config field reference

| Field | Required | Description |
|-------|----------|-------------|
| SERVICE | yes | Machine name, used for init file names `/etc/init.d/{SERVICE}` |
| DISPLAY | yes | Human-readable name for menus |
| MENU_ORDER | yes | Sort key in menu |
| SOURCE | yes | Download source type |
| GITHUB_REPO | if SOURCE=github | `owner/repo` for GitHub Releases API |
| BINARY_NAME | if SOURCE=github/direct | Binary filename after extraction |
| ARCHIVE_FORMAT | if SOURCE=github | Archive format |
| BIN_PATH | yes | Final binary install path |
| CONF_DIR | yes | Config directory |
| CONF_FILE | yes | Config file path |
| CLIENT_FILE | no | Path to save client export info |
| PORT_RANGE | yes | `min-max` for `shuf` |
| PASS_TYPE | yes | Password generation method |
| CONF_TEMPLATE | yes | Config template, `{port}` and `{pass}` replaced at write time |
| CLIENT_URL_FMT | no | URL format string for client export |
| CLIENT_SURGE_FMT | no | Surge format string for client export |
| COMMAND_ARGS | yes | Arguments passed to binary, `{port}` `{pass}` replaced |
| COMMAND_USER | yes | User for service execution |
| EXTRA_DEPS | no | Space-separated extra packages for Alpine/Debian |
| DEPENDS_ON | no | Service name this depends on |
| BACKEND_PORT_FROM | no | Read port from this dependent service's config |

## Framework Functions

All in `lib/framework.sh`, each takes a config file path as argument.

| Function | Signature | Logic |
|----------|-----------|-------|
| `svc_status` | `($conf)` | Check binary exists → check init file exists → svc_is_active → print status + CPU/MEM |
| `svc_install` | `($conf)` | Check deps → install system deps → firewall notice → detect arch → get latest version → download → extract → install binary → interactive port/pass → write config → write init → enable → start → view config |
| `svc_update` | `($conf)` | Check installed → read current config → get latest version → download → replace binary → restart |
| `svc_uninstall` | `($conf)` | Confirm → stop service → disable service → remove init file → remove binary → remove config dir |
| `svc_view` | `($conf)` | Read config → print URL + Surge format → write client file |
| `svc_port` | `($conf)` | Read current config → interactive port → rewrite config → update init → restart |
| `svc_pass` | `($conf)` | Read current config → generate new pass → rewrite config → update init → restart |
| `svc_config` | `($conf)` | Interactive modify all fields (port/pass/method/tfo/dns) → rewrite config → restart |

### Install flow detail

```
svc_install $conf
  1. Source $conf, load all vars
  2. If DEPENDS_ON: check dependent service installed, error if not
  3. os_install (unified: apk add / apt-get / dnf with ca-certificates curl unzip + EXTRA_DEPS)
  4. close_wall (firewall detection + port notice)
  5. detect_arch → construct download URL from SOURCE type
  6. get_latest_version (GitHub Releases API) if SOURCE=github
  7. Download archive → extract → find binary → install -D -m755 to BIN_PATH
  8. Verify BIN_PATH is executable, error if not
  9. Interactive: read port (PORT_RANGE), generate password (PASS_TYPE)
  10. Template replace {port} {pass} in CONF_TEMPLATE → write CONF_FILE
  11. If BACKEND_PORT_FROM: read dependent config, use that port for backend args
  12. write_init (openrc or systemd from COMMAND_ARGS template)
  13. mkdir -p /var/log/{SERVICE}.log etc and chown nobody
  14. svc_reload, svc_enable, svc_start
  15. Sleep 2, check svc_is_active
  16. If active: print success + svc_view, else: print error + tail logs
```

## OpenRC Init Template (framework.sh)

```bash
write_openrc() {
    local name=$1 cmd=$2 args=$3 user=$4
    cat > "/etc/init.d/${name}" << EOF
#!/sbin/openrc-run
name="${name}"
command="${cmd}"
command_user="${user}"
command_args="${args}"
command_background="yes"
pidfile="/run/${name}.pid"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.err"
EOF
    chmod +x "/etc/init.d/${name}"
    touch "/var/log/${name}.log" "/var/log/${name}.err"
    chown "${user}:${user}" "/var/log/${name}.log" "/var/log/${name}.err" 2>/dev/null || \
        chown "${user}" "/var/log/${name}.log" "/var/log/${name}.err" 2>/dev/null || true
}
```

## Systemd Template (framework.sh)

Standard template with Type=simple, User=nobody, AmbientCapabilities=CAP_NET_BIND_SERVICE, Restart=on-failure, LimitNOFILE=65535.

## Migration Strategy

### Phase 1: Build new files, keep old code

- Create `lib/framework.sh`
- Create `services/anytls.conf`, `services/hysteria2.conf` (first two)
- Add a test menu entry "7. [新] 测试新模式" in menu.sh
- All existing scripts and menu entries remain untouched

### Phase 2: Migrate per-service

Order: AnyTLS → Hysteria2 → VLESS → SS-2022 → ShadowTLS → Snell

- Write `.conf` for next service
- Replace old menu entry with new framework entry
- Mark old script as deprecated
- Test full lifecycle: install, status, restart, config change, uninstall

### Phase 3: Cleanup

- Delete all old standalone scripts
- Remove old menu entries
- menu.sh becomes thin: just `source lib/framework.sh` + scan loop

## Edge Cases

- **Alpine/BusyBox compat**: `ps -o rss=` and `ps -o %cpu=` for status display (already fixed in menu.sh), no `top -p`, no `journalctl`, use `install -D` for binary placement, musl libc detection for arch suffix
- **`set -e` guards**: `show_status` wrapped in `set +e`/`set -e` to prevent silent exit on Alpine bash
- **Snell multi-user**: Snell supports multiple instances on different ports; framework treats it as a single-instance service, multi-user left for a future `.conf` extension
- **ShadowTLS depends on SS-Rust or Snell**: `DEPENDS_ON` + `BACKEND_PORT_FROM` handles this; framework verifies dependency is installed before allowing ShadowTLS install

## Non-Goals (deferred)

- Snell multi-user management UI
- VLESS's custom install script (`SOURCE="script"`) - VLESS will keep `SOURCE="script"` with `INSTALL_SCRIPT` field
- Performance monitoring dashboard
- Web UI
