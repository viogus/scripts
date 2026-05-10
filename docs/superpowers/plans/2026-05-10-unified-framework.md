# Unified Script Framework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `lib/framework.sh` — a shared framework that drives all proxy service scripts from declarative `services/*.conf` files, replacing 7 standalone scripts with one code path.

**Architecture:** `menu.sh` scans `services/*.conf`, delegates to `lib/framework.sh`. Framework reads config fields (download source, paths, templates), provides unified install/update/uninstall/status/config operations. `lib/svc-utils.sh` remains as low-level utility layer.

**Tech Stack:** Bash 4+, POSIX utilities, OpenRC + systemd, GitHub Releases API

---

### Task 1: Create `lib/framework.sh` — Core utilities and arch/download

**Files:**
- Create: `lib/framework.sh`

- [ ] **Step 1: Write the header, source lib, and helper functions**

Write `lib/framework.sh`:

```bash
#!/usr/bin/env bash
# =========================================
# viogus/scripts — Unified Service Framework
# 用法: source lib/framework.sh; svc_install services/anytls.conf
# =========================================
set -euo pipefail

# 加载底层工具库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [[ -f "${SCRIPT_DIR}/svc-utils.sh" ]]; then
    . "${SCRIPT_DIR}/svc-utils.sh"
else
    echo "[ERROR] svc-utils.sh not found" >&2; exit 1
fi

# ============================================
# 内部工具
# ============================================

# 加载并验证 .conf 文件
source_conf() {
    local conf="$1"
    [[ -f "$conf" ]] || { echo "[ERROR] $conf 不存在"; return 1; }
    . "$conf"
    local required=(SERVICE DISPLAY BIN_PATH CONF_DIR CONF_FILE COMMAND_ARGS COMMAND_USER)
    local missing=""
    for f in "${required[@]}"; do
        [[ -z "${!f:-}" ]] && missing="$missing $f"
    done
    [[ -n "$missing" ]] && { echo "[ERROR] $conf 缺少必填字段:$missing"; return 1; }
    return 0
}

# 模板替换：将 {var} 替换为对应值
tmpl() {
    local s="$1"; shift
    while [[ $# -gt 0 ]]; do
        s="${s//\{$1\}/$2}"
        shift 2
    done
    echo "$s"
}

# 验证端口
valid_port() {
    local p="${1:-}"; [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

# 随机端口
random_port() {
    local range="${1:-2000-65000}"
    local lo hi; lo=${range%-*}; hi=${range#*-}
    shuf -i "$lo-$hi" -n 1 2>/dev/null || echo $(( lo + RANDOM % (hi - lo) ))
}

# 生成密码
gen_pass() {
    local type="${1:-uuid}"
    case "$type" in
        uuid)   cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c16 /dev/urandom | xxd -p ;;
        base64) head -c24 /dev/urandom | base64 ;;
        random) head -c32 /dev/urandom | xxd -p ;;
        *)      cat /proc/sys/kernel/random/uuid 2>/dev/null ;;
    esac
}

# 端口被占用检测
is_port_used() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | awk '{print $5}' | grep -Eq "[:.]${port}([[:space:]]|$)"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

# 交互式输入端口
read_port() {
    local range="${1:-2000-65000}" input
    while true; do
        read -rp "输入端口 (${range}), 回车随机: " input
        [[ -z "${input:-}" ]] && input=$(random_port "$range")
        if ! valid_port "$input"; then echo "端口不合法: $input"; continue; fi
        if is_port_used "$input"; then echo "端口 $input 已被占用"; continue; fi
        echo "$input"; break
    done
}

# ============================================
# 架构检测 (musl/glibc)
# ============================================

detect_arch_musl() {
    local arch; arch=$(uname -m)
    local libc="gnu"

    if [[ -f /lib/ld-musl-x86_64.so.1 ]] || [[ -f /lib/ld-musl-aarch64.so.1 ]] || \
       ldd --version 2>&1 | grep -qi musl; then
        libc="musl"
    fi

    case "$arch" in
        x86_64|amd64)  echo "amd64-${libc}" ;;
        aarch64|arm64) echo "arm64-${libc}" ;;
        *) echo "unknown-${libc}" ;;
    esac
}

# ============================================
# 系统依赖安装
# ============================================

os_install() {
    local extra="${1:-}"
    if has_cmd apk; then
        apk update >/dev/null
        apk add --no-cache ca-certificates curl unzip bash tzdata $extra
    elif has_cmd apt-get; then
        apt-get update -y -qq
        apt-get install -y -qq ca-certificates curl unzip $extra
    elif has_cmd dnf; then
        dnf install -y ca-certificates curl unzip $extra
    elif has_cmd yum; then
        yum install -y ca-certificates curl unzip $extra
    fi
}

# ============================================
# 防火墙提示
# ============================================

close_wall() {
    local found=false
    for svc in firewalld nftables ufw; do
        if [[ -f "/etc/systemd/system/${svc}.service" ]] || [[ -f "/etc/init.d/${svc}" ]]; then
            found=true; break
        fi
    done
    if $found; then
        echo -e "${YELLOW}[WARN] 检测到防火墙，请手动放行端口${RESET}"
    fi
}

# ============================================
# 下载
# ============================================

get_latest_version() {
    local repo="$1"
    curl -s --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${repo}/releases/latest" \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true
}

download_and_install_binary() {
    local source="$1" repo="$2" binary_name="$3" bin_path="$4" archive_fmt="${5:-tar.xz}"
    local arch version url dl_dir filename

    arch=$(detect_arch_musl)
    version=$(get_latest_version "$repo")
    [[ -z "$version" ]] && { echo -e "${ERROR} 无法获取最新版本"; return 1; }
    echo -e "${INFO} 最新版本: ${version}"

    dl_dir=$(mktemp -d /tmp/fw-install-XXXXXX)
    case "$source" in
        github)
            # 构造 GitHub 下载 URL
            # anytls: zip, filename=anytls_${version#v}_linux_amd64.zip
            # hysteria: tar.xz, filename=hysteria-linux-amd64
            filename="${binary_name}_${version#v}_linux_${arch%%.*}.${archive_fmt}"
            url="https://github.com/${repo}/releases/download/${version}/${filename}"
            ;;
        *)
            echo -e "${ERROR} 不支持的 SOURCE: $source"; return 1
            ;;
    esac

    echo -e "${INFO} 正在下载: ${url}"
    curl -L --connect-timeout 10 --max-time 120 -o "${dl_dir}/${filename}" "$url" || {
        echo -e "${ERROR} 下载失败"; rm -rf "$dl_dir"; return 1
    }

    cd "$dl_dir"
    case "$archive_fmt" in
        zip) unzip -o "$filename" >/dev/null ;;
        tar.xz) tar -xf "$filename" ;;
    esac

    # 查找二进制文件
    local found; found=$(find . -type f -name "$binary_name" -o -name "${binary_name}*" | head -1)
    [[ -z "$found" ]] && { echo -e "${ERROR} 未找到 $binary_name"; rm -rf "$dl_dir"; return 1; }

    install -D -m755 "$found" "$bin_path"
    [[ -x "$bin_path" ]] || { echo -e "${ERROR} 安装 $bin_path 失败"; rm -rf "$dl_dir"; return 1; }
    rm -rf "$dl_dir"
    echo -e "${OK} 下载安装完成: ${bin_path}"
}
```

