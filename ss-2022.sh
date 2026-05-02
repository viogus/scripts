#!/usr/bin/env bash
set -euo pipefail

# =========================================
# 作者: jinqians + viogus
# 日期: 2025年3月 / 2026年5月
# 网站：jinqians.com / github.com/viogus
# 描述: Shadowsocks Rust 管理脚本
# =========================================

# 版本信息
SCRIPT_VERSION="1.7"
SS_VERSION=""

# 系统路径
SCRIPT_PATH=$(cd "$(dirname "$0")"; pwd)
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
SCRIPT_NAME=$(basename "$0")

# 安装路径
INSTALL_DIR="/usr/local/etc/ss-rust"
BINARY_PATH="/usr/local/bin/ss-rust"
CONFIG_PATH="/usr/local/etc/ss-rust/config.json"
VERSION_FILE="/usr/local/etc/ss-rust/ver.txt"
SYSCTL_CONF="/etc/sysctl.d/local.conf"
MAINLAND_BLOCK_SCRIPT="/usr/local/bin/block-mainland.sh"
MAINLAND_EXTRACT_SCRIPT="/usr/local/bin/extract-cn-ip-from-mmdb.py"
MAINLAND_BLOCK_REPO_URL="https://raw.githubusercontent.com/viogus/scripts/main/block-mainland.sh"
MAINLAND_EXTRACT_REPO_URL="https://raw.githubusercontent.com/viogus/scripts/main/extract-cn-ip-from-mmdb.py"

# 颜色定义
[ -z "${RED:-}" ] && {
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
BLUE='[0;34m'
CYAN='[0;36m'
PLAIN='[0m'
RESET='[0m'
BOLD='[1m'
}
RED_BG='[41;37m'

# 状态提示
INFO="${GREEN}[信息]${PLAIN}"
ERROR="${RED}[错误]${PLAIN}"
WARNING="${YELLOW}[警告]${PLAIN}"
SUCCESS="${GREEN}[成功]${PLAIN}"

# 系统信息
OS_TYPE=""
OS_ARCH=""
OS_VERSION=""

# 配置信息
SS_PORT=""
SS_PASSWORD=""
SS_METHOD=""
SS_TFO=""
SS_DNS=""

# 错误处理函数
error_exit() {
    echo -e "${ERROR} $1" >&2
    exit 1
}

# 检查 root 权限
check_root() {
    if [[ $EUID != 0 ]]; then
        error_exit "当前非ROOT账号(或没有ROOT权限)，无法继续操作，请使用 sudo su 命令获取临时ROOT权限"
    fi
}

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
svc_main_pid() { if [[ "$(detect_init)" == "openrc" ]]; then cat "/run/${1}.pid" 2>/dev/null || echo "0"; else systemctl show -p MainPID "$1" 2>/dev/null | cut -d'=' -f2; fi; }

fi  # end inline svc fallback
write_openrc_init_ss() {
    cat > "/etc/init.d/ss-rust" << OPENRCEOF
#!/sbin/openrc-run
name="ss-rust"
description="Shadowsocks Rust Service"
command="${BINARY_PATH}"
command_user="nobody"
command_args="-c ${CONFIG_PATH}"
command_background="yes"
pidfile="/run/ss-rust.pid"
OPENRCEOF
    chmod +x "/etc/init.d/ss-rust"
}

# 检测操作系统
detect_os() {
    if grep -qi "alpine" /etc/os-release 2>/dev/null; then
        OS_TYPE="alpine"
    elif [[ -f /etc/redhat-release ]]; then
        OS_TYPE="centos"
    elif grep -q -E -i "debian" /etc/issue 2>/dev/null; then
        OS_TYPE="debian"
    elif grep -q -E -i "ubuntu" /etc/issue 2>/dev/null; then
        OS_TYPE="ubuntu"
    elif grep -q -E -i "centos|red hat|redhat" /etc/issue 2>/dev/null; then
        OS_TYPE="centos"
    elif grep -q -E -i "debian" /proc/version 2>/dev/null; then
        OS_TYPE="debian"
    elif grep -q -E -i "ubuntu" /proc/version 2>/dev/null; then
        OS_TYPE="ubuntu"
    elif grep -q -E -i "centos|red hat|redhat" /proc/version 2>/dev/null; then
        OS_TYPE="centos"
    else
        error_exit "不支持的操作系统"
    fi
}

# 检测系统架构
detect_arch() {
    local arch=$(uname -m)
    local os=$(uname -s)
    
    case "${os}" in
        "Darwin")
            case "${arch}" in
                "arm64")
                    OS_ARCH="aarch64-apple-darwin"
                    ;;
                "x86_64")
                    OS_ARCH="x86_64-apple-darwin"
                    ;;
            esac
            ;;
        "Linux")
            case "${arch}" in
                "x86_64")
                    OS_ARCH="x86_64-unknown-linux-gnu"
                    ;;
                "aarch64")
                    OS_ARCH="aarch64-unknown-linux-gnu"
                    ;;
                "armv7l"|"armv7")
                    # 检查是否支持硬浮点
                    if grep -q "gnueabihf" /proc/cpuinfo; then
                        OS_ARCH="armv7-unknown-linux-gnueabihf"
                    else
                        OS_ARCH="arm-unknown-linux-gnueabi"
                    fi
                    ;;
                "armv6l")
                    OS_ARCH="arm-unknown-linux-gnueabi"
                    ;;
                "i686"|"i386")
                    OS_ARCH="i686-unknown-linux-musl"
                    ;;
                *)
                    error_exit "不支持的CPU架构: ${arch}"
                    ;;
            esac
            ;;
        *)
            error_exit "不支持的操作系统: ${os}"
            ;;
    esac
    
    echo -e "${INFO} 检测到系统架构为 [ ${OS_ARCH} ]"
}

# 检查安装状态
check_installation() {
    if [[ ! -e ${BINARY_PATH} ]]; then
        error_exit "Shadowsocks Rust 未安装，请先安装！"
    fi
}

