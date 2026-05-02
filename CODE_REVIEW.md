# 代码审核报告（第四轮）

**审核范围:** menu.sh, vless.sh, anytls.sh, hysteria2.sh, shadowtls.sh, snell.sh, ss-2022.sh  
**审核日期:** 2026-05-02  
**审核类型:** 全面审核 + 修改验证

---

## 本轮变更

本轮修改涉及 **5 个文件**（anytls.sh 和 hysteria2.sh 未改），是一次系统性的 `svc_is_active()` 改造。

### 1. `svc_is_active()` 统一增强（5 个文件）

```bash
# 旧（以 snell.sh 第 412 行为例）
svc_is_active() {
    ...
    else systemctl is-active "$1" 2>/dev/null || echo "inactive"
}

# 新
svc_is_active() {
    ...
    else if systemctl is-active --quiet "$1" 2>/dev/null; then echo "active"; else echo "inactive"; return 1; fi;
}
```

三个改进：
- 改用 `if ... then ... else` 结构，明确两条分支
- 添加 `--quiet` 抑制 systemctl 的输出噪音
- 非激活状态时 `return 1`，让调用方可以通过 `$?` 判断

涉及文件：menu.sh:168, shadowtls.sh:68, snell.sh:412, ss-2022.sh:96, vless.sh:44

### 2. menu.sh ShadowTLS 卸载 Bug 修复（第 442 行）

```bash
# 旧（删除错误路径，缺少 .service 扩展名）
rm -f "/etc/systemd/system/${service}"

# 新（删除正确路径）
rm -f "/etc/systemd/system/${service}.service" "/etc/init.d/${service}"
```

`svc_list()` 返回的服务名不带 `.service` 后缀，旧的写法会导致清理 systemd 服务文件时路径错误 → 文件未删除遗留。现在正确添加了 `.service` 扩展名。

### 3. vless.sh `svc_is_active()` 被定义两次（第 44-45 行） ⚠️ 新 Bug

```bash
svc_is_active() { ... }    # 第 44 行（有效定义）
svc_is_active() { ... }    # 第 45 行（重复定义，完全相同的函数体）
```

两行代码完全相同，第 44 行的定义会被第 45 行覆盖。Bash 允许重复定义函数且不会报错，但第 44 行是无意义死代码。建议删除第 44 行。

---

## 当前问题总表

| # | 问题 | 严重程度 | 文件 | 状态 |
|---|------|---------|------|------|
| 1 | 远程脚本无校验执行 | 🔴 严重 | 全部 | ❌ 未改 |
| 2 | anytls.sh 服务以 root 运行 | 🔴 严重 | anytls.sh | ❌ 未改 |
| 3 | anytls.sh IP 探测用 HTTP | 🟡 中等 | anytls.sh | ❌ 未改 |
| 4 | anytls.sh 自动禁用防火墙 | 🟡 中等 | anytls.sh | ❌ 未改 |
| 5 | hysteria2.sh change_password() sed 不安全 | 🟡 中等 | hysteria2.sh | ❌ 未改 |
| 6 | 共享库 lib/svc-utils.sh 不存在 | 🟡 中等 | 5 脚本 | ❌ 未改 |
| 7 | `declare -A` bash 3.x 不兼容 | 🟢 轻微 | shadowtls.sh, snell.sh | ❌ 未改 |
| 8 | **vless.sh 重复函数定义（第 44-45 行）** | 🟢 轻微 | vless.sh | ⚠️ 本轮新增 |

---

## 逐轮修复统计

| 轮次 | 修复数量 | 修复内容 |
|------|---------|---------|
| 第一轮 | — | 初始审核，列出所有问题 |
| 第二轮 | 9 项 | OpenRC 参数、重复 cut、HTTPS、root→nobody 等 |
| 第三轮 | 2 项 | 重复 rm 路径、svc_main_pid 回归 |
| **第四轮** | **2 项 + 1 新 Bug** | svc_is_active 统一增强、卸载路径修复；vless 重复函数定义 |

---

## 总结

经过四轮迭代，项目代码质量稳步提升。当前最突出的遗留问题集中在 **anytls.sh**（未同步改进，仍以 root 运行、HTTP 探测 IP、自动关防火墙）和 **全项目的远程校验**（架构级安全风险）。vless.sh 第 44-45 行的重复函数定义是新引入的小瑕疵。