- [ ] **Step 2: Verify the file is syntactically valid**

```bash
bash -n lib/framework.sh
```

Expected: no output (syntax OK)

- [ ] **Step 3: Commit**

```bash
git add lib/framework.sh
git commit -m "feat: add framework.sh core utilities, arch detection, download"
```

---

### Task 2: Add init templates and service lifecycle to framework.sh

**Files:**
- Modify: `lib/framework.sh`

- [ ] **Step 1: Append OpenRC and systemd init templates, install/update/uninstall functions**

Append to `lib/framework.sh`:

```bash
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
            echo -e "${ERROR} ${DISPLAY} 依赖 ${DEPENDS_ON}，请在 services/ 目录提供其配置文件"; return 1
        fi
        . "$dep_conf"
        [[ -x "${BIN_PATH}" ]] || { echo -e "${ERROR} ${DISPLAY} 依赖 ${DEPENDS_ON}，请先安装 ${DEPENDS_ON}"; return 1; }
        . "$conf"  # 重新加载当前配置，恢复自己的变量
        echo -e "${INFO} 依赖 ${DEPENDS_ON} 已满足"
    fi

    # 检查已安装
    [[ -x "${BIN_PATH}" ]] && { echo -e "${YELLOW}${DISPLAY} 已安装，请先卸载或使用更新${RESET}"; return 1; }

    echo -e "${INFO} 正在安装系统依赖..."
    os_install "${EXTRA_DEPS:-}"
    echo -e "${OK} 依赖安装完成"

    close_wall

    echo -e "${INFO} 正在下载 ${DISPLAY}..."
    case "${SOURCE:-github}" in
        github)
            download_and_install_binary "github" "$GITHUB_REPO" "$BINARY_NAME" "$BIN_PATH" "${ARCHIVE_FORMAT:-tar.xz}" || return 1
            ;;
        direct_url)
            echo -e "${ERROR} SOURCE=direct_url 尚未实现"; return 1
            ;;
        script)
            echo -e "${ERROR} SOURCE=script 尚未实现"; return 1
            ;;
    esac

    # 交互式配置
    local port; port=$(read_port "${PORT_RANGE:-2000-65000}")
    local pass; pass=$(gen_pass "${PASS_TYPE:-uuid}")
    echo -e "${INFO} 端口: ${port}  密码: ${pass}"

    # 写配置
    mkdir -p "$CONF_DIR"
    local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$port" pass "$pass")
    echo -e "$conf_content" > "$CONF_FILE"
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
        . "$conf"  # 恢复当前配置
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

    # 输出客户端配置
    svc_view "$conf"
}

# ============================================
# 更新
# ============================================

svc_update() {
    local conf="$1"
    source_conf "$conf" || return 1

    [[ -x "${BIN_PATH}" ]] || { echo -e "${ERROR} ${DISPLAY} 未安装，无法更新"; return 1; }

    # 保留当前端口和密码
    local port pass
    port=$(sed -nE 's/.*:([0-9]+).*/\1/p' "$CONF_FILE" 2>/dev/null | head -1 || true)
    pass=$(grep -oP '(?:password|pass)[:=]\s*\K\S+' "$CONF_FILE" 2>/dev/null | head -1 || true)

    echo -e "${INFO} 正在更新 ${DISPLAY}..."
    case "${SOURCE:-github}" in
        github)
            svc_stop "$SERVICE" 2>/dev/null || true
            download_and_install_binary "github" "$GITHUB_REPO" "$BINARY_NAME" "$BIN_PATH" "${ARCHIVE_FORMAT:-tar.xz}" || return 1
            svc_start "$SERVICE"
            ;;
        *)
            echo -e "${ERROR} 不支持的更新方式"; return 1
            ;;
    esac

    # 重新生成配置（端口密码不变）
    [[ -n "$port" ]] && [[ -n "$pass" ]] && {
        local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$port" pass "$pass")
        echo -e "$conf_content" > "$CONF_FILE"
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
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n lib/framework.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add lib/framework.sh
git commit -m "feat: add init templates, install/update/uninstall to framework.sh"
```