# 获取最新版本
get_latest_version() {
    SS_VERSION=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases | \
                 jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    
    if [[ -z ${SS_VERSION} ]]; then
        error_exit "获取 Shadowsocks Rust 最新版本失败！"
    fi
    
    # 移除版本号中的 'v' 前缀
    SS_VERSION=${SS_VERSION#v}
    
    echo -e "${INFO} 检测到 Shadowsocks Rust 最新版本为 [ ${SS_VERSION} ]"
}


check_installed_status() {
    if [[ ! -e ${BINARY_PATH} ]]; then
        echo -e "${RED}[错误]${RESET} Shadowsocks Rust 没有安装，请检查！"
        return 1
    fi
    return 0
}

check_status() {
    if svc_is_active ss-rust >/dev/null 2>&1; then
        status="running"
    else
        status="stopped"
    fi
}

check_new_ver() {
    new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases| jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]')
    [[ -z ${new_ver} ]] && echo -e "${RED}[错误]${RESET} Shadowsocks Rust 最新版本获取失败！" && exit 1
    echo -e "${GREEN}[信息]${RESET} 检测到 Shadowsocks Rust 最新版本为 [ ${new_ver} ]"
}

# 检查版本并比较
check_ver_comparison() {
    if [[ ! -f "${VERSION_FILE}" ]]; then
        echo -e "${GREEN}[信息]${RESET} 未找到版本文件，可能是首次安装"
        return 0
    fi
    
    local now_ver=$(cat ${VERSION_FILE})
    if [[ "${now_ver}" != "${new_ver}" ]]; then
        echo -e "${GREEN}[信息]${RESET} 发现 Shadowsocks Rust 新版本 [ ${new_ver} ]"
        echo -e "${GREEN}[信息]${RESET} 当前版本 [ ${now_ver} ]"
        return 0
    else
        echo -e "${GREEN}[信息]${RESET} 当前已是最新版本 [ ${new_ver} ]"
        return 1
    fi
}

# 获取当前安装版本
get_current_version() {
    if [[ -f "${VERSION_FILE}" ]]; then
        current_ver=$(cat "${VERSION_FILE}")
        echo "${current_ver}"
    else
        echo "0.0.0"
    fi
}

# 版本号比较函数
version_compare() {
    local current=$1
    local latest=$2
    
    # 移除版本号中的 'v' 前缀
    current=${current#v}
    latest=${latest#v}
    
    if [[ "${current}" == "${latest}" ]]; then
        return 1  # 版本相同
    fi
    
    # 将版本号分割为数组
    IFS='.' read -r -a current_parts <<< "${current}"
    IFS='.' read -r -a latest_parts <<< "${latest}"
    
    # 比较每个部分
    for i in "${!current_parts[@]}"; do
        if [[ "${current_parts[$i]}" -lt "${latest_parts[$i]}" ]]; then
            return 0  # 当前版本低于最新版本
        elif [[ "${current_parts[$i]}" -gt "${latest_parts[$i]}" ]]; then
            return 1  # 当前版本高于最新版本
        fi
    done
    
    return 1
}

# 下载 Shadowsocks Rust
download_ss() {
    local version=$1
    local arch=$2
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}"
    local filename=""

    case "${arch}" in
        # macOS 系统
        "aarch64-apple-darwin"|"x86_64-apple-darwin")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        
        # Linux x86_64 系统
        "x86_64-unknown-linux-gnu"|"x86_64-unknown-linux-musl")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        
        # Linux ARM 64位
        "aarch64-unknown-linux-gnu"|"aarch64-unknown-linux-musl")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        
        # Linux ARM 32位
        "arm-unknown-linux-gnueabi"|"arm-unknown-linux-gnueabihf"|"arm-unknown-linux-musleabi"|"arm-unknown-linux-musleabihf")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        
        # Linux ARMv7
        "armv7-unknown-linux-gnueabihf"|"armv7-unknown-linux-musleabihf")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        
        # Linux i686
        "i686-unknown-linux-musl")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        
        # Windows
        "x86_64-pc-windows-gnu")
            filename="shadowsocks-v${version}.${arch}.zip"
            ;;
        "x86_64-pc-windows-msvc")
            filename="shadowsocks-v${version}.${arch}.zip"
            ;;
            
        *)
            error_exit "不支持的系统架构: ${arch}"
            ;;
    esac
    
    echo -e "${INFO} 开始下载 Shadowsocks Rust ${version}..."
    echo -e "${INFO} 下载地址：${url}/${filename}"
    wget --no-check-certificate -N "${url}/${filename}"
    
    if [[ ! -e "${filename}" ]]; then
        error_exit "Shadowsocks Rust 下载失败！"
    fi
    
    # 根据文件扩展名选择解压方式
    if [[ "${filename}" == *.tar.xz ]]; then
        if ! tar -xf "${filename}"; then
            error_exit "Shadowsocks Rust 解压失败！"
        fi
    elif [[ "${filename}" == *.zip ]]; then
        if ! unzip -o "${filename}"; then
            error_exit "Shadowsocks Rust 解压失败！"
        fi
    fi
    
    if [[ ! -e "ssserver" ]]; then
        error_exit "Shadowsocks Rust 解压后未找到主程序！"
    fi
    
    rm -f "${filename}"
    chmod +x ssserver
    mv -f ssserver "${BINARY_PATH}"
    rm -f sslocal ssmanager ssservice ssurl
    
    echo "${version}" > "${VERSION_FILE}"
    echo -e "${SUCCESS} Shadowsocks Rust ${version} 下载安装完成！"
}

# 下载主函数
download() {
    if [[ ! -e "${INSTALL_DIR}" ]]; then
        mkdir -p "${INSTALL_DIR}"
    fi
    
    local version=${SS_VERSION}
    local arch=${OS_ARCH}
    download_ss "${version}" "${arch}"
}

# 安装系统服务
install_service() {
    echo -e "${INFO} 开始安装系统服务..."
    if [[ "$(detect_init)" == "openrc" ]]; then
        write_openrc_init_ss
    else
        cat > /etc/systemd/system/ss-rust.service << EOF
[Unit]
Description=Shadowsocks Rust Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=${BINARY_PATH} -c ${CONFIG_PATH}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    fi

    echo -e "${INFO} 重新加载服务配置..."
    svc_reload

    echo -e "${INFO} 启用 ss-rust 服务..."
    svc_enable ss-rust

    echo -e "${SUCCESS} Shadowsocks Rust 服务配置完成！"
}

