#!/usr/bin/env bash
# =========================================
set -euo pipefail
# 作者: jinqians + viogus
# 日期: 2026年5月
# 网站：jinqians.com / github.com/viogus
# 描述: 统一管理 Snell、SS-Rust、ShadowTLS、VLESS Reality、AnyTLS
# =========================================

# 定义颜色代码
[ -z "${RED:-}" ] && {
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[0;33m'
CYAN='[0;36m'
BLUE='[0;34m'
RESET='[0m'
}

# === 新框架 (Phase 1) ===
# 从 GitHub 下载框架，不留本地文件
GITHUB_RAW="https://raw.githubusercontent.com/viogus/scripts/main"

fw_download() {
    local tmp; tmp=$(mktemp /tmp/fw-XXXXXX)
    if curl -fsSL --connect-timeout 10 --max-time 30 "${GITHUB_RAW}/$1" -o "$tmp" 2>/dev/null; then
        echo "$tmp"
    else
        rm -f "$tmp"
        return 1
    fi
}



# 当前版本号
current_version="4.0"

# ============================================
# AnyTLS 常量
# ============================================
ANYTLS_CONFIG_DIR="/usr/local/etc/anytls"
ANYTLS_BINARY="/usr/local/bin/anytls-server"
ANYTLS_SERVICE_NAME="anytls"
ANYTLS_SYSTEMD_UNIT="/etc/systemd/system/${ANYTLS_SERVICE_NAME}.service"
ANYTLS_OPENRC_INIT="/etc/init.d/${ANYTLS_SERVICE_NAME}"
ANYTLS_CONFIG_FILE="${ANYTLS_CONFIG_DIR}/config.yaml"
ANYTLS_CLIENT_FILE="${ANYTLS_CONFIG_DIR}/anytls.txt"
ANYTLS_TZ="Asia/Shanghai"
ANYTLS_SNAP_DIR="/tmp/anytls_install_$$"

# ============================================
# Hysteria 2 常量
# ============================================
HY2_SERVICE_NAME="hysteria-server"
HY2_CONFIG_FILE="/usr/local/etc/hysteria/config.yaml"
HY2_CLIENT_YAML="/usr/local/etc/hysteria/hy-client.yaml"
HY2_URL_FILE="/usr/local/etc/hysteria/url.txt"

# ============================================
# 通用工具函数
# ============================================

# 安装全局命令
install_global_command() {
    echo -e "${CYAN}正在安装全局命令...${RESET}"
    local tmp; tmp=$(mktemp)
    if curl -L --connect-timeout 10 --max-time 30 -s https://raw.githubusercontent.com/viogus/scripts/main/menu.sh -o "$tmp"; then
        mv "$tmp" "/usr/local/bin/menu.sh"
        chmod +x "/usr/local/bin/menu.sh"
        if [ -f "/usr/local/bin/menu" ]; then
            rm -f "/usr/local/bin/menu"
        fi
        ln -s "/usr/local/bin/menu.sh" "/usr/local/bin/menu"
        echo -e "${GREEN}安装成功！现在您可以在任何位置使用 'menu' 命令来启动管理脚本${RESET}"
    else
        rm -f "$tmp"
        echo -e "${YELLOW}安装全局命令失败（网络不可达），脚本继续运行${RESET}"
    fi
}

# 检查并安装依赖
check_dependencies() {
    local deps=("bc" "curl" "unzip")
    local need_update=false

    echo -e "${CYAN}正在检查依赖...${RESET}"

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${YELLOW}未检测到 ${dep}，准备安装...${RESET}"
            need_update=true
            break
        fi
    done

    if [ "$need_update" = true ]; then
        if [ -x "$(command -v apt)" ]; then
            apt update
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    echo -e "${CYAN}正在安装 ${dep}...${RESET}"
                    apt install -y "$dep"
                fi
            done
        elif [ -x "$(command -v yum)" ]; then
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    echo -e "${CYAN}正在安装 ${dep}...${RESET}"
                    yum install -y "$dep"
                fi
            done
        elif [ -x "$(command -v dnf)" ]; then
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    echo -e "${CYAN}正在安装 ${dep}...${RESET}"
                    dnf install -y "$dep"
                fi
            done
        elif [ -x "$(command -v apk)" ]; then
            apk update
            for dep in "${deps[@]}"; do
                if ! command -v "$dep" &> /dev/null; then
                    echo -e "${CYAN}正在安装 ${dep}...${RESET}"
                    apk add --no-cache "$dep"
                fi
            done
        else
            echo -e "${RED}未支持的包管理器，请手动安装以下依赖：${deps[*]}${RESET}"
            exit 1
        fi
    fi

    echo -e "${GREEN}所有依赖已满足${RESET}"
}

# 获取 CPU 使用率
get_cpu_usage() {
    local pid=$1
    local cpu_usage=0
    local cpu_cores=$(nproc)

    if [ ! -z "$pid" ] && [ "$pid" != "0" ]; then
        # ps -o %cpu= 在 BusyBox 和 GNU 上都可用
        cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo "")
        if [ -z "$cpu_usage" ]; then
            # 在 GNU top 上尝试 top -p（BusyBox top 没有 -p）
            cpu_usage=$( { top -b -n 2 -d 0.2 -p "$pid" 2>/dev/null || true; } | tail -1 | awk '{print $9}')
        fi
        cpu_usage=$(echo "scale=2; ${cpu_usage:-0} / $cpu_cores" | bc -l 2>/dev/null || echo "0")
    fi

    echo "$cpu_usage"
}

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# ============================================
# Init 系统检测 & 服务操作包装器
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
if ! command -v svc_start >/dev/null 2>&1; then

