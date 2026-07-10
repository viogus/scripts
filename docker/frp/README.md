# frp-rs Docker

[frp-rs](https://github.com/viogus/frp-rs) 多架构 Docker 镜像，内置 C 入口点支持环境变量生成配置。

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

## 与 Go frp 的配置格式差异

frp-rs 使用原生配置格式（snake_case，分段式），与 fatedier/frp V1 wire protocol 兼容。

| Go frp (fatedier) | frp-rs (viogus) |
|-------------------|-----------------|
| `auth.token = "x"` | `[auth]` / `method = "token"` / `token = "x"` |
| `webServer.port = 7500` | `[web_server]` / `port = 7500` |
| `bindAddr` / `bindPort` | `bind_addr` / `bind_port` |
| `serverAddr` / `serverPort` | `server_addr` / `server_port` |

环境变量生成的是 frp-rs 原生格式。挂载配置文件时请使用 frp-rs 格式（或 Go frp `[common]` 兼容格式）。

## 更新

每周日自动抓取 [viogus/frp-rs](https://github.com/viogus/frp-rs/releases) 最新版本并重建。
