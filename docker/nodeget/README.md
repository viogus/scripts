# NodeGet Docker

[NodeGet](https://github.com/NodeSeekDev/NodeGet) 多架构 Docker 镜像，二进制取自 [GenshinMinecraft/NodeGet](https://github.com/GenshinMinecraft/NodeGet) 构建的 release。

## 镜像

| 镜像 | Tag |
|------|-----|
| `ghcr.io/viogus/nodeget-server` | `latest`, `0.3.1` |
| `ghcr.io/viogus/nodeget-agent` | `latest`, `0.3.1` |

linux/amd64, arm64, arm/v7

## 用法

### 环境变量（自动生成配置，仅 Server）

Server 首次启动时若 `/etc/nodeget/config.toml` 不存在或为空，entrypoint 自动从环境变量生成配置文件。Agent 必须挂载已有配置文件。

与 [官方镜像](https://github.com/GenshinMinecraft/NodeGet) env 完全兼容。

| 环境变量 | 别名 | 默认值 |
|----------|------|--------|
| `NODEGET_SERVER_UUID` | — | 自动生成（`/proc/.../uuid`） |
| `NODEGET_PORT` | `PORT` | `2211` |
| `NODEGET_WS_LISTENER` | — | `0.0.0.0:${PORT}` |
| `NODEGET_LOG_FILTER` | `LOG_FILTER` | `info` |
| `NODEGET_DATABASE_URL` | `DATABASE_URL` | `sqlite:///var/lib/nodeget/nodeget.db?mode=rwc` |
| `NODEGET_DATA_DIR` | — | `/var/lib/nodeget` |
| `NODEGET_CONFIG_PATH` | — | `/etc/nodeget/config.toml` |
| `NODEGET_JSONRPC_MAX_CONNECTIONS` | — | `100` |
| `NODEGET_ENABLE_UNIX_SOCKET` | — | `false` |
| `NODEGET_UNIX_SOCKET_PATH` | — | `/var/lib/nodeget.sock` |
| `NODEGET_MONITORING_FLUSH_INTERVAL_MS` | — | `500` |
| `NODEGET_MONITORING_MAX_BATCH_SIZE` | — | `1000` |
| `NODEGET_DB_CONNECT_TIMEOUT_MS` | — | `3000` |
| `NODEGET_DB_ACQUIRE_TIMEOUT_MS` | — | `3000` |
| `NODEGET_DB_IDLE_TIMEOUT_MS` | — | `3000` |
| `NODEGET_DB_MAX_LIFETIME_MS` | — | `30000` |
| `NODEGET_DB_MAX_CONNECTIONS` | — | `10` |

### Server

```yaml
services:
  nodeget-server:
    image: ghcr.io/viogus/nodeget-server:latest
    restart: always
    network_mode: host
    environment:
      NODEGET_PORT: "2211"
    volumes:
      - nodeget-data:/var/lib/nodeget
```

### Agent

Agent 需要预配置 server 地址和 token，必须挂载配置文件：

```yaml
services:
  nodeget-agent:
    image: ghcr.io/viogus/nodeget-agent:latest
    restart: always
    network_mode: host
    volumes:
      - ./agent-config.toml:/etc/nodeget/config.toml
```

### 使用已有配置文件

挂载配置文件后 entrypoint 跳过自动生成，直接使用已有配置：

```yaml
services:
  nodeget-server:
    image: ghcr.io/viogus/nodeget-server:latest
    restart: always
    network_mode: host
    volumes:
      - ./config.toml:/etc/nodeget/config.toml
```

## 更新

每天自动从 [GenshinMinecraft/NodeGet](https://github.com/GenshinMinecraft/NodeGet/releases) 抓取最新版本并重建。
