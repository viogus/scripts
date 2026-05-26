#!/usr/bin/env bash
# =========================================
# 作者: viogus
# 日期: 2026年5月
# 网站：github.com/viogus
# 描述: NodeGet 一键管理脚本（Server 服务端 / Agent 客户端）
# 适配: Debian/Ubuntu (apt) / RHEL系 (dnf/yum) / Alpine (apk) / OpenWrt
# init: systemd / openrc / procd (OpenWrt)
# =========================================
set -euo pipefail

# ============================================
# 常量 (FHS 3.0)
# ============================================
NG_CONF_DIR="/usr/local/etc/nodeget"
NG_SERVER_BIN="/usr/local/bin/nodeget-server"
NG_AGENT_BIN="/usr/local/bin/nodeget-agent"
NG_SERVER_CONF="${NG_CONF_DIR}/nodeget-server.toml"
NG_AGENT_CONF="${NG_CONF_DIR}/nodeget-agent.toml"
NG_SERVER_DATA="/var/lib/nodeget-server"
NG_AGENT_DATA="/var/lib/nodeget-agent"
NG_SERVER_LOG="/var/log/nodeget-server.log"
NG_AGENT_LOG="/var/log/nodeget-agent.log"
NG_SERVER_PID="/run/nodeget-server.pid"
NG_AGENT_PID="/run/nodeget-agent.pid"
NG_SERVER_SERVICE="nodeget-server"
NG_AGENT_SERVICE="nodeget-agent"
NG_REPO="GenshinMinecraft/NodeGet"
NG_SCRIPT_VERSION="1.0.0"

# ============================================
# 颜色 & 工具函数 (与 menu.sh 兼容，独立运行时自给)
# ============================================
if [ -z "${RED:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
fi

OK="${GREEN}[OK]${RESET}"
ERROR="${RED}[ERROR]${RESET}"
WARN="${YELLOW}[WARN]${RESET}"
INFO="${CYAN}[INFO]${RESET}"

print_ok(){ echo -e "${OK}${BLUE} $1 ${RESET}"; }
print_info(){ echo -e "${INFO}${CYAN} $1 ${RESET}"; }
print_error(){ echo -e "${ERROR} $1 ${RESET}"; }
print_warn(){ echo -e "${WARN} $1 ${RESET}"; }

# 尝试 source menu.sh 的共享函数，失败则使用内置实现
if declare -f detect_os &>/dev/null; then
    # 从 menu.sh 继承，复用其函数
    :
else
    has_cmd() { command -v "$1" >/dev/null 2>&1; }
    ensure_root() {
        if [ "${EUID:-$(id -u)}" -ne 0 ]; then
            echo -e "${RED}请以 root 权限运行此脚本${RESET}"
            exit 1
        fi
    }
    detect_os() {
        if grep -qi "openwrt" /etc/os-release 2>/dev/null; then echo "openwrt"
        elif grep -qi "alpine" /etc/os-release 2>/dev/null; then echo "alpine"
        elif grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then echo "debian"
        elif grep -qi "centos\|red hat\|rhel\|alma\|rocky\|fedora\|amazon" /etc/os-release 2>/dev/null; then echo "rhel"
        else echo "unknown"; fi
    }
    _INIT_TYPE=""
    detect_init() {
        if [ -n "${_INIT_TYPE:-}" ]; then echo "$_INIT_TYPE"; return; fi
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            _INIT_TYPE="systemd"
        elif command -v rc-service >/dev/null 2>&1; then
            _INIT_TYPE="openrc"
        elif [ -f /etc/rc.common ] && command -v ubus >/dev/null 2>&1; then
            _INIT_TYPE="procd"
        elif [ -d /etc/init.d ]; then
            _INIT_TYPE="sysvinit"
        else
            _INIT_TYPE="systemd"
        fi
        echo "$_INIT_TYPE"
    }
fi

trap 'echo -e "${WARN} 已中断"; exit 1' INT

# ============================================
# 检测架构 & libc
# ============================================

get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l)         echo "armv7" ;;
        armv6l)         echo "arm" ;;
        i386|i686)      echo "i686" ;;
        *) print_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}