# 安装依赖
install_dependencies() {
    echo -e "${INFO} 开始安装系统依赖..."
    
    if [[ ${OS_TYPE} == "centos" ]]; then
        yum update -y || dnf update -y
        yum install -y jq gzip wget curl unzip xz openssl qrencode tar || \
            dnf install -y jq gzip wget curl unzip xz openssl qrencode tar
    elif [ -x "$(command -v apk)" ]; then
        apk update && apk add --no-cache jq gzip wget curl unzip xz openssl qrencode tar
    else
        apt-get update
        apt-get install -y jq gzip wget curl unzip xz-utils openssl qrencode tar
    fi
    
    # 设置时区
    echo -e "${CYAN}正在设置时区...${RESET}"
    if [ -f "/usr/share/zoneinfo/Asia/Shanghai" ]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    else
        echo -e "${RED}时区文件不存在，跳过设置${RESET}"
    fi
    echo -e "${SUCCESS} 系统依赖安装完成！"
}

# 写入配置文件
write_config() {
    cat > ${CONFIG_PATH} << EOF
{
    "server": "::",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "fast_open": ${SS_TFO},
    "mode": "tcp_and_udp",
    "user": "nobody",
    "timeout": 300
}
EOF
    if [[ -n "${SS_DNS:-}" ]]; then
        sed -i 's/"timeout": 300/"timeout": 300,
    "nameserver": "'"${SS_DNS}"'"/' ${CONFIG_PATH}
    fi
    echo -e "${SUCCESS} 配置文件写入完成！"
}

# 读取配置文件
read_config() {
    if [[ ! -e ${CONFIG_PATH} ]]; then
        error_exit "Shadowsocks Rust 配置文件不存在！"
    fi
    
    SS_PORT=$(jq -r '.server_port' ${CONFIG_PATH})
    SS_PASSWORD=$(jq -r '.password' ${CONFIG_PATH})
    SS_METHOD=$(jq -r '.method' ${CONFIG_PATH})
    SS_TFO=$(jq -r '.fast_open' ${CONFIG_PATH})
    SS_DNS=$(jq -r '.nameserver // empty' ${CONFIG_PATH})
}

# 检查防火墙并开放端口
check_firewall() {
    local port=$1
    echo -e "${INFO} 检查防火墙配置..."
    
    # 检查 UFW
    if command -v ufw >/dev/null 2>&1; then
        echo -e "${INFO} 检测到 UFW 防火墙..."
        if ufw status | grep -qw active; then
            echo -e "${INFO} 正在将端口 ${port} 加入 UFW 规则..."
            ufw allow ${port}/tcp
            ufw allow ${port}/udp
            echo -e "${SUCCESS} UFW 端口开放完成！"
        fi
    fi
    
    # 检查 iptables
    if command -v iptables >/dev/null 2>&1; then
        echo -e "${INFO} 检测到 iptables 防火墙..."
        echo -e "${INFO} 正在将端口 ${port} 加入 iptables 规则..."
        iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
        iptables -I INPUT -p udp --dport ${port} -j ACCEPT
        echo -e "${SUCCESS} iptables 端口开放完成！"
        
        # 保存 iptables 规则
        if [[ ${OS_TYPE} == "centos" ]]; then
            service iptables save
        else
            iptables-save > /etc/iptables.rules
        fi
    fi
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65535
    echo $(shuf -i ${min_port}-${max_port} -n 1)
}

# 设置端口
set_port() {
    SS_PORT=$(generate_random_port)
    echo -e "${INFO} 已生成随机端口：${SS_PORT}"
    echo -e "${YELLOW}[注意]${RESET} 是否使用该随机端口？"
    echo "=================================="
    echo -e " ${GREEN}1.${RESET} 是"
    echo -e " ${GREEN}2.${RESET} 否，我要自定义端口"
    echo "=================================="
    
    read -e -p "(默认: 1. 使用随机端口)：" port_choice
    [[ -z "${port_choice}" ]] && port_choice="1"
    
    if [[ ${port_choice} == "2" ]]; then
        while true; do
            echo -e "请输入 Shadowsocks Rust 端口 [1-65535]"
            read -e -p "(默认：2525)：" SS_PORT
            [[ -z "${SS_PORT}" ]] && SS_PORT="2525"
            
            if [[ ${SS_PORT} =~ ^[0-9]+$ ]]; then
                if (( SS_PORT >= 1 && SS_PORT <= 65535 )); then
                    break
                else
                    echo -e "${RED}[错误]${RESET} 输入错误，端口范围必须在 1-65535 之间"
                fi
            else
                echo -e "${RED}[错误]${RESET} 输入错误，请输入数字"
            fi
        done
    fi
    
    echo && echo "=================================="
    echo -e "端口：${RED_BG} ${SS_PORT} ${RESET}"
    echo "=================================="
    
    # 检查并配置防火墙
    check_firewall "${SS_PORT}"
    echo
}

# 设置密码
set_password() {
    echo "请输入 Shadowsocks Rust 密码 [0-9][a-z][A-Z]"
    read -e -p "(默认：随机生成 Base64)：" SS_PASSWORD
    if [[ -z "${SS_PASSWORD}" ]]; then
        # 根据加密方式选择合适的密钥长度
        case "${SS_METHOD}" in
            "2022-blake3-aes-128-gcm")
                # 生成16字节密钥并进行base64编码
                SS_PASSWORD=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64)
                ;;
            "2022-blake3-aes-256-gcm"|"2022-blake3-chacha20-poly1305"|"2022-blake3-chacha8-poly1305")
                # 生成32字节密钥并进行base64编码
                # 32字节 = 44个base64字符（包含填充）
                raw_key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)
                # 确保生成的base64字符串长度为44个字符
                while [[ ${#raw_key} -ne 44 ]]; do
                    raw_key=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64)
                done
                SS_PASSWORD="${raw_key}"
                ;;
            *)
                # 其他加密方式使用16字节密钥
                SS_PASSWORD=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64)
                ;;
        esac
    fi
    
    # 验证密码长度
    if [[ "${SS_METHOD}" == "2022-blake3-aes-256-gcm" || "${SS_METHOD}" == "2022-blake3-chacha20-poly1305" || "${SS_METHOD}" == "2022-blake3-chacha8-poly1305" ]]; then
        # 解码base64并检查字节长度
        decoded_length=$(echo -n "${SS_PASSWORD}" | base64 -d | wc -c)
        echo -e "${INFO} 当前加密方式需要32字节密钥"
        echo -e "${INFO} 当前密码长度：${#SS_PASSWORD} 个base64字符"
        echo -e "${INFO} 解码后的字节长度：${decoded_length} 字节"
        if [[ ${decoded_length} -ne 32 ]]; then
            echo -e "${WARNING} 密码长度不符合要求，请重新设置密码！"
            set_password
            return
        fi
    fi
    
    echo && echo "=================================="
    echo -e "密码：${RED_BG} ${SS_PASSWORD} ${RESET}"
    echo "==================================" && echo
}

