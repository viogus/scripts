# 代码审核报告（第二轮）

**审核范围:** menu.sh, vless.sh, anytls.sh, hysteria2.sh, shadowtls.sh, snell.sh, ss-2022.sh  
**审核日期:** 2026-05-02  
**审核类型:** 全面审核 + 修改验证

---

## 一、变更概要

本轮修改覆盖范围广，针对第一轮审核中提出的多个严重和中等问题进行了修复：

| 问题 | 第一轮状态 | 涉及文件 | 当前状态 |
|------|-----------|---------|---------|
| `svc_list_match` 在 OpenRC 下的参数 Bug | 🔴 严重 | menu.sh | ✅ 已修复 |
| `svc_main_pid` 结果被重复 cut | 🔴 严重 | menu.sh | ✅ 已修复 |
| IP 探测使用 HTTP 明文 | 🟡 中等 | menu.sh, hysteria2.sh | ✅ 已修复 |
| shadowtls.sh 服务以 root 运行 | 🔴 严重 | shadowtls.sh | ✅ 已修复 |
| ss-2022.sh 服务以 root 运行 | 🔴 严重 | ss-2022.sh | ✅ 已修复 |
| 公共函数大量重复 | 🔴 严重 | 5 个文件 | 🟡 部分修复 |
| ss-2022.sh View() 仅检查 systemd | 🟡 中等 | ss-2022.sh | ✅ 已修复 |
| vless.sh 密钥文件安全 | 🟢 轻微 | vless.sh | ✅ 已修复 |
| menu.sh 卸载未删除 OpenRC 路径 | 🟡 中等 | menu.sh | ✅ 已修复 |
| anytls.sh 服务以 root 运行 | 🔴 严重 | anytls.sh | ❌ 未修复 |
| anytls.sh IP 探测用 HTTP | 🟡 中等 | anytls.sh | ❌ 未修复 |

---

## 二、逐文件修改详情

### menu.sh — 修改最多，质量显著提升

**共享库加载（第 146-147 行）**
```bash
LIB_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib"
[ -f "$LIB_DIR/svc-utils.sh" ] && . "$LIB_DIR/svc-utils.sh"
```
当 `lib/svc-utils.sh` 存在时优先加载。设计思路好：发布版本可附带公库，独立运行时降级到内联实现。需要注意：发布到 GitHub 时需确保 lib 目录一起打包，否则线上版本永远不加载公库。

**svc_list_match → svc_list 重构（第 172 行）**
```bash
# 旧（有 OpenRC 参数传递 Bug）
svc_list_match() { ... | grep -E "$1" }

# 新（用文件系统查询替代 systemctl 命令查询）
svc_list() { ls /etc/systemd/system/$1*.service /etc/init.d/$1* 2>/dev/null | sed 's|.*/||; s/\.service$//' | sort -u; }
```
优点：避免了 `svc_list_match` 在 OpenRC 下将 systemd 特有参数（`--type=service` 等）当正则去 grep 的问题，且统一了 systemd 和 openrc 的行为。局限：只检查服务文件是否存在，不检查服务是否被 init 系统注册（如 `systemctl list-units` vs 仅检查文件）。实际使用场景下这个差异不大。

**svc_main_pid 修复（第 171 行）**
```bash
# 旧：硬编码单等号分隔，某些 systemd 版本用 =
svc_main_pid() { ... | cut -d'=' -f2; }

# 新：用 cut -d= -f2（与单等号兼容更好）
svc_main_pid() { ... | cut -d= -f2; }
```
同时移除了所有调用点（第 190、210、236、255、296 行）中重复的 `| cut -d'=' -f2`。

**IP 探测改 HTTPS（第 524 行）**
```bash
# 旧
curl -s ... http://www.cloudflare.com/cdn-cgi/trace

# 新
curl -s ... https://www.cloudflare.com/cdn-cgi/trace
```

**卸载 OpenRC 路径补充（第 413、419、431、503-504 行）**
卸载功能现在同时清理 `/etc/init.d/` 下的 OpenRC 服务文件。不过第 418-419 行有轻微问题：
```bash
rm -f "/lib/systemd/system/snell.service" "/etc/init.d/snell"
rm -f "/etc/systemd/system/snell.service" "/etc/init.d/snell"
```
`/etc/init.d/snell` 在两个 `rm -f` 中都出现了，虽然无害，但是重复代码。

### hysteria2.sh

**共享库加载（第 48-50 行）** — 与 menu.sh 相同的模式。

**IP 探测改 HTTPS（第 86 行）** — Cloudflare trace 改用 HTTPS。

**新发现：第 86 行 grep 表达式**
```bash
ip4=$(curl ... https://www.cloudflare.com/cdn-cgi/trace ... | awk -F= '/^ip=/{print $2}')
```
`awk -F=` 使用单等号作为分隔符，这与 `svc_main_pid` 的 `cut -d=` 存在相同的风格不一致。在 Cloudflare trace 的 `ip=1.2.3.4` 格式下结果正确，因为等号后就是 IP。

**仍需关注：** `change_password()` 第 632-634 行的不安全 sed 替换仍未修复。如果密码含 `/`、`&` 等字符可导致异常。

### shadowtls.sh

**服务用户从 root 改为 nobody（第 537-539 行）**
```bash
# 旧
User=root

# 新
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
Group=nogroup
```
这是重要的安全改进。`nobody` 用户配合 `CAP_NET_BIND_SERVICE` capability 是正确的做法。同时保留了先前已有的 `NoNewPrivileges=yes`、`ProtectSystem=full` 等安全加固。

**共享库加载（第 38-39 行）** — 与 menu.sh 相同。

