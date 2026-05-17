#!/usr/bin/env bash
# =========================================
# 作者: viogus (基于 flame1ce/hysteria2-install 重构)
# 日期: 2026年5月
# 网站：github.com/viogus
# 描述: Hysteria 2 一键管理脚本（安装/卸载/配置/启停/Surge输出）
# 适配: Debian/Ubuntu (apt) / RHEL系 (dnf/yum) / Alpine (apk)
# init: systemd / openrc
# =========================================
set -euo pipefail

# ============================================
# 常量
# ============================================
CONFIG_DIR="/usr/local/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
CLIENT_YAML="${CONFIG_DIR}/hy-client.yaml"
CLIENT_JSON="${CONFIG_DIR}/hy-client.json"
URL_FILE="${CONFIG_DIR}/url.txt"
SERVICE_NAME="hysteria-server"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_VERSION="1.0.0"

is_installed() {
    if [[ -f "/usr/local/bin/hysteria" ]] && [[ -f "${CONFIG_FILE}" ]]; then
        return 0
    fi
    return 1
}

# ============================================
# 安装依赖
# ============================================

install_deps() {
    local os_type; os_type=$(detect_os)
    print_info "检测到系统类型: ${os_type}"

    if [[ "$os_type" == "debian" ]]; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget sudo procps iptables-persistent netfilter-persistent openssl
    elif [[ "$os_type" == "rhel" ]]; then
        yum -y update || dnf -y update
        yum -y install curl wget sudo procps iptables-services openssl || \
            dnf -y install curl wget sudo procps iptables-services openssl
    elif [[ "$os_type" == "alpine" ]]; then
        apk update
        apk add --no-cache curl wget sudo procps iptables openssl openrc
    else
        print_error "不支持的操作系统"; exit 1
    fi
}

install_hysteria_binary() {
    local os_type; os_type=$(detect_os)
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) print_error "不支持的架构: $arch"; exit 1 ;;
    esac

    if [[ "$os_type" == "alpine" ]]; then
        # Alpine: 直接从官方 GitHub 下载二进制
        local latest_ver; latest_ver=$(curl -s --connect-timeout 10 --max-time 30 https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || true
        if [[ -z "$latest_ver" ]]; then
            print_error "无法获取 Hysteria 最新版本号"; exit 1
        fi
        print_info "Hysteria 最新版本: ${latest_ver}"
        local url="https://github.com/apernet/hysteria/releases/download/${latest_ver}/hysteria-linux-${arch}"
        print_info "正在下载 Hysteria..."
        curl -L --connect-timeout 10 --max-time 120 -o /usr/local/bin/hysteria "$url"
        chmod +x /usr/local/bin/hysteria
    else
        # Debian/RHEL: 使用 Misaka-blog 安装脚本
        local tmp; tmp=$(mktemp)
        print_info "正在下载 Hysteria 2 安装脚本..."
        if curl -sL --connect-timeout 10 --max-time 30 https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/install_server.sh -o "$tmp"; then
            bash "$tmp"
            rm -f "$tmp"
        else
            print_error "下载安装脚本失败"; rm -f "$tmp"; exit 1
        fi
    fi

    if [[ -f "/usr/local/bin/hysteria" ]]; then
        print_ok "Hysteria 2 二进制安装成功"
    else
        print_error "Hysteria 2 安装失败"; exit 1
    fi
}

# ============================================
# 证书
# ============================================

