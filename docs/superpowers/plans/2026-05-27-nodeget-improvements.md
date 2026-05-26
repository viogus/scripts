# NodeGet Script Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply 4 targeted fixes to `nodeget.sh`: Alpine grep compat, upgrade feature, expanded arch support, robust JSON parsing.

**Architecture:** All changes in single file `nodeget.sh`. No cross-file dependencies. Each fix touches isolated sections of the script.

**Tech Stack:** Bash, POSIX sed/awk, systemd/OpenRC/procd init systems.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `nodeget.sh:96-105` | Modify | Expand `get_arch()` with 6 new arch cases |
| `nodeget.sh:162-172` | Modify | Robust `get_latest_version()` JSON parsing |
| `nodeget.sh:174-203` | Modify | Add `check_asset()` call before `download_binary()` |
| `nodeget.sh:541-542` | Modify | `grep -oP` → `sed` for Alpine compat |
| `nodeget.sh:559` (after) | Insert | New `upgrade_nodeget()` function |
| `nodeget.sh:707-725` | Modify | Menu: add upgrade options 14/15, adjust range |

---

### Task 1: Fix grep -oP → sed for Alpine compat

**Files:**
- Modify: `nodeget.sh:541-542`

- [ ] **Step 1: Replace grep -oP with sed in install_server()**

Read the current lines 540-543. Replace the grep -oP lines:

```bash
# Old (line 541):
    token=$(echo "$init_out" | grep -oP 'Super Token:\s*\K.*' || echo "未知")
# New:
    token=$(echo "$init_out" | sed -nE 's/.*Super Token:\s*//p' | head -1)
    token="${token:-未知}"

# Old (line 542):
    account_password=$(echo "$init_out" | grep -oP 'Root Password:\s*\K.*' || echo "未知")
# New:
    account_password=$(echo "$init_out" | sed -nE 's/.*Root Password:\s*//p' | head -1)
    account_password="${account_password:-未知}"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n nodeget.sh`
Expected: Exit 0, no output.

- [ ] **Step 3: Commit**