# 设置加密方式
set_method() {
    echo -e "请选择 Shadowsocks Rust 加密方式
==================================	
 ${GREEN} 1.${RESET} aes-128-gcm
 ${GREEN} 2.${RESET} aes-256-gcm
 ${GREEN} 3.${RESET} chacha20-ietf-poly1305
 ${GREEN} 4.${RESET} plain
 ${GREEN} 5.${RESET} none
 ${GREEN} 6.${RESET} table
 ${GREEN} 7.${RESET} aes-128-cfb
 ${GREEN} 8.${RESET} aes-256-cfb
 ${GREEN} 9.${RESET} aes-256-ctr 
 ${GREEN}10.${RESET} camellia-256-cfb
 ${GREEN}11.${RESET} rc4-md5
 ${GREEN}12.${RESET} chacha20-ietf
==================================
 ${YELLOW}[注意]${RESET} AEAD 2022 加密（使用随机加密）
==================================	
 ${GREEN}13.${RESET} 2022-blake3-aes-128-gcm ${GREEN}(默认)${RESET}
 ${GREEN}14.${RESET} 2022-blake3-aes-256-gcm ${GREEN}(推荐)${RESET}
 ${GREEN}15.${RESET} 2022-blake3-chacha20-poly1305
 ${GREEN}16.${RESET} 2022-blake3-chacha8-poly1305
=================================="
    
    read -e -p "(默认: 13. 2022-blake3-aes-128-gcm)：" method_choice
    [[ -z "${method_choice}" ]] && method_choice="13"
    
    case ${method_choice} in
        1) SS_METHOD="aes-128-gcm" ;;
        2) SS_METHOD="aes-256-gcm" ;;
        3) SS_METHOD="chacha20-ietf-poly1305" ;;
        4) SS_METHOD="plain" ;;
        5) SS_METHOD="none" ;;
        6) SS_METHOD="table" ;;
        7) SS_METHOD="aes-128-cfb" ;;
        8) SS_METHOD="aes-256-cfb" ;;
        9) SS_METHOD="aes-256-ctr" ;;
        10) SS_METHOD="camellia-256-cfb" ;;
        11) SS_METHOD="arc4-md5" ;;
        12) SS_METHOD="chacha20-ietf" ;;
        13) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        14) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        15) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        16) SS_METHOD="2022-blake3-chacha8-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac
    
    echo && echo "=================================="
    echo -e "加密：${RED_BG} ${SS_METHOD} ${RESET}"
    echo "==================================" && echo
}

# 设置 TFO
set_tfo() {
    echo -e "是否启用 TFO ？
==================================
 ${GREEN}1.${RESET} 启用
 ${GREEN}2.${RESET} 禁用
=================================="
    read -e -p "(默认：1)：" tfo_choice
    [[ -z "${tfo_choice}" ]] && tfo_choice="1"
    
    if [[ ${tfo_choice} == "1" ]]; then
        SS_TFO="true"
    else
        SS_TFO="false"
    fi
    
    echo && echo "=================================="
    echo -e "TFO：${RED_BG} ${SS_TFO} ${RESET}"
    echo "==================================" && echo
}

# 设置 DNS
set_dns() {
    echo -e "请选择 DNS 配置方式：
==================================
 ${GREEN}1.${RESET} 使用系统默认 DNS ${GREEN}(推荐)${RESET}
 ${GREEN}2.${RESET} 自定义 DNS 服务器
=================================="
    read -e -p "(默认：1)：" dns_choice
    [[ -z "${dns_choice}" ]] && dns_choice="1"
    
    if [[ ${dns_choice} == "2" ]]; then
        echo -e "请输入自定义 DNS 服务器地址（多个 DNS 用逗号分隔，如：8.8.8.8,8.8.4.4）"
        read -e -p "(默认：8.8.8.8)：" SS_DNS
        [[ -z "${SS_DNS}" ]] && SS_DNS="8.8.8.8"
        echo && echo "=================================="
        echo -e "DNS：${RED_BG} ${SS_DNS} ${RESET}"
        echo "==================================" && echo
    else
        SS_DNS=""
        echo && echo "=================================="
        echo -e "DNS：${RED_BG} 使用系统默认 DNS ${RESET}"
        echo "==================================" && echo
    fi
}

# 修改配置
modify_config() {
    check_installation
    echo && echo -e "你要做什么？
==================================
 ${GREEN}1.${RESET}  修改 端口配置
 ${GREEN}2.${RESET}  修改 密码配置
 ${GREEN}3.${RESET}  修改 加密配置
 ${GREEN}4.${RESET}  修改 TFO 配置
 ${GREEN}5.${RESET}  修改 DNS 配置
 ${GREEN}6.${RESET}  修改 全部配置" && echo
    
    read -e -p "(默认：取消)：" modify
    [[ -z "${modify}" ]] && echo "已取消..." && Start_Menu
    
    case "${modify}" in
        1)
            read_config
            set_port
            write_config
            Restart
            ;;
        2)
            read_config
            set_password
            write_config
            Restart
            ;;
        3)
            read_config
            set_method
            write_config
            Restart
            ;;
        4)
            read_config
            set_tfo
            write_config
            Restart
            ;;
        5)
            read_config
            set_dns
            write_config
            Restart
            ;;
        6)
            read_config
            set_port
            set_password
            set_method
            set_tfo
            set_dns
            write_config
            Restart
            ;;
        *)
            echo -e "${RED}[错误]${RESET} 请输入正确的数字(1-6)"
            sleep 2s
            modify_config
            ;;
    esac
}

