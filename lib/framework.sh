#!/usr/bin/env bash
# =========================================
# lib/framework.sh — 共享服务管理框架
# 提供: 配置加载、模板、端口/密码生成、架构检测、
#       包安装、防火墙检测、GitHub 发布下载
# 用法: source /path/to/lib/framework.sh
# =========================================
set -euo pipefail

# ── sourcing guard ──
if declare -F source_conf &>/dev/null; then
    return 0
fi

# ── Source svc-utils.sh (guard against double-sourcing — svc-utils has readonly vars) ──
_FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F has_cmd &>/dev/null; then
    if [[ -f "${_FW_DIR}/svc-utils.sh" ]]; then
        source "${_FW_DIR}/svc-utils.sh"
    elif [[ -f /usr/local/lib/svc-utils.sh ]]; then
        source /usr/local/lib/svc-utils.sh
    fi
fi

# ── Ensure status labels are available (don't override caller's values) ──
: "${OK:=${GREEN}[OK]${RESET}}"
: "${ERROR:=${RED}[ERROR]${RESET}}"
: "${WARN:=${YELLOW}[WARN]${RESET}}"
: "${INFO:=${CYAN}[INFO]${RESET}}"

# ============================================
# 1. source_conf — 加载并验证服务配置
# ============================================
# 用法: source_conf "/path/to/service.conf"
# 必需字段: SERVICE DISPLAY BIN_PATH CONF_DIR CONF_FILE COMMAND_ARGS COMMAND_USER
source_conf() {
    local conf="$1"

    if [[ ! -f "$conf" ]]; then
        echo -e "${ERROR} 配置文件不存在: ${conf}${RESET}" >&2
        return 1
    fi

    source "$conf"

    local missing=false
    local var
    for var in SERVICE DISPLAY BIN_PATH CONF_DIR CONF_FILE COMMAND_ARGS COMMAND_USER; do
        if [[ -z "${!var:-}" ]]; then
            echo -e "${ERROR} 配置缺少必要字段: ${var} (${conf})${RESET}" >&2
            missing=true
        fi
    done

    if $missing; then
        return 1
    fi

    echo -e "${OK} 已加载配置: ${conf}${RESET}"
    return 0
}

# ============================================
# 2. tmpl — 模板字符串替换  {key} -> value
# ============================================
# 用法: tmpl "hello {name}" name world   => "hello world"
tmpl() {
    local str="$1"
    shift
    while [[ $# -ge 2 ]]; do
        str="${str//\{$1\}/$2}"
        shift 2
    done
    echo "$str"
}

# ============================================
# 3. valid_port — 校验端口 (1-65535)
# ============================================
valid_port() {
    local p="${1:-}"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# ============================================
# 4. random_port — 生成随机端口
# ============================================
# 用法: random_port "2000-65000"
# 优先使用 shuf，回退 $RANDOM (兼容 BusyBox)
random_port() {
    local range="${1:-2000-65000}"
    local min="${range%-*}"
    local max="${range#*-}"

    if has_cmd shuf; then
        shuf -i "${min}-${max}" -n 1
    else
        # Fallback for BusyBox / systems without shuf
        echo $(( RANDOM % (max - min + 1) + min ))
    fi
}

# ============================================
# 5. gen_pass — 生成密码
# ============================================
# 类型: uuid (默认), base64, hex
gen_pass() {
    local type="${1:-uuid}"

    case "$type" in
        uuid)
            if [[ -f /proc/sys/kernel/random/uuid ]]; then
                cat /proc/sys/kernel/random/uuid
            elif has_cmd dd && has_cmd od; then
                # Fallback: build a UUID-like string from /dev/urandom
                local raw
                raw=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -A n -tx1 | tr -d ' \n')
                echo "${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
            elif has_cmd openssl; then
                local raw
                raw=$(openssl rand -hex 16)
                echo "${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
            else
                echo -e "${ERROR} gen_pass: 缺少 dd、od 或 openssl${RESET}" >&2
                return 1
            fi
            ;;
        base64)
            if has_cmd dd && has_cmd base64; then
                dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n'
            elif has_cmd openssl; then
                openssl rand -base64 32 | tr -d '\n'
            else
                echo -e "${ERROR} gen_pass: 缺少 dd、base64 或 openssl${RESET}" >&2
                return 1
            fi
            ;;
        hex)
            if has_cmd openssl; then
                openssl rand -hex 16
            elif has_cmd dd && has_cmd od; then
                local n
                n=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -A n -tx1 | tr -d ' \n')
                echo "${n:0:32}"
            else
                echo -e "${ERROR} gen_pass: 缺少 dd、od 或 openssl${RESET}" >&2
                return 1
            fi
            ;;
        *)
            gen_pass uuid
            ;;
    esac
}

