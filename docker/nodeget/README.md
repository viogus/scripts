# NodeGet Docker

[NodeGet](https://github.com/NodeSeekDev/NodeGet) 多架构 Docker 镜像，二进制取自 [GenshinMinecraft/NodeGet](https://github.com/GenshinMinecraft/NodeGet) 构建的 release。

## 镜像

| 镜像 | Tag |
|------|-----|
| `ghcr.io/viogus/nodeget-server` | `latest`, `<version>` |
| `ghcr.io/viogus/nodeget-agent` | `latest`, `<version>` |

linux/amd64, arm64, arm/v7

## 用法

### 环境变量（自动生成配置）

首次启动时若 `/etc/nodeget/config.toml` 不存在，entrypoint 自动从环境变量生成配置文件。

| 环境变量 | 默认值 |
|----------|--------|
| `NODEGET_PORT` | `2211` |
| `NODEGET_LOG_FILTER` | `info` |
| `NODEGET_DATABASE_URL` | `sqlite:///var/lib/nodeget/nodeget.db?mode=rwc` |
| `NODEGET_CONFIG_PATH` | `/etc/nodeget/config.toml` |

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

```yaml
services:
  nodeget-agent:
    image: ghcr.io/viogus/nodeget-agent:latest
    restart: always
    network_mode: host
    environment:
      NODEGET_PORT: "2211"
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