# 安装
Install() {
    [[ -e ${BINARY_PATH} ]] && echo -e "${RED}[错误]${RESET} 检测到 Shadowsocks Rust 已安装！" && exit 1
    
    echo -e "${GREEN}[信息]${RESET} 检测系统信息..."
    detect_os
    
    echo -e "${GREEN}[信息]${RESET} 开始设置配置..."
    set_port
    set_method
    set_password
    set_tfo
    set_dns
    
    echo -e "${GREEN}[信息]${RESET} 开始安装/配置依赖..."
    install_dependencies
    
    echo -e "${GREEN}[信息]${RESET} 开始下载/安装..."
    detect_arch
    get_latest_version
    download
    
    echo -e "${GREEN}[信息]${RESET} 开始写入配置文件..."
    write_config
    
    echo -e "${GREEN}[信息]${RESET} 开始安装系统服务..."
    install_service

    echo -e "${GREEN}[信息]${RESET} 创建命令快捷方式..."
    curl -L -s https://raw.githubusercontent.com/viogus/scripts/main/ss-2022.sh -o "/usr/local/bin/ss-2022.sh"
    chmod +x "/usr/local/bin/ss-2022.sh"
    if [ -f "/usr/local/bin/ssrust" ]; then
        rm -f "/usr/local/bin/ssrust"
    fi
    ln -s "/usr/local/bin/ss-2022.sh" "/usr/local/bin/ssrust"
    
    echo -e "${GREEN}[信息]${RESET} 所有步骤安装完毕，开始启动服务..."
    start_service
    
    if [[ "$?" == "0" ]]; then
        echo -e "${SUCCESS} Shadowsocks Rust 安装并启动成功！"
        View
        echo -e "${GREEN}[信息]${RESET} 您可以使用 ${GREEN}ssrust${RESET} 命令进行管理"
        Before_Start_Menu
    else
        echo -e "${RED}[错误]${RESET} Shadowsocks Rust 启动失败，请检查日志！"
        echo -e "${GREEN}[信息]${RESET} 您可以使用以下命令查看详细日志："
        echo -e " - svc_status ss-rust"
        echo -e " - journalctl -xe --unit ss-rust"
        Before_Start_Menu
    fi
}

# 启动服务
start_service() {
    check_installed_status || return 1
    
    echo -e "${INFO} 检查服务状态..."
    check_status
    if [[ "$status" == "running" ]]; then
        echo -e "${INFO} Shadowsocks Rust 已在运行！"
        return 1
    fi
    
    echo -e "${INFO} 正在启动 Shadowsocks Rust..."
    svc_start ss-rust
    
    # 等待服务启动
    sleep 2
    
    # 检查服务状态和日志
    if ! svc_is_active ss-rust >/dev/null 2>&1; then
        echo -e "${ERROR} Shadowsocks Rust 启动失败！"
        echo -e "${INFO} 查看服务日志："
        journalctl -xe --unit ss-rust
        return 1
    fi
    
    echo -e "${SUCCESS} Shadowsocks Rust 启动成功！"
}

# 停止
Stop() {
    check_installed_status || return 1
    check_status
    if [[ ! "$status" == "running" ]]; then
        echo -e "${RED}[错误]${RESET} Shadowsocks Rust 没有运行，请检查！"
        return 1
    fi
    svc_stop ss-rust
    echo -e "${GREEN}[信息]${RESET} Shadowsocks Rust 已停止！"
}

# 重启
Restart() {
    check_installed_status || return 1
    svc_restart ss-rust
    echo -e "${GREEN}[信息]${RESET} Shadowsocks Rust 重启完毕！"
}

# 更新
Update() {
    check_installed_status
    
    # 获取当前版本
    current_ver=$(get_current_version)
    echo -e "${GREEN}[信息]${RESET} 当前版本: [ ${current_ver} ]"
    
    # 获取最新版本
    check_new_ver
    
    # 比较版本
    if version_compare "${current_ver}" "${new_ver}"; then
        echo -e "${GREEN}[信息]${RESET} 发现新版本 [ ${new_ver} ]"
        echo -e "${GREEN}[信息]${RESET} 是否更新？[Y/n]"
        read -p "(默认: y)：" yn
        [[ -z "${yn}" ]] && yn="y"
        if [[ ${yn} == [Yy] ]]; then
            echo -e "${GREEN}[信息]${RESET} 开始更新 Shadowsocks Rust..."
            detect_arch
            download_ss "${new_ver#v}" "${OS_ARCH}"
            svc_restart ss-rust
            echo -e "${SUCCESS} Shadowsocks Rust 已更新到最新版本 [ ${new_ver} ]"
        else
            echo -e "${GREEN}[信息]${RESET} 已取消更新"
        fi
    else
        echo -e "${GREEN}[信息]${RESET} 当前已是最新版本 [ ${new_ver} ]，无需更新"
    fi
    
    sleep 3s
    Start_Menu
}

# 卸载
Uninstall() {
    check_installed_status || return 1
    echo "确定要卸载 Shadowsocks Rust ? (y/N)"
    echo
    read -e -p "(默认：n)：" unyn
    [[ -z ${unyn} ]] && unyn="n"
    if [[ ${unyn} == [Yy] ]]; then
        check_status
        [[ "$status" == "running" ]] && svc_stop ss-rust
        svc_disable ss-rust
        rm -f "/etc/systemd/system/ss-rust.service" "/etc/init.d/ss-rust"
        rm -rf "${INSTALL_DIR}"
        rm -f "${BINARY_PATH}"
        rm -f "/usr/local/bin/ssrust"
        rm -f "/usr/local/bin/ss-2022.sh"
        echo && echo "Shadowsocks Rust 卸载完成！" && echo
    else
        echo && echo "卸载已取消..." && echo
    fi
}