# ============================================
# 6. is_port_used — 检查端口是否被占用
# ============================================
# 通过 ss 或 netstat 检测
is_port_used() {
    local port="$1"

    if has_cmd ss; then
        ss -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}([[:space:]]|$)"
    elif has_cmd netstat; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}([[:space:]]|$)"
    else
        return 1
    fi
}

# ============================================
# 7. read_port — 交互式端口输入
# ============================================
# 用法: port=$(read_port "2000-65000")
# 输出端口号到 stdout，交互信息到 stderr
read_port() {
    local range="${1:-2000-65000}"
    local input

    while true; do
        printf "输入端口(1-65535)，回车随机: " >&2
        read -r input
        if [[ -z "$input" ]]; then
            input=$(random_port "$range")
            echo -e "${INFO} 已生成随机端口: ${input}${RESET}" >&2
        fi
        if ! valid_port "$input"; then
            echo -e "${WARN} 端口不合法: ${input}${RESET}" >&2
            continue
        fi
        if is_port_used "$input"; then
            echo -e "${WARN} 端口 ${input} 已被占用${RESET}" >&2
            continue
        fi
        echo "$input"
        return 0
    done
}

# ============================================
# 8. detect_arch_musl — 架构 + libc 检测
# ============================================
# 返回格式: amd64-musl, amd64-gnu, arm64-musl 等
# libc 检测: /lib/ld-musl-*.so.1 存在或 ldd --version 含 musl
detect_arch_musl() {
    local arch_raw libc arch arch_musl_name

    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)               arch="amd64"; arch_musl_name="x86_64" ;;
        aarch64|arm64)              arch="arm64"; arch_musl_name="aarch64" ;;
        armv7l|armv7)               arch="armv7"; arch_musl_name="armhf" ;;
        armv8l)                     arch="arm64"; arch_musl_name="aarch64" ;;
        armv6l|armv6)               arch="armv6"; arch_musl_name="armhf" ;;
        i686|i386)                  arch="i686"; arch_musl_name="i386" ;;
        riscv64)                    arch="riscv64"; arch_musl_name="riscv64" ;;
        *)
            echo -e "${ERROR} 不支持的系统架构: ${arch_raw}${RESET}" >&2
            return 1
            ;;
    esac

    # Detect musl vs gnu — check dynamically for ld-musl-<arch>.so.1
    libc="gnu"
    if [[ -n "$arch_musl_name" && -f "/lib/ld-musl-${arch_musl_name}.so.1" ]]; then
        libc="musl"
    elif has_cmd ldd && ldd --version 2>&1 | grep -qi musl; then
        libc="musl"
    fi

    echo "${arch}-${libc}"
}