_INIT_TYPE=""
detect_init() {
    if [[ -n "$_INIT_TYPE" ]]; then echo "$_INIT_TYPE"; return; fi
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        _INIT_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        _INIT_TYPE="openrc"
    else
        _INIT_TYPE="systemd"
    fi
    echo "$_INIT_TYPE"
}

svc_start()   { if [[ "$(detect_init)" == "openrc" ]]; then rc-service "$1" start; else systemctl start "$1"; fi; }
svc_stop()    { if [[ "$(detect_init)" == "openrc" ]]; then rc-service "$1" stop 2>/dev/null || true; else systemctl stop "$1" 2>/dev/null || true; fi; }
svc_restart() { if [[ "$(detect_init)" == "openrc" ]]; then rc-service "$1" restart; else systemctl restart "$1"; fi; }
svc_enable()  { if [[ "$(detect_init)" == "openrc" ]]; then rc-update add "$1" default >/dev/null 2>&1 || true; else systemctl enable "$1" >/dev/null 2>&1 || true; fi; }
svc_disable() { if [[ "$(detect_init)" == "openrc" ]]; then rc-update del "$1" default >/dev/null 2>&1 || true; else systemctl disable "$1" 2>/dev/null || true; fi; }
svc_is_active() { if [[ "$(detect_init)" == "openrc" ]]; then if rc-service "$1" status >/dev/null 2>&1; then echo "active"; else echo "inactive"; return 1; fi; else if systemctl is-active --quiet "$1" 2>/dev/null; then echo "active"; else echo "inactive"; return 1; fi; fi; }
svc_status()  { if [[ "$(detect_init)" == "openrc" ]]; then rc-service "$1" status 2>/dev/null || true; else systemctl status "$1" --no-pager 2>/dev/null || true; fi; }
svc_reload()  { if [[ "$(detect_init)" != "openrc" ]]; then systemctl daemon-reload; fi; }
svc_main_pid() { if [[ "$(detect_init)" == "openrc" ]]; then cat "/run/${1}.pid" 2>/dev/null || echo "0"; else systemctl show -p MainPID "$1" 2>/dev/null | cut -d= -f2; fi; }
svc_list()    { ls /etc/systemd/system/$1*.service /etc/init.d/$1* 2>/dev/null | sed 's|.*/||; s/\.service$//' | sort -u; }
svc_cat()     { if [[ "$(detect_init)" == "openrc" ]]; then cat "/etc/init.d/$1" 2>/dev/null; else systemctl cat "$1" 2>/dev/null; fi; }

