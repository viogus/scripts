#!/bin/bash
# =========================================
# 作者: jinqians + viogus
# 日期: 2026年5月
# 网站：jinqians.com / github.com/viogus
# 描述: 统一管理 Snell、SS-Rust、ShadowTLS、VLESS Reality、AnyTLS
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

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
        cpu_usage=$(top -b -n 2 -d 0.2 -p "$pid" | tail -1 | awk '{print $9}')
        if [ -z "$cpu_usage" ]; then
            cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo 0)
        fi
        cpu_usage=$(echo "scale=2; $cpu_usage / $cpu_cores" | bc -l 2>/dev/null || echo "0")
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
# 服务状态检查
# ============================================

check_and_show_status() {
    local cpu_cores=$(nproc)

    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    echo -e "${CYAN}系统 CPU 核心数：${cpu_cores}${RESET}"

    # --- Snell ---
    if command -v snell-server &> /dev/null; then
        local user_count=0 running_count=0 total_snell_memory=0 total_snell_cpu=0
        if systemctl is-active snell &> /dev/null; then
            user_count=$((user_count + 1)); running_count=$((running_count + 1))
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
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
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
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
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${running_count}/${user_count}${RESET}\n" "${total_snell_cpu:-0}" "${total_snell_memory_mb:-0}"
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi

    # --- SS-2022 ---
    if [[ -e "/usr/local/bin/ss-rust" ]]; then
        local ss_memory=0 ss_cpu=0 ss_running=0
        if systemctl is-active ss-rust &> /dev/null; then
            ss_running=1
            local ss_pid=$(systemctl show -p MainPID ss-rust | cut -d'=' -f2)
            if [ ! -z "$ss_pid" ] && [ "$ss_pid" != "0" ]; then
                ss_memory=$(ps -o rss= -p $ss_pid 2>/dev/null || echo 0)
                ss_cpu=$(get_cpu_usage "$ss_pid")
            fi
        fi
        local ss_memory_mb=$(echo "scale=2; $ss_memory/1024" | bc 2>/dev/null || echo "0")
        printf "${GREEN}SS-2022 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${ss_running}/1${RESET}\n" "$ss_cpu" "$ss_memory_mb"
    else
        echo -e "${YELLOW}SS-2022 未安装${RESET}"
    fi

    # --- ShadowTLS ---
    if systemctl list-units --type=service 2>/dev/null | grep -q "shadowtls-"; then
        local stls_total=0 stls_running=0 total_stls_memory=0 total_stls_cpu=0
        while IFS= read -r service; do
            stls_total=$((stls_total + 1))
            if systemctl is-active "$service" &> /dev/null; then
                stls_running=$((stls_running + 1))
                local stls_pid=$(systemctl show -p MainPID "$service" | cut -d'=' -f2)
                if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                    local mem=$(ps -o rss= -p $stls_pid 2>/dev/null || echo 0)
                    local cpu=$(get_cpu_usage "$stls_pid")
                    total_stls_memory=$((total_stls_memory + mem))
                    total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l 2>/dev/null || echo "0")
                fi
            fi
        done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "shadowtls-" | awk '{print $1}')
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc 2>/dev/null || echo "0")
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi

    # --- AnyTLS ---
    if [[ -x "${ANYTLS_BINARY}" ]] || [[ -f "${ANYTLS_SYSTEMD_UNIT}" ]]; then
        local at_memory=0 at_cpu=0 at_running=0
        if [[ -f "${ANYTLS_SYSTEMD_UNIT}" ]] && systemctl is-active "${ANYTLS_SERVICE_NAME}" &> /dev/null; then
            at_running=1
            local at_pid=$(systemctl show -p MainPID "${ANYTLS_SERVICE_NAME}" | cut -d'=' -f2)
            if [ ! -z "$at_pid" ] && [ "$at_pid" != "0" ]; then
                at_memory=$(ps -o rss= -p $at_pid 2>/dev/null || echo 0)
                at_cpu=$(get_cpu_usage "$at_pid")
            fi
        fi
        local at_memory_mb=$(echo "scale=2; $at_memory/1024" | bc 2>/dev/null || echo "0")
        printf "${GREEN}AnyTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${at_running}/1${RESET}\n" "$at_cpu" "$at_memory_mb"
    else
        echo -e "${YELLOW}AnyTLS 未安装${RESET}"
    fi

    # --- Hysteria 2 ---
    if [[ -f "/usr/local/bin/hysteria" ]] && [[ -f "${HY2_CONFIG_FILE}" ]]; then
        local hy2_memory=0 hy2_cpu=0 hy2_running=0
        if systemctl is-active "${HY2_SERVICE_NAME}" &> /dev/null; then
            hy2_running=1
            local hy2_pid=$(systemctl show -p MainPID "${HY2_SERVICE_NAME}" | cut -d'=' -f2)
            if [ ! -z "$hy2_pid" ] && [ "$hy2_pid" != "0" ]; then
                hy2_memory=$(ps -o rss= -p $hy2_pid 2>/dev/null || echo 0)
                hy2_cpu=$(get_cpu_usage "$hy2_pid")
            fi
        fi
        local hy2_memory_mb=$(echo "scale=2; $hy2_memory/1024" | bc 2>/dev/null || echo "0")
        printf "${GREEN}Hysteria2 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：${hy2_running}/1${RESET}\n" "$hy2_cpu" "$hy2_memory_mb"
    else
        echo -e "${YELLOW}Hysteria2 未安装${RESET}"
    fi

    echo -e "${CYAN}====================${RESET}\n"
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