get_libc() {
    if ldd --version 2>&1 | grep -qi musl; then
        echo "musl"
        return
    fi
    # glibc 版本检查，< 2.25 退回 musl
    local glibc_ver
    glibc_ver=$(ldd --version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || echo "0")
    local lowest
    lowest=$(printf '%s\n%s\n' "2.25" "$glibc_ver" | sort -V | head -n1)
    if [ "$lowest" != "2.25" ]; then
        echo "musl"
    else
        echo "gnu"
    fi
}

# ARM 硬浮点检测
has_hardfloat() {
    ldd --version 2>&1 | grep -qi 'hard float'
}

get_target() {
    local arch; arch=$(get_arch)
    local libc; libc=$(get_libc)

    case "$arch" in
        armv7)
            if [ "$libc" = "gnu" ]; then
                echo "armv7-gnueabi"
            elif has_hardfloat; then
                echo "armv7-musleabihf"
            else
                echo "armv7-musleabi"
            fi
            ;;
        arm)
            if [ "$libc" = "gnu" ]; then
                echo "arm-gnueabi"
            elif has_hardfloat; then
                echo "arm-musleabihf"
            else
                echo "arm-musleabi"
            fi
            ;;
        *)
            echo "${arch}-${libc}"
            ;;
    esac
}

# ============================================
# 版本 & 下载
# ============================================

get_latest_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${NG_REPO}/releases/latest" 2>/dev/null \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([0-9.]+)".*/\1/p' \
        | head -1) || true
    if [ -z "$ver" ]; then
        ver="0.4.0"
        print_warn "无法获取最新版本号，使用默认版本: v${ver}"
    fi
    echo "$ver"
}

download_binary() {
    local component="$1"   # server or agent
    local ver="$2"
    local target="$3"
    local dest="$4"

    local fname="nodeget-${component}-linux-${target}"
    local url="https://github.com/${NG_REPO}/releases/download/v${ver}/${fname}"

    print_info "下载 ${fname} (v${ver})..."

    local tmp; tmp=$(mktemp -d)
    if curl -L --connect-timeout 10 --max-time 300 -o "${tmp}/${fname}" "$url" 2>/dev/null; then
        install -m 0755 "${tmp}/${fname}" "$dest"
        rm -rf "$tmp"
        print_ok "二进制安装完成: ${dest}"
    else
        rm -rf "$tmp"
        # 尝试 install.nodeget.com 代理
        print_warn "GitHub 直连失败，尝试代理..."
        local proxy_url="https://install.nodeget.com/releases/${fname}?tag=v${ver}"
        if curl -L --connect-timeout 10 --max-time 300 -o "${dest}" "$proxy_url" 2>/dev/null; then
            chmod +x "$dest"
            print_ok "二进制安装完成 (代理): ${dest}"
        else
            print_error "下载失败，请检查网络"
            exit 1
        fi
    fi
}

# ============================================
# init 模板
# ============================================

write_systemd() {
    local name="$1" bin="$2" args="$3" log="$4"
    cat > "/etc/systemd/system/${name}.service" << SYSTEMDEOF
[Unit]
Description=NodeGet ${name} Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${bin} ${args}
Restart=always
RestartSec=5
StandardOutput=append:${log}
StandardError=append:${log}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
}

write_openrc() {
    local name="$1" bin="$2" args="$3" log="$4" pid="$5" data="$6"
    local pid_dir; pid_dir=$(dirname "$pid")
    cat > "/etc/init.d/${name}" << OPENRCEOF
#!/sbin/openrc-run
name="${name}"
description="NodeGet ${name} service"
command="${bin}"
command_args="${args}"
command_background="yes"
pidfile="${pid}"
output_log="${log}"
error_log="${log}"

depend() {
    need networking
}

start_pre() {
    checkpath --directory --mode 0755 ${pid_dir}
    checkpath --directory --mode 0755 ${data}
}
OPENRCEOF
    chmod +x "/etc/init.d/${name}"
}