# ============================================
# 9. os_install — 统一包安装
# ============================================
# 用法: os_install "iptables openssl"   (extra 可选)
# 自动适配 apk / apt / dnf / yum
os_install() {
    local extra="${1:-}"
    local os
    os=$(detect_os)

    echo -e "${INFO} 正在安装系统依赖 (${os})...${RESET}"

    # Validate extra package names to prevent hyphen-injection
    if [[ -n "$extra" ]] && ! [[ "$extra" =~ ^[a-zA-Z0-9._-]+( [a-zA-Z0-9._-]+)*$ ]]; then
        echo -e "${ERROR} 非法的额外包名: ${extra}${RESET}" >&2
        return 1
    fi

    # Build package list with safe concatenation
    local pkgs="ca-certificates curl unzip bash tzdata${extra:+ $extra}"

    case "$os" in
        alpine)
            apk update
            apk add --no-cache $pkgs
            update-ca-certificates >/dev/null 2>&1 || true
            ;;
        debian)
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs
            ;;
        rhel)
            dnf install -y $pkgs 2>/dev/null || yum install -y $pkgs
            ;;
        *)
            echo -e "${ERROR} 不支持的操作系统: ${os}${RESET}" >&2
            return 1
            ;;
    esac

    echo -e "${OK} 依赖安装完成${RESET}"
}

# ============================================
# 10. close_wall — 防火墙检测警告
# ============================================
# 检测 firewalld / nftables / ufw 并打印放行提示
close_wall() {
    local found=false

    # Check by service file existence
    for svc in firewalld nftables ufw; do
        if [[ -f "/etc/systemd/system/${svc}.service" ]] || [[ -f "/etc/init.d/${svc}" ]]; then
            found=true
            break
        fi
    done

    # Also check ufw command directly (may not have a service file)
    if [[ "$found" == "false" ]] && has_cmd ufw && ufw status 2>/dev/null | grep -qi active; then
        found=true
    fi

    if [[ "$found" == "true" ]]; then
        echo -e "${WARN} 检测到防火墙服务，请手动放行端口。示例：${RESET}"
        echo -e "  ${YELLOW}ufw:        ufw allow <端口>${RESET}"
        echo -e "  ${YELLOW}firewalld:  firewall-cmd --add-port=<端口>/tcp --permanent && firewall-cmd --reload${RESET}"
        echo -e "  ${YELLOW}nftables:   nft add rule inet filter input tcp dport <端口> accept${RESET}"
        echo ""
    fi
}

# ============================================
# 11. get_latest_version — 获取 GitHub 最新版本
# ============================================
# 用法: version=$(get_latest_version "owner/repo")
get_latest_version() {
    local repo="$1"
    local version

    # Try grep -oP first (GNU grep), fall back to grep/sed
    if echo "test" | grep -oP 'test' >/dev/null 2>&1; then
        version=$(curl -s --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | grep -oP '"tag_name":\s*"\K[^"]+') || true
    fi
    if [[ -z "$version" ]]; then
        version=$(curl -s --connect-timeout 10 --max-time 30 \
            "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || true
    fi

    if [[ -z "$version" ]]; then
        echo -e "${ERROR} 无法获取 ${repo} 最新版本号${RESET}" >&2
        return 1
    fi

    echo "$version"
}

# ============================================
# ── 内部辅助: 解压归档 ──
# ============================================
__extract_archive() {
    local file="$1"

    case "$file" in
        *.zip)
            unzip -o "$file"
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$file"
            ;;
        *.tar.xz)
            # Try native -J first, then pipe through xz
            if tar -xJf "$file" 2>/dev/null; then
                :  # success
            elif has_cmd xz; then
                xz -dc "$file" | tar -x
            else
                echo -e "${ERROR} 无法解压 .tar.xz: 请安装 xz-utils / xz${RESET}" >&2
                return 1
            fi
            ;;
        *.tar.bz2)
            tar -xjf "$file"
            ;;
        *)
            echo -e "${ERROR} 不支持的归档格式: ${file}${RESET}" >&2
            return 1
            ;;
    esac
}

