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

## Docker 镜像

多架构镜像（amd64/arm64/armv7），每周自动更新，推送到 [ghcr.io/viogus](https://github.com/viogus/scripts/pkgs/container/)。

### frp（frps / frpc）

| 镜像 | 基础 | 大小 | 说明 |
|------|------|------|------|
| `ghcr.io/viogus/frps:latest` | scratch | ~15MB | frp 服务端 |
| `ghcr.io/viogus/frpc:latest` | scratch | ~15MB | frp 客户端 |

```yaml
# docker-compose.yml
services:
  frps:
    image: ghcr.io/viogus/frps:latest
    restart: always
    network_mode: host
    volumes:
      - ./frps.toml:/etc/frp/frps.toml
    command: -c /etc/frp/frps.toml

  frpc:
    image: ghcr.io/viogus/frpc:latest
    restart: always
    network_mode: host
    volumes:
      - ./frpc.toml:/etc/frp/frpc.toml
    command: -c /etc/frp/frpc.toml
```

### snell-server

| 标签 | 基础 | 大小 | 说明 |
|------|------|------|------|
| `:latest` `:v5` `:v4` | scratch | ~3MB | 挂载配置文件 |
| `:busybox` `:v5-busybox` `:v4-busybox` | busybox | ~4.5MB | 支持 env 变量 |

**方式一：挂载配置（推荐）**

```yaml
services:
  snell-server:
    image: ghcr.io/viogus/snell-server:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./snell-server.conf:/app/snell-server.conf
    command: -c /app/snell-server.conf
```

`snell-server.conf`：
```ini
[snell-server]
listen = 0.0.0.0:9102
psk = your_psk_here
```

**方式二：env 变量**

```yaml
services:
  snell-server:
    image: ghcr.io/viogus/snell-server:busybox
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=9102
      - PSK=your_psk
      # 可选:
      - OBFS=http        # off | http
      - OBFS_HOST=       # 仅 OBFS=http 时有效
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PORT` | 随机 1025-65535 | 监听端口 |
| `PSK` | 随机 32 位 | 预共享密钥 |
| `OBFS` | `off` | 混淆模式 |
| `OBFS_HOST` | — | 混淆域名 |

## 许可

MIT License