write_procd() {
    local name="$1" bin="$2" args="$3"
    # args 中的 -c /path 需要拆分，procd 用 procd_append_param command
    # 将 bin 和 args 拆分到 procd_set_param command 中
    cat > "/etc/init.d/${name}" << PROCDEOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95

start_service() {
    procd_open_instance
    procd_set_param command ${bin}
    procd_append_param command ${args}
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    :
}
PROCDEOF
    chmod +x "/etc/init.d/${name}"
}

# ============================================
# 安装服务
# ============================================

install_service() {
    local name="$1" bin="$2" args="$3" log="$4" pid="$5" data="$6"
    local init; init=$(detect_init)

    mkdir -p "$(dirname "$log")" "$(dirname "$pid")" "$data"
    touch "$log"

    case "$init" in
        systemd)
            write_systemd "$name" "$bin" "$args" "$log"
            systemctl daemon-reload
            systemctl enable "$name" >/dev/null 2>&1 || true
            systemctl restart "$name" || systemctl start "$name"
            if systemctl is-active --quiet "$name" 2>/dev/null; then
                print_ok "${name} 服务已启动 (systemd)"
            else
                print_warn "${name} 启动可能失败，请检查: systemctl status ${name}"
            fi
            ;;
        openrc)
            write_openrc "$name" "$bin" "$args" "$log" "$pid" "$data"
            rc-update add "$name" default >/dev/null 2>&1 || true
            rc-service "$name" restart 2>/dev/null || rc-service "$name" start 2>/dev/null || true
            if rc-service "$name" status >/dev/null 2>&1; then
                print_ok "${name} 服务已启动 (OpenRC)"
            else
                print_warn "${name} 启动可能失败，请检查: rc-service ${name} status"
            fi
            ;;
        procd)
            write_procd "$name" "$bin" "$args"
            # OpenWrt: enable and start
            /etc/init.d/${name} enable 2>/dev/null || true
            /etc/init.d/${name} start 2>/dev/null || true
            if /etc/init.d/${name} running 2>/dev/null; then
                print_ok "${name} 服务已启动 (procd)"
            else
                print_warn "${name} 启动可能失败，请检查: /etc/init.d/${name} status"
            fi
            ;;
        sysvinit)
            print_warn "SysV init 支持有限，请手动配置启动脚本"
            print_info "二进制已安装: ${bin}"
            print_info "手动启动: ${bin} ${args}"
            ;;
        *)
            print_error "不支持的 init 系统: ${init}"
            exit 1
            ;;
    esac
}

remove_service() {
    local name="$1"
    local init; init=$(detect_init)
    case "$init" in
        systemd)
            systemctl stop "$name" 2>/dev/null || true
            systemctl disable "$name" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${name}.service"
            systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc)
            rc-service "$name" stop 2>/dev/null || true
            rc-update del "$name" default >/dev/null 2>&1 || true
            rm -f "/etc/init.d/${name}"
            ;;
        procd)
            /etc/init.d/${name} stop 2>/dev/null || true
            /etc/init.d/${name} disable 2>/dev/null || true
            rm -f "/etc/init.d/${name}"
            ;;
        sysvinit)
            service "$name" stop 2>/dev/null || true
            rm -f "/etc/init.d/${name}"
            ;;
    esac
}