**仍存在：** `view_config()` 和 `restart_shadowtls_services()` 中对 `svc_status ... --no-pager` 的调用在 OpenRC 下参数会被静默丢弃。这是轻微问题，不影响功能。

### snell.sh

**共享库加载（第 383-384 行）** — 与 menu.sh 相同。

**svc_main_pid 返回值调整（第 415 行）**
```bash
# 旧
svc_main_pid() { ... | cut -d'=' -f2; }

# 新（systemd 分支不再加 cut，保留原始 MainPID=12345 格式）
svc_main_pid() { ... systemctl show -p MainPID "$1" 2>/dev/null; }
```
新版本不再对 `systemctl show` 的输出做 `cut`，这意味着返回值是 `MainPID=12345` 而非 `12345`。但调用方 `check_and_show_status()` 第 924 行直接使用该值做 `ps -p $main_pid`，这需要验证 `ps` 是否能解析 `MainPID=12345` 格式。在大多数系统上 `ps -p "MainPID=12345"` 会失败。

⚠️ **这可能是一个回归 Bug**：`svc_main_pid` 返回 `MainPID=12345` 而非 `12345`，导致 `check_and_show_status()` 中 `svc_main_pid snell` 的返回值无法直接用于 `ps -p`。

### ss-2022.sh

**服务用户从 root 改为 nobody（第 406-409 行）**
```bash
# 旧
User=root

# 新
User=nobody
AmbientCapabilities=CAP_NET_BIND_SERVICE
```

**View() 函数 ShadowTLS 路径兼容（第 1059-1064 行）**
```bash
# 旧：仅检查 systemd
if [ -f "/etc/systemd/system/shadowtls-ss.service" ]; then

# 新：检查 systemd 和 openrc
if [ -f "/etc/systemd/system/shadowtls-ss.service" ]; then
    stls_svc_file="/etc/systemd/system/shadowtls-ss.service"
elif [ -f "/etc/init.d/shadowtls-ss" ]; then
    stls_svc_file="/etc/init.d/shadowtls-ss"
fi
```
这是正确的修复，解决了 View() 在 OpenRC 系统上无法显示 ShadowTLS 配置的问题。

**卸载路径（第 923 行）** — 增加了 `/etc/init.d/ss-rust` 的删除。

### vless.sh

**密钥文件安全（第 80-81、94 行）**
```bash
# 旧：直接写 /tmp/x25519-raw.txt
xray x25519 > /tmp/x25519-raw.txt 2>&1
KEY_OUTPUT=$(cat /tmp/x25519-raw.txt)

# 新：用 mktemp + chmod 600
local tmp_keyfile; tmp_keyfile=$(mktemp) && chmod 600 "$tmp_keyfile"
xray x25519 > "$tmp_keyfile" 2>&1
KEY_OUTPUT=$(cat "$tmp_keyfile")
rm -f "$tmp_keyfile"
```
正确做法：私钥写入仅 root 可读的临时文件，使用后立即删除。

### anytls.sh

本轮未做修改。以下问题仍然存在：
- 第 156 行：IP 探测仍使用 HTTP（`http://www.cloudflare.com/cdn-cgi/trace`）
- 第 233 行：服务仍以 `User=root` 运行
- 第 103-126 行：自动禁用防火墙行为未改

---

## 三、仍存在的问题

### 🔴 严重

**1. snell.sh: svc_main_pid 返回值格式变化可能导致调用失败**

第 415 行 `svc_main_pid` 不再对 `systemctl show` 输出做 `cut`，返回 `MainPID=12345`。`check_and_show_status()` 第 924 行 `local main_pid=$(svc_main_pid snell)` 后直接 `ps -p $main_pid` 可能失败。建议恢复 `cut -d= -f2`（参考 menu.sh 第 171 行的做法）。

**2. 远程脚本无校验执行（所有脚本）** — 未修改。

### 🟡 中等

**3. anytls.sh 未同步修改** — 仍使用 root 用户运行、HTTP 探测 IP、自动关闭防火墙。

**4. hysteria2.sh change_password() sed 替换风险** — 未修改。密码含特殊字符时可能导致 YAML 格式损坏。

**5. 共享库机制不完整** — 5 个脚本加了 LIB_DIR 加载逻辑，但 `lib/svc-utils.sh` 文件不在仓库中。如果没有配套发布，这行代码永远是空操作。建议：要么创建该文件并纳入版本管理，要么移除加载逻辑。

### 🟢 轻微

**6. shadowtls.sh declare -A 兼容性** — 未修改。bash 3.x 系统仍不兼容。

**7. snell.sh check_and_show_status() 第 981 行 declare -A** — 同上。

**8. menu.sh 第 418-419 行重复的 rm -f 路径** — 小瑕疵。

---

## 四、改进建议（优先级排序）

1. **修复 snell.sh svc_main_pid 回归** — 在 systemd 分支加回 `cut -d= -f2`，或修改 `check_and_show_status()` 对返回值的处理
2. **同步修复 anytls.sh** — 参照 shadowtls.sh 的模式：`User=nobody` + `AmbientCapabilities`
3. **创建 lib/svc-utils.sh** — 将各脚本仍然内联的 `detect_init`/`svc_*` 函数移至共享库，纳入 Git
4. **hysteria2.sh change_password()** — 用 awk 或 python 做安全替换
5. **考虑 bash 版本检测** — 在脚本入口检测 bash 版本，避免在旧系统上使用 declare -A

整体评价：本轮修改质量好，针对性地修复了第一轮审核中最关键的几个 Bug（OpenRC 参数传递、重复 cut、root 运行服务、IP 明文传输）。snell.sh 的 svc_main_pid 回归是唯一需要注意的新问题。