manage_snell() {
    local tmp; tmp=$(mktemp)
    if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/viogus/scripts/main/snell.sh -o "$tmp"; then
        bash "$tmp"; rm -f "$tmp"
    else
        echo -e "${RED}下载 Snell 管理脚本失败，请检查网络${RESET}"; rm -f "$tmp"
    fi
}

manage_ss_rust() {
    local tmp; tmp=$(mktemp)
    if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/viogus/scripts/main/ss-2022.sh -o "$tmp"; then
        bash "$tmp"; rm -f "$tmp"
    else
        echo -e "${RED}下载 SS-2022 管理脚本失败，请检查网络${RESET}"; rm -f "$tmp"
    fi
}

manage_shadowtls() {
    local tmp; tmp=$(mktemp)
    if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/viogus/scripts/main/shadowtls.sh -o "$tmp"; then
        bash "$tmp"; rm -f "$tmp"
    else
        echo -e "${RED}下载 ShadowTLS 管理脚本失败，请检查网络${RESET}"; rm -f "$tmp"
    fi
}

manage_vless() {
    local tmp; tmp=$(mktemp)
    if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/viogus/scripts/main/vless.sh -o "$tmp"; then
        bash "$tmp"; rm -f "$tmp"
    else
        echo -e "${RED}下载 VLESS 管理脚本失败，请检查网络${RESET}"; rm -f "$tmp"
    fi
}

# ============================================
# 卸载功能
# ============================================

uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell${RESET}"
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    if [ -d "/usr/local/etc/snell/users" ]; then
        for user_conf in "/usr/local/etc/snell/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}正在停止用户服务 (端口: $port)${RESET}"
                    systemctl stop "snell-${port}" 2>/dev/null
                    systemctl disable "snell-${port}" 2>/dev/null
                    rm -f "/etc/systemd/system/snell-${port}.service"
                fi
            fi
        done
    fi
    rm -f "/lib/systemd/system/snell.service"
    rm -f "/etc/systemd/system/snell.service"
    rm -f /usr/local/bin/snell-server
    rm -rf /usr/local/etc/snell
    rm -f /usr/local/bin/snell
    systemctl daemon-reload
    echo -e "${GREEN}Snell 及其所有多用户配置已成功卸载${RESET}"
}

uninstall_ss_rust() {
    echo -e "${CYAN}正在卸载 SS-2022...${RESET}"
    systemctl stop ss-rust 2>/dev/null
    systemctl disable ss-rust 2>/dev/null
    rm -f "/etc/systemd/system/ss-rust.service"
    rm -f "/usr/local/bin/ss-rust"
    rm -rf "/usr/local/etc/ss-rust"
    systemctl daemon-reload
    echo -e "${GREEN}SS-2022 卸载完成！${RESET}"
}

uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"
    while IFS= read -r service; do
        systemctl stop "$service" 2>/dev/null
        systemctl disable "$service" 2>/dev/null
        rm -f "/etc/systemd/system/${service}"
    done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "shadowtls-" | awk '{print $1}')
    rm -f "/usr/local/bin/shadow-tls"
    systemctl daemon-reload
    echo -e "${GREEN}ShadowTLS 卸载完成！${RESET}"
}

# ============================================
# AnyTLS 管理（委托到 anytls.sh）
# ============================================

manage_anytls() {
    local tmp; tmp=$(mktemp)
    if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/viogus/scripts/main/anytls.sh -o "$tmp"; then
        bash "$tmp"; rm -f "$tmp"
    else
        echo -e "${RED}下载 AnyTLS 管理脚本失败，请检查网络${RESET}"; rm -f "$tmp"
    fi
}

manage_hysteria() {
    local tmp; tmp=$(mktemp)
    if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/viogus/scripts/main/hysteria2.sh -o "$tmp"; then
        bash "$tmp"; rm -f "$tmp"
    else
        echo -e "${RED}下载 Hysteria 2 管理脚本失败，请检查网络${RESET}"; rm -f "$tmp"
    fi
}

uninstall_anytls() {
    echo -e "${CYAN}正在卸载 AnyTLS...${RESET}"
    if [[ -f "${ANYTLS_SYSTEMD_UNIT}" ]]; then
        read -p "确认卸载并删除 AnyTLS 配置？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        systemctl stop "${ANYTLS_SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${ANYTLS_SERVICE_NAME}" 2>/dev/null || true
        rm -f "${ANYTLS_SYSTEMD_UNIT}" || true
        rm -rf "${ANYTLS_CONFIG_DIR}" || true
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}AnyTLS 卸载完成！${RESET}"
    elif [[ -f "${ANYTLS_OPENRC_INIT}" ]]; then
        read -p "确认卸载并删除 AnyTLS 配置？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        rc-service "${ANYTLS_SERVICE_NAME}" stop 2>/dev/null || true
        rc-update del "${ANYTLS_SERVICE_NAME}" default >/dev/null 2>&1 || true
        rm -f "${ANYTLS_OPENRC_INIT}" || true
        rm -rf "${ANYTLS_CONFIG_DIR}" || true
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
        systemctl stop "${HY2_SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${HY2_SERVICE_NAME}" 2>/dev/null || true
        rm -f "/lib/systemd/system/${HY2_SERVICE_NAME}.service"
        rm -f "/etc/systemd/system/${HY2_SERVICE_NAME}.service"
        rm -f "/usr/local/bin/hysteria"
        if [[ -f "/usr/local/etc/hysteria/port_hop" ]]; then
            local hop_range; hop_range=$(cat "/usr/local/etc/hysteria/port_hop")
            iptables -t nat -D PREROUTING -p udp --dport "$hop_range" -j DNAT --to-destination ":" 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$hop_range" -j DNAT --to-destination ":" 2>/dev/null || true
            netfilter-persistent save 2>/dev/null || true
        fi
        rm -f /root/cert.crt /root/private.key /root/ca.log 2>/dev/null || true
        rm -rf "/usr/local/etc/hysteria"
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}Hysteria 2 卸载完成！${RESET}"
    else
        echo -e "${YELLOW}Hysteria 2 未安装${RESET}"
    fi
}