---

### Task 3: Add config management, status, and menu to framework.sh

**Files:**
- Modify: `lib/framework.sh`

- [ ] **Step 1: Append svc_view, svc_port, svc_pass, status, and menu functions**

Append to `lib/framework.sh`:

```bash
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
            [[ -n "${CLIENT_URL_FMT:-}" ]] && echo "URL: $(tmpl "$CLIENT_URL_FMT" ip "$ip" port "$port" pass "$pass")"
            [[ -n "${CLIENT_SURGE_FMT:-}" ]] && echo "Surge: $(tmpl "$CLIENT_SURGE_FMT" ip "$ip" port "$port" pass "$pass")"
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
    [[ -f "$CONF_FILE" ]] || { echo -e "${ERROR} 配置文件不存在"; return 1; }

    local old_pass new_port
    old_pass=$(grep -oP '(?:password|pass)[:=]\s*\K\S+' "$CONF_FILE" 2>/dev/null | head -1 || gen_pass "${PASS_TYPE:-uuid}")
    new_port=$(read_port "${PORT_RANGE:-2000-65000}")

    local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$new_port" pass "$old_pass")
    echo -e "$conf_content" > "$CONF_FILE"

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
    [[ -f "$CONF_FILE" ]] || { echo -e "${ERROR} 配置文件不存在"; return 1; }

    local old_port new_pass
    old_port=$(sed -nE 's/.*:([0-9]+).*/\1/p' "$CONF_FILE" 2>/dev/null | head -1 || random_port "${PORT_RANGE:-2000-65000}")
    new_pass=$(gen_pass "${PASS_TYPE:-uuid}")

    local conf_content; conf_content=$(tmpl "${CONF_TEMPLATE}" port "$old_port" pass "$new_pass")
    echo -e "$conf_content" > "$CONF_FILE"

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
    source_conf "$conf" || { echo -e "  ${YELLOW}${conf}: 配置错误${RESET}"; return 1; }

    set +e
    local running="0/1"

    if [[ -x "${BIN_PATH}" ]]; then
        if svc_is_active "$SERVICE" >/dev/null 2>&1; then
            local pid; pid=$(svc_main_pid "$SERVICE")
            local mem; mem=$(ps -o rss= -p "$pid" 2>/dev/null || echo 0)
            local cpu; cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null || echo 0)
            local cores; cores=$(nproc 2>/dev/null || echo 1)
            cpu=$(echo "scale=2; ${cpu:-0} / $cores" | bc -l 2>/dev/null || echo "0")
            mem=$(echo "scale=2; ${mem:-0} / 1024" | bc -l 2>/dev/null || echo "0")
            running="1/1"
            printf "  ${GREEN}%-12s${RESET} 运行中  PID: %-6s  CPU: %5s%%  MEM: %6s MB  运行: %s\n" \
                "$DISPLAY" "${pid:-N/A}" "$cpu" "$mem" "$running"
        else
            printf "  ${YELLOW}%-12s${RESET} 已停止  运行: %s\n" "$DISPLAY" "$running"
        fi
    else
        printf "  ${YELLOW}%-12s${RESET} 未安装\n" "$DISPLAY"
    fi
    set -e
}

show_all_status() {
    local services_dir="${1:-services}"
    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"

    local cores; cores=$(nproc 2>/dev/null || echo 1)
    echo -e "系统 CPU 核心数: ${cores}"

    if [[ -d "$services_dir" ]]; then
        for conf in "$services_dir"/*.conf; do
            [[ -f "$conf" ]] || continue
            svc_status "$conf"
        done
    fi
    echo -e "${CYAN}====================${RESET}\n"
}

# ============================================
# 菜单
# ============================================

show_service_submenu() {
    local conf="$1"
    source_conf "$conf" || return 1

    while true; do
        clear
        echo -e "${CYAN}============================================${RESET}"
        echo -e "${CYAN} ${DISPLAY} 管理菜单${RESET}"
        echo -e "${CYAN}============================================${RESET}"

        set +e; svc_status "$conf"; set -e

        echo ""
        echo -e "${GREEN}1.${RESET} 安装/重装 ${DISPLAY}"
        echo -e "${GREEN}2.${RESET} 更新 ${DISPLAY}"
        echo -e "${GREEN}3.${RESET} 卸载 ${DISPLAY}"
        echo -e "${GREEN}4.${RESET} 查看配置"
        echo -e "${GREEN}5.${RESET} 更改端口"
        echo -e "${GREEN}6.${RESET} 更改密码"
        echo -e "${GREEN}0.${RESET} 返回主菜单"
        echo -e "${CYAN}============================================${RESET}"

        read -rp "请输入选项 [0-6]: " choice
        case "$choice" in
            1) svc_install "$conf"; read -rp "按回车返回..." _ ;;
            2) svc_update "$conf"; read -rp "按回车返回..." _ ;;
            3) svc_uninstall "$conf"; read -rp "按回车返回..." _ ;;
            4) svc_view "$conf"; read -rp "按回车返回..." _ ;;
            5) svc_port "$conf"; read -rp "按回车返回..." _ ;;
            6) svc_pass "$conf"; read -rp "按回车返回..." _ ;;
            0) return ;;
            *) echo -e "${RED}无效选项${RESET}" ;;
        esac
    done
}
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n lib/framework.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add lib/framework.sh
git commit -m "feat: add config, status, menu functions to framework.sh"
```