# 获取IPv4地址
getipv4() {
    set +e
    ipv4=$(curl -m 2 -s4 https://api.ipify.org)
    if [[ -z "${ipv4}" ]]; then
        ipv4="IPv4_Error"
    fi
    set -e
}

# 获取IPv6地址
getipv6() {
    set +e
    ipv6=$(curl -m 2 -s6 https://api64.ipify.org)
    if [[ -z "${ipv6}" ]]; then
        ipv6="IPv6_Error"
    fi
    set -e
}

# 查看配置信息
View() {
    check_installed_status
    getipv4
    getipv6
    
    # 新增：如果 IPv4 和 IPv6 都获取失败，直接报错退出
    if [[ "${ipv4}" == "IPv4_Error" && "${ipv6}" == "IPv6_Error" ]]; then
        echo -e "${RED}[错误]${RESET} 无法获取 IPv4 或 IPv6 地址，无法输出配置信息！"
        return 1
    fi
    
    # 从配置文件读取信息
    if [[ -f "${CONFIG_PATH}" ]]; then
        local config_port=$(jq -r '.server_port' "${CONFIG_PATH}")
        local config_password=$(jq -r '.password' "${CONFIG_PATH}")
        local config_method=$(jq -r '.method' "${CONFIG_PATH}")
        local config_tfo=$(jq -r '.fast_open' "${CONFIG_PATH}")
        local config_dns=$(jq -r '.nameserver // empty' "${CONFIG_PATH}")

        # 修复：赋值给全局变量，保证后续二维码/链接等输出正常
        SS_PORT="$config_port"
        SS_PASSWORD="$config_password"
        SS_METHOD="$config_method"
        SS_TFO="$config_tfo"
        SS_DNS="$config_dns"

        echo -e "Shadowsocks Rust 配置："
        echo -e "——————————————————————————————————"
        [[ "${ipv4}" != "IPv4_Error" ]] && echo -e " 地址：${GREEN}${ipv4}${RESET}"
        [[ "${ipv6}" != "IPv6_Error" ]] && echo -e " 地址：${GREEN}${ipv6}${RESET}"
        echo -e " 端口：${GREEN}${config_port}${RESET}"
        echo -e " 密码：${GREEN}${config_password}${RESET}"
        echo -e " 加密：${GREEN}${config_method}${RESET}"
        echo -e " TFO ：${GREEN}${config_tfo}${RESET}"
        [[ ! -z "${config_dns}" ]] && echo -e " DNS ：${GREEN}${config_dns}${RESET}"
        echo -e "——————————————————————————————————"
    else
        echo -e "${RED}[错误]${RESET} 配置文件不存在！"
        return 1
    fi

    # 生成 SS 链接
    local userinfo=$(echo -n "${config_method}:${config_password}" | base64 -w 0)
    local ss_url_ipv4=""
    local ss_url_ipv6=""
    
    if [[ "${ipv4}" != "IPv4_Error" ]]; then
        ss_url_ipv4="ss://${userinfo}@${ipv4}:${config_port}#SS-${ipv4}"
    fi
    if [[ "${ipv6}" != "IPv6_Error" ]]; then
        ss_url_ipv6="ss://${userinfo}@${ipv6}:${config_port}#SS-${ipv6}"
    fi

    echo -e "
${YELLOW}=== Shadowsocks 链接 ===${RESET}"
    [[ ! -z "${ss_url_ipv4}" ]] && echo -e "${GREEN}IPv4 链接：${RESET}${ss_url_ipv4}"
    [[ ! -z "${ss_url_ipv6}" ]] && echo -e "${GREEN}IPv6 链接：${RESET}${ss_url_ipv6}"

    echo -e "
${YELLOW}=== Shadowsocks 二维码 ===${RESET}"
    if command -v qrencode &> /dev/null; then
        if [[ ! -z "${ss_url_ipv4}" ]]; then
            echo -e "${GREEN}IPv4 二维码：${RESET}"
            echo "${ss_url_ipv4}" | qrencode -t UTF8
        fi
        if [[ ! -z "${ss_url_ipv6}" ]]; then
            echo -e "${GREEN}IPv6 二维码：${RESET}"
            echo "${ss_url_ipv6}" | qrencode -t UTF8
        fi
    else
        echo -e "${RED}未安装 qrencode，无法生成二维码${RESET}"
    fi

    echo -e "
${YELLOW}=== Surge 配置 ===${RESET}"
    if [[ "${ipv4}" != "IPv4_Error" ]]; then
        echo -e "SS-${ipv4} = ss, ${ipv4}, ${config_port}, encrypt-method=${config_method}, password=${config_password}, tfo=${config_tfo}, udp-relay=true"
    fi
    if [[ "${ipv6}" != "IPv6_Error" ]]; then
        echo -e "SS-${ipv6} = ss, ${ipv6}, ${config_port}, encrypt-method=${config_method}, password=${config_password}, tfo=${config_tfo}, udp-relay=true"
    fi

    # 检查 ShadowTLS 是否安装并获取配置（兼容 systemd + openrc）
    local stls_svc_file=""
    if [ -f "/etc/systemd/system/shadowtls-ss.service" ]; then
        stls_svc_file="/etc/systemd/system/shadowtls-ss.service"
    elif [ -f "/etc/init.d/shadowtls-ss" ]; then
        stls_svc_file="/etc/init.d/shadowtls-ss"
    fi
    if [ -n "$stls_svc_file" ]; then
        local stls_listen_port; stls_listen_port=$(sed -n 's/.*--listen ::0:\([0-9]*\).*/\1/p' "$stls_svc_file")
        local stls_password; stls_password=$(sed -n 's/.*--password \([^ ]*\).*/\1/p' "$stls_svc_file")
        local stls_sni; stls_sni=$(sed -n 's/.*--tls \([^ ]*\).*/\1/p' "$stls_svc_file")

        echo -e "
${YELLOW}=== ShadowTLS 配置 ===${RESET}"
        echo -e " 监听端口：${GREEN}${stls_listen_port}${RESET}"
        echo -e " 密码：${GREEN}${stls_password}${RESET}"
        echo -e " SNI：${GREEN}${stls_sni}${RESET}"
        echo -e " 版本：3"

        # 生成 SS + ShadowTLS 合并链接
        local shadow_tls_config="{\"version\":\"3\",\"password\":\"${stls_password}\",\"host\":\"${stls_sni}\",\"port\":\"${stls_listen_port}\",\"address\":\"${ipv4}\"}"
        local shadow_tls_base64=$(echo -n "${shadow_tls_config}" | base64 -w 0)
        local ss_stls_url="ss://${userinfo}@${ipv4}:${config_port}?shadow-tls=${shadow_tls_base64}#SS-${ipv4}"

        echo -e "
${YELLOW}=== SS + ShadowTLS 链接 ===${RESET}"
        [[ "${ipv4}" != "IPv4_Error" ]] && echo -e "${GREEN}合并链接：${RESET}${ss_stls_url}"

        echo -e "
${YELLOW}=== SS + ShadowTLS 二维码 ===${RESET}"
        if command -v qrencode &> /dev/null; then
            [[ "${ipv4}" != "IPv4_Error" ]] && echo "${ss_stls_url}" | qrencode -t UTF8
        else
            echo -e "${RED}未安装 qrencode，无法生成二维码${RESET}"
        fi

        echo -e "
${YELLOW}=== Surge Shadowsocks + ShadowTLS 配置 ===${RESET}"
        if [[ "${ipv4}" != "IPv4_Error" ]]; then
            echo -e "SS-${ipv4} = ss, ${ipv4}, ${stls_listen_port}, encrypt-method=${config_method}, password=${config_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
        fi
        if [[ "${ipv6}" != "IPv6_Error" ]]; then
            echo -e "SS-${ipv6} = ss, ${ipv6}, ${stls_listen_port}, encrypt-method=${config_method}, password=${config_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
        fi
    fi

    echo -e "—————————————————————————"
    return 0
}

# 查看运行状态
Status() {
    echo -e "${GREEN}[信息]${RESET} 获取 Shadowsocks Rust 活动日志 ……"
    echo -e "${YELLOW}[注意]${RESET} 返回主菜单请按 q ！"
    svc_status ss-rust
    Start_Menu
}

# 更新脚本
Update_Shell() {
    echo -e "${GREEN}[信息]${RESET} 当前脚本版本为 [ ${SCRIPT_VERSION} ]"
    echo -e "${GREEN}[信息]${RESET} 开始检测脚本更新..."
    
    # 下载最新版本进行版本对比
    local temp_file="/tmp/ss-2022.sh"
    if ! wget --no-check-certificate -O ${temp_file} "https://raw.githubusercontent.com/viogus/scripts/main/ss-2022.sh"; then
        echo -e "${RED}[错误]${RESET} 下载最新脚本失败！"
        rm -f ${temp_file}
        return 1
    fi
    
    # 检查下载的文件是否存在且有内容
    if [[ ! -s ${temp_file} ]]; then
        echo -e "${RED}[错误]${RESET} 下载的脚本文件为空！"
        rm -f ${temp_file}
        return 1
    fi
    
    # 获取最新版本号（修复版本号提取）
    sh_new_ver=$(grep -m1 '^SCRIPT_VERSION=' ${temp_file} | cut -d'"' -f2)
    if [[ -z ${sh_new_ver} ]]; then
        echo -e "${RED}[错误]${RESET} 获取最新版本号失败！"
        rm -f ${temp_file}
        return 1
    fi
    
    # 比较版本号
    if [[ ${sh_new_ver} != ${SCRIPT_VERSION} ]]; then
        echo -e "${GREEN}[信息]${RESET} 发现新版本 [ ${sh_new_ver} ]"
        echo -e "${GREEN}[信息]${RESET} 是否更新？[Y/n]"
        read -p "(默认: y)：" yn
        [[ -z "${yn}" ]] && yn="y"
        if [[ ${yn} == [Yy] ]]; then
            # 备份当前脚本
            cp "${SCRIPT_PATH}/${SCRIPT_NAME}" "${SCRIPT_PATH}/${SCRIPT_NAME}.bak.${SCRIPT_VERSION}"
            echo -e "${GREEN}[信息]${RESET} 已备份当前版本到 ${SCRIPT_NAME}.bak.${SCRIPT_VERSION}"
            
            # 更新脚本
            mv -f ${temp_file} "${SCRIPT_PATH}/${SCRIPT_NAME}"
            chmod +x "${SCRIPT_PATH}/${SCRIPT_NAME}"
            echo -e "${SUCCESS} 脚本已更新至 [ ${sh_new_ver} ]"
            echo -e "${GREEN}[信息]${RESET} 2秒后执行新脚本..."
            sleep 2s
            exec "${SCRIPT_PATH}/${SCRIPT_NAME}"
        else
            echo -e "${GREEN}[信息]${RESET} 已取消更新..."
            rm -f ${temp_file}
        fi
    else
        echo -e "${GREEN}[信息]${RESET} 当前已是最新版本 [ ${sh_new_ver} ]"
        rm -f ${temp_file}
    fi
}

# 安装 ShadowTLS
install_shadowtls() {
    echo -e "${GREEN}[信息]${RESET} 开始下载 ShadowTLS 安装脚本..."
    
    # 下载 ShadowTLS 脚本
    wget -N --no-check-certificate -O /tmp/shadowtls-$$.sh https://raw.githubusercontent.com/viogus/scripts/main/shadowtls.sh
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[错误]${RESET} ShadowTLS 脚本下载失败！"
        return 1
    fi
    
    # 添加执行权限
    chmod +x /tmp/shadowtls-$$.sh
    
    echo -e "${GREEN}[信息]${RESET} 开始安装 ShadowTLS..."
    
    # 执行 ShadowTLS 安装脚本
    bash /tmp/shadowtls-$$.sh
    
    # 清理下载的脚本
    rm -f /tmp/shadowtls-$$.sh
    
    Before_Start_Menu
}

# 部署中国大陆IP屏蔽脚本
install_mainland_block_scripts() {
    local local_block_script="${SCRIPT_PATH}/block-mainland.sh"
    local local_extract_script="${SCRIPT_PATH}/extract-cn-ip-from-mmdb.py"

    echo -e "${GREEN}[信息]${RESET} 准备部署中国大陆IP屏蔽脚本..."

    if [[ -f "${local_block_script}" ]]; then
        cp -f "${local_block_script}" "${MAINLAND_BLOCK_SCRIPT}"
    else
        wget --no-check-certificate -O "${MAINLAND_BLOCK_SCRIPT}" "${MAINLAND_BLOCK_REPO_URL}"
    fi

    if [[ -f "${local_extract_script}" ]]; then
        cp -f "${local_extract_script}" "${MAINLAND_EXTRACT_SCRIPT}"
    else
        wget --no-check-certificate -O "${MAINLAND_EXTRACT_SCRIPT}" "${MAINLAND_EXTRACT_REPO_URL}"
    fi

    if [[ ! -s "${MAINLAND_BLOCK_SCRIPT}" || ! -s "${MAINLAND_EXTRACT_SCRIPT}" ]]; then
        echo -e "${RED}[错误]${RESET} 大陆IP屏蔽脚本部署失败，请检查网络或仓库文件"
        return 1
    fi

    chmod +x "${MAINLAND_BLOCK_SCRIPT}" "${MAINLAND_EXTRACT_SCRIPT}"
    echo -e "${SUCCESS} 大陆IP屏蔽脚本部署完成"
    return 0
}

run_mainland_block_cmd() {
    local cmd="$1"

    if [[ ! -x "${MAINLAND_BLOCK_SCRIPT}" ]]; then
        echo -e "${RED}[错误]${RESET} 未找到可执行脚本：${MAINLAND_BLOCK_SCRIPT}"
        return 1
    fi

    if [[ -n "${cmd}" ]]; then
        PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 bash "${MAINLAND_BLOCK_SCRIPT}" "${cmd}"
    else
        PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 bash "${MAINLAND_BLOCK_SCRIPT}"
    fi
}

# 中国大陆IP屏蔽菜单
mainland_block_menu() {
    check_installed_status || return 1

    if ! install_mainland_block_scripts; then
        Before_Start_Menu
        return 1
    fi

    while true; do
        clear
        echo -e "${GREEN}============================================${RESET}"
        echo -e "${GREEN}        中国大陆IP屏蔽管理 ${RESET}"
        echo -e "${GREEN}============================================${RESET}"
        echo -e " ${GREEN}1.${RESET} 初始化并启用屏蔽"
        echo -e " ${GREEN}2.${RESET} 更新中国大陆IP库"
        echo -e " ${GREEN}3.${RESET} 查看屏蔽状态"
        echo -e " ${GREEN}4.${RESET} 禁用屏蔽规则"
        echo -e " ${GREEN}5.${RESET} 进入高级菜单"
        echo -e " ${GREEN}0.${RESET} 返回上一级"
        echo -e "${GREEN}============================================${RESET}"
        echo

        read -e -p " 请输入数字 [0-5]：" mainland_num
        case "${mainland_num}" in
            1)
                if run_mainland_block_cmd "enable"; then
                    echo -e "${SUCCESS} 大陆IP屏蔽启用完成"
                else
                    echo -e "${RED}[错误]${RESET} 大陆IP屏蔽启用失败"
                fi
                ;;
            2)
                if run_mainland_block_cmd "update"; then
                    echo -e "${SUCCESS} 大陆IP库更新完成"
                else
                    echo -e "${RED}[错误]${RESET} 大陆IP库更新失败"
                fi
                ;;
            3)
                run_mainland_block_cmd "status" || echo -e "${RED}[错误]${RESET} 状态查询失败"
                ;;
            4)
                if run_mainland_block_cmd "disable"; then
                    echo -e "${SUCCESS} 大陆IP屏蔽已禁用"
                else
                    echo -e "${RED}[错误]${RESET} 禁用失败"
                fi
                ;;
            5)
                run_mainland_block_cmd
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${RED}[错误]${RESET} 请输入正确数字 [0-5]"
                ;;
        esac

        echo && echo -n -e "${YELLOW}* 按回车返回此菜单 *${RESET}" && read temp
    done
}

