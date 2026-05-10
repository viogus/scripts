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
            else
                # Fallback: build a UUID-like string from /dev/urandom
                local raw
                raw=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -A n -tx1 | tr -d ' \n')
                echo "${raw:0:8}-${raw:8:4}-${raw:12:4}-${raw:16:4}-${raw:20:12}"
            fi
            ;;
        base64)
            dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n'
            ;;
        hex)
            local n
            n=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -A n -tx1 | tr -d ' \n')
            echo "${n:0:32}"
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
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
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
        read -r -p "输入端口(1-65535)，回车随机: " input
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
    local arch_raw libc arch

    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)               arch="amd64" ;;
        aarch64|arm64)              arch="arm64" ;;
        armv7l|armv7)               arch="armv7" ;;
        armv6l|armv6)               arch="armv6" ;;
        i686|i386)                  arch="i686" ;;
        riscv64)                    arch="riscv64" ;;
        *)
            echo -e "${ERROR} 不支持的系统架构: ${arch_raw}${RESET}" >&2
            return 1
            ;;
    esac

    # Detect musl vs gnu
    libc="gnu"
    if [[ -f /lib/ld-musl-x86_64.so.1 ]] || [[ -f /lib/ld-musl-aarch64.so.1 ]] || [[ -f /lib/ld-musl-armhf.so.1 ]]; then
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

    # Build package list
    local pkgs="ca-certificates curl unzip bash tzdata"
    pkgs="$pkgs $extra"

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
    if ! $found && has_cmd ufw && ufw status 2>/dev/null | grep -qi active; then
        found=true
    fi

    if $found; then
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

    version=$(curl -s --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || true

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
    found=$(find "$tmpdir" -type f -name "$binary_name" 2>/dev/null | head -1)
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