# ============================================
# 12. download_and_install_binary — GitHub 下载安装
# ============================================
# 用法:
#   download_and_install_binary github <repo> <binary_name> <bin_path> <archive_fmt>
#
# 参数:
#   source      固定 "github" (未来扩展)
#   repo        "owner/repo"  如 "anytls/anytls-go"
#   binary_name "anytls-server" / "hysteria"
#   bin_path    安装目标路径 如 "/usr/local/bin/anytls-server"
#   archive_fmt "zip" / "tar.gz" / "tar.xz" / "raw" (直接下载二进制)
#
# URL 拼接使用通用模式:
#   raw:   {binary_name}-linux-{arch}
#   zip:   {repo_name}_{version}_linux_{arch}.zip
#   tar.*: {repo_name}-{version}-linux-{arch}.tar.*
#
# 注意: 各项目的实际文件名可能不同 (anytls 使用项目名而非仓库名,
#       ss-rust 使用完整 triple 架构名等), 此时需要 per-project 覆盖 URL。
download_and_install_binary() {
    local source="$1" repo="$2" binary_name="$3" bin_path="$4" archive_fmt="$5"

    if [[ "$source" != "github" ]]; then
        echo -e "${ERROR} 不支持的下载源: ${source}${RESET}" >&2
        return 1
    fi

    # 1. Detect architecture
    local arch_info arch
    arch_info=$(detect_arch_musl) || return 1
    arch="${arch_info%%-*}"   # "amd64", "arm64", etc.

    # 2. Get latest version from GitHub
    local version
    version=$(get_latest_version "$repo") || return 1
    echo -e "${INFO} 最新版本: ${version} (${arch})${RESET}"

    # 3. Derive repo short name
    local repo_name="${repo#*/}"   # "anytls-go" from "anytls/anytls-go"
    local version_clean="${version#v}"

    # 4. Construct download URL (generic pattern)
    local url
    case "$archive_fmt" in
        raw)
            url="https://github.com/${repo}/releases/download/${version}/${binary_name}-linux-${arch}"
            ;;
        zip)
            url="https://github.com/${repo}/releases/download/${version}/${repo_name}_${version_clean}_linux_${arch}.zip"
            ;;
        tar.gz)
            url="https://github.com/${repo}/releases/download/${version}/${repo_name}-${version_clean}-linux-${arch}.tar.gz"
            ;;
        tar.xz)
            url="https://github.com/${repo}/releases/download/${version}/${repo_name}-${version_clean}-linux-${arch}.tar.xz"
            ;;
        *)
            echo -e "${ERROR} 不支持的归档格式: ${archive_fmt}${RESET}" >&2
            return 1
            ;;
    esac

    # 5. Create temp work directory
    local tmpdir
    if has_cmd mktemp; then
        tmpdir=$(mktemp -d)
    else
        tmpdir="/tmp/fw_install_$$"
        mkdir -p "$tmpdir"
    fi
    trap 'rm -rf "$tmpdir"' RETURN

    # 6. Download
    echo -e "${INFO} 正在下载: ${url}${RESET}"
    if [[ "$archive_fmt" == "raw" ]]; then
        curl -L --connect-timeout 10 --max-time 120 -o "${tmpdir}/${binary_name}" "$url" || {
            echo -e "${ERROR} 下载失败: ${url}${RESET}" >&2
            return 1
        }
    else
        local archive_file="${tmpdir}/archive.${archive_fmt}"
        curl -L --connect-timeout 10 --max-time 120 -o "$archive_file" "$url" || {
            echo -e "${ERROR} 下载失败: ${url}${RESET}" >&2
            return 1
        }
        # 7. Extract
        (cd "$tmpdir" && __extract_archive "archive.${archive_fmt}") || {
            echo -e "${ERROR} 解压失败${RESET}" >&2
            return 1
        }
    fi

    # 8. Find the binary (in extracted tree or raw file)
    local found
    found=$(find "$tmpdir" -type f -name "$binary_name" -executable 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        echo -e "${ERROR} 未在归档中找到可执行文件: ${binary_name}${RESET}" >&2
        echo -e "  ${YELLOW}归档内容:${RESET}" >&2
        find "$tmpdir" -type f -exec echo "    {}" \; >&2
        return 1
    fi

    # 9. Install with parent dir creation
    install -D -m755 "$found" "$bin_path" || {
        echo -e "${ERROR} 安装失败: install -D -m755${RESET}" >&2
        return 1
    }

    # 10. Verify
    if [[ -x "$bin_path" ]]; then
        echo -e "${OK} 已安装: ${bin_path}${RESET}"
    else
        echo -e "${ERROR} 验证失败: ${bin_path} 不可执行${RESET}" >&2
        return 1
    fi
}

