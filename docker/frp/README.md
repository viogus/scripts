# frp Docker

[frp](https://github.com/fatedier/frp) 多架构 Docker 镜像，`FROM scratch`，内置静态 C 入口点，支持环境变量生成配置。

## 镜像

| 镜像 | 平台 |
|------|------|
| `ghcr.io/viogus/frps:latest` | linux/amd64, arm64, arm/v7 |
| `ghcr.io/viogus/frpc:latest` | linux/amd64, arm64, arm/v7 |

## 用法

### env 变量（无需配置文件）

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

多隧道：

```yaml
environment:
  - FRP_SERVER_ADDR=1.2.3.4
  - FRP_AUTH_TOKEN=your_token
  # 隧道 1 — TCP
  - FRP_TUNNEL_NAME=ssh
  - FRP_TUNNEL_LOCAL_PORT=22
  - FRP_TUNNEL_REMOTE_PORT=6022
  # 隧道 2 — HTTP
  - FRP_TUNNEL_2_NAME=web
  - FRP_TUNNEL_2_TYPE=http
  - FRP_TUNNEL_2_LOCAL_PORT=80
  - FRP_TUNNEL_2_SUBDOMAIN=web
  - FRP_TUNNEL_2_CUSTOM_DOMAINS=example.com,www.example.com
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

检测到已挂载的非空配置文件时，自动跳过 env 生成。

## 环境变量

### frps

| 变量 | 默认 | 说明 |
|------|------|------|
| `FRP_BIND_ADDR` | `0.0.0.0` | 监听地址 |
| `FRP_BIND_PORT` | `7000` | 监听端口 |
| `FRP_KCP_BIND_PORT` | — | KCP 端口（不设则禁用 KCP） |
| `FRP_QUIC_BIND_PORT` | — | QUIC 端口 |
| `FRP_AUTH_METHOD` | `token` | `token` / `oidc` |
| `FRP_AUTH_TOKEN` | — | 认证 token |
| `FRP_AUTH_OIDC_ISSUER` | — | OIDC issuer |
| `FRP_AUTH_OIDC_AUDIENCE` | — | OIDC audience |
| `FRP_TLS_FORCE` | `false` | 强制 TLS |
| `FRP_TLS_CERT_FILE` | — | TLS 证书 |
| `FRP_TLS_KEY_FILE` | — | TLS 私钥 |
| `FRP_TLS_CA_FILE` | — | TLS CA |
| `FRP_VHOST_HTTP_PORT` | — | 虚拟主机 HTTP 端口 |
| `FRP_VHOST_HTTPS_PORT` | — | 虚拟主机 HTTPS 端口 |
| `FRP_SUBDOMAIN_HOST` | — | 子域名后缀 |
| `FRP_DASHBOARD_ADDR` | `0.0.0.0` | 面板地址 |
| `FRP_DASHBOARD_PORT` | — | 面板端口（不设则不启用） |
| `FRP_DASHBOARD_USER` | — | 面板用户名 |
| `FRP_DASHBOARD_PWD` | — | 面板密码 |
| `FRP_ALLOW_PORTS` | — | 允许的端口范围，逗号分隔（如 `2000-3000,4001`） |
| `FRP_MAX_PORTS_PER_CLIENT` | `0` | 每客户端最大端口数 |
| `FRP_UDP_PACKET_SIZE` | `1500` | UDP 包大小 |
| `FRP_ENABLE_PROMETHEUS` | `false` | Prometheus 指标 |
| `FRP_LOG_LEVEL` | `info` | `trace` / `debug` / `info` / `warn` / `error` |
| `FRP_LOG_FILE` | `console` | 日志文件路径 |
| `FRP_LOG_MAX_DAYS` | `3` | 日志保留天数 |

### frpc

| 变量 | 默认 | 说明 |
|------|------|------|
| `FRP_SERVER_ADDR` | `127.0.0.1` | 服务器地址 |
| `FRP_SERVER_PORT` | `7000` | 服务器端口 |
| `FRP_USER` | — | 用户标识 |
| `FRP_AUTH_METHOD` | `token` | `token` / `oidc` |
| `FRP_AUTH_TOKEN` | — | 认证 token |
| `FRP_AUTH_OIDC_ISSUER` | — | OIDC issuer |
| `FRP_AUTH_OIDC_AUDIENCE` | — | OIDC audience |
| `FRP_AUTH_OIDC_CLIENT_ID` | — | OIDC client ID |
| `FRP_AUTH_OIDC_CLIENT_SECRET` | — | OIDC client secret |
| `FRP_AUTH_OIDC_TOKEN_URL` | — | OIDC token endpoint |
| `FRP_TRANSPORT_PROTOCOL` | `tcp` | `tcp` / `kcp` / `quic` / `websocket` / `wss` |
| `FRP_TLS_ENABLE` | `true` | 启用 TLS |
| `FRP_TLS_CERT_FILE` | — | TLS 客户端证书 |
| `FRP_TLS_KEY_FILE` | — | TLS 客户端私钥 |
| `FRP_TLS_CA_FILE` | — | TLS CA |
| `FRP_TLS_SERVER_NAME` | — | TLS SNI |
| `FRP_TLS_INSECURE_SKIP_VERIFY` | — | 跳过 TLS 验证 |
| `FRP_PROXY_URL` | — | 代理 URL（`http://`/`socks5://`/`ntlm://`） |
| `FRP_LOGIN_FAIL_EXIT` | `true` | 首次登录失败即退出 |
| `FRP_UDP_PACKET_SIZE` | `1500` | UDP 包大小 |
| `FRP_LOG_LEVEL` | `info` | `trace` / `debug` / `info` / `warn` / `error` |
| `FRP_LOG_FILE` | `console` | 日志文件路径 |
| `FRP_LOG_MAX_DAYS` | `3` | 日志保留天数 |

### 隧道变量 (frpc)

最多 3 个隧道，`_N` 为 `_2` / `_3`（第一个无后缀，如 `FRP_TUNNEL_NAME`）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `FRP_TUNNEL[_N]_NAME` | 必填 | 代理名称 |
| `FRP_TUNNEL[_N]_TYPE` | `tcp` | `tcp` / `udp` / `http` / `https` |
| `FRP_TUNNEL[_N]_LOCAL_IP` | `127.0.0.1` | 本地 IP |
| `FRP_TUNNEL[_N]_LOCAL_PORT` | 必填 | 本地端口 |
| `FRP_TUNNEL[_N]_REMOTE_PORT` | tcp/udp 必填 | 远程端口（http/https 不需要） |
| `FRP_TUNNEL[_N]_SUBDOMAIN` | — | 子域名（http/https） |
| `FRP_TUNNEL[_N]_CUSTOM_DOMAINS` | — | 自定义域名，逗号分隔（http/https） |
| `FRP_TUNNEL[_N]_BANDWIDTH_LIMIT` | — | 带宽限制（如 `1MB`） |
| `FRP_TUNNEL[_N]_USE_ENCRYPTION` | `false` | 加密 |
| `FRP_TUNNEL[_N]_USE_COMPRESSION` | `false` | 压缩 |

## 构建

```bash
# frps
docker build --build-arg FRP_MODE=frps --build-arg FRP_VERSION=0.68.1 -t frps docker/frp

# frpc
docker build --build-arg FRP_MODE=frpc --build-arg FRP_VERSION=0.68.1 -t frpc docker/frp
```

## 更新

每周日自动抓取 [fatedier/frp](https://github.com/fatedier/frp/releases) 最新版本并重建。