svc_op() {
    local name="$1" op="$2"
    local init; init=$(detect_init)
    case "$op" in
        start)
            case "$init" in
                systemd) systemctl start "$name" ;;
                openrc)  rc-service "$name" start ;;
                procd)   /etc/init.d/${name} start ;;
            esac ;;
        stop)
            case "$init" in
                systemd) systemctl stop "$name" ;;
                openrc)  rc-service "$name" stop ;;
                procd)   /etc/init.d/${name} stop ;;
            esac ;;
        restart)
            case "$init" in
                systemd) systemctl restart "$name" ;;
                openrc)  rc-service "$name" restart ;;
                procd)   /etc/init.d/${name} restart ;;
            esac ;;
        status)
            case "$init" in
                systemd) systemctl status "$name" --no-pager 2>/dev/null || true ;;
                openrc)  rc-service "$name" status 2>/dev/null || true ;;
                procd)   /etc/init.d/${name} status 2>/dev/null || true ;;
            esac ;;
    esac
}

# ============================================
# 生成默认配置
# ============================================

write_server_config() {
    local ws_listener="$1" server_uuid="$2" db_url="$3" tls_cert="$4" tls_key="$5"
    mkdir -p "${NG_CONF_DIR}" "${NG_SERVER_DATA}"

    cat > "${NG_SERVER_CONF}" << NGSEOF
log_level = "warn"

ws_listener = "${ws_listener}"

jsonrpc_max_connections = 200
jsonrpc_timing_log_level = "warn"

enable_unix_socket = false

server_uuid = "${server_uuid}"

tls_cert = "${tls_cert}"
tls_key = "${tls_key}"

static_path = "${NG_SERVER_DATA}/static/"

[database]
database_url = "${db_url}"
sqlx_log_level = "warn"
connect_timeout_ms = 3000
acquire_timeout_ms = 3000
idle_timeout_ms = 3000
max_lifetime_ms = 30000
max_connections = 20
NGSEOF
}

write_agent_config() {
    local server_name="$1" server_uuid="$2" token="$3" ws_url="$4" agent_uuid="$5" ignore_cert="$6"
    mkdir -p "${NG_CONF_DIR}" "${NG_AGENT_DATA}"

    cat > "${NG_AGENT_CONF}" << NGAEOF
log_level = "info"

dynamic_summary_report_interval_ms = 1000
dynamic_report_interval_ms = 1000
static_report_interval_ms = 300000

agent_uuid = "${agent_uuid}"

connect_timeout_ms = 5000

terminal_shell = "bash"

exec_max_character = 30000

ip_provider = "cloudflare"

[[server]]
name = "${server_name}"
server_uuid = "${server_uuid}"
token = "${token}"
ws_url = "${ws_url}"
allow_task = true
allow_task_type = [
    "http_ping",
    "web_shell",
    "read_config",
    "execute",
    "self_update",
    "ip",
    "version",
    "edit_config",
    "http_request",
    "ping",
    "tcp_ping",
    "dns",
]
ignore_cert = ${ignore_cert}
NGAEOF
}

# ============================================
# 安装 Server
# ============================================