# ============================================
# Init 模板
# ============================================

write_openrc() {
    local name="$1" cmd="$2" args="$3" user="${4:-nobody}"
    cat > "/etc/init.d/${name}" << OPENRCEOF
#!/sbin/openrc-run
name="${name}"
command="${cmd}"
command_user="${user}"
command_args="${args}"
command_background="yes"
pidfile="/run/${name}.pid"
output_log="/var/log/${name}.log"
error_log="/var/log/${name}.err"
OPENRCEOF
    chmod +x "/etc/init.d/${name}"
    touch "/var/log/${name}.log" "/var/log/${name}.err"
    chown "${user}:${user}" "/var/log/${name}.log" "/var/log/${name}.err" 2>/dev/null || \
        chown "${user}" "/var/log/${name}.log" "/var/log/${name}.err" 2>/dev/null || true
}

write_systemd() {
    local name="$1" cmd="$2" args="$3" user="${4:-nobody}"
    cat > "/etc/systemd/system/${name}.service" << SYSTEMDEOF
[Unit]
Description=${name} service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${user}
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=${cmd} ${args}
Restart=on-failure
RestartSec=10s
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMDEOF
}

# ============================================
# 安装
# ============================================

svc_install() {
    local conf="$1"
    source_conf "$conf" || return 1

    # 依赖检查
    if [[ -n "${DEPENDS_ON:-}" ]]; then
        local dep_conf="services/${DEPENDS_ON}.conf"
        if [[ ! -f "$dep_conf" ]]; then
            echo -e "${ERROR} ${DISPLAY} 依赖 ${DEPENDS_ON}，配置文件不存在${RESET}"
            return 1
        fi
        . "$dep_conf"
        [[ -x "${BIN_PATH}" ]] || {
            echo -e "${ERROR} ${DISPLAY} 依赖 ${DEPENDS_ON}，请先安装 ${DEPENDS_ON}${RESET}"
            return 1
        }
        . "$conf"
        echo -e "${INFO} 依赖 ${DEPENDS_ON} 已满足"
    fi

    # 检查已安装
    [[ -x "${BIN_PATH}" ]] && {
        echo -e "${YELLOW}${DISPLAY} 已安装，请先卸载或使用更新${RESET}"
        return 1
    }

    echo -e "${INFO} 正在安装系统依赖..."
    os_install "${EXTRA_DEPS:-}"
    echo -e "${OK} 依赖安装完成"

    close_wall

    echo -e "${INFO} 正在下载 ${DISPLAY}..."
    case "${SOURCE:-github}" in
        github)
            download_and_install_binary "github" "$GITHUB_REPO" "$BINARY_NAME" "$BIN_PATH" \
                "${ARCHIVE_FORMAT:-tar.xz}" || return 1
            ;;
        *)
            echo -e "${ERROR} 不支持的 SOURCE: ${SOURCE:-}${RESET}"
            return 1
            ;;
    esac

    # 交互式配置
    local port; port=$(read_port "${PORT_RANGE:-2000-65000}")
    local pass; pass=$(gen_pass "${PASS_TYPE:-uuid}")
    echo -e "${INFO} 端口: ${port}  密码: ${pass}"

    # 写配置
    mkdir -p "$CONF_DIR"
    local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$port" pass "$pass")
    printf '%s\n' "$conf_content" > "$CONF_FILE"
    echo -e "${OK} 配置文件写入完成"

    # 构造命令行参数，支持 BACKEND_PORT_FROM
    local cmd_args; cmd_args=$(tmpl "${COMMAND_ARGS}" port "$port" pass "$pass")
    if [[ -n "${BACKEND_PORT_FROM:-}" ]]; then
        local backend_conf="services/${BACKEND_PORT_FROM}.conf"
        if [[ -f "$backend_conf" ]]; then
            . "$backend_conf"
            local backend_port
            backend_port=$(sed -nE 's/.*:([0-9]+).*/\1/p' "$CONF_FILE" 2>/dev/null | head -1 || true)
            [[ -n "$backend_port" ]] && cmd_args="${cmd_args//__BACKEND_PORT__/${backend_port}}"
        fi
        . "$conf"
    fi

    # 写 init
    echo -e "${INFO} 正在安装系统服务..."
    if [[ "$(detect_init)" == "openrc" ]]; then
        write_openrc "$SERVICE" "$BIN_PATH" "$cmd_args" "${COMMAND_USER:-nobody}"
    else
        write_systemd "$SERVICE" "$BIN_PATH" "$cmd_args" "${COMMAND_USER:-nobody}"
    fi

    svc_reload
    svc_enable "$SERVICE"

    echo -e "${INFO} 正在启动 ${DISPLAY}..."
    svc_start "$SERVICE"
    sleep 2

    if svc_is_active "$SERVICE" >/dev/null 2>&1; then
        echo -e "${OK} ${DISPLAY} 安装并启动成功！"
    else
        echo -e "${ERROR} ${DISPLAY} 启动失败，查看日志："
        if [[ "$(detect_init)" == "openrc" ]]; then
            tail -20 "/var/log/${SERVICE}.log" "/var/log/${SERVICE}.err" 2>/dev/null
        else
            journalctl -xe --unit "$SERVICE" 2>/dev/null || true
        fi
        return 1
    fi

    svc_view "$conf"
}

