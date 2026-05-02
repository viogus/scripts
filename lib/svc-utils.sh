#!/bin/sh
# =========================================
# 共享 Init/Service 工具库
# =========================================

_INIT_TYPE=""
detect_init() {
    if [ -n "$_INIT_TYPE" ]; then echo "$_INIT_TYPE"; return; fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        _INIT_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        _INIT_TYPE="openrc"
    else
        _INIT_TYPE="systemd"
    fi
    echo "$_INIT_TYPE"
}

detect_os() {
    if grep -qi "alpine" /etc/os-release 2>/dev/null; then echo "alpine"
    elif grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then echo "debian"
    elif grep -qi "centos\|red hat\|rhel\|alma\|rocky\|fedora\|amazon" /etc/os-release 2>/dev/null; then echo "rhel"
    else echo "unknown"; fi
}

svc_start()   { if [ "$(detect_init)" = "openrc" ]; then rc-service "$1" start; else systemctl start "$1"; fi; }
svc_stop()    { if [ "$(detect_init)" = "openrc" ]; then rc-service "$1" stop 2>/dev/null || true; else systemctl stop "$1" 2>/dev/null || true; fi; }
svc_restart() { if [ "$(detect_init)" = "openrc" ]; then rc-service "$1" restart; else systemctl restart "$1"; fi; }
svc_enable()  { if [ "$(detect_init)" = "openrc" ]; then rc-update add "$1" default >/dev/null 2>&1 || true; else systemctl enable "$1" >/dev/null 2>&1 || true; fi; }
svc_disable() { if [ "$(detect_init)" = "openrc" ]; then rc-update del "$1" default >/dev/null 2>&1 || true; else systemctl disable "$1" 2>/dev/null || true; fi; }

# MUST output "active"/"inactive" text AND return 0/1 exit code
svc_is_active() {
    if [ "$(detect_init)" = "openrc" ]; then
        if rc-service "$1" status >/dev/null 2>&1; then echo "active"; else echo "inactive"; return 1; fi
    else
        if systemctl is-active --quiet "$1" 2>/dev/null; then echo "active"; else echo "inactive"; return 1; fi
    fi
}

svc_status() {
    if [ "$(detect_init)" = "openrc" ]; then
        rc-service "$1" status 2>/dev/null || true
    else
        systemctl status "$1" --no-pager 2>/dev/null || true
    fi
}
svc_reload()  { if [ "$(detect_init)" != "openrc" ]; then systemctl daemon-reload; fi; }
svc_main_pid() {
    if [ "$(detect_init)" = "openrc" ]; then
        cat "/run/${1}.pid" 2>/dev/null || echo "0"
    else
        systemctl show -p MainPID "$1" 2>/dev/null | cut -d= -f2
    fi
}

svc_file_path() {
    if [ -f "/etc/init.d/${1}" ]; then echo "/etc/init.d/${1}"
    elif [ -f "/etc/systemd/system/${1}.service" ]; then echo "/etc/systemd/system/${1}.service"
    else echo ""; fi
}
svc_find_services() { find /etc/systemd/system /etc/init.d -name "$1" 2>/dev/null || true; }
svc_list()          { ls /etc/systemd/system/"$1"*.service /etc/init.d/"$1"* 2>/dev/null | sed 's|.*/||; s/\.service$//' | sort -u; }
svc_cat()  { if [ "$(detect_init)" = "openrc" ]; then cat "/etc/init.d/$1" 2>/dev/null; else systemctl cat "$1" 2>/dev/null; fi; }

install_pkg() {
    local os; os=$(detect_os)
    case "$os" in
        debian) apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        rhel)   dnf install -y "$@" 2>/dev/null || yum install -y "$@" ;;
        alpine) apk add --no-cache "$@" ;;
        *)      return 1 ;;
    esac
}
