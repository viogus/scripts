#!/usr/bin/env bash
# =========================================
# 作者: viogus (基于 stilleshan/frpc + stilleshan/frps 整合)
# 日期: 2026年5月
# 网站：github.com/viogus
# 描述: frp 一键管理脚本（frps 服务端 / frpc 客户端）
# 适配: Debian/Ubuntu (apt) / RHEL系 (dnf/yum) / Alpine (apk)
# init: systemd / openrc
# =========================================
set -euo pipefail

# ============================================
# 常量
# ============================================
CONF_DIR="/usr/local/etc/frp"
FRPS_BIN="/usr/local/bin/frps"
FRPC_BIN="/usr/local/bin/frpc"
FRPS_CONF="${CONF_DIR}/frps.toml"
FRPC_CONF="${CONF_DIR}/frpc.toml"
SCRIPT_VERSION="1.0.0"

# ============================================
# 颜色
# ============================================
[ -z "${RED:-}" ] && {
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'
}

OK="${GREEN}[OK]${RESET}"
ERROR="${RED}[ERROR]${RESET}"
WARN="${YELLOW}[WARN]${RESET}"
INFO="${CYAN}[INFO]${RESET}"

print_ok(){ echo -e "${OK} ${BLUE}$1 ${RESET}"; }
print_info(){ echo -e "${INFO} ${CYAN}$1 ${RESET}"; }
print_error(){ echo -e "${ERROR} $1 ${RESET}"; }
print_warn(){ echo -e "${WARN} $1 ${RESET}"; }
trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

# ============================================
# 工具函数
# ============================================

# 加载共享库（本地 > 系统 > GitHub > 内联兜底）
LIB_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
if [ -f "$LIB_DIR/svc-utils.sh" ]; then
    . "$LIB_DIR/svc-utils.sh"
elif [ -f /usr/local/lib/svc-utils.sh ]; then
    . /usr/local/lib/svc-utils.sh
else
    TMP_LIB=$(mktemp /tmp/svc-utils-XXXXXX)
    if curl -fsSL --connect-timeout 5 --max-time 15 \
        https://raw.githubusercontent.com/viogus/scripts/main/lib/svc-utils.sh \
        -o "$TMP_LIB" 2>/dev/null; then
        . "$TMP_LIB"
    fi
    rm -f "$TMP_LIB"
fi
# ============================================

ensure_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        print_error "必须使用 root 运行本脚本!"
        exit 1
    fi
}

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

if ! command -v detect_init >/dev/null 2>&1; then
_INIT_TYPE=""
detect_os() {
    if grep -qi "alpine" /etc/os-release 2>/dev/null; then
        echo "alpine"
    elif grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
        echo "debian"
    elif grep -qi "centos\|red hat\|rhel\|alma\|rocky\|fedora\|amazon" /etc/os-release 2>/dev/null; then
        echo "rhel"
    else
        echo "unknown"
    fi
}

detect_init() {
    if [[ -n "$_INIT_TYPE" ]]; then echo "$_INIT_TYPE"; return; fi
    if has_cmd systemctl && [[ -d /run/systemd/system ]]; then
        _INIT_TYPE="systemd"; echo "systemd"; return
    fi
    if has_cmd rc-service; then
        _INIT_TYPE="openrc"; echo "openrc"; return
    fi
    _INIT_TYPE="systemd"; echo "systemd"
}
fi  # end inline fallback

get_ip() {
    local ip4 ip6
    ip4=$(curl -s --connect-timeout 5 --max-time 10 -4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -n "${ip4}" ]] && { echo "${ip4}"; return; }
    ip6=$(curl -s --connect-timeout 5 --max-time 10 -6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -n "${ip6}" ]] && { echo "${ip6}"; return; }
    curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "未知IP"
}

get_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null \
        | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/') || true
    if [[ -z "$ver" ]]; then
        ver="0.68.1"
        print_warn "无法获取最新版本号，使用默认版本: v${ver}"
    fi
    echo "$ver"
}

get_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv6l) echo "arm" ;;
        *) print_error "不支持的架构: $m"; exit 1 ;;
    esac
}

# ============================================
# 安装依赖
# ============================================

