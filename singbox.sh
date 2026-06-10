#!/usr/bin/env bash
# =========================================
# 作者: viogus
# 日期: 2026年6月
# 网站：github.com/viogus
# 描述: sing-box 一键管理脚本（服务端 / 客户端）
# 适配: Debian/Ubuntu (apt) / RHEL系 (dnf/yum) / Alpine (apk)
# init: systemd / openrc
#
# === 服务端架构 (h2-connect + SNI auth) ===
#
# 无 SNI 认证模式:
#   Surge ──TLS──▶ sing-box:443 (HTTP/2 CONNECT)
#   简单直接，靠 TLS 加密。端口暴露即可连。
#
# SNI 认证模式 (推荐):
#                         ┌─ SNI 匹配 ──▶ sing-box:1xxxx (localhost)
#   Surge ──TLS──▶ nginx:443 ─┤
#      sni=xxxx               └─ SNI 不匹配 ──▶ 127.0.0.1:1 (RST)
#
#   nginx stream 模块在 TLS 握手之前通过 ssl_preread 读取 SNI。
#   SNI 正确才转发到 sing-box，否则直接 RST —— 连 TLS 握手都不发生。
#   HTTP/2 多路复用: 1 个 TCP 连接承载多个并发请求。
#   TLS 证书: 自签名/Cloudflare Origin/正式证书均可。
#
# === 客户端架构 ===
#
#   APP ──▶ sing-box mixed inbound (127.0.0.1:2080)
#           HTTP + SOCKS5 双协议本地代理。
#           用户需手动编辑出站规则 (outbounds) 添加代理链。
#
# =========================================
set -euo pipefail

# ============================================
# 常量
# ============================================
CONF_DIR="/usr/local/etc/sing-box"
SB_BIN="/usr/local/bin/sing-box"
SB_SERVER_CONF="${CONF_DIR}/server.json"
SB_CLIENT_CONF="${CONF_DIR}/client.json"
SB_SERVICE_NAME="sing-box"
SCRIPT_VERSION="1.0.0"

get_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/') || true
    if [[ -z "$ver" ]]; then
        ver="1.13.13"
        print_warn "无法获取最新版本号，使用默认版本: v${ver}"
    fi
    echo "$ver"
}

get_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv6l) echo "armv7" ;;
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
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget tar openssl
            ;;
        rhel)
            yum -y install curl wget tar openssl 2>/dev/null || dnf -y install curl wget tar openssl
            ;;
        alpine)
            apk update
            apk add --no-cache curl wget tar openssl
            ;;
        *) print_error "不支持的操作系统"; exit 1 ;;
    esac
}

# ============================================
# 下载 sing-box 二进制
# ============================================

download_singbox() {
    local ver arch
    ver=$(get_version)
    arch=$(get_arch)
    local file_name="sing-box-${ver}-linux-${arch}"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${file_name}.tar.gz"
    local tmp; tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT

    print_info "sing-box 版本: v${ver} 架构: ${arch}"
    print_info "正在下载 sing-box..."

    if ! curl -L --connect-timeout 10 --max-time 120 -o "${tmp}/${file_name}.tar.gz" "$url" 2>/dev/null; then
        print_warn "GitHub 直连失败，尝试镜像..."
        local mirror_url="https://ghfast.top/${url}"
        curl -L --connect-timeout 10 --max-time 120 -o "${tmp}/${file_name}.tar.gz" "$mirror_url" || {
            print_error "下载失败，请检查网络"
            exit 1
        }
    fi

    mkdir -p "${CONF_DIR}"
    tar -xzf "${tmp}/${file_name}.tar.gz" -C "$tmp"
    local extract_dir="${tmp}/${file_name}"
    if [ -d "$extract_dir" ] && [ -f "${extract_dir}/sing-box" ]; then
        cp "${extract_dir}/sing-box" "${SB_BIN}"
        chmod +x "${SB_BIN}"
    else
        local found; found=$(find "$tmp" -name "sing-box" -type f 2>/dev/null | head -1)
        if [ -z "$found" ]; then
            print_error "未找到 sing-box 二进制文件"
            exit 1
        fi
        cp "$found" "${SB_BIN}"
        chmod +x "${SB_BIN}"
    fi

    trap - EXIT
    rm -rf "$tmp"
    print_ok "sing-box 二进制安装完成"
}