# ============================================
# 服务状态检查
# ============================================

fi  # end inline svc fallback
check_and_show_status() {
    local cpu_cores=$(nproc)

    echo -e "
${CYAN}=== 服务状态检查 ===${RESET}"
    echo -e "${CYAN}系统 CPU 核心数：${cpu_cores}${RESET}"

    # --- Snell ---
    if command -v snell-server &> /dev/null; then
        local user_count=0 running_count=0 total_snell_memory=0 total_snell_cpu=0
        if svc_is_active snell &> /dev/null; then
            user_count=$((user_count + 1)); running_count=$((running_count + 1))
            local main_pid=$(svc_main_pid snell)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null || echo 0)
                local cpu=$(get_cpu_usage "$main_pid")
                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        if [ -d "/usr/local/etc/snell/users" ]; then
            for user_conf in "/usr/local/etc/snell/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if svc_is_active "snell-${port}"; then
                            running_count=$((running_count + 1))
                            local user_pid=$(svc_main_pid "snell-${port}")
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null || echo 0)
                                local cpu=$(get_cpu_usage "$user_pid")
                                total_snell_memory=$((total_snell_memory + ${mem:-0}))
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + ${cpu:-0}" | bc -l 2>/dev/null || echo "0")
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        total_snell_memory=${total_snell_memory:-0}; total_snell_cpu=${total_snell_cpu:-0}
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc -l 2>/dev/null || echo "0")
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}
" "${total_snell_cpu:-0}" "${total_snell_memory_mb:-0}"
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi

    # --- SS-2022 ---
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_memory=0 ss_cpu=0 ss_running=0
        if svc_is_active ss-rust &> /dev/null; then
            ss_running=1
            local ss_pid=$(svc_main_pid ss-rust)
            if [ ! -z "$ss_pid" ] && [ "$ss_pid" != "0" ]; then
                ss_memory=$(ps -o rss= -p $ss_pid 2>/dev/null || echo 0)
                ss_cpu=$(get_cpu_usage "$ss_pid")
            fi
        fi
        local ss_memory_mb=$(echo "scale=2; $ss_memory/1024" | bc 2>/dev/null || echo "0")
        printf "${GREEN}SS-2022 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${ss_running}/1${RESET}
" "$ss_cpu" "$ss_memory_mb"
    else
        echo -e "${YELLOW}SS-2022 未安装${RESET}"
    fi

    # --- ShadowTLS ---
    if svc_list "shadowtls-" 2>/dev/null | grep -q .; then
        local stls_total=0 stls_running=0 total_stls_memory=0 total_stls_cpu=0
        while IFS= read -r service; do
            stls_total=$((stls_total + 1))
            if svc_is_active "$service" &> /dev/null; then
                stls_running=$((stls_running + 1))
                local stls_pid=$(svc_main_pid "$service")
                if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                    local mem=$(ps -o rss= -p $stls_pid 2>/dev/null || echo 0)
                    local cpu=$(get_cpu_usage "$stls_pid")
                    total_stls_memory=$((total_stls_memory + mem))
                    total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l 2>/dev/null || echo "0")
                fi
            fi
        done < <(svc_list "shadowtls-" 2>/dev/null | awk '{print $1}')
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc 2>/dev/null || echo "0")
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}
" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi

    # --- AnyTLS ---
    if [[ -x "${ANYTLS_BINARY}" ]] || [[ -f "${ANYTLS_SYSTEMD_UNIT}" ]] || [[ -f "${ANYTLS_OPENRC_INIT}" ]]; then
        local at_memory=0 at_cpu=0 at_running=0
        if [[ -f "${ANYTLS_SYSTEMD_UNIT}" ]] && svc_is_active "${ANYTLS_SERVICE_NAME}" &> /dev/null; then
            at_running=1
            local at_pid=$(svc_main_pid "${ANYTLS_SERVICE_NAME}")
            if [ ! -z "$at_pid" ] && [ "$at_pid" != "0" ]; then
                at_memory=$(ps -o rss= -p $at_pid 2>/dev/null || echo 0)
                at_cpu=$(get_cpu_usage "$at_pid")
            fi
        fi
        local at_memory_mb=$(echo "scale=2; $at_memory/1024" | bc 2>/dev/null || echo "0")
        printf "${GREEN}AnyTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${at_running}/1${RESET}