setup_cert() {
    echo ""
    print_info "Hysteria 2 证书申请方式："
    echo -e " ${GREEN}1.${RESET} 自签证书 ${YELLOW}（默认，bing.com）${RESET}"
    echo -e " ${GREEN}2.${RESET} ACME 自动申请 Let's Encrypt 证书"
    echo -e " ${GREEN}3.${RESET} 自定义证书路径"
    echo ""
    read -rp "请选择 [1-3]: " cert_choice

    case "${cert_choice:-1}" in
        2)
            print_info "ACME 证书申请"
            read -p "请输入域名：" domain
            [[ -z "$domain" ]] && { print_error "未输入域名"; exit 1; }

            local ip; ip=$(get_ip)
            local domain_ip; domain_ip=$(curl -s --connect-timeout 5 --max-time 10 https://ipget.net/?ip="${domain}" 2>/dev/null || true)

            if [[ "$domain_ip" != "$ip" ]]; then
                print_error "域名 ${domain} 解析的 IP (${domain_ip}) 与 VPS IP (${ip}) 不匹配"
                print_warn "请确认 DNS 解析正确后再试"; exit 1
            fi

            install_deps
            curl -s https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
            source ~/.bashrc 2>/dev/null || true
            bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

            if [[ -n $(echo "$ip" | grep ":") ]]; then
                bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
            else
                bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure
            fi

            cert_path="/root/cert.crt"
            key_path="/root/private.key"
            bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file "$key_path" --fullchain-file "$cert_path" --ecc

            if [[ -f "$cert_path" && -f "$key_path" ]]; then
                echo "$domain" > /root/ca.log
                sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1 || true
                echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                hy_domain="$domain"
                print_ok "证书申请成功: ${domain}"
            else
                print_error "证书申请失败"; exit 1
            fi
            ;;
        3)
            read -p "请输入公钥 crt 文件路径：" cert_path
            read -p "请输入密钥 key 文件路径：" key_path
            read -p "请输入证书域名：" hy_domain
            print_info "cert: ${cert_path}, key: ${key_path}, domain: ${hy_domain}"
            ;;
        *)
            print_info "使用自签证书 (bing.com)"
            cert_path="${CONFIG_DIR}/cert.crt"
            key_path="${CONFIG_DIR}/private.key"
            mkdir -p "${CONFIG_DIR}"
            openssl ecparam -genkey -name prime256v1 -out "$key_path"
            openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com"
            chmod 644 "$cert_path"; chmod 600 "$key_path"
            hy_domain="www.bing.com"
            print_ok "自签证书生成完毕"
            ;;
    esac
}

# ============================================
# 端口 / 密码 / 伪装站
# ============================================

setup_port() {
    local port
    while true; do
        read -p "设置 Hysteria 2 UDP 端口 [1-65535]，回车随机：" port
        [[ -z "$port" ]] && port=$(shuf -i 2000-65535 -n 1)
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
            if ss -tunlp 2>/dev/null | grep -q ":${port} "; then
                print_warn "端口 ${port} 已被占用"
            else
                break
            fi
        else
            print_warn "端口不合法: ${port}"
        fi
    done
    echo "$port"
}

setup_port_hopping() {
    echo ""
    print_info "Hysteria 2 端口模式："
    echo -e " ${GREEN}1.${RESET} 单端口 ${YELLOW}（默认）${RESET}"
    echo -e " ${GREEN}2.${RESET} 端口跳跃"
    echo ""
    read -rp "请选择 [1-2]: " jump_choice
    if [[ "${jump_choice}" == "2" ]]; then
        local firstport endport
        while true; do
            read -p "起始端口 (10000-65535)：" firstport
            read -p "末尾端口 (大于起始端口)：" endport
            if [[ "$firstport" =~ ^[0-9]+$ ]] && [[ "$endport" =~ ^[0-9]+$ ]] && (( firstport < endport )); then
                iptables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":${1}"
                ip6tables -t nat -A PREROUTING -p udp --dport "$firstport:$endport" -j DNAT --to-destination ":${1}" 2>/dev/null || true
                netfilter-persistent save >/dev/null 2>&1 || true
                echo "${firstport}:${endport}" > "${CONFIG_DIR}/port_hop"
                print_ok "端口跳跃已配置: ${firstport}-${endport}"
                echo "${firstport}-${endport}"
                return
            else
                print_warn "端口范围不合法，请重新输入"
            fi
        done
    fi
}