# ============================================
# init 模板
# ============================================

write_systemd() {
    local name="$1" conf="$2"
    cat > "/etc/systemd/system/${name}.service" << SYSTEMDEOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=${SB_BIN} run -c ${conf}
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
}

write_openrc() {
    local name="$1" conf="$2"
    cat > "/etc/init.d/${name}" << OPENRCEOF
#!/sbin/openrc-run
name="${name}"
description="sing-box Service"
command="${SB_BIN}"
command_args="run -c ${conf}"
command_background="yes"
command_user="nobody"
pidfile="/run/${name}.pid"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.err"

depend() {
    need networking
}
OPENRCEOF
    chmod +x "/etc/init.d/${name}"
}

install_service() {
    local name="$1" conf="$2"
    local init; init=$(detect_init)

    if [[ "$init" == "openrc" ]]; then
        write_openrc "$name" "$conf"
        rc-update add "$name" default >/dev/null 2>&1 || true
        rc-service "$name" restart || rc-service "$name" start
        if rc-service "$name" status 2>/dev/null; then
            print_ok "${name} 服务已启动 (OpenRC)"
        else
            print_warn "${name} 服务启动，请检查状态"
        fi
    else
        write_systemd "$name" "$conf"
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
# 密码生成
# ============================================

gen_password() {
    local len="${1:-32}"
    local pw
    pw=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c "$len" 2>/dev/null) || true
    if [[ -z "${pw}" ]]; then
        pw=$(date +%s%N 2>/dev/null | sha256sum 2>/dev/null | cut -c1-"$len") || true
    fi
    echo "${pw:-$(date +%s | sha256sum | cut -c1-"$len")}"
}

SNGX_NGX_CONF="/etc/nginx/stream.d/sing-box.conf"

setup_sni_auth() {
    local public_port="$1" sni_secret="$2" sb_listen="$3"

    local os_type; os_type=$(detect_os 2>/dev/null || echo "debian")
    print_info "安装 nginx (stream 模块)..."
    case "$os_type" in
        debian) apt-get update -y; DEBIAN_FRONTEND=noninteractive apt-get install -y nginx ;;
        rhel)   yum -y install nginx 2>/dev/null || dnf -y install nginx ;;
        alpine) apk update; apk add --no-cache nginx ;;
        *) print_error "不支持的操作系统"; return 1 ;;
    esac

    if ! nginx -V 2>&1 | grep -q "stream"; then
        print_error "nginx 未编译 stream 模块，无法使用 SNI 分流"
        return 1
    fi

    # ensure stream include in nginx.conf
    if ! grep -q "stream {" /etc/nginx/nginx.conf 2>/dev/null; then
        cat >> /etc/nginx/nginx.conf << 'NGXEOF'