" "$at_cpu" "$at_memory_mb"
    else
        echo -e "${YELLOW}AnyTLS 未安装${RESET}"
    fi

    # --- Hysteria 2 ---
    if [[ -f "/usr/local/bin/hysteria" ]] && [[ -f "${HY2_CONFIG_FILE}" ]]; then
        local hy2_memory=0 hy2_cpu=0 hy2_running=0
        if svc_is_active "${HY2_SERVICE_NAME}" &> /dev/null; then
            hy2_running=1
            local hy2_pid=$(svc_main_pid "${HY2_SERVICE_NAME}")
            if [ ! -z "$hy2_pid" ] && [ "$hy2_pid" != "0" ]; then
                hy2_memory=$(ps -o rss= -p $hy2_pid 2>/dev/null || echo 0)
                hy2_cpu=$(get_cpu_usage "$hy2_pid")
            fi
        fi
        local hy2_memory_mb=$(echo "scale=2; $hy2_memory/1024" | bc 2>/dev/null || echo "0")
        printf "${GREEN}Hysteria2 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${hy2_running}/1${RESET}
" "$hy2_cpu" "$hy2_memory_mb"
    else
        echo -e "${YELLOW}Hysteria2 未安装${RESET}"
    fi

    echo -e "${CYAN}====================${RESET}
"
}

# ============================================
# 脚本更新
# ============================================

update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    TMP_SCRIPT=$(mktemp)

    if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/viogus/scripts/main/menu.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep "current_version=" "$TMP_SCRIPT" | cut -d'"' -f2)

        if [ -z "$new_version" ]; then
            echo -e "${RED}无法获取新版本信息${RESET}"
            rm -f "$TMP_SCRIPT"
            return 1
        fi

        echo -e "${YELLOW}当前版本：${current_version}${RESET}"
        echo -e "${YELLOW}最新版本：${new_version}${RESET}"

        if [ "$new_version" != "$current_version" ]; then
            echo -e "${CYAN}是否更新到新版本？[y/N]${RESET}"
            read -r choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                SCRIPT_PATH=$(readlink -f "$0")
                cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                mv "$TMP_SCRIPT" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                echo -e "${GREEN}脚本已更新到最新版本${RESET}"
                echo -e "${YELLOW}已备份原脚本到：${SCRIPT_PATH}.backup${RESET}"
                echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
                exit 0
            else
                echo -e "${YELLOW}已取消更新${RESET}"
                rm -f "$TMP_SCRIPT"
            fi
        else
            echo -e "${GREEN}当前已是最新版本${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}下载新版本失败，请检查网络连接${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# ============================================
# 外部服务管理（委托到对应脚本）
# ============================================

run_service_script() {
    local name="$1" url="$2"
    local tmp; tmp=$(mktemp)
    if curl -sL --connect-timeout 10 --max-time 30 "$url" -o "$tmp"; then
        bash "$tmp"; rm -f "$tmp"
    else
        echo -e "${RED}下载 ${name} 管理脚本失败，请检查网络${RESET}"; rm -f "$tmp"
    fi
}

# ============================================
# 卸载功能
# ============================================

uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"
    svc_stop snell 2>/dev/null
    svc_disable snell 2>/dev/null
    if [ -d "/usr/local/etc/snell/users" ]; then
        for user_conf in "/usr/local/etc/snell/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在停止用户服务 (端口: $port)${RESET}"
                    svc_stop "snell-${port}" 2>/dev/null
                    svc_disable "snell-${port}" 2>/dev/null
                    rm -f "/etc/systemd/system/snell-${port}.service" "/etc/init.d/snell-${port}"
                fi
            fi
        done
    fi
    rm -f "/lib/systemd/system/snell.service" "/etc/systemd/system/snell.service" "/etc/init.d/snell"
    rm -f /usr/local/bin/snell-server
    rm -rf /usr/local/etc/snell
    rm -f /usr/local/bin/snell
    svc_reload
    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