install_deps() {
    local os_type; os_type=$(detect_os)
    print_info "检测到系统类型: ${os_type}"

    case "$os_type" in
        debian)
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar
            ;;
        rhel)
            yum -y install curl wget tar 2>/dev/null || dnf -y install curl wget tar
            ;;
        alpine)
            apk update
            apk add --no-cache curl wget tar
            ;;
        *) print_error "不支持的操作系统"; exit 1 ;;
    esac
}

# ============================================
# 下载 frp 二进制
# ============================================

download_frp() {
    local ver arch
    ver=$(get_version)
    arch=$(get_arch)
    local file_name="frp_${ver}_linux_${arch}"
    local url="https://github.com/fatedier/frp/releases/download/v${ver}/${file_name}.tar.gz"
    local tmp; tmp=$(mktemp -d)

    print_info "frp 版本: v${ver} 架构: ${arch}"
    print_info "正在下载 frp..."

    # Try direct GitHub first, fallback to ghfast mirror
    if ! curl -L --connect-timeout 10 --max-time 120 -o "${tmp}/${file_name}.tar.gz" "$url" 2>/dev/null; then
        print_warn "GitHub 直连失败，尝试镜像..."
        local mirror_url="https://ghfast.top/${url}"
        curl -L --connect-timeout 10 --max-time 120 -o "${tmp}/${file_name}.tar.gz" "$mirror_url" || {
            print_error "下载失败，请检查网络"
            rm -rf "$tmp"
            exit 1
        }
    fi

    mkdir -p "${CONF_DIR}"
    tar -xzf "${tmp}/${file_name}.tar.gz" -C "$tmp"
    cp "${tmp}/${file_name}/frps" "${FRPS_BIN}" 2>/dev/null || true
    cp "${tmp}/${file_name}/frpc" "${FRPC_BIN}" 2>/dev/null || true
    chmod +x "${FRPS_BIN}" "${FRPC_BIN}" 2>/dev/null || true

    rm -rf "$tmp"
    print_ok "frp 二进制安装完成"
}

# ============================================
# init 模板
# ============================================

write_systemd() {
    local name="$1" bin="$2" conf="$3"
    cat > "/etc/systemd/system/${name}.service" << SYSTEMDEOF
[Unit]
Description=Frp ${name} Service
After=network.target syslog.target
Wants=network.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStart=${bin} -c ${conf}
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
}

write_openrc() {
    local name="$1" bin="$2" conf="$3"
    cat > "/etc/init.d/${name}" << OPENRCEOF
#!/sbin/openrc-run
name="${name}"
description="Frp ${name} server"
command="${bin}"
command_args="-c ${conf}"
command_background="yes"
pidfile="/run/${name}.pid"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.err"

depend() {
    need networking
}

OPENRCEOF
    chmod +x "/etc/init.d/${name}"
    touch "/var/log/${name}.log" "/var/log/${name}.err"
}

install_service() {
    local name="$1" bin="$2" conf="$3"
    local init; init=$(detect_init)

    if [[ "$init" == "openrc" ]]; then
        write_openrc "$name" "$bin" "$conf"
        rc-update add "$name" default >/dev/null 2>&1 || true
        rc-service "$name" restart || rc-service "$name" start
        if rc-service "$name" status 2>/dev/null; then
            print_ok "${name} 服务已启动 (OpenRC)"
        else
            print_warn "${name} 服务启动，请检查状态"
        fi
    else
        write_systemd "$name" "$bin" "$conf"
        systemctl daemon-reload
        systemctl enable "$name" >/dev/null 2>&1 || true
        systemctl restart "$name" || systemctl start "$name"
        if systemctl is-active --quiet "$name" 2>/dev/null; then
            print_ok "${name} 服务已启动 (systemd)"
        else
            print_warn "${name} 服务启动，请检查状态"
        fi
    fi
}

remove_service() {
    local name="$1"
    local init; init=$(detect_init)
    if [[ "$init" == "openrc" ]]; then
        rc-service "$name" stop 2>/dev/null || true
        rc-update del "$name" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${name}"
    else
        systemctl stop "$name" 2>/dev/null || true
        systemctl disable "$name" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${name}.service"
        systemctl daemon-reload
    fi
    rm -f "/var/log/${name}.log" "/var/log/${name}.err"
}