# IP 检测（供 surge_export_all 使用）
at_get_ip() {
    local ip4 ip6
    ip4=$(curl -s --connect-timeout 5 --max-time 10 -4 http://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -n "${ip4}" ]] && { echo "${ip4}"; return; }
    ip6=$(curl -s --connect-timeout 5 --max-time 10 -6 http://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
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
    echo -e "${YELLOW}服务器 IP: ${ip}${RESET}\n"

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
    if command -v snell-server &> /dev/null && [ -f "/usr/local/etc/snell/snell-server.conf" ]; then
        local sn_port sn_psk sn_obfs
        sn_port=$(grep -E '^listen' /usr/local/etc/snell/snell-server.conf 2>/dev/null | sed -n 's/.*:\([0-9]*\)/\1/p' | head -1 || true)
        sn_psk=$(grep -E '^psk' /usr/local/etc/snell/snell-server.conf 2>/dev/null | awk '{print $3}' || true)
        sn_obfs=$(grep -E '^obfs' /usr/local/etc/snell/snell-server.conf 2>/dev/null | awk '{print $3}' || echo "http")
        if [[ -n "${sn_port}" && -n "${sn_psk}" ]]; then
            echo -e "${GREEN}[Snell]${RESET}"
            local sn_extra=""
            [[ -n "${sn_obfs}" && "${sn_obfs}" != "off" ]] && sn_extra=", obfs=${sn_obfs}"
            echo "Proxy-Snell = snell, ${ip}, ${sn_port}, psk=${sn_psk}, version=4${sn_extra}"
            echo ""
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
    if systemctl list-units --type=service 2>/dev/null | grep -q "shadowtls-"; then
        echo -e "${CYAN}[ShadowTLS - Surge 中需附加到其他代理]${RESET}"
        echo -e "${YELLOW}将 shadow-tls-password 参数附加到 Snell/SS 代理即可：${RESET}"
        local stls_count=0
        while IFS= read -r service; do
            local stls_exec=$(systemctl cat "$service" 2>/dev/null | grep "ExecStart=" | head -1 || true)
            if [[ -n "$stls_exec" ]]; then
                local stls_port=$(echo "$stls_exec" | sed -n 's/.*--tls[[:space:]]\+[^[:space:]]*:\([0-9]\+\).*/\1/p' | head -1 || true)
                [[ -z "$stls_port" ]] && stls_port=$(echo "$stls_exec" | sed -n 's/.*0\.0\.0\.0:\([0-9]\+\).*/\1/p' | head -1 || true)
                local stls_pass=$(echo "$stls_exec" | sed -n 's/.*--password[[:space:]]\+\([^[:space:]]\+\).*/\1/p' || true)
                if [[ -n "${stls_pass}" ]]; then
                    stls_count=$((stls_count + 1))
                    echo "# STLS-${stls_count}: shadow-tls-password=${stls_pass}, shadow-tls-version=3, shadow-tls-port=${stls_port:-?}"
                fi
            fi
        done < <(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep "shadowtls-" | awk '{print $1}')
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
        hy2_sni=$(sed -n '/^tls:/,/^[a-z]/{s/^[[:space:]]*sni:[[:space:]]*\(.*\)/\1/p}' "${HY2_CLIENT_YAML}" 2>/dev/null | head -1 || echo "www.bing.com")
        if [[ -n "${hy2_port}" && -n "${hy2_pwd}" ]]; then
            echo -e "${GREEN}[Hysteria2]${RESET}"
            echo "Proxy-Hysteria = hysteria2, ${ip}, ${hy2_port}, password=${hy2_pwd}, sni=${hy2_sni}"
            echo ""
        fi
    fi

    # --- VLESS Reality ---
    # Surge 不支持 VLESS 协议，跳过
    if [ -f "/usr/local/etc/xray/config.json" ] || [ -d "/usr/local/etc/xray" ]; then
        echo -e "${YELLOW}[VLESS] Surge 不支持 VLESS 协议，无法导出。请使用支持 VLESS 的客户端。${RESET}\n"
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

    echo -e "\n${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}7.${RESET} 卸载 Snell"
    echo -e "${GREEN}8.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}9.${RESET} 卸载 ShadowTLS"
    echo -e "${GREEN}10.${RESET} 卸载 AnyTLS"
    echo -e "${GREEN}11.${RESET} 卸载 Hysteria 2"

    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}12.${RESET} 更新脚本"
    echo -e "${GREEN}13.${RESET} 输出 Surge 配置"
    echo -e "${GREEN}0.${RESET} 退出"

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}退出脚本后，输入 menu 可重新进入${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-13]: " num
}

# ============================================
# 主程序入口
# ============================================

check_root
check_dependencies
install_global_command

while true; do
    show_menu
    case "$num" in
        1) manage_snell ;;
        2) manage_ss_rust ;;
        3) manage_vless ;;
        4) manage_shadowtls ;;
        5) manage_anytls ;;
        6) manage_hysteria ;;
        7) uninstall_snell ;;
        8) uninstall_ss_rust ;;
        9) uninstall_shadowtls ;;
        10) uninstall_anytls ;;
        11) uninstall_hysteria ;;
        12) update_script ;;
        13) surge_export_all ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}请输入正确的选项 [0-13]${RESET}" ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done