setup_password() {
    local pwd
    read -p "设置 Hysteria 2 密码，回车随机：" pwd
    [[ -z "$pwd" ]] && pwd=$(date +%s%N | md5sum | cut -c 1-8) || true
    echo "$pwd"
}

setup_masquerade() {
    local site
    read -p "伪装网站域名 (去除 https://)，回车默认 en.snu.ac.kr：" site
    [[ -z "$site" ]] && site="en.snu.ac.kr"
    echo "$site"
}

# ============================================
# 配置生成
# ============================================

write_config() {
    local port="$1" pwd="$2" cert="$3" key="$4" site="$5" sni_domain="$6" ph_range="$7"

    cat > "${CONFIG_FILE}" <<EOF
listen: :${port}

tls:
  cert: ${cert}
  key: ${key}

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: ${pwd}

masquerade:
  type: proxy
  proxy:
    url: https://${site}
    rewriteHost: true
EOF

    local ip; ip=$(get_ip)
    local last_ip="$ip"
    [[ -n $(echo "$ip" | grep ":") ]] && last_ip="[$ip]"

    local last_port="$port"
    [[ -n "${ph_range:-}" ]] && last_port="${port},${ph_range}"

    cat > "${CLIENT_YAML}" <<EOF
server: ${last_ip}:${last_port}

auth: ${pwd}

tls:
  sni: ${sni_domain}
  insecure: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

fastOpen: true

socks5:
  listen: 127.0.0.1:5678

transport:
  udp:
    hopInterval: 30s
EOF

    cat > "${CLIENT_JSON}" <<EOF
{
  "server": "${last_ip}:${last_port}",
  "auth": "${pwd}",
  "tls": {
    "sni": "${sni_domain}",
    "insecure": true
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "transport": {
    "udp": {
      "hopInterval": "30s"
    }
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  }
}
EOF

    local url="hysteria2://${pwd}@${last_ip}:${port}/?insecure=1&sni=${sni_domain}#Hysteria2"
    echo "$url" > "${URL_FILE}"
}

write_openrc_init() {
    cat > "/etc/init.d/${SERVICE_NAME}" <<'OPENRCEOF'
#!/sbin/openrc-run
name="hysteria-server"
description="Hysteria 2 server"
command="/usr/local/bin/hysteria"
command_user="nobody"
command_args="server -c /usr/local/etc/hysteria/config.yaml"
command_background="yes"
pidfile="/run/hysteria.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.err"

depend() {
    need networking
}

OPENRCEOF
    chmod +x "/etc/init.d/${SERVICE_NAME}"
    touch /var/log/hysteria.log /var/log/hysteria.err
    chown nobody:nobody /var/log/hysteria.log /var/log/hysteria.err 2>/dev/null || chown nobody /var/log/hysteria.log /var/log/hysteria.err 2>/dev/null || true
}

reload_service() {
    local init; init=$(detect_init)
    if [[ "$init" == "openrc" ]]; then
        write_openrc_init
        rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true
        rc-service "${SERVICE_NAME}" restart || rc-service "${SERVICE_NAME}" start
        if rc-service "${SERVICE_NAME}" status 2>/dev/null; then
            print_ok "Hysteria 2 服务已启动"
        else
            print_error "Hysteria 2 服务启动失败"
            return 1
        fi
        return
    fi

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl restart "${SERVICE_NAME}"
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        print_ok "Hysteria 2 服务已启动"
    else
        print_error "Hysteria 2 服务启动失败，请运行 systemctl status ${SERVICE_NAME} 检查"
        return 1
    fi
}

# ============================================
# 配置导出（含 Surge 格式）
# ============================================

show_config() {
    if ! is_installed; then
        print_error "Hysteria 2 未安装"
        return
    fi

    local ip; ip=$(get_ip)
    local port pwd sni
    port=$(sed -n 's/^listen:[[:space:]]*:\([0-9]*\).*/\1/p' "${CONFIG_FILE}" 2>/dev/null || true)
    pwd=$(sed -n '/^auth:/,/^[a-z]/{s/^[[:space:]]*password:[[:space:]]*\(.*\)/\1/p}' "${CONFIG_FILE}" 2>/dev/null | head -1 || true)
    sni=$(sed -n '/^tls:/,/^[a-z]/{s/^[[:space:]]*sni:[[:space:]]*\(.*\)/\1/p}' "${CLIENT_YAML}" 2>/dev/null || echo "www.bing.com")

    echo ""
    echo -e "${CYAN}========== Hysteria 2 客户端配置 ==========${RESET}"
    echo ""

    if [[ -f "${URL_FILE}" ]]; then
        echo -e "${GREEN}分享链接：${RESET}$(cat ${URL_FILE})"
    fi

    echo ""
    echo -e "${GREEN}Surge 格式：${RESET}"
    echo "Proxy-Hysteria = hysteria2, ${ip}, ${port}, password=${pwd}, sni=${sni}"
    echo ""
    echo -e "${YELLOW}⚠ 当前使用自签证书 + insecure 模式，仅防运营商 QoS，不防中间人攻击。${RESET}"
    echo -e "${YELLOW}如需安全传输，请使用 ACME 申请受信证书，并在客户端配置中移除 insecure。${RESET}"
    echo ""
    echo -e "${CYAN}========================================${RESET}"
    echo -e "${YELLOW}完整配置已保存至：${RESET}"
    echo -e "  YAML: ${CLIENT_YAML}"
    echo -e "  JSON: ${CLIENT_JSON}"
    echo -e "  URL:  ${URL_FILE}"
}

# ============================================
# 安装 / 卸载
# ============================================

install_hysteria() {
    if is_installed; then
        read -p "Hysteria 2 已安装，是否重装？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        if [[ "$(detect_init)" == "openrc" ]]; then
            rc-service "${SERVICE_NAME}" stop 2>/dev/null || true
        else
            systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        fi
    fi

    mkdir -p "${CONFIG_DIR}"

    print_info "安装依赖..."
    install_deps

    print_info "安装 Hysteria 2 二进制..."
    install_hysteria_binary

    print_info "配置证书..."
    setup_cert

    local port pwd site hop_range
    port=$(setup_port)
    hop_range=$(setup_port_hopping "$port" || true)
    pwd=$(setup_password)
    site=$(setup_masquerade)

    print_info "生成配置..."
    write_config "$port" "$pwd" "$cert_path" "$key_path" "$site" "${hy_domain}" "${hop_range:-}"

    reload_service
    print_ok "Hysteria 2 安装完成！"
    show_config
}

uninstall_hysteria() {
    if ! is_installed; then
        print_error "Hysteria 2 未安装"
        return
    fi
    read -p "确认卸载 Hysteria 2？(y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }

    local init; init=$(detect_init)
    if [[ "$init" == "openrc" ]]; then
        rc-service "${SERVICE_NAME}" stop 2>/dev/null || true
        rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 || true
    else
        systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
        systemctl daemon-reload
    fi
    rm -f "/lib/systemd/system/${SERVICE_NAME}.service" \
          "/etc/systemd/system/${SERVICE_NAME}.service" \
          "/etc/init.d/${SERVICE_NAME}"
    rm -f "/usr/local/bin/hysteria"

    # 清理端口跳跃规则（精确删除，不影响其他服务）
    if [[ -f "${CONFIG_DIR}/port_hop" ]]; then
        local hop_range; hop_range=$(cat "${CONFIG_DIR}/port_hop")
        iptables -t nat -D PREROUTING -p udp --dport "$hop_range" -j DNAT --to-destination ":" 2>/dev/null || true
        ip6tables -t nat -D PREROUTING -p udp --dport "$hop_range" -j DNAT --to-destination ":" 2>/dev/null || true
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    # 清理 ACME 证书（如果存在）
    rm -f /root/cert.crt /root/private.key /root/ca.log 2>/dev/null || true

    rm -rf "${CONFIG_DIR}"

    print_ok "Hysteria 2 卸载完成。"
}

# ============================================
# 状态 / 启停
# ============================================

show_status() {
    echo -e "
${CYAN}=== Hysteria 2 状态 ===${RESET}"
    set +e
    if is_installed; then
        local init; init=$(detect_init)
        if [[ "$init" == "openrc" ]]; then
            if rc-service "${SERVICE_NAME}" status 2>/dev/null; then
                local pid; pid=$(cat /run/${SERVICE_NAME}.pid 2>/dev/null || echo "N/A")
                echo -e "${GREEN}状态: 运行中${RESET}  ${YELLOW}PID: ${pid}${RESET}"
            else
                echo -e "${RED}状态: 已停止${RESET}"
            fi
        else
            if systemctl is-active --quiet "${SERVICE_NAME}"; then
                local pid=$(systemctl show -p MainPID "${SERVICE_NAME}" | cut -d'=' -f2)
                echo -e "${GREEN}状态: 运行中${RESET}  ${YELLOW}PID: ${pid:-N/A}${RESET}"
            else
                echo -e "${RED}状态: 已停止${RESET}"
            fi
        fi

        local port pwd
        port=$(sed -n 's/^listen:[[:space:]]*:\([0-9]*\).*/\1/p' "${CONFIG_FILE}" 2>/dev/null || true)
        pwd=$(sed -n '/^auth:/,/^[a-z]/{s/^[[:space:]]*password:[[:space:]]*\(.*\)/\1/p}' "${CONFIG_FILE}" 2>/dev/null | head -1 || true)
        echo -e "${YELLOW}端口: ${port:-N/A}${RESET}"
        echo -e "${YELLOW}密码: ${pwd:-N/A}${RESET}"
    else
        echo -e "${YELLOW}Hysteria 2 未安装${RESET}"
    fi
    echo -e "${CYAN}===================${RESET}
"
    set -e
}

start_service() {
    local init; init=$(detect_init)
    if [[ "$init" == "openrc" ]]; then
        rc-service "${SERVICE_NAME}" start && print_ok "已启动" || print_error "启动失败"
    else
        systemctl start "${SERVICE_NAME}" && print_ok "已启动" || print_error "启动失败"
    fi
}

stop_service() {
    local init; init=$(detect_init)
    if [[ "$init" == "openrc" ]]; then
        rc-service "${SERVICE_NAME}" stop && print_ok "已停止" || print_error "停止失败"
    else
        systemctl stop "${SERVICE_NAME}" && print_ok "已停止" || print_error "停止失败"
    fi
}

restart_service() {
    local init; init=$(detect_init)
    if [[ "$init" == "openrc" ]]; then
        rc-service "${SERVICE_NAME}" restart && print_ok "已重启" || print_error "重启失败"
    else
        systemctl restart "${SERVICE_NAME}" && print_ok "已重启" || print_error "重启失败"
    fi
}

# ============================================
# 修改配置
# ============================================

change_port() {
    if ! is_installed; then print_error "未安装"; return; fi
    local old_port new_port ip sni pwd
    old_port=$(sed -n 's/^listen:[[:space:]]*:\([0-9]*\).*/\1/p' "${CONFIG_FILE}" 2>/dev/null || true)
    new_port=$(setup_port)
    ip=$(get_ip)
    sni=$(sed -n '/^tls:/,/^[a-z]/{s/^[[:space:]]*sni:[[:space:]]*\(.*\)/\1/p}' "${CLIENT_YAML}" 2>/dev/null || echo "www.bing.com")
    pwd=$(sed -n '/^auth:/,/^[a-z]/{s/^[[:space:]]*password:[[:space:]]*\(.*\)/\1/p}' "${CONFIG_FILE}" 2>/dev/null | head -1 || true)

    sed -i "s/^listen: :${old_port}$/listen: :${new_port}/" "${CONFIG_FILE}"
    sed -i "s/^server: .*:${old_port}$/server: ${ip}:${new_port}/" "${CLIENT_YAML}" 2>/dev/null || true
    sed -i "s/\"server\": \".*:${old_port}\"/\"server\": \"${ip}:${new_port}\"/" "${CLIENT_JSON}" 2>/dev/null || true

    echo "hysteria2://${pwd}@${ip}:${new_port}/?insecure=1&sni=${sni}#Hysteria2" > "${URL_FILE}"

    restart_service
    print_ok "端口已更新为: ${new_port}"
    show_config
}

change_password() {
    if ! is_installed; then print_error "未安装"; return; fi
    local old_pwd new_pwd
    old_pwd=$(sed -n '/^auth:/,/^[a-z]/{s/^[[:space:]]*password:[[:space:]]*\(.*\)/\1/p}' "${CONFIG_FILE}" 2>/dev/null | head -1 || true)
    new_pwd=$(setup_password)

    # 使用 awk 做字面值替换（避免 sed 中 / & \ 等特殊字符导致异常）
    for f in "${CONFIG_FILE}" "${CLIENT_YAML}" "${CLIENT_JSON}"; do
        [[ -f "$f" ]] && awk -v old="$old_pwd" -v new="$new_pwd" '{gsub(old, new)}1' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    done

    # 更新 URL
    local ip; ip=$(get_ip)
    local port; port=$(sed -n 's/^listen:[[:space:]]*:\([0-9]*\).*/\1/p' "${CONFIG_FILE}" 2>/dev/null || true)
    local sni; sni=$(sed -n '/^tls:/,/^[a-z]/{s/^[[:space:]]*sni:[[:space:]]*\(.*\)/\1/p}' "${CLIENT_YAML}" 2>/dev/null || echo "www.bing.com")
    echo "hysteria2://${new_pwd}@${ip}:${port}/?insecure=1&sni=${sni}#Hysteria2" > "${URL_FILE}"

    restart_service
    print_ok "密码已更新"
    show_config
}

change_conf() {
    if ! is_installed; then print_error "未安装"; return; fi
    echo ""
    echo -e " ${GREEN}1.${RESET} 修改端口"
    echo -e " ${GREEN}2.${RESET} 修改密码"
    echo ""
    read -rp "请选择 [1-2]: " conf_choice
    case "${conf_choice}" in
        1) change_port ;;
        2) change_password ;;
        *) print_error "无效选项" ;;
    esac
}