# 返回主菜单
Before_Start_Menu() {
    echo && echo -n -e "${YELLOW}* 按回车返回主菜单 *${RESET}" && read temp
}

# 主菜单
Start_Menu() {
    while true; do
        clear
        check_root
        detect_os
        action=${1:-}
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}          SS - 2022 管理脚本 ${RESET}"
    echo -e "${GREEN}============================================${RESET}"
    echo -e "${GREEN}         作者: jinqian & viogus${RESET}"
    echo -e "${GREEN}   网站: jinqians.com / github.com/viogus${RESET}"
    echo -e "${GREEN}============================================${RESET}"
        echo && echo -e "  
 ${GREEN}0.${RESET} 更新脚本
——————————————————————————————————
 ${GREEN}1.${RESET} 安装 Shadowsocks Rust
 ${GREEN}2.${RESET} 更新 Shadowsocks Rust
 ${GREEN}3.${RESET} 卸载 Shadowsocks Rust
——————————————————————————————————
 ${GREEN}4.${RESET} 启动 Shadowsocks Rust
 ${GREEN}5.${RESET} 停止 Shadowsocks Rust
 ${GREEN}6.${RESET} 重启 Shadowsocks Rust
——————————————————————————————————
 ${GREEN}7.${RESET} 设置 配置信息
 ${GREEN}8.${RESET} 查看 配置信息
 ${GREEN}9.${RESET} 查看 运行状态