```bash
git add nodeget.sh
git commit -m "fix(nodeget): replace grep -oP with POSIX sed for Alpine compat

BusyBox grep (Alpine/OpenWrt) lacks -P flag. Token and password
extraction silently returned empty on those platforms. sed -nE is
POSIX and works everywhere.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Robust JSON parsing in get_latest_version()

**Files:**
- Modify: `nodeget.sh:162-172`

- [ ] **Step 1: Replace fragile grep with robust sed**

Current code (lines 162-172):
```bash
get_latest_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${NG_REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/') || true
    if [ -z "$ver" ]; then
        ver="0.4.0"
        print_warn "无法获取最新版本号，使用默认版本: v${ver}"
    fi
    echo "$ver"
}
```

Replace with:
```bash
get_latest_version() {
    local ver
    ver=$(curl -s --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${NG_REPO}/releases/latest" 2>/dev/null \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v?([0-9.]+)".*/\1/p' \
        | head -1) || true
    if [ -z "$ver" ]; then
        ver="0.4.0"
        print_warn "无法获取最新版本号，使用默认版本: v${ver}"
    fi
    echo "$ver"
}
```

Key change: `sed -nE` with `[[:space:]]*` handles any whitespace around the colon. `head -1` picks first match to avoid nested key confusion.

- [ ] **Step 2: Verify syntax**

Run: `bash -n nodeget.sh`
Expected: Exit 0.

- [ ] **Step 3: Commit**

```bash
git add nodeget.sh
git commit -m "fix(nodeget): use robust sed for GitHub API JSON parsing

Handles variable whitespace around colon in JSON tag_name field.
Picks first match to avoid confusion with nested keys.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Expand arch support + add asset validation

**Files:**
- Modify: `nodeget.sh:96-105` (get_arch)
- Modify: `nodeget.sh:174-203` (download_binary — add pre-check)

- [ ] **Step 1: Add 6 new arch cases to get_arch()**

Current (lines 96-105):
```bash
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "x86_64" ;;
        aarch64|arm64)  echo "aarch64" ;;
        armv7l)         echo "armv7" ;;
        armv6l)         echo "arm" ;;
        i386|i686)      echo "i686" ;;
        *) print_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}
```

Replace with:
```bash
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)       echo "x86_64" ;;
        aarch64|arm64)      echo "aarch64" ;;
        armv7l)             echo "armv7" ;;
        armv6l)             echo "arm" ;;
        i386|i686)          echo "i686" ;;
        riscv64|riscv64gc)  echo "riscv64gc" ;;
        ppc64|powerpc64)    echo "powerpc64" ;;
        ppc64le|powerpc64le) echo "powerpc64le" ;;
        s390x)              echo "s390x" ;;
        sparc64)            echo "sparc64" ;;
        thumbv7neon)        echo "thumbv7neon" ;;
        *) print_error "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
}
```

- [ ] **Step 2: Add check_asset() function + pre-check in download_binary()**

Insert `check_asset()` before `download_binary()` (after line 172, before the `download_binary` function comment block):

```bash
# 验证 release 中存在指定二进制
# 返回 0 = 存在, 1 = 不存在
check_asset() {
    local fname="$1"
    local ver="$2"
    # 使用 GitHub API 列出 assets，静默检查
    curl -s --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${NG_REPO}/releases/tags/v${ver}" 2>/dev/null \
        | grep -qF "\"name\": \"${fname}\""
}
```

Then modify `download_binary()` to add pre-check after constructing `fname`. After line 181 (`local fname="nodeget-${component}-linux-${target}"`), add:

```bash
    # 校验该架构/组件组合是否存在
    if ! check_asset "$fname" "$ver"; then
        print_error "NodeGet 未提供 ${component} 的 ${target} 架构二进制"
        if [ "$component" = "server" ] && { [ "$arch" = "arm" ] || [ "$arch" = "i686" ]; }; then
            print_info "Server 仅支持 x86_64、aarch64、armv7 架构"
        fi
        exit 1
    fi
```

Wait — `$arch` isn't in scope inside `download_binary()`. The arch value from `get_arch` is in `get_target()`. Let me re-check the flow...

In `install_server()` and `install_agent()`:
```bash
local target; target=$(get_target)    # target is e.g. "x86_64-gnu"
```

So in `download_binary()`, the `target` parameter is the full target string like `x86_64-gnu`. For the arch-only check, I need to extract the arch part.

Revised pre-check code for `download_binary()`:

Insert after line 181 (`local fname="nodeget-${component}-linux-${target}"`):

```bash
    # 校验该架构/组件组合是否存在
    if ! check_asset "$fname" "$ver"; then
        local asset_arch="${target%%-*}"
        print_error "NodeGet release v${ver} 中未找到: ${fname}"
        if [ "$component" = "server" ] && { [ "$asset_arch" = "arm" ] || [ "$asset_arch" = "i686" ]; }; then
            print_info "Server 仅提供 x86_64、aarch64、armv7 架构，请更换设备或使用 Agent"
        fi
        exit 1
    fi
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n nodeget.sh`
Expected: Exit 0.

- [ ] **Step 4: Commit**

```bash
git add nodeget.sh
git commit -m "feat(nodeget): expand arch support and add asset validation

Add riscv64gc, powerpc64, powerpc64le, s390x, sparc64, thumbv7neon.
Pre-flight asset check before download gives clear error when
a component doesn't exist for the target architecture (e.g. server on arm/i686).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Add upgrade feature

**Files:**
- Modify: `nodeget.sh` — insert `upgrade_nodeget()` function after `install_agent()` (~line 615)
- Modify: `nodeget.sh` — menu display and case statement (~lines 707-755)

- [ ] **Step 1: Insert upgrade_nodeget() function**

Insert after line 615 (the closing `}` of `install_agent()`):

```bash
# ============================================
# 升级 (仅更新二进制，保留配置)
# ============================================