---

### Task 4: Create `services/anytls.conf`

**Files:**
- Create: `services/anytls.conf`

- [ ] **Step 1: Write the config**

```bash
# AnyTLS 服务定义
# https://github.com/anytls/anytls-go

SERVICE="anytls"
DISPLAY="AnyTLS"
MENU_ORDER=5

SOURCE="github"
GITHUB_REPO="anytls/anytls-go"
BINARY_NAME="anytls-server"
ARCHIVE_FORMAT="zip"

BIN_PATH="/usr/local/bin/anytls-server"
CONF_DIR="/usr/local/etc/anytls"
CONF_FILE="/usr/local/etc/anytls/config.yaml"
CLIENT_FILE="/usr/local/etc/anytls/anytls.txt"

PORT_RANGE="2000-65000"
PASS_TYPE="uuid"
CONF_TEMPLATE="listen: 0.0.0.0:{port}\npassword: {pass}\n"
CLIENT_URL_FMT="anytls://{pass}@{ip}:{port}/?insecure=1#AT_Proxy"
CLIENT_SURGE_FMT="Proxy-AnyTLS = anytls, {ip}, {port}, password={pass}"

COMMAND_ARGS="-l 0.0.0.0:{port} -p {pass}"
COMMAND_USER="nobody"
EXTRA_DEPS=""

DEPENDS_ON=""
BACKEND_PORT_FROM=""
```