——————————————————————————————————
 ${GREEN}10.${RESET} 安装 ShadowTLS
 ${GREEN}11.${RESET} 中国大陆IP屏蔽
 ${GREEN}12.${RESET} 退出脚本
——————————————————————————————————
==================================" && echo
        if [[ -e ${BINARY_PATH} ]]; then
            check_status
            if [[ "$status" == "running" ]]; then
                echo -e " 当前状态：${GREEN}已安装${RESET} 并 ${GREEN}已启动${RESET}"
            else
                echo -e " 当前状态：${GREEN}已安装${RESET} 但 ${RED}未启动${RESET}"
            fi
        else
            echo -e " 当前状态：${RED}未安装${RESET}"
        fi
        echo
        read -e -p " 请输入数字 [0-12]：" num
        case "$num" in
            0)
                Update_Shell
                ;;
            1)
                Install
                ;;
            2)
                Update
                ;;
            3)
                Uninstall
                sleep 2
                ;;
            4)
                start_service
                sleep 2
                ;;
            5)
                Stop
                sleep 2
                ;;
            6)
                Restart
                sleep 2
                ;;
            7)
                modify_config
                ;;
            8)
                View
                echo && echo -n -e "${YELLOW}* 按回车返回主菜单 *${RESET}" && read temp
                ;;
            9)
                Status
                ;;
            10)
                install_shadowtls
                ;;
            11)
                mainland_block_menu
                ;;
            12)
                echo -e "${GREEN}[信息]${RESET} 退出脚本..."
                exit 0
                ;;
            *)
                echo -e "${RED}[错误]${RESET} 请输入正确数字 [0-12]"
                sleep 2
                ;;
        esac
    done
}

# 启动脚本
Start_Menu "$@"