svc_op() {
    local name="$1" op="$2"
    local init; init=$(detect_init)
    case "$op" in
        start)
            if [[ "$init" == "openrc" ]]; then rc-service "$name" start; else systemctl start "$name"; fi ;;
        stop)
            if [[ "$init" == "openrc" ]]; then rc-service "$name" stop; else systemctl stop "$name"; fi ;;
        restart)
            if [[ "$init" == "openrc" ]]; then rc-service "$name" restart; else systemctl restart "$name"; fi ;;
        status)
            if [[ "$init" == "openrc" ]]; then rc-service "$name" status 2>/dev/null || true
            else systemctl status "$name" --no-pager 2>/dev/null || true; fi ;;
    esac
}

# ============================================
# 安装 frps
# ============================================

install_frps() {
    if [[ -f "${FRPS_BIN}" ]] && [[ -f "${FRPS_CONF}" ]]; then
        read -rp "frps 已安装，是否重装？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        remove_service "frps"
    fi

    install_deps
    download_frp

    local port
    read -rp "请输入 frps 监听端口 [7000]: " port
    port="${port:-7000}"

    local token
    read -rp "请输入 frps 认证 token (留空则无认证): " token

    print_info "生成配置..."
    mkdir -p "${CONF_DIR}"
    cat > "${FRPS_CONF}" << FRPSEOF
bindPort = ${port}

FRPSEOF
    if [[ -n "${token:-}" ]]; then
        echo "auth.token = \"${token}\"" >> "${FRPS_CONF}"
    fi

    install_service "frps" "${FRPS_BIN}" "${FRPS_CONF}"
    print_ok "frps 安装完成！"
    show_frps_config
}

# ============================================
# 安装 frpc
# ============================================

install_frpc() {
    if [[ -f "${FRPC_BIN}" ]] && [[ -f "${FRPC_CONF}" ]]; then
        read -rp "frpc 已安装，是否重装？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        remove_service "frpc"
    fi

    install_deps
    download_frp

    local server_addr server_port token
    read -rp "请输入 frps 服务器地址: " server_addr
    [[ -z "$server_addr" ]] && { print_error "服务器地址不能为空"; return; }

    read -rp "请输入 frps 服务器端口 [7000]: " server_port
    server_port="${server_port:-7000}"

    read -rp "请输入 frps 认证 token (留空则无认证): " token

    print_info "生成配置..."
    mkdir -p "${CONF_DIR}"
    cat > "${FRPC_CONF}" << FRPCEOF
serverAddr = "${server_addr}"
serverPort = ${server_port}

FRPCEOF
    if [[ -n "${token:-}" ]]; then
        echo "auth.token = \"${token}\"" >> "${FRPC_CONF}"
    fi

    print_info "请手动编辑 ${FRPC_CONF} 添加代理规则 (如 [[proxies]])"

    install_service "frpc" "${FRPC_BIN}" "${FRPC_CONF}"
    print_ok "frpc 安装完成！"
    show_frpc_config
}

# ============================================
# 卸载
# ============================================

uninstall_frps() {
    if [[ ! -f "${FRPS_BIN}" ]] && [[ ! -f "${FRPS_CONF}" ]]; then
        print_warn "frps 未安装"; return
    fi
    read -rp "确认卸载 frps？(y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
    remove_service "frps"
    rm -f "${FRPS_BIN}" "${FRPS_CONF}"
    print_ok "frps 卸载完成"
}

uninstall_frpc() {
    if [[ ! -f "${FRPC_BIN}" ]] && [[ ! -f "${FRPC_CONF}" ]]; then
        print_warn "frpc 未安装"; return
    fi
    read -rp "确认卸载 frpc？(y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
    remove_service "frpc"
    rm -f "${FRPC_BIN}" "${FRPC_CONF}"
    print_ok "frpc 卸载完成"
}

# ============================================
# 显示配置
# ============================================

show_frps_config() {
    echo ""
    echo -e "${CYAN}=== frps 配置 ===${RESET}"
    if [[ -f "${FRPS_CONF}" ]]; then
        cat "${FRPS_CONF}"
    else
        print_warn "frps 未安装"
    fi
    echo -e "${CYAN}================${RESET}"
}