- [ ] **Step 2: Commit**

```bash
mkdir -p services
git add services/anytls.conf
git commit -m "feat: add AnyTLS service config"
```

---

### Task 5: Create `services/hysteria2.conf`

**Files:**
- Create: `services/hysteria2.conf`

- [ ] **Step 1: Write the config**

```bash
# Hysteria 2 服务定义
# https://github.com/apernet/hysteria

SERVICE="hysteria"
DISPLAY="Hysteria 2"
MENU_ORDER=6

SOURCE="github"
GITHUB_REPO="apernet/hysteria"
BINARY_NAME="hysteria"
ARCHIVE_FORMAT="tar.xz"

BIN_PATH="/usr/local/bin/hysteria"
CONF_DIR="/usr/local/etc/hysteria"
CONF_FILE="/usr/local/etc/hysteria/config.yaml"
CLIENT_FILE="/usr/local/etc/hysteria/client.txt"

PORT_RANGE="2000-65000"
PASS_TYPE="base64"
CONF_TEMPLATE="listen: :{port}\n\nauth:\n  type: password\n  password: {pass}\n\ntls:\n  cert: /etc/hysteria/cert.crt\n  key: /etc/hysteria/cert.key\n"
CLIENT_URL_FMT="hysteria2://{pass}@{ip}:{port}/?insecure=1#HY2_Proxy"
CLIENT_SURGE_FMT="Proxy-Hysteria2 = hysteria2, {ip}, {port}, password={pass}"

COMMAND_ARGS="server -c /usr/local/etc/hysteria/config.yaml"
COMMAND_USER="nobody"
EXTRA_DEPS=""

DEPENDS_ON=""
BACKEND_PORT_FROM=""
```