upgrade_nodeget_server() {
    if [[ ! -x "${NG_SERVER_BIN}" ]] || [[ ! -f "${NG_SERVER_CONF}" ]]; then
        print_warn "nodeget-server 未安装，请先安装"; return
    fi

    local ver; ver=$(get_latest_version)
    local target; target=$(get_target)
    print_info "当前架构: ${target}, 目标版本: v${ver}"

    svc_op "${NG_SERVER_SERVICE}" stop
    download_binary "server" "$ver" "$target" "${NG_SERVER_BIN}"
    svc_op "${NG_SERVER_SERVICE}" start

    if svc_op "${NG_SERVER_SERVICE}" status >/dev/null 2>&1; then
        print_ok "nodeget-server 升级到 v${ver} 完成"
    else
        print_warn "升级后服务启动失败，请检查: journalctl -u ${NG_SERVER_SERVICE}"
    fi
}

upgrade_nodeget_agent() {
    if [[ ! -x "${NG_AGENT_BIN}" ]] || [[ ! -f "${NG_AGENT_CONF}" ]]; then
        print_warn "nodeget-agent 未安装，请先安装"; return
    fi

    local ver; ver=$(get_latest_version)
    local target; target=$(get_target)
    print_info "当前架构: ${target}, 目标版本: v${ver}"

    svc_op "${NG_AGENT_SERVICE}" stop
    download_binary "agent" "$ver" "$target" "${NG_AGENT_BIN}"
    svc_op "${NG_AGENT_SERVICE}" start

    print_ok "nodeget-agent 升级到 v${ver} 完成"
}
```

- [ ] **Step 2: Add upgrade options to menu**

Current menu display (lines 707-726):
```bash
    echo -e "${GREEN}11.${RESET} 查看 Server 配置"
    echo -e "${GREEN}12.${RESET} 查看 Agent 配置"
    echo -e "${GREEN}13.${RESET} 查看 Server UUID"
    echo -e "---"
    echo -e "${GREEN}0.${RESET} 退出"
    hr
    read -rp "请输入选项 [0-13]: " choice
```

Replace with:
```bash
    echo -e "${GREEN}11.${RESET} 查看 Server 配置"
    echo -e "${GREEN}12.${RESET} 查看 Agent 配置"
    echo -e "${GREEN}13.${RESET} 查看 Server UUID"
    echo -e "---"
    echo -e "${GREEN}14.${RESET} 更新 Server (保留配置)"
    echo -e "${GREEN}15.${RESET} 更新 Agent (保留配置)"
    echo -e "---"
    echo -e "${GREEN}0.${RESET} 退出"
    hr
    read -rp "请输入选项 [0-15]: " choice
```

- [ ] **Step 3: Add case handlers for options 14/15**

Current end of case statement (lines 753-755):
```bash
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; pause ;;
```

Replace with:
```bash
        14) upgrade_nodeget_server; pause ;;
        15) upgrade_nodeget_agent; pause ;;
        0) echo -e "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) echo -e "${RED}无效选项${RESET}"; pause ;;
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n nodeget.sh`
Expected: Exit 0.

- [ ] **Step 5: Final review — verify all 4 fixes present**

Run: `grep -n 'sed -nE.*Super Token\|sed -nE.*Root Password\|upgrade_nodeget_\|check_asset\|riscv64gc\|tag_name.*\[\[:space:\]\]' nodeget.sh`
Expected: All patterns found.

- [ ] **Step 6: Commit**

```bash
git add nodeget.sh
git commit -m "feat(nodeget): add upgrade feature for server and agent

Menu options 14/15 upgrade binary in-place without touching config.
Stop -> download latest -> start. No init re-run needed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Verification Checklist

After all tasks complete, verify:

1. `bash -n nodeget.sh` passes (syntax)
2. `grep -oP` no longer appears: `grep 'grep.*-oP' nodeget.sh` → empty
3. `check_asset` function exists: `grep -c 'check_asset()' nodeget.sh` → 1
4. `upgrade_nodeget_server` exists: `grep -c 'upgrade_nodeget_server()' nodeget.sh` → 1
5. `riscv64gc` in get_arch: `grep -c 'riscv64gc' nodeget.sh` → 1
6. Menu shows option 15: `grep -c '0-15' nodeget.sh` → 1
7. Menu case handles option 15: `grep -c '15)' nodeget.sh` → at least 1
