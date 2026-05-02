#!/usr/bin/env bash
# =========================================
# 作者: viogus
# 日期: 2026年5月
# 网站：github.com/viogus
# 描述: AnyTLS 一键管理脚本（安装/更新/卸载/端口/密码/Surge配置）
# 适配: Debian/Ubuntu (apt) / RHEL系 (dnf/yum) / Alpine (apk)
# init: systemd / openrc
# =========================================
set -euo pipefail

# ============================================
# 常量
# ============================================
CONFIG_DIR="/etc/AnyTLS"
BINARY="${CONFIG_DIR}/server"
SERVICE_NAME="anytls"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_INIT="/etc/init.d/${SERVICE_NAME}"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CLIENT_FILE="${CONFIG_DIR}/anytls.txt"
SNAP_DIR="/tmp/anytls_install_$$"
TZ_DEFAULT="Asia/Shanghai"
SCRIPT_VERSION="1.0.0"

# ============================================
# 颜色
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

OK="${GREEN}[OK]${RESET}"
ERROR="${RED}[ERROR]${RESET}"
WARN="${YELLOW}[WARN]${RESET}"
INFO="${CYAN}[INFO]${RESET}"

print_ok(){ echo -e "${OK}${BLUE} $1 ${RESET}"; }
print_info(){ echo -e "${INFO}${CYAN} $1 ${RESET}"; }
print_error(){ echo -e "${ERROR} $1 ${RESET}"; }
print_warn(){ echo -e "${WARN} $1 ${RESET}"; }

judge(){ if [[ 0 -eq $? ]]; then print_ok "$1 完成"; else print_error "$1 失败"; exit 1; fi; }
trap 'echo -e "\n${WARN} 已中断"; exit 1' INT

# ============================================
# 工具函数
# ============================================

ensure_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        print_error "必须使用 root 运行本脚本!"
        exit 1
    fi
}

has_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_init() {
    if has_cmd systemctl && [[ -d /run/systemd/system ]]; then
        echo "systemd"; return
    fi
    if has_cmd rc-service; then
        echo "openrc"; return
    fi
    echo "unknown"
}

get_arch() {
    local arch_raw; arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) print_error "不支持的系统架构 ($arch_raw)"; return 1 ;;
    esac
}

os_install() {
    if has_cmd apk; then
        apk update
        apk add --no-cache ca-certificates curl unzip bash iproute2 tzdata
        update-ca-certificates >/dev/null 2>&1 || true
        return
    fi
    if has_cmd apt-get; then
        apt-get update -y
        apt-get install -y ca-certificates curl unzip
    elif has_cmd dnf; then
        dnf update -y
        dnf install -y ca-certificates curl unzip
    elif has_cmd yum; then
        yum update -y
        yum install -y ca-certificates curl unzip
    else
        print_error "未识别的包管理器，请手动安装 ca-certificates、curl、unzip 后重试"
        exit 1
    fi
}

close_wall() {
    local init; init="$(detect_init)"
    if [[ "$init" == "openrc" ]]; then
        print_info "检测到 OpenRC (Alpine)。脚本不自动关闭防火墙，请自行放行端口。"
        return 0
    fi
    for svc in firewalld nftables ufw; do
        if has_cmd systemctl && systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                print_warn "检测到防火墙 ${svc} 正在运行。脚本将关闭并禁用防火墙以放行端口。"
                print_warn "如不希望禁用防火墙，请按 Ctrl+C 取消，手动放行端口后重试。"
                sleep 2
                systemctl stop "$svc" 2>/dev/null || true
                systemctl disable "$svc" 2>/dev/null || true
                print_ok "已关闭并禁用防火墙: $svc"
            else
                if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                    systemctl disable "$svc" 2>/dev/null || true
                    print_ok "已禁用开机自启: $svc"
                fi
            fi
        fi
    done
}

random_port(){ shuf -i 2000-65000 -n 1; }
gen_password(){ cat /proc/sys/kernel/random/uuid; }
valid_port(){ local p="${1:-}"; [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 )); }

is_port_used() {
    local port="$1"
    if has_cmd ss; then
        ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}([[:space:]]|$)"
    elif has_cmd netstat; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