stream {
    include /etc/nginx/stream.d/*.conf;
}
NGXEOF
    fi

    mkdir -p /etc/nginx/stream.d
    cat > "${SNGX_NGX_CONF}" << NGXEOF
# sing-box h2-connect SNI auth — generated by singbox.sh
map \$ssl_preread_server_name \$sb_backend {
    ${sni_secret}  ${sb_listen};
    default        127.0.0.1:1;
}

server {
    listen ${public_port} reuseport;
    ssl_preread on;
    proxy_pass \$sb_backend;
}
NGXEOF

    # ensure nginx is enabled and running
    if [[ "$os_type" == "alpine" ]]; then
        rc-update add nginx default >/dev/null 2>&1 || true
        rc-service nginx restart || rc-service nginx start
    else
        systemctl enable nginx >/dev/null 2>&1 || true
        systemctl restart nginx || systemctl start nginx
    fi

    if ! nginx -t >/dev/null 2>&1; then
        print_error "nginx 配置验证失败"
        nginx -t 2>&1 || true
        return 1
    fi

    print_ok "nginx SNI 分流已配置"
}

remove_sni_auth() {
    rm -f "${SNGX_NGX_CONF}"
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 && nginx -s reload 2>/dev/null || true
    fi
}

install_server() {
    if [[ -f "${SB_BIN}" ]] && [[ -f "${SB_SERVER_CONF}" ]]; then
        read -rp "sing-box 服务端已安装，是否重装？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        remove_service "${SB_SERVICE_NAME}"
        remove_sni_auth
    fi

    install_deps
    download_singbox

    local cert_path key_path
    local public_port sni_secret sni_enabled=""

    echo -e "${CYAN}认证方式:${RESET}"
    echo "  1) 无认证 (仅 TLS 加密，简单)"
    echo "  2) SNI 认证 (nginx stream ssl_preread 前置分流, 推荐)"
    read -rp "请选择 [2]: " auth_choice
    case "${auth_choice:-2}" in
        1) sni_enabled="" ;;
        2) sni_enabled="yes" ;;
        *) sni_enabled="yes" ;;
    esac

    if [[ -n "$sni_enabled" ]]; then
        read -rp "对外监听端口 [443]: " public_port
        public_port="${public_port:-443}"
        sni_secret=$(gen_password 16 | tr '[:upper:]' '[:lower:]')
        local sb_local_port; sb_local_port=$(( (RANDOM % 30000) + 10000 ))
        print_info "SNI 密钥: ${sni_secret}"
        print_info "sing-box 内部端口: ${sb_local_port}"
    else
        read -rp "监听端口 [443]: " public_port
        public_port="${public_port:-443}"
    fi

    echo -e "${CYAN}证书选项:${RESET}"
    echo "  1) 自动生成自签名证书"
    echo "  2) 使用已有证书文件"
    read -rp "请选择 [1]: " cert_choice
    case "${cert_choice:-1}" in
        1)
            cert_path="${CONF_DIR}/cert.crt"
            key_path="${CONF_DIR}/private.key"
            if [[ ! -f "${cert_path}" ]] || [[ ! -f "${key_path}" ]]; then
                print_info "正在生成自签名证书 (10年有效)..."
                openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
                    -keyout "${key_path}" \
                    -out "${cert_path}" \
                    -subj "/CN=sing-box" \
                    -addext "subjectAltName=DNS:sing-box,IP:127.0.0.1" 2>/dev/null || {
                    print_error "证书生成失败"
                    return 1
                }
                chmod 600 "${key_path}"
                print_ok "自签名证书已生成"
            fi
            ;;
        2)
            read -rp "证书文件路径 (.crt): " cert_path
            read -rp "私钥文件路径 (.key): " key_path
            if [[ ! -f "${cert_path}" ]] || [[ ! -f "${key_path}" ]]; then
                print_error "证书文件不存在"
                return 1
            fi
            ;;
        *) cert_path="${CONF_DIR}/cert.crt"; key_path="${CONF_DIR}/private.key"
            openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
                -keyout "${key_path}" -out "${cert_path}" \
                -subj "/CN=sing-box" \
                -addext "subjectAltName=DNS:sing-box,IP:127.0.0.1" 2>/dev/null || {
                print_error "证书生成失败"; return 1
            }
            chmod 600 "${key_path}" ;;
    esac

    local sb_listen sb_listen_port
    if [[ -n "$sni_enabled" ]]; then
        sb_listen="127.0.0.1"
        sb_listen_port="${sb_local_port}"
    else
        sb_listen="::"
        sb_listen_port="${public_port}"
    fi

    print_info "生成配置文件..."
    mkdir -p "${CONF_DIR}"
    cat > "${SB_SERVER_CONF}" << SSEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "http",
      "tag": "http-in",
      "listen": "${sb_listen}",
      "listen_port": ${sb_listen_port},
      "tls": {
        "enabled": true,
        "certificate_path": "${cert_path}",
        "key_path": "${key_path}"
      }
    }
  ]
}
SSEOF

    if [[ -n "$sni_enabled" ]]; then
        setup_sni_auth "$public_port" "$sni_secret" "127.0.0.1:${sb_listen_port}" || return 1
        SNGX_SNI_SECRET="${sni_secret}"
    fi

    install_service "${SB_SERVICE_NAME}" "${SB_SERVER_CONF}"
    print_ok "sing-box 服务端安装完成！"
    show_server_config
}

# ============================================
# 安装 sing-box 客户端 (Mixed: HTTP + SOCKS5)
# ============================================

install_client() {
    if [[ -f "${SB_BIN}" ]] && [[ -f "${SB_CLIENT_CONF}" ]]; then
        read -rp "sing-box 客户端已安装，是否重装？(y/N): " ans
        [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
        remove_service "${SB_SERVICE_NAME}"
    fi

    install_deps
    download_singbox

    local port
    read -rp "请输入本地监听端口 [2080]: " port
    port="${port:-2080}"

    print_info "生成配置..."
    mkdir -p "${CONF_DIR}"
    cat > "${SB_CLIENT_CONF}" << CLEOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": ${port}
    }
  ]
}
CLEOF

    print_info "客户端配置已生成，请手动编辑 ${SB_CLIENT_CONF} 添加出站规则"

    install_service "${SB_SERVICE_NAME}" "${SB_CLIENT_CONF}"
    print_ok "sing-box 客户端安装完成！"
    show_client_config
}

# ============================================
# 卸载
# ============================================

uninstall_singbox() {
    if [[ ! -f "${SB_BIN}" ]]; then
        print_warn "sing-box 未安装"
        return
    fi
    read -rp "确认卸载 sing-box？将删除二进制、配置和服务 (y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }
    remove_service "${SB_SERVICE_NAME}"
    remove_sni_auth
    rm -f "${SB_BIN}"
    rm -rf "${CONF_DIR}"
    print_ok "sing-box 卸载完成"
}

# ============================================
# 显示配置
# ============================================

show_server_config() {
    echo ""
    echo -e "${CYAN}=== sing-box 服务端配置 ===${RESET}"
    if [[ -f "${SB_SERVER_CONF}" ]]; then
        local ip; ip=$(get_ip 2>/dev/null || echo "服务器IP")
        local port; port=$(sed -n 's/.*"listen_port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$SB_SERVER_CONF" 2>/dev/null || echo "?")
        local sb_listen; sb_listen=$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SB_SERVER_CONF" 2>/dev/null || echo "::")

        echo -e "${YELLOW}服务端:${RESET}"
        echo -e "  协议: HTTP/2 CONNECT (TLS)"
        if [[ "$sb_listen" == "127.0.0.1" ]] && [[ -n "${SNGX_SNI_SECRET:-}" ]]; then
            local pub_port; pub_port=$(grep -oP 'listen \K[0-9]+' "${SNGX_NGX_CONF}" 2>/dev/null || echo "?")
            echo -e "  对外端口: ${pub_port}"
            echo -e "  认证: SNI 密钥 = ${SNGX_SNI_SECRET}"
            echo -e "  前置: nginx stream ssl_preread → sing-box (${port})"

            echo ""
            echo -e "${YELLOW}Surge (h2-connect + SNI):${RESET}"
            echo "Proxy-H2 = h2-connect, ${ip}, ${pub_port}, sni=${SNGX_SNI_SECRET}, skip-cert-verify=true, max-streams=3"
        else
            echo -e "  端口: ${port}"
            echo -e "  认证: 仅 TLS 加密"

            echo ""
            echo -e "${YELLOW}Surge (h2-connect):${RESET}"
            echo "Proxy-H2 = h2-connect, ${ip}, ${port}, skip-cert-verify=true, max-streams=3"
        fi

        echo ""
        echo -e "${YELLOW}Tips:${RESET}"
        echo "  自签名证书需 skip-cert-verify=true"
        echo "  Cloudflare Origin 证书或正式证书可去掉此参数"
        echo "  max-streams 控制多路复用并发流数 (默认 3)"

        echo ""
        echo -e "${YELLOW}配置文件: ${SB_SERVER_CONF}${RESET}"
        cat "$SB_SERVER_CONF"
    else
        print_warn "sing-box 服务端未安装"
    fi
    echo -e "${CYAN}===============================${RESET}"
}

show_client_config() {
    echo ""
    echo -e "${CYAN}=== sing-box 客户端配置 ===${RESET}"
    if [[ -f "${SB_CLIENT_CONF}" ]]; then
        cat "$SB_CLIENT_CONF"
    else
        print_warn "sing-box 客户端未安装"
    fi
    echo -e "${CYAN}==============================${RESET}"
}

# ============================================
# 状态
# ============================================

show_status() {
    echo ""
    echo -e "${CYAN}--- sing-box 服务状态 ---${RESET}"

    if [[ -f "${SB_BIN}" ]]; then
        local sb_active="停止"
        local init; init=$(detect_init)
        if [[ "$init" == "openrc" ]]; then
            rc-service "${SB_SERVICE_NAME}" status >/dev/null 2>&1 && sb_active="运行中" || true
        else
            systemctl is-active --quiet "${SB_SERVICE_NAME}" 2>/dev/null && sb_active="运行中" || true
        fi
        local conf=""
        [[ -f "${SB_SERVER_CONF}" ]] && conf="服务端"
        [[ -f "${SB_CLIENT_CONF}" ]] && conf="客户端"
        echo -e "${GREEN}[sing-box] 已安装 (${conf:-无配置})${RESET}  |  状态: ${sb_active}"
        echo -e "  版本: $("${SB_BIN}" version 2>/dev/null | head -1 || echo "未知")"
    else
        echo -e "${YELLOW}[sing-box] 未安装${RESET}"
    fi

    echo -e "${CYAN}----------------------${RESET}"
}

# ============================================
# 菜单
# ============================================

hr(){ printf '%*s\n' 44 '' | tr ' ' '='; }
pause(){ read -rp "按回车返回菜单..." _; }

show_menu() {
    clear
    hr
    echo -e "${CYAN} sing-box 一键管理脚本  v${SCRIPT_VERSION}${RESET}"
    echo -e "${CYAN} https://github.com/viogus/scripts${RESET}"
    echo -e "${CYAN} 系统: $(detect_os)  |  架构: $(uname -m)${RESET}"
    hr

    show_status

    echo -e "${GREEN}1.${RESET} 安装/重装 sing-box 服务端 (h2-connect + SNI auth)"
    echo -e "${GREEN}2.${RESET} 安装/重装 sing-box 客户端 (Mixed: HTTP+SOCKS5)"
    echo -e "---"
    echo -e "${GREEN}3.${RESET} 卸载 sing-box"
    echo -e "---"
    echo -e "${GREEN}4.${RESET} 查看服务端配置"
    echo -e "${GREEN}5.${RESET} 查看客户端配置"
    echo -e "---"
    echo -e "${GREEN}6.${RESET} 启动 sing-box"
    echo -e "${GREEN}7.${RESET} 停止 sing-box"
    echo -e "${GREEN}8.${RESET} 重启 sing-box"
    echo -e "---"
    echo -e "${GREEN}0.${RESET} 退出"
    hr
    read -rp "请输入选项 [0-8]: " choice

    case "${choice}" in
        1) install_server; pause ;;
        2) install_client; pause ;;
        3) uninstall_singbox; pause ;;
        4) show_server_config; pause ;;
        5) show_client_config; pause ;;
        6) svc_op "${SB_SERVICE_NAME}" start; pause ;;
        7) svc_op "${SB_SERVICE_NAME}" stop; pause ;;
        8) svc_op "${SB_SERVICE_NAME}" restart; pause ;;
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
