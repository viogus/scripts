# frp Docker

[frp](https://github.com/fatedier/frp) 多架构 Docker 镜像，内置 C 入口点支持环境变量生成配置。

## 镜像

| 镜像 | 平台 |
|------|------|
| `ghcr.io/viogus/frps:latest` | linux/amd64, arm64, arm/v7 |
| `ghcr.io/viogus/frpc:latest` | linux/amd64, arm64, arm/v7 |

## 用法

### 环境变量（无需配置文件）

**frps：**

```yaml
services:
  frps:
    image: ghcr.io/viogus/frps:latest
    restart: unless-stopped
    network_mode: host
    environment:
      - FRP_BIND_PORT=7000
      - FRP_AUTH_TOKEN=your_token
      - FRP_DASHBOARD_PORT=7500
      - FRP_DASHBOARD_USER=admin
      - FRP_DASHBOARD_PWD=secret
```

**frpc：**

```yaml
services:
  frpc:
    image: ghcr.io/viogus/frpc:latest
    restart: unless-stopped
    network_mode: host
    environment:
      - FRP_SERVER_ADDR=1.2.3.4
      - FRP_SERVER_PORT=7000
      - FRP_AUTH_TOKEN=your_token
      - FRP_TUNNEL_NAME=ssh
      - FRP_TUNNEL_LOCAL_PORT=22
      - FRP_TUNNEL_REMOTE_PORT=6022
```

### 挂载配置文件

```yaml
services:
  frps:
    image: ghcr.io/viogus/frps:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./frps.toml:/app/frp.toml
```

检测到已挂载非空配置文件时，跳过 env 生成。

## 环境变量

### frps

| 变量 | 默认 | 说明 |
|------|------|------|
| `FRP_BIND_ADDR` | `0.0.0.0` | 监听地址 |
| `FRP_BIND_PORT` | `7000` | 监听端口 |
| `FRP_AUTH_TOKEN` | — | 认证 token |
| `FRP_DASHBOARD_ADDR` | `0.0.0.0` | 面板地址 |
| `FRP_DASHBOARD_PORT` | — | 面板端口（不设则不启用） |
| `FRP_DASHBOARD_USER` | — | 面板用户名 |
| `FRP_DASHBOARD_PWD` | — | 面板密码 |
| `FRP_SUBDOMAIN_HOST` | — | 子域名后缀 |
| `FRP_TLS_CERT_FILE` | — | TLS 证书文件 |
| `FRP_TLS_KEY_FILE` | — | TLS 私钥文件 |

### frpc

| 变量 | 默认 | 说明 |
|------|------|------|
| `FRP_SERVER_ADDR` | `127.0.0.1` | 服务器地址 |
| `FRP_SERVER_PORT` | `7000` | 服务器端口 |
| `FRP_AUTH_TOKEN` | — | 认证 token |
| `FRP_TUNNEL_NAME` | — | 隧道名称 |
| `FRP_TUNNEL_TYPE` | `tcp` | 隧道类型 |
| `FRP_TUNNEL_LOCAL_IP` | `127.0.0.1` | 本地 IP |
| `FRP_TUNNEL_LOCAL_PORT` | — | 本地端口 |
| `FRP_TUNNEL_REMOTE_PORT` | — | 远程端口 |
| `FRP_TUNNEL_BANDWIDTH_LIMIT` | — | 带宽限制（如 `1MB`） |

## 更新

每周日自动抓取 [fatedier/frp](https://github.com/fatedier/frp/releases) 最新版本并重建。