read_port_interactive() {
    local input
    while true; do
        read -p "输入端口(1-65535)，回车随机：" input
        [[ -z "${input:-}" ]] && input=$(random_port)
        if ! valid_port "$input"; then echo "端口不合法：$input"; continue; fi
        if is_port_used "$input"; then echo "端口 $input 已被占用"; continue; fi
        echo "$input"; break
    done
}

get_ip() {
    local ip4 ip6
    ip4=$(curl -s --connect-timeout 5 --max-time 10 -4 http://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -n "${ip4}" ]] && { echo "${ip4}"; return; }
    ip6=$(curl -s --connect-timeout 5 --max-time 10 -6 http://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -n "${ip6}" ]] && { echo "${ip6}"; return; }
    curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "未知IP"
}

get_latest_version() {
    local version
    version=$(curl -s --connect-timeout 10 --max-time 30 https://api.github.com/repos/anytls/anytls-go/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$version" ]] && { print_error "无法获取AnyTLS最新版本号"; return 1; }
    echo "$version"
}

# ============================================
# 配置读写
# ============================================

write_config() {
    local port="$1" pass="$2"
    mkdir -p "$(dirname "${CONFIG_FILE}")"
    cat > "${CONFIG_FILE}" <<EOF
listen: 0.0.0.0:${port}
password: ${pass}
EOF
}

client_export() {
    local ip port pass
    ip="$(get_ip)"
    port="$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONFIG_FILE}" || true)"
    pass="$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONFIG_FILE}" || true)"

    echo ""
    echo -e "${CYAN}========== AnyTLS 客户端配置 ==========${RESET}"
    echo -e "${GREEN}URL 格式：${RESET}anytls://${pass}@${ip}:${port}/?insecure=1#AT_Proxy"
    echo ""
    echo -e "${GREEN}Surge 格式：${RESET}"
    echo "Proxy-AnyTLS = anytls, ${ip}, ${port}, password=${pass}"
    echo -e "${CYAN}========================================${RESET}"

    cat > "${CLIENT_FILE}" <<EOF
URL格式：anytls://${pass}@${ip}:${port}/?insecure=1#AT_Proxy
Surge格式：Proxy-AnyTLS = anytls, ${ip}, ${port}, password=${pass}
EOF
    echo -e "${YELLOW}配置已保存至：${CLIENT_FILE}${RESET}"
}

# ============================================
# 安装状态
# ============================================

binary_exists(){ [[ -x "${BINARY}" ]]; }
service_exists_systemd(){ [[ -f "${SYSTEMD_UNIT}" ]]; }
service_exists_openrc(){ [[ -f "${OPENRC_INIT}" ]]; }

is_installed() {
    binary_exists || service_exists_systemd || service_exists_openrc
}

# ============================================
# systemd / openrc
# ============================================

write_systemd() {
    local version="$1" port="$2" pass="$3"
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=AnyTLS Server Service
Documentation=https://github.com/anytls/anytls-go
After=network.target network-online.target
Wants=network-online.target
X-AT-Version=${version}

[Service]
Type=simple
User=root
Environment=TZ=${TZ_DEFAULT}
ExecStart="${BINARY}" -l 0.0.0.0:${port} -p "${pass}"
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_openrc() {
    local port="$1" pass="$2"
    cat > "$OPENRC_INIT" <<'OPENRCEOF'
#!/sbin/openrc-run
name="AnyTLS"
description="AnyTLS server"
command="/etc/AnyTLS/server"
command_background="yes"
pidfile="/run/anytls.pid"
output_log="/var/log/anytls.log"
error_log="/var/log/anytls.err"
OPENRCEOF
    cat >> "$OPENRC_INIT" <<EOF
command_args="-l 0.0.0.0:${port} -p ${pass}"
EOF
    chmod +x "$OPENRC_INIT"
}

restart_service() {
    local init; init="$(detect_init)"
    if [[ "$init" == "systemd" ]]; then
        systemctl daemon-reload || true
        systemctl enable "${SERVICE_NAME}" || true
        systemctl restart "${SERVICE_NAME}"
        systemctl status --no-pager "${SERVICE_NAME}" | sed -n '1,8p' || true
        return
    fi
    if [[ "$init" == "openrc" ]]; then
        rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true
        rc-service "${SERVICE_NAME}" restart || rc-service "${SERVICE_NAME}" start
        rc-service "${SERVICE_NAME}" status || true
        return
    fi
    print_error "未知 init 系统，无法管理服务"
    exit 1
}

# ============================================
# 安装 / 更新 / 卸载
# ============================================

install_anytls() {
    mkdir -p "$CONFIG_DIR"

    print_info "正在安装依赖..."
    os_install; judge "依赖安装"

    print_info "正在处理防火墙..."
    close_wall; judge "防火墙处理"

    print_info "正在检测系统架构..."
    local arch latest url filename out
    arch="$(get_arch)" || exit 1
    print_info "检测到架构: ${arch}"

    latest="$(get_latest_version)" || exit 1
    print_info "AnyTLS 最新版本: ${latest}"

    url="https://github.com/anytls/anytls-go/releases/download/${latest}/anytls_${latest#v}_linux_${arch}.zip"
    filename="anytls_${latest#v}_linux_${arch}.zip"
    out="${SNAP_DIR}/${filename}"

    rm -rf "${SNAP_DIR}"
    mkdir -p "${SNAP_DIR}"

    print_info "正在下载 AnyTLS..."
    curl -L --connect-timeout 10 --max-time 120 -o "$out" "$url"
    judge "下载AnyTLS"

    unzip -o "$out" -d "$SNAP_DIR" >/dev/null
    mv "${SNAP_DIR}/anytls-server" "$BINARY"
    chmod +x "$BINARY"
    rm -rf "${SNAP_DIR}"

    local port pass init
    port="$(read_port_interactive)"
    pass="$(gen_password)"
    write_config "$port" "$pass"

    init="$(detect_init)"
    print_info "检测到 init: ${init}"

    if [[ "$init" == "systemd" ]]; then
        write_systemd "$latest" "$port" "$pass"
    elif [[ "$init" == "openrc" ]]; then
        write_openrc "$port" "$pass"
    else
        print_error "不支持的 init 系统：${init}"
        exit 1
    fi

    restart_service
    print_ok "AnyTLS 安装完成！"
    client_export
}

update_anytls() {
    if ! is_installed; then
        print_error "您还未安装 AnyTLS, 无法更新"
        return
    fi

    local port pass
    port="$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONFIG_FILE}" || true)"
    pass="$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONFIG_FILE}" || true)"
    [[ -z "${port}" ]] && port="$(random_port)"
    [[ -z "${pass}" ]] && pass="$(gen_password)"

    local arch latest url filename out
    arch="$(get_arch)" || exit 1
    latest="$(get_latest_version)" || exit 1
    url="https://github.com/anytls/anytls-go/releases/download/${latest}/anytls_${latest#v}_linux_${arch}.zip"
    filename="anytls_${latest#v}_linux_${arch}.zip"
    out="${SNAP_DIR}/${filename}"

    rm -rf "${SNAP_DIR}"
    mkdir -p "${SNAP_DIR}"

    print_info "正在下载 AnyTLS..."
    curl -L -o "$out" "$url"
    judge "下载AnyTLS"

    unzip -o "$out" -d "$SNAP_DIR" >/dev/null
    mv "${SNAP_DIR}/anytls-server" "$BINARY"
    chmod +x "$BINARY"
    rm -rf "${SNAP_DIR}"

    write_config "$port" "$pass"

    local init; init="$(detect_init)"
    if [[ "$init" == "systemd" ]]; then
        write_systemd "$latest" "$port" "$pass"
    elif [[ "$init" == "openrc" ]]; then
        write_openrc "$port" "$pass"
    fi

    restart_service
    print_ok "AnyTLS 更新完成！"
    client_export
}