# ============================================
# 更新
# ============================================

svc_update() {
    local conf="$1"
    source_conf "$conf" || return 1

    [[ -x "${BIN_PATH}" ]] || {
        echo -e "${ERROR} ${DISPLAY} 未安装，无法更新${RESET}"
        return 1
    }

    local port pass
    port=$(sed -nE 's/.*:([0-9]+).*/\1/p' "$CONF_FILE" 2>/dev/null | head -1 || true)
    pass=$(grep -oP '(?:password|pass)[:=]\s*\K\S+' "$CONF_FILE" 2>/dev/null | head -1 || true)

    echo -e "${INFO} 正在更新 ${DISPLAY}..."
    case "${SOURCE:-github}" in
        github)
            svc_stop "$SERVICE" 2>/dev/null || true
            download_and_install_binary "github" "$GITHUB_REPO" "$BINARY_NAME" "$BIN_PATH" \
                "${ARCHIVE_FORMAT:-tar.xz}" || return 1
            svc_start "$SERVICE"
            ;;
        *)
            echo -e "${ERROR} 不支持的更新方式${RESET}"
            return 1
            ;;
    esac

    [[ -n "$port" ]] && [[ -n "$pass" ]] && {
        local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$port" pass "$pass")
        printf '%s\n' "$conf_content" > "$CONF_FILE"
    }

    echo -e "${OK} ${DISPLAY} 更新完成"
}

# ============================================
# 卸载
# ============================================

svc_uninstall() {
    local conf="$1"
    source_conf "$conf" || return 1

    local ans
    read -rp "确认卸载 ${DISPLAY}? (y/N): " ans
    [[ "${ans:-N}" != [yY] ]] && { echo "已取消"; return; }

    svc_stop "$SERVICE" 2>/dev/null || true
    svc_disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/init.d/${SERVICE}" "/etc/systemd/system/${SERVICE}.service"
    svc_reload
    rm -f "$BIN_PATH"
    rm -rf "$CONF_DIR" || true
    echo -e "${OK} ${DISPLAY} 卸载完成"
}

# ============================================
# 查看配置
# ============================================