uninstall_ss_rust() {
    echo -e "${CYAN}正在卸载 SS-2022...${RESET}"
    svc_stop ss-rust 2>/dev/null
    svc_disable ss-rust 2>/dev/null
    rm -f "/etc/systemd/system/ss-rust.service" "/etc/init.d/ss-rust"
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/usr/local/etc/ss-rust"
    svc_reload
    echo -e "${GREEN}SS-2022 卸载完成！${RESET}"
}

uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"
    while IFS= read -r service; do
        svc_stop "$service" 2>/dev/null
        svc_disable "$service" 2>/dev/null
        rm -f "/etc/systemd/system/${service}.service" "/etc/init.d/${service}"
    done < <(svc_list "shadowtls-" 2>/dev/null | awk '{print $1}')
    rm -f "/usr/local/bin/shadow-tls"
    svc_reload
    echo -e "${GREEN}ShadowTLS 卸载完成！${RESET}"
}


uninstall_anytls() {
    echo -e "${CYAN}正在卸载 AnyTLS...${RESET}"
    if [[ -f "${ANYTLS_SYSTEMD_UNIT}" ]] || [[ -f "${ANYTLS_OPENRC_INIT}" ]]; then
        read -p "确认卸载并删除 AnyTLS 配置？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        svc_stop "${ANYTLS_SERVICE_NAME}" 2>/dev/null || true
        svc_disable "${ANYTLS_SERVICE_NAME}" 2>/dev/null || true
        rm -f "${ANYTLS_SYSTEMD_UNIT}" "${ANYTLS_OPENRC_INIT}"
        rm -rf "${ANYTLS_CONFIG_DIR}" || true
        svc_reload 2>/dev/null || true
        echo -e "${GREEN}AnyTLS 卸载完成！${RESET}"
    else
        echo -e "${YELLOW}AnyTLS 未安装${RESET}"
    fi
}

uninstall_hysteria() {
    echo -e "${CYAN}正在卸载 Hysteria 2...${RESET}"
    if [[ -f "/usr/local/bin/hysteria" ]] || [[ -f "${HY2_CONFIG_FILE}" ]]; then
        read -p "确认卸载并删除 Hysteria 2 配置？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        svc_stop "${HY2_SERVICE_NAME}" 2>/dev/null || true
        svc_disable "${HY2_SERVICE_NAME}" 2>/dev/null || true
        rm -f "/lib/systemd/system/${HY2_SERVICE_NAME}.service" "/etc/init.d/${HY2_SERVICE_NAME}"
        rm -f "/etc/systemd/system/${HY2_SERVICE_NAME}.service" "/etc/init.d/${HY2_SERVICE_NAME}"
        rm -f "/usr/local/bin/hysteria"
        if [[ -f "/usr/local/etc/hysteria/port_hop" ]]; then
            local hop_range; hop_range=$(cat "/usr/local/etc/hysteria/port_hop")
            iptables -t nat -D PREROUTING -p udp --dport "$hop_range" -j DNAT --to-destination ":" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$hop_range" -j DNAT --to-destination ":" 2>/dev/null || true
            netfilter-persistent save 2>/dev/null || true
        fi
        rm -f /root/cert.crt /root/private.key /root/ca.log 2>/dev/null || true
        rm -rf "/usr/local/etc/hysteria"
        svc_reload 2>/dev/null || true
        echo -e "${GREEN}Hysteria 2 卸载完成！${RESET}"
    else
        echo -e "${YELLOW}Hysteria 2 未安装${RESET}"
    fi
}

# IP 检测（供 surge_export_all 使用）
at_get_ip() {
    local ip4 ip6
    ip4=$(curl -s --connect-timeout 5 --max-time 10 -4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -n "${ip4}" ]] && { echo "${ip4}"; return; }
    ip6=$(curl -s --connect-timeout 5 --max-time 10 -6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -n "${ip6}" ]] && { echo "${ip6}"; return; }
    curl -s --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || echo "未知IP"
}

# ============================================
# Surge 配置导出（所有服务）
# ============================================

