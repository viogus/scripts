# Proxy Management Scripts

一键安装/管理代理服务的 Shell 脚本集合。支持 VLESS Reality、Hysteria 2、AnyTLS、ShadowTLS、Snell、Shadowsocks 2022。

## 快速开始

```bash
# 统一管理菜单（推荐）
bash <(curl -fsSL https://raw.githubusercontent.com/viogus/scripts/main/menu.sh)

# 或单独运行某个脚本
bash <(curl -fsSL https://raw.githubusercontent.com/viogus/scripts/main/hysteria2.sh)
```

安装后可通过 `menu` 命令重新进入管理菜单。

## 支持的平台

| 系统 | 包管理器 | Init 系统 |
|------|---------|----------|
| Debian / Ubuntu | apt | systemd |
| RHEL / CentOS / Fedora | dnf / yum | systemd |
| Alpine Linux | apk | OpenRC |

## 脚本说明

| 脚本 | 协议 | 端口 | 传输 |
|------|------|------|------|
| `menu.sh` | 统一管理菜单 | — | — |
| `vless.sh` | VLESS + XTLS Reality | 443 (默认) | TCP |
| `hysteria2.sh` | Hysteria 2 | 随机/UDP | QUIC |
| `anytls.sh` | AnyTLS | 随机 | TCP + TLS |
| `shadowtls.sh` | ShadowTLS V3 | 随机 | TCP + TLS 伪装 |
| `snell.sh` | Snell v4/v5 | 随机 | TCP |
| `ss-2022.sh` | Shadowsocks 2022 | 随机 | TCP+UDP |

### 功能

每个脚本提供：
- **安装** — 下载二进制、生成配置、创建 systemd/openrc 服务
- **卸载** — 停止服务、删除二进制和配置
- **查看配置** — 输出 Surge/Shadowrocket 客户端配置和二维码
- **修改端口/密码** — 在线更新配置并重启
- **服务启停** — start / stop / restart / status

### 配置文件路径

| 服务 | 配置目录 |
|------|---------|
| Xray (VLESS) | `/usr/local/etc/xray/` |
| Hysteria 2 | `/usr/local/etc/hysteria/` |
| AnyTLS | `/usr/local/etc/anytls/` |
| ShadowTLS | `/usr/local/etc/shadowtls/` |
| Snell | `/usr/local/etc/snell/` |
| SS-Rust | `/usr/local/etc/ss-rust/` |

二进制文件统一安装在 `/usr/local/bin/`。

## 共享库

`lib/svc-utils.sh` 提供统一的 init 检测和服务操作：

```bash
# 加载链：本地 > 系统 > GitHub 下载 > 内联兜底
source lib/svc-utils.sh
```

提供的公共函数：`detect_init`、`detect_os`、`svc_start/stop/restart/enable/disable`、`svc_is_active`、`svc_main_pid`、`get_ip`、`install_pkg`、`has_cmd` 等。

## 客户端配置格式

所有脚本均输出以下客户端格式：
- **Surge** — 代理策略组配置
- **Shadowrocket** — 分享链接 + 二维码
- **Clash Meta** — YAML 代理配置（部分脚本）

## 安全说明

- 所有服务以 `nobody` 用户运行（非 root）
- 外部请求全部使用 HTTPS
- 安装脚本不会自动关闭防火墙
- 私钥/密码不会写入全局可读的临时文件

## 许可

MIT License