install_server() {
    if [[ -x "${NG_SERVER_BIN}" ]] && [[ -f "${NG_SERVER_CONF}" ]]; then
        read -rp "nodeget-server 已安装，是否重装？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        remove_service "${NG_SERVER_SERVICE}"
    fi

    local ver; ver=$(get_latest_version)
    local target; target=$(get_target)
    print_info "系统架构: ${target}, 版本: v${ver}"

    download_binary "server" "$ver" "$target" "${NG_SERVER_BIN}"

    echo ""
    local ws_listener server_uuid db_url tls_auto tls_cert tls_key

    read -rp "WS 监听地址 [0.0.0.0:2211]: " ws_listener
    ws_listener="${ws_listener:-0.0.0.0:2211}"

    read -rp "Server UUID (留空自动生成): " server_uuid
    server_uuid="${server_uuid:-auto_gen}"

    read -rp "Postgres 数据库 URL (留空使用 SQLite): " db_url
    if [ -z "$db_url" ]; then
        db_url="sqlite://${NG_SERVER_DATA}/nodeget-server.db?mode=rwc"
    fi

    read -rp "自动生成自签名 TLS 证书？(y/N): " tls_auto
    tls_auto="${tls_auto:-n}"

    if [[ "$tls_auto" == "y" || "$tls_auto" == "Y" ]]; then
        tls_cert="${NG_SERVER_DATA}/ssl/nodeget_cert.pem"
        tls_key="${NG_SERVER_DATA}/ssl/nodeget_key.pem"
        mkdir -p "$(dirname "$tls_cert")"
        if [ -f "$tls_cert" ] && [ -f "$tls_key" ]; then
            print_warn "TLS 证书已存在，跳过生成"
        else
            print_info "生成自签名 TLS 证书..."
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout "$tls_key" -out "$tls_cert" \
                -days 3650 -subj "/CN=localhost" 2>/dev/null
        fi
    else
        tls_cert=""
        tls_key=""
    fi

    print_info "写入配置..."
    write_server_config "$ws_listener" "$server_uuid" "$db_url" "$tls_cert" "$tls_key"

    # 初始化数据库
    print_info "初始化 Server..."
    local init_out; init_out=$("${NG_SERVER_BIN}" init -c "${NG_SERVER_CONF}" 2>&1) || {
        print_error "Server 初始化失败"
        echo "$init_out"
        exit 1
    }

    local token account_password final_uuid
    token=$(echo "$init_out" | sed -nE 's/.*Super Token:\s*//p' | head -1)
    token="${token:-未知}"
    account_password=$(echo "$init_out" | sed -nE 's/.*Root Password:\s*//p' | head -1)
    account_password="${account_password:-未知}"
    final_uuid=$("${NG_SERVER_BIN}" get-uuid -c "${NG_SERVER_CONF}" 2>/dev/null | tail -n 1)

    # 安装服务 (serve 子命令)
    install_service "${NG_SERVER_SERVICE}" "${NG_SERVER_BIN}" \
        "serve -c ${NG_SERVER_CONF}" "${NG_SERVER_LOG}" "${NG_SERVER_PID}" "${NG_SERVER_DATA}"

    echo ""
    print_ok "NodeGet Server 安装完成！"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${YELLOW}以下信息仅显示一次，请妥善保存${RESET}"
    echo -e "${GREEN}Token:        ${token}${RESET}"
    echo -e "${GREEN}用户名:       root${RESET}"
    echo -e "${GREEN}密码:         ${account_password}${RESET}"
    echo -e "${GREEN}服务器 UUID:  ${final_uuid}${RESET}"
    echo -e "${GREEN}监听地址:     ${ws_listener}${RESET}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# ============================================
# 安装 Agent
# ============================================

install_agent() {
    if [[ -x "${NG_AGENT_BIN}" ]] && [[ -f "${NG_AGENT_CONF}" ]]; then
        read -rp "nodeget-agent 已安装，是否重装？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        remove_service "${NG_AGENT_SERVICE}"
    fi

    local ver; ver=$(get_latest_version)
    local target; target=$(get_target)
    print_info "系统架构: ${target}, 版本: v${ver}"

    download_binary "agent" "$ver" "$target" "${NG_AGENT_BIN}"

    echo ""
    local server_ws server_uuid token server_name agent_uuid ignore_cert

    read -rp "Server WS 地址 (如 ws://1.2.3.4:2211): " server_ws
    [[ -z "$server_ws" ]] && { print_error "Server WS 地址不能为空"; return; }

    read -rp "Server UUID: " server_uuid
    [[ -z "$server_uuid" ]] && { print_error "Server UUID 不能为空"; return; }

    read -rp "授权 Token: " token
    [[ -z "$token" ]] && { print_error "Token 不能为空"; return; }

    read -rp "节点名称 [$(hostname -s)-${RANDOM}]: " server_name
    server_name="${server_name:-$(hostname -s)-${RANDOM}}"

    read -rp "Agent UUID (留空自动生成): " agent_uuid
    agent_uuid="${agent_uuid:-auto_gen}"

    read -rp "忽略 TLS 证书错误？(y/N): " ignore_cert
    ignore_cert="${ignore_cert:-n}"
    if [[ "$ignore_cert" == "y" || "$ignore_cert" == "Y" ]]; then
        ignore_cert="true"
    else
        ignore_cert="false"
    fi

    print_info "写入配置..."
    write_agent_config "$server_name" "$server_uuid" "$token" "$server_ws" "$agent_uuid" "$ignore_cert"

    # Agent 没有子命令，直接传 -c
    install_service "${NG_AGENT_SERVICE}" "${NG_AGENT_BIN}" \
        "-c ${NG_AGENT_CONF}" "${NG_AGENT_LOG}" "${NG_AGENT_PID}" "${NG_AGENT_DATA}"

    echo ""
    print_ok "NodeGet Agent 安装完成！"
    echo -e "${GREEN}Agent UUID: ${agent_uuid}${RESET}"
    echo -e "${GREEN}配置: ${NG_AGENT_CONF}${RESET}"
}

# ============================================
# 卸载
# ============================================

uninstall_nodeget_server() {
    if [[ ! -f "${NG_SERVER_BIN}" ]] && [[ ! -f "${NG_SERVER_CONF}" ]]; then
        print_warn "nodeget-server 未安装"; return
    fi
    read -rp "确认卸载 nodeget-server？(y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
    remove_service "${NG_SERVER_SERVICE}"
    rm -f "${NG_SERVER_BIN}"
    rm -f "${NG_SERVER_LOG}"
    print_info "数据目录保留: ${NG_SERVER_DATA}"
    print_ok "nodeget-server 卸载完成"
}

uninstall_nodeget_agent() {
    if [[ ! -f "${NG_AGENT_BIN}" ]] && [[ ! -f "${NG_AGENT_CONF}" ]]; then
        print_warn "nodeget-agent 未安装"; return
    fi
    read -rp "确认卸载 nodeget-agent？(y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
    remove_service "${NG_AGENT_SERVICE}"
    rm -f "${NG_AGENT_BIN}"
    rm -f "${NG_AGENT_LOG}"
    print_info "数据目录保留: ${NG_AGENT_DATA}"
    print_ok "nodeget-agent 卸载完成"
}

# ============================================
# 状态显示
# ============================================

show_status() {
    echo ""
    echo -e "${CYAN}--- NodeGet 服务状态 ---${RESET}"

    # Server
    if [[ -x "${NG_SERVER_BIN}" ]] && [[ -f "${NG_SERVER_CONF}" ]]; then
        local active="停止"
        if [ "$(detect_init)" = "openrc" ]; then
            rc-service "${NG_SERVER_SERVICE}" status >/dev/null 2>&1 && active="运行中" || true
        elif [ "$(detect_init)" = "procd" ]; then
            /etc/init.d/${NG_SERVER_SERVICE} running 2>/dev/null && active="运行中" || true
        else
            systemctl is-active --quiet "${NG_SERVER_SERVICE}" 2>/dev/null && active="运行中" || true
        fi
        echo -e "${GREEN}[Server] 已安装${RESET}  |  状态: ${active}"
        echo -e "  配置: ${NG_SERVER_CONF}"
    else
        echo -e "${YELLOW}[Server] 未安装${RESET}"
    fi

    # Agent
    if [[ -x "${NG_AGENT_BIN}" ]] && [[ -f "${NG_AGENT_CONF}" ]]; then
        local active="停止"
        if [ "$(detect_init)" = "openrc" ]; then
            rc-service "${NG_AGENT_SERVICE}" status >/dev/null 2>&1 && active="运行中" || true
        elif [ "$(detect_init)" = "procd" ]; then
            /etc/init.d/${NG_AGENT_SERVICE} running 2>/dev/null && active="运行中" || true
        else
            systemctl is-active --quiet "${NG_AGENT_SERVICE}" 2>/dev/null && active="运行中" || true
        fi
        echo -e "${GREEN}[Agent]  已安装${RESET}  |  状态: ${active}"
        echo -e "  配置: ${NG_AGENT_CONF}"
    else
        echo -e "${YELLOW}[Agent]  未安装${RESET}"
    fi

    echo -e "${CYAN}------------------------${RESET}"
}

# ============================================
# 菜单 & 入口
# ============================================

hr(){ printf '%*s\n' 44 '' | tr ' ' '='; }
pause(){ read -rp "按回车返回菜单..." _; }

show_menu() {
    clear
    hr
    echo -e "${CYAN} NodeGet 管理脚本  v${NG_SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN} https://github.com/viogus/scripts${RESET}"
    echo -e "${CYAN} 系统: $(detect_os)  |  架构: $(uname -m)  |  init: $(detect_init)${RESET}"
    hr

    show_status

    echo -e "${GREEN}1.${RESET} 安装/重装 Server (服务端)"
    echo -e "${GREEN}2.${RESET} 安装/重装 Agent (客户端)"
    echo -e "---"
    echo -e "${GREEN}3.${RESET} 卸载 Server"
    echo -e "${GREEN}4.${RESET} 卸载 Agent"
    echo -e "---"
    echo -e "${GREEN}5.${RESET} 启动 Server"
    echo -e "${GREEN}6.${RESET} 停止 Server"
    echo -e "${GREEN}7.${RESET} 重启 Server"
    echo -e "---"
    echo -e "${GREEN}8.${RESET} 启动 Agent"
    echo -e "${GREEN}9.${RESET} 停止 Agent"
    echo -e "${GREEN}10.${RESET} 重启 Agent"
    echo -e "---"
    echo -e "${GREEN}11.${RESET} 查看 Server 配置"
    echo -e "${GREEN}12.${RESET} 查看 Agent 配置"
    echo -e "${GREEN}13.${RESET} 查看 Server UUID"
    echo -e "---"
    echo -e "${GREEN}0.${RESET} 退出"
    hr
    read -rp "请输入选项 [0-13]: " choice

    case "${choice}" in
        1) install_server; pause ;;
        2) install_agent; pause ;;
        3) uninstall_nodeget_server; pause ;;
        4) uninstall_nodeget_agent; pause ;;
        5) svc_op "${NG_SERVER_SERVICE}" start; pause ;;
        6) svc_op "${NG_SERVER_SERVICE}" stop; pause ;;
        7) svc_op "${NG_SERVER_SERVICE}" restart; pause ;;
        8) svc_op "${NG_AGENT_SERVICE}" start; pause ;;
        9) svc_op "${NG_AGENT_SERVICE}" stop; pause ;;
        10) svc_op "${NG_AGENT_SERVICE}" restart; pause ;;
        11)
            if [ -f "${NG_SERVER_CONF}" ]; then cat "${NG_SERVER_CONF}"; else print_warn "Server 配置不存在"; fi
            pause ;;
        12)
            if [ -f "${NG_AGENT_CONF}" ]; then cat "${NG_AGENT_CONF}"; else print_warn "Agent 配置不存在"; fi
            pause ;;
        13)
            if [ -x "${NG_SERVER_BIN}" ] && [ -f "${NG_SERVER_CONF}" ]; then
                "${NG_SERVER_BIN}" get-uuid -c "${NG_SERVER_CONF}" 2>/dev/null | tail -n 1
            else
                print_warn "Server 未安装"
            fi
            pause ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; pause ;;
    esac
}

main() {
    ensure_root
    while true; do
        show_menu
    done
}

# 当被 menu.sh source 时不自动运行; 直接执行时运行菜单
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