surge_export_all() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}         Surge 代理配置汇总${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    local ip; ip="$(at_get_ip 2>/dev/null || echo "服务器IP")"
    echo -e "${YELLOW}服务器 IP: ${ip}${RESET}
"

    # --- AnyTLS ---
    if [[ -f "${ANYTLS_CONFIG_FILE}" ]]; then
        local at_port at_pass
        at_port=$(sed -nE 's/^[[:space:]]*listen:[[:space:]]*.*:([0-9]+)[[:space:]]*$/\1/p' "${ANYTLS_CONFIG_FILE}" 2>/dev/null || true)
        at_pass=$(sed -nE 's/^[[:space:]]*password:[[:space:]]*(.*)$/\1/p' "${ANYTLS_CONFIG_FILE}" 2>/dev/null || true)
        if [[ -n "${at_port}" && -n "${at_pass}" ]]; then
            echo -e "${GREEN}[AnyTLS]${RESET}"
            echo "Proxy-AnyTLS = anytls, ${ip}, ${at_port}, password=${at_pass}"
            echo ""
        fi
    fi

    # --- Snell ---
    if command -v snell-server &> /dev/null; then
        # 优先使用新路径，兼容旧路径
        local sn_conf=""
        if [ -f "/usr/local/etc/snell/users/snell-main.conf" ]; then
            sn_conf="/usr/local/etc/snell/users/snell-main.conf"
        elif [ -f "/usr/local/etc/snell/snell-server.conf" ]; then
            sn_conf="/usr/local/etc/snell/snell-server.conf"
        fi
        if [[ -n "${sn_conf}" ]]; then
            local sn_port sn_psk sn_obfs
            sn_port=$(grep -E '^listen' "$sn_conf" 2>/dev/null | sed -n 's/.*:\([0-9]*\)/\1/p' | head -1 || true)
            sn_psk=$(grep -E '^psk' "$sn_conf" 2>/dev/null | awk '{print $3}' || true)
            sn_obfs=$(grep -E '^obfs' "$sn_conf" 2>/dev/null | awk '{print $3}' || echo "http")
            if [[ -n "${sn_port}" && -n "${sn_psk}" ]]; then
                echo -e "${GREEN}[Snell]${RESET}"
                local sn_extra=""
                [[ -n "${sn_obfs}" && "${sn_obfs}" != "off" ]] && sn_extra=", obfs=${sn_obfs}"
                echo "Proxy-Snell = snell, ${ip}, ${sn_port}, psk=${sn_psk}, version=4${sn_extra}"
                echo ""
            fi
        fi

        # Snell 多用户
        if [ -d "/usr/local/etc/snell/users" ]; then
            local idx=1
            for user_conf in "/usr/local/etc/snell/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local u_port u_psk
                    u_port=$(grep -E '^listen' "$user_conf" 2>/dev/null | sed -n 's/.*:\([0-9]*\)/\1/p' || true)
                    u_psk=$(grep -E '^psk' "$user_conf" 2>/dev/null | awk '{print $3}' || true)
                    if [[ -n "${u_port}" && -n "${u_psk}" ]]; then
                        echo -e "${GREEN}[Snell 用户${idx}]${RESET}"
                        echo "Proxy-Snell-${idx} = snell, ${ip}, ${u_port}, psk=${u_psk}, version=4"
                        echo ""
                        idx=$((idx + 1))
                    fi
                fi
            done
        fi
    fi

    # --- SS-2022 ---
    if [ -f "/usr/local/etc/ss-rust/config.json" ]; then
        local ss_port ss_method ss_pass
        ss_port=$(sed -n 's/.*"server_port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' /usr/local/etc/ss-rust/config.json 2>/dev/null | head -1 || true)
        ss_method=$(sed -n 's/.*"method"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/ss-rust/config.json 2>/dev/null | head -1 || true)
        ss_pass=$(sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /usr/local/etc/ss-rust/config.json 2>/dev/null | head -1 || true)
        if [[ -n "${ss_port}" ]]; then
            echo -e "${GREEN}[SS-2022]${RESET}"
            echo "Proxy-SS = ss, ${ip}, ${ss_port}, encrypt-method=${ss_method:-2022-blake3-aes-256-gcm}, password=${ss_pass}"
            echo ""
        fi
    fi

    # --- ShadowTLS ---
    # ShadowTLS 在 Surge 中不是独立代理，而是附加参数
    # 从 systemd 服务提取密码，提示用户附加到其他代理
    if svc_list "shadowtls-" 2>/dev/null | grep -q .; then
        echo -e "${CYAN}[ShadowTLS - Surge 中需附加到其他代理]${RESET}"
        echo -e "${YELLOW}将 shadow-tls-password 参数附加到 Snell/SS 代理即可：${RESET}"
        local stls_count=0
        while IFS= read -r service; do
            local stls_exec=$(svc_cat "$service" 2>/dev/null | grep "ExecStart=" | head -1 || true)
            if [[ -n "$stls_exec" ]]; then
                local stls_port=$(echo "$stls_exec" | sed -n 's/.*--tls[[:space:]]\+[^[:space:]]*:\([0-9]\+\).*/\1/p' | head -1 || true)
                [[ -z "$stls_port" ]] && stls_port=$(echo "$stls_exec" | sed -n 's/.*0\.0\.0\.0:\([0-9]\+\).*/\1/p' | head -1 || true)
                local stls_pass=$(echo "$stls_exec" | sed -n 's/.*--password[[:space:]]\+\([^[:space:]]\+\).*/\1/p' || true)
                if [[ -n "${stls_pass}" ]]; then
                    stls_count=$((stls_count + 1))
                    echo "# STLS-${stls_count}: shadow-tls-password=${stls_pass}, shadow-tls-version=3, shadow-tls-port=${stls_port:-?}"
                fi
            fi
        done < <(svc_list "shadowtls-" 2>/dev/null | awk '{print $1}')
        if [[ $stls_count -eq 0 ]]; then
            echo -e "${YELLOW}  (无法自动提取配置，请查看 systemd 服务文件)${RESET}"
        fi
        echo ""
    fi

    # --- Hysteria 2 ---
    if [[ -f "${HY2_CONFIG_FILE}" ]]; then
        local hy2_port hy2_pwd hy2_sni
        hy2_port=$(sed -n 's/^listen:[[:space:]]*:\([0-9]*\).*/\1/p' "${HY2_CONFIG_FILE}" 2>/dev/null | head -1 || true)
        hy2_pwd=$(sed -n '/^auth:/,/^[a-z]/{s/^[[:space:]]*password:[[:space:]]*\(.*\)/\1/p}' "${HY2_CONFIG_FILE}" 2>/dev/null | head -1 || true)
        hy2_sni=$(sed -n '/^tls:/,/^[a-z]/{s/^[[:space:]]*sni:[[:space:]]*\(.*\)/\1/p}' "${HY2_CLIENT_YAML}" 2>/dev/null || echo "www.bing.com")
        if [[ -n "${hy2_port}" && -n "${hy2_pwd}" ]]; then
            echo -e "${GREEN}[Hysteria2]${RESET}"
            echo "Proxy-Hysteria = hysteria2, ${ip}, ${hy2_port}, password=${hy2_pwd}, sni=${hy2_sni}"
            echo ""
        fi
    fi

    # --- VLESS Reality ---
    # Surge 不支持 VLESS 协议，跳过
    if [ -f "/usr/local/etc/xray/config.json" ] || [ -d "/usr/local/etc/xray" ]; then
        echo -e "${YELLOW}[VLESS] Surge 不支持 VLESS 协议，无法导出。请使用支持 VLESS 的客户端。${RESET}
"
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${YELLOW}提示：复制上方配置到 Surge 的 [Proxy] 段落即可${RESET}"
    echo -e "${CYAN}============================================${RESET}"
}

# ============================================
# 主菜单
# ============================================

show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}     统一管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian & viogus${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com | https://github.com/viogus${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    check_and_show_status

    echo -e "${YELLOW}=== 安装管理 ===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell 安装管理"
    echo -e "${GREEN}2.${RESET} SS-2022 安装管理"
    echo -e "${GREEN}3.${RESET} VLESS Reality 安装管理"
    echo -e "${GREEN}4.${RESET} ShadowTLS 安装管理"
    echo -e "${GREEN}5.${RESET} AnyTLS 安装管理"
    echo -e "${GREEN}6.${RESET} Hysteria 2 安装管理"

    echo -e "
${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}7.${RESET} 卸载 Snell"
    echo -e "${GREEN}8.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}9.${RESET} 卸载 ShadowTLS"
    echo -e "${GREEN}10.${RESET} 卸载 AnyTLS"
    echo -e "${GREEN}11.${RESET} 卸载 Hysteria 2"

    echo -e "
${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}12.${RESET} 更新脚本"
    echo -e "${GREEN}13.${RESET} 输出 Surge 配置"
	    echo -e "${GREEN}14.${RESET} [新] 统一管理模式 (测试中)"
    echo -e "${GREEN}0.${RESET} 退出"

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}退出脚本后，输入 menu 可重新进入${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-14]: " num
}