show_frpc_config() {
    echo ""
    echo -e "${CYAN}=== frpc 配置 ===${RESET}"
    if [[ -f "${FRPC_CONF}" ]]; then
        cat "${FRPC_CONF}"
    else
        print_warn "frpc 未安装"
    fi
    echo -e "${CYAN}================${RESET}"
}

# ============================================
# 状态
# ============================================

show_status() {
    echo ""
    echo -e "${CYAN}--- frp 服务状态 ---${RESET}"

    # frps
    if [[ -f "${FRPS_BIN}" ]] && [[ -f "${FRPS_CONF}" ]]; then
        local frps_active="停止"
        local init; init=$(detect_init)
        if [[ "$init" == "openrc" ]]; then
            rc-service frps status >/dev/null 2>&1 && frps_active="运行中" || true
        else
            systemctl is-active --quiet frps 2>/dev/null && frps_active="运行中" || true
        fi
        echo -e "${GREEN}[frps] 已安装${RESET}  |  状态: ${frps_active}"
    else
        echo -e "${YELLOW}[frps] 未安装${RESET}"
    fi

    # frpc
    if [[ -f "${FRPC_BIN}" ]] && [[ -f "${FRPC_CONF}" ]]; then
        local frpc_active="停止"
        local init; init=$(detect_init)
        if [[ "$init" == "openrc" ]]; then
            rc-service frpc status >/dev/null 2>&1 && frpc_active="运行中" || true
        else
            systemctl is-active --quiet frpc 2>/dev/null && frpc_active="运行中" || true
        fi
        echo -e "${GREEN}[frpc] 已安装${RESET}  |  状态: ${frpc_active}"
    else
        echo -e "${YELLOW}[frpc] 未安装${RESET}"
    fi

    echo -e "${CYAN}-------------------${RESET}"
}

# ============================================
# 菜单
# ============================================

hr(){ printf '%*s\n' 44 '' | tr ' ' '='; }
pause(){ read -rp "按回车返回菜单..." _; }

show_menu() {
    clear
    hr
    echo -e "${CYAN} frp 一键管理脚本  v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN} https://github.com/viogus/scripts${RESET}"
    echo -e "${CYAN} 系统: $(detect_os)  |  架构: $(uname -m)${RESET}"
    hr

    show_status

    echo -e "${GREEN}1.${RESET} 安装/重装 frps (服务端)"
    echo -e "${GREEN}2.${RESET} 安装/重装 frpc (客户端)"
    echo -e "---"
    echo -e "${GREEN}3.${RESET} 卸载 frps"
    echo -e "${GREEN}4.${RESET} 卸载 frpc"
    echo -e "---"
    echo -e "${GREEN}5.${RESET} 查看 frps 配置"
    echo -e "${GREEN}6.${RESET} 查看 frpc 配置"
    echo -e "---"
    echo -e "${GREEN}7.${RESET} 启动 frps"
    echo -e "${GREEN}8.${RESET} 停止 frps"
    echo -e "${GREEN}9.${RESET} 重启 frps"
    echo -e "---"
    echo -e "${GREEN}10.${RESET} 启动 frpc"
    echo -e "${GREEN}11.${RESET} 停止 frpc"
    echo -e "${GREEN}12.${RESET} 重启 frpc"
    echo -e "---"
    echo -e "${GREEN}0.${RESET} 退出"
    hr
    read -rp "请输入选项 [0-12]: " choice

    case "${choice}" in
        1) install_frps; pause ;;
        2) install_frpc; pause ;;
        3) uninstall_frps; pause ;;
        4) uninstall_frpc; pause ;;
        5) show_frps_config; pause ;;
        6) show_frpc_config; pause ;;
        7) svc_op frps start; pause ;;
        8) svc_op frps stop; pause ;;
        9) svc_op frps restart; pause ;;
        10) svc_op frpc start; pause ;;
        11) svc_op frpc stop; pause ;;
        12) svc_op frpc restart; pause ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; pause ;;
    esac
}

# ============================================
# 主程序
# ============================================

main() {
    ensure_root
    while true; do
        show_menu
    done
}

main
