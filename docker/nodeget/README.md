# NodeGet Docker

[NodeGet](https://github.com/NodeSeekDev/NodeGet) 多架构 Docker 镜像，二进制取自 [GenshinMinecraft/NodeGet](https://github.com/GenshinMinecraft/NodeGet) 构建的 release。

## 镜像

| 镜像 | Tag |
|------|-----|
| `ghcr.io/viogus/nodeget-server` | `latest`, `<version>` |
| `ghcr.io/viogus/nodeget-agent` | `latest`, `<version>` |

linux/amd64, arm64, arm/v7

## 用法

### Server

```yaml
services:
  nodeget-server:
    image: ghcr.io/viogus/nodeget-server:latest
    restart: always
    network_mode: host
    volumes:
      - ./config:/etc/nodeget
    command: -c /etc/nodeget/config.toml
```

### Agent

```yaml
services:
  nodeget-agent:
    image: ghcr.io/viogus/nodeget-agent:latest
    restart: always
    network_mode: host
    volumes:
      - ./config:/etc/nodeget
    command: -c /etc/nodeget/config.toml
```

## 更新

每天自动从 [GenshinMinecraft/NodeGet](https://github.com/GenshinMinecraft/NodeGet/releases) 抓取最新版本并重建。