# ============================================
# 主程序入口
# ============================================

# === 统一框架模式 (从 GitHub 动态加载) ===
run_framework_mode() {
    local fw_tmp svc_tmp conf_tmp
    echo -e "${CYAN}正在加载统一管理框架...${RESET}"

    fw_tmp=$(fw_download "lib/framework.sh") || {
        echo -e "${RED}下载 framework.sh 失败，请检查网络${RESET}"
        read -rp "按回车返回..." _
        return
    }
    . "$fw_tmp"

    svc_tmp=$(mktemp -d /tmp/fw-services-XXXXXX)
    local confs="anytls hysteria2"
    for c in $confs; do
        conf_tmp=$(fw_download "services/${c}.conf") && mv "$conf_tmp" "${svc_tmp}/${c}.conf"
    done

    show_all_status "$svc_tmp"

    echo -e "${CYAN}可用服务:${RESET}"
    local i=1
    local confs_list=()
    for conf in "${svc_tmp}"/*.conf; do
        [[ -f "$conf" ]] || continue
        . "$conf"
        echo -e "${GREEN}${i}.${RESET} ${DISPLAY}"
        confs_list+=("$conf")
        ((i++))
    done

    if [[ ${#confs_list[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有可用的服务配置${RESET}"
        rm -rf "$svc_tmp" "$fw_tmp"
        read -rp "按回车返回..." _
        return
    fi

    echo ""
    read -rp "选择服务 (1-$((i-1)), 0 返回): " svc_choice
    if [[ "${svc_choice:-0}" != "0" ]] && [[ "$svc_choice" -ge 1 ]] && [[ "$svc_choice" -le ${#confs_list[@]} ]]; then
        show_service_submenu "${confs_list[$((svc_choice-1))]}"
    fi

    rm -rf "$svc_tmp" "$fw_tmp"
}

check_root
check_dependencies
install_global_command

while true; do
    show_menu
    case "$num" in
        1) run_service_script "Snell" "https://raw.githubusercontent.com/viogus/scripts/main/snell.sh" ;;
        2) run_service_script "SS-2022" "https://raw.githubusercontent.com/viogus/scripts/main/ss-2022.sh" ;;
        3) run_service_script "VLESS" "https://raw.githubusercontent.com/viogus/scripts/main/vless.sh" ;;
        4) run_service_script "ShadowTLS" "https://raw.githubusercontent.com/viogus/scripts/main/shadowtls.sh" ;;
        5) run_service_script "AnyTLS" "https://raw.githubusercontent.com/viogus/scripts/main/anytls.sh" ;;
        6) run_service_script "Hysteria 2" "https://raw.githubusercontent.com/viogus/scripts/main/hysteria2.sh" ;;
        7) uninstall_snell ;;
        8) uninstall_ss_rust ;;
        9) uninstall_shadowtls ;;
        10) uninstall_anytls ;;
        11) uninstall_hysteria ;;
        12) update_script ;;
        13) surge_export_all ;;
        14) run_framework_mode ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的选项 [0-14]${RESET}" ;;
    esac
    echo -e "
${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