- [ ] **Step 2: Commit**

```bash
git add services/hysteria2.conf
git commit -m "feat: add Hysteria2 service config"
```

---

### Task 6: Update `menu.sh` — Add new framework test entry

**Files:**
- Modify: `menu.sh`

- [ ] **Step 1: Add framework sourcing and test menu entry**

At the top of `menu.sh`, after the header comment block and before the first function (around line 15), add:

```bash
# === 新框架 (Phase 1) ===
FRAMEWORK_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [[ -f "${FRAMEWORK_DIR}/lib/framework.sh" ]]; then
    FRAMEWORK_LOADED=true
else
    FRAMEWORK_LOADED=false
fi
```

After the "12. 更新脚本" menu echo, add:

```bash
    echo -e "${GREEN}13.${RESET} [新] 统一管理模式 (测试中)"
```

Change the exit prompt from "0-12" to "0-13".

Add case 13 before case 0:

```bash
        13)
            if $FRAMEWORK_LOADED; then
                . "${FRAMEWORK_DIR}/lib/framework.sh"
                show_all_status "services"
                echo -e "${CYAN}可用服务:${RESET}"
                local i=1
                for conf in services/*.conf; do
                    [[ -f "$conf" ]] || continue
                    . "$conf"
                    echo -e "${GREEN}${i}.${RESET} ${DISPLAY}"
                    ((i++))
                done
                echo ""
                read -rp "选择服务 (1-$((i-1)), 0 返回): " svc_choice
                [[ "$svc_choice" == "0" ]] && continue
                local c=1
                for conf in services/*.conf; do
                    [[ -f "$conf" ]] || continue
                    [[ "$c" -eq "$svc_choice" ]] && { show_service_submenu "$conf"; break; }
                    ((c++))
                done
            else
                echo -e "${RED}framework.sh 未找到${RESET}"
                read -rp "按回车返回..." _
            fi
            ;;
```

- [ ] **Step 2: Verify syntax**

```bash
bash -n menu.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add menu.sh
git commit -m "feat: add framework test entry to menu.sh (option 13)"
```

---

### Task 7: End-to-end verification

**Files:**
- (no changes, verification only)

- [ ] **Step 1: Check all files exist and are valid**

```bash
bash -n lib/framework.sh
bash -n menu.sh
# .conf files are sourced, not executed — verify they parse as bash:
bash -c 'source services/anytls.conf; echo "SERVICE=$SERVICE"'
bash -c 'source services/hysteria2.conf; echo "SERVICE=$SERVICE"'
```

Expected: all pass, SERVICE variables printed.

- [ ] **Step 2: Verify framework.sh functions are defined**

```bash
bash -c 'source lib/framework.sh; for fn in source_conf tmpl svc_install svc_update svc_uninstall svc_view svc_port svc_pass svc_status show_all_status show_service_submenu; do printf "%-25s %s\n" "$fn" "$(type -t $fn)"; done'
```

Expected: all 11 show "function".

- [ ] **Step 3: Commit**

```bash
git commit --allow-empty -m "chore: end-to-end verification passed"
```

---

### Phase 2-3: Migration and Cleanup (follow-up plan)

After Phase 1 validated on real Alpine server:

- **Task 8**: Migrate `ss-2022.sh` → `services/ss-2022.conf`, remove old menu entry
- **Task 9**: Migrate `vless.sh` → `services/vless.conf` with `SOURCE="script"`
- **Task 10**: Migrate `shadowtls.sh` → `services/shadowtls.conf` with `DEPENDS_ON`
- **Task 11**: Migrate `snell.sh` → `services/snell.conf` (single instance)
- **Task 12**: Delete old standalone scripts, final menu.sh cleanup