uninstall_anytls() {
    if ! is_installed; then
        print_error "您还未安装 AnyTLS, 无法卸载"
        return
    fi
    read -p "确认卸载并删除 AnyTLS 配置？(y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }

    local init; init="$(detect_init)"
    if [[ "$init" == "systemd" ]]; then
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        rm -f "${SYSTEMD_UNIT}" || true
        systemctl daemon-reload || true
    elif [[ "$init" == "openrc" ]]; then
        rc-service "${SERVICE_NAME}" stop 2>/dev/null || true
        rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 || true
        rm -f "${OPENRC_INIT}" || true
    fi

    rm -rf "${CONFIG_DIR}" || true
    print_ok "AnyTLS 卸载完成。"
}

# ============================================
# 配置管理
# ============================================

view_config() {
    if ! is_installed; then
        print_error "您还未安装 AnyTLS, 无法查看配置"
        return
    fi
    client_export
}

set_port() {
    if ! is_installed; then
        print_error "您还未安装 AnyTLS"
        return
    fi
    local new_port pass init
    new_port="$(read_port_interactive)"
    pass="$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONFIG_FILE}" || true)"
    [[ -z "${pass}" ]] && pass="$(gen_password)"
    write_config "$new_port" "$pass"

    init="$(detect_init)"
    if [[ "$init" == "systemd" ]]; then
        write_systemd "unknown" "$new_port" "$pass"
    elif [[ "$init" == "openrc" ]]; then
        write_openrc "$new_port" "$pass"
    fi
    restart_service
    print_ok "端口已更新为：${new_port}"
    client_export
}