svc_view() {
    local conf="$1"
    source_conf "$conf" || return 1

    local port pass ip
    ip=$(get_ip)
    port=$(sed -nE 's/.*:([0-9]+).*/\1/p' "$CONF_FILE" 2>/dev/null | head -1 || echo "N/A")
    pass=$(grep -oP '(?:password|pass)[:=]\s*\K\S+' "$CONF_FILE" 2>/dev/null | head -1 || echo "N/A")

    echo ""
    echo -e "${CYAN}========== ${DISPLAY} 客户端配置 ==========${RESET}"
    if [[ -n "${CLIENT_URL_FMT:-}" ]]; then
        local url; url=$(tmpl "$CLIENT_URL_FMT" ip "$ip" port "$port" pass "$pass")
        echo -e "${GREEN}URL 格式：${RESET}${url}"
    fi
    if [[ -n "${CLIENT_SURGE_FMT:-}" ]]; then
        local surge; surge=$(tmpl "$CLIENT_SURGE_FMT" ip "$ip" port "$port" pass "$pass")
        echo -e "${GREEN}Surge 格式：${RESET}${surge}"
    fi
    echo -e "${CYAN}========================================${RESET}"

    if [[ -n "${CLIENT_FILE:-}" ]]; then
        {
            [[ -n "${CLIENT_URL_FMT:-}" ]] && \
                tmpl "$CLIENT_URL_FMT" ip "$ip" port "$port" pass "$pass" | sed 's/^/URL: /'
            [[ -n "${CLIENT_SURGE_FMT:-}" ]] && \
                tmpl "$CLIENT_SURGE_FMT" ip "$ip" port "$port" pass "$pass" | sed 's/^/Surge: /'
        } > "$CLIENT_FILE"
        echo -e "${YELLOW}配置已保存至: ${CLIENT_FILE}${RESET}"
    fi
}

# ============================================
# 修改端口
# ============================================

svc_port() {
    local conf="$1"
    source_conf "$conf" || return 1
    [[ -f "$CONF_FILE" ]] || { echo -e "${ERROR} 配置文件不存在${RESET}"; return 1; }

    local old_pass new_port
    old_pass=$(grep -oP '(?:password|pass)[:=]\s*\K\S+' "$CONF_FILE" 2>/dev/null | head -1 || \
        gen_pass "${PASS_TYPE:-uuid}")
    new_port=$(read_port "${PORT_RANGE:-2000-65000}")

    local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$new_port" pass "$old_pass")
    printf '%s\n' "$conf_content" > "$CONF_FILE"

    local cmd_args; cmd_args=$(tmpl "${COMMAND_ARGS}" port "$new_port" pass "$old_pass")
    if [[ "$(detect_init)" == "openrc" ]]; then
        write_openrc "$SERVICE" "$BIN_PATH" "$cmd_args" "${COMMAND_USER:-nobody}"
    else
        write_systemd "$SERVICE" "$BIN_PATH" "$cmd_args" "${COMMAND_USER:-nobody}"
    fi

    svc_reload
    svc_restart "$SERVICE"
    echo -e "${OK} 端口已更新为: ${new_port}"
}

# ============================================
# 修改密码
# ============================================

svc_pass() {
    local conf="$1"
    source_conf "$conf" || return 1
    [[ -f "$CONF_FILE" ]] || { echo -e "${ERROR} 配置文件不存在${RESET}"; return 1; }

    local old_port new_pass
    old_port=$(sed -nE 's/.*:([0-9]+).*/\1/p' "$CONF_FILE" 2>/dev/null | head -1 || \
        random_port "${PORT_RANGE:-2000-65000}")
    new_pass=$(gen_pass "${PASS_TYPE:-uuid}")

    local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$old_port" pass "$new_pass")
    printf '%s\n' "$conf_content" > "$CONF_FILE"

    local cmd_args; cmd_args=$(tmpl "${COMMAND_ARGS}" port "$old_port" pass "$new_pass")
    if [[ "$(detect_init)" == "openrc" ]]; then
        write_openrc "$SERVICE" "$BIN_PATH" "$cmd_args" "${COMMAND_USER:-nobody}"
    else
        write_systemd "$SERVICE" "$BIN_PATH" "$cmd_args" "${COMMAND_USER:-nobody}"
    fi

    svc_reload
    svc_restart "$SERVICE"
    echo -e "${OK} 密码已更新为: ${new_pass}"
}