# ============================================
# 菜单
# ============================================

hr(){ printf '%*s
' 44 '' | tr ' ' '='; }
pause(){ read -rp "按回车返回菜单..." _; }

show_menu() {
    clear
    hr
    echo -e "${CYAN} Hysteria 2 一键管理脚本  v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN} https://github.com/viogus/scripts${RESET}"
    echo -e "${CYAN} 系统: $(detect_os)  |  架构: $(uname -m)${RESET}"
    hr

    show_status

    echo -e "${GREEN}1.${RESET} 安装/重装 Hysteria 2"
    echo -e "${GREEN}2.${RESET} 卸载 Hysteria 2"
    echo -e "${GREEN}3.${RESET} 查看配置 (输出 Surge 格式)"
    echo -e "---"
    echo -e "${GREEN}4.${RESET} 启动服务"
    echo -e "${GREEN}5.${RESET} 停止服务"
    echo -e "${GREEN}6.${RESET} 重启服务"
    echo -e "---"
    echo -e "${GREEN}7.${RESET} 修改配置"
    echo -e "${GREEN}0.${RESET} 退出"
    hr
    read -rp "请输入选项 [0-7]: " choice

    case "${choice}" in
        1) install_hysteria; pause ;;
        2) uninstall_hysteria; pause ;;
        3) show_config; pause ;;
        4) start_service; pause ;;
        5) stop_service; pause ;;
        6) restart_service; pause ;;
        7) change_conf; pause ;;
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