set_password() {
    if ! is_installed; then
        print_error "您还未安装 AnyTLS"
        return
    fi
    local new_pass port init
    new_pass="$(gen_password)"
    port="$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONFIG_FILE}" || true)"
    [[ -z "${port}" ]] && port="$(random_port)"
    write_config "$port" "$new_pass"

    init="$(detect_init)"
    if [[ "$init" == "systemd" ]]; then
        write_systemd "unknown" "$port" "$new_pass"
    elif [[ "$init" == "openrc" ]]; then
        write_openrc "$port" "$new_pass"
    fi
    restart_service
    print_ok "密码已更新为：${new_pass}"
    client_export
}

# ============================================
# 状态显示
# ============================================

show_status() {
    echo -e "\n${CYAN}=== AnyTLS 状态 ===${RESET}"
    if is_installed; then
        if [[ -f "${SYSTEMD_UNIT}" ]]; then
            if systemctl is-active --quiet "${SERVICE_NAME}"; then
                local pid=$(systemctl show -p MainPID "${SERVICE_NAME}" | cut -d'=' -f2)
                echo -e "${GREEN}状态: 运行中${RESET}  ${YELLOW}PID: ${pid:-N/A}${RESET}"
                systemctl status --no-pager "${SERVICE_NAME}" | sed -n '1,8p' || true
            else
                echo -e "${RED}状态: 已停止${RESET}"
            fi
        elif [[ -f "${OPENRC_INIT}" ]]; then
            rc-service "${SERVICE_NAME}" status 2>/dev/null || echo -e "${RED}状态: 已停止${RESET}"
        else
            echo -e "${GREEN}状态: 已安装${RESET}"
        fi

        if [[ -f "${CONFIG_FILE}" ]]; then
            local port pass
            port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${CONFIG_FILE}" || true)
            pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${CONFIG_FILE}" || true)
            echo -e "${YELLOW}端口: ${port:-N/A}${RESET}"
            echo -e "${YELLOW}密码: ${pass:-N/A}${RESET}"
        fi
    else
        echo -e "${YELLOW}AnyTLS 未安装${RESET}"
    fi
    echo -e "${CYAN}===================${RESET}\n"
}

# ============================================
# 菜单
# ============================================

hr(){ printf '%*s\n' 44 '' | tr ' ' '='; }
pause(){ read -rp "按回车返回菜单..." _; }

show_menu() {
    clear
    hr
    echo -e "${CYAN} AnyTLS 一键管理脚本  v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN} https://github.com/viogus/AnyTLS${RESET}"
    echo -e "${CYAN} init: $(detect_init)  |  架构: $(uname -m)${RESET}"
    hr

    show_status

    echo -e "${GREEN}1.${RESET} 安装/重装 AnyTLS"
    echo -e "${GREEN}2.${RESET} 更新 AnyTLS"
    echo -e "${GREEN}3.${RESET} 查看配置 (输出 Surge 格式)"
    echo -e "${GREEN}4.${RESET} 卸载 AnyTLS"
    echo -e "${GREEN}5.${RESET} 更改端口"
    echo -e "${GREEN}6.${RESET} 更改密码"
    echo -e "${GREEN}0.${RESET} 退出"
    hr
    read -rp "请输入选项 [0-6]: " choice

    case "${choice}" in
        1) install_anytls; pause ;;
        2) update_anytls; pause ;;
        3) view_config; pause ;;
        4) uninstall_anytls; pause ;;
        5) set_port; pause ;;
        6) set_password; pause ;;
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