# ============================================
# 状态显示
# ============================================

svc_status() {
    local conf="$1"
    source_conf "$conf" || {
        printf "  ${YELLOW}%-12s${RESET} 配置错误\n" "$(basename "$conf")"
        return 1
    }

    set +e

    if [[ -x "${BIN_PATH}" ]]; then
        if svc_is_active "$SERVICE" >/dev/null 2>&1; then
            local pid; pid=$(svc_main_pid "$SERVICE")
            local mem; mem=$(ps -o rss= -p "$pid" 2>/dev/null || echo 0)
            local cpu; cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null || echo 0)
            local cores; cores=$(nproc 2>/dev/null || echo 1)
            cpu=$(echo "scale=2; ${cpu:-0} / $cores" | bc -l 2>/dev/null || echo "0")
            mem=$(echo "scale=2; ${mem:-0} / 1024" | bc -l 2>/dev/null || echo "0")
            printf "  ${GREEN}%-12s${RESET} 运行中  PID: %-6s  CPU: %5s%%  MEM: %6s MB  运行: 1/1\n" \
                "${DISPLAY}" "${pid:-N/A}" "$cpu" "$mem"
        else
            printf "  ${YELLOW}%-12s${RESET} 已停止  运行: 0/1\n" "$DISPLAY"
        fi
    else
        printf "  ${YELLOW}%-12s${RESET} 未安装\n" "$DISPLAY"
    fi

    set -e
}

show_all_status() {
    local services_dir="${1:-services}"
    printf '\n%b=== 服务状态检查 ===%b\n' "$CYAN" "$RESET"

    local cores; cores=$(nproc 2>/dev/null || echo 1)
    printf '系统 CPU 核心数: %s\n' "$cores"

    if [[ -d "$services_dir" ]]; then
        local conf
        for conf in "$services_dir"/*.conf; do
            [[ -f "$conf" ]] || continue
            svc_status "$conf"
        done
    fi
    printf '%b====================%b\n\n' "$CYAN" "$RESET"
}

# ============================================
# 菜单
# ============================================

show_service_submenu() {
    local conf="$1"
    source_conf "$conf" || return 1

    while true; do
        clear
        printf '%b============================================%b\n' "$CYAN" "$RESET"
        printf '%b %s 管理菜单%b\n' "$CYAN" "$DISPLAY" "$RESET"
        printf '%b============================================%b\n' "$CYAN" "$RESET"

        set +e; svc_status "$conf"; set -e

        echo ""
        printf '%b1.%b 安装/重装 %s\n' "$GREEN" "$RESET" "$DISPLAY"
        printf '%b2.%b 更新 %s\n' "$GREEN" "$RESET" "$DISPLAY"
        printf '%b3.%b 卸载 %s\n' "$GREEN" "$RESET" "$DISPLAY"
        printf '%b4.%b 查看配置\n' "$GREEN" "$RESET"
        printf '%b5.%b 更改端口\n' "$GREEN" "$RESET"
        printf '%b6.%b 更改密码\n' "$GREEN" "$RESET"
        printf '%b0.%b 返回主菜单\n' "$GREEN" "$RESET"
        printf '%b============================================%b\n' "$CYAN" "$RESET"

        printf '请输入选项 [0-6]: '
        local choice
        read -r choice
        case "$choice" in
            1) svc_install "$conf"; printf '按回车返回...'; read -r _ ;;
            2) svc_update "$conf"; printf '按回车返回...'; read -r _ ;;
            3) svc_uninstall "$conf"; printf '按回车返回...'; read -r _ ;;
            4) svc_view "$conf"; printf '按回车返回...'; read -r _ ;;
            5) svc_port "$conf"; printf '按回车返回...'; read -r _ ;;
            6) svc_pass "$conf"; printf '按回车返回...'; read -r _ ;;
            0) return ;;
            *) printf '%b无效选项%b\n' "$RED" "$RESET" ;;
        esac
    done
}
