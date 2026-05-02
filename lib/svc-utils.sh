#!/bin/sh
# =========================================
# 共享工具库 — viogus/scripts
# 提供: init 检测、服务操作、OS 检测、IP 获取、通用工具
# 用法: source /path/to/lib/svc-utils.sh
# =========================================

# --- 颜色变量（统一方案） ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly BLUE='\033[0;34m'
readonly RESET='\033[0m'

# --- 通用工具 ---
has_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# --- IP 获取（HTTPS，超时保护） ---
get_ip() {
    local ip4 ip6
    ip4=$(curl -s --connect-timeout 5 --max-time 10 -4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [ -n "${ip4}" ] && { echo "${ip4}"; return; }
    ip6=$(curl -s --connect-timeout 5 --max-time 10 -6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [ -n "${ip6}" ] && { echo "${ip6}"; return; }
    curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "未知IP"
}

# --- Init 系统检测（结果缓存在 _INIT_TYPE） ---
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

# --- OS 检测 ---
detect_os() {
    if grep -qi "alpine" /etc/os-release 2>/dev/null; then echo "alpine"
    elif grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then echo "debian"
    elif grep -qi "centos\|red hat\|rhel\|alma\|rocky\|fedora\|amazon" /etc/os-release 2>/dev/null; then echo "rhel"
    else echo "unknown"; fi
}

# --- 服务操作包装器 ---
svc_start()   { if [ "$(detect_init)" = "openrc" ]; then rc-service "$1" start; else systemctl start "$1"; fi; }
svc_stop()    { if [ "$(detect_init)" = "openrc" ]; then rc-service "$1" stop 2>/dev/null || true; else systemctl stop "$1" 2>/dev/null || true; fi; }
svc_restart() { if [ "$(detect_init)" = "openrc" ]; then rc-service "$1" restart; else systemctl restart "$1"; fi; }
svc_enable()  { if [ "$(detect_init)" = "openrc" ]; then rc-update add "$1" default >/dev/null 2>&1 || true; else systemctl enable "$1" >/dev/null 2>&1 || true; fi; }
svc_disable() { if [ "$(detect_init)" = "openrc" ]; then rc-update del "$1" default >/dev/null 2>&1 || true; else systemctl disable "$1" 2>/dev/null || true; fi; }

svc_is_active() {
    if [ "$(detect_init)" = "openrc" ]; then
        if rc-service "$1" status >/dev/null 2>&1; then echo "active"; else echo "inactive"; return 1; fi
    else
        if systemctl is-active --quiet "$1" 2>/dev/null; then echo "active"; else echo "inactive"; return 1; fi
    fi
}

svc_status() {
    if [ "$(detect_init)" = "openrc" ]; then rc-service "$1" status 2>/dev/null || true
    else systemctl status "$1" --no-pager 2>/dev/null || true; fi
}

svc_reload()  { if [ "$(detect_init)" != "openrc" ]; then systemctl daemon-reload; fi; }

svc_main_pid() {
    if [ "$(detect_init)" = "openrc" ]; then cat "/run/${1}.pid" 2>/dev/null || echo "0"
    else systemctl show -p MainPID "$1" 2>/dev/null | cut -d= -f2; fi
}

svc_file_path() {
    if [ -f "/etc/init.d/${1}" ]; then echo "/etc/init.d/${1}"
    elif [ -f "/etc/systemd/system/${1}.service" ]; then echo "/etc/systemd/system/${1}.service"
    else echo ""; fi
}

svc_find_services() { find /etc/systemd/system /etc/init.d -name "$1" 2>/dev/null || true; }
svc_list()          { ls /etc/systemd/system/"$1"*.service /etc/init.d/"$1"* 2>/dev/null | sed 's|.*/||; s/\.service$//' | sort -u; }
svc_cat()  { if [ "$(detect_init)" = "openrc" ]; then cat "/etc/init.d/$1" 2>/dev/null; else systemctl cat "$1" 2>/dev/null; fi; }

# --- 包管理器安装 ---
install_pkg() {
    local os; os=$(detect_os)
    case "$os" in
        debian) apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        rhel)   dnf install -y "$@" 2>/dev/null || yum install -y "$@" ;;
        alpine) apk add --no-cache "$@" ;;
        *)      return 1 ;;
    esac
}
