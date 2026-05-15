# frp Docker

[frp](https://github.com/fatedier/frp) 多架构 Docker 镜像。

## 镜像

| 镜像 | 平台 |
|------|------|
| `ghcr.io/viogus/frps:latest` | linux/amd64, arm64, arm/v7 |
| `ghcr.io/viogus/frpc:latest` | linux/amd64, arm64, arm/v7 |

## 用法

```yaml
services:
  frps:
    image: ghcr.io/viogus/frps:latest
    restart: always
    network_mode: host
    volumes:
      - ./frps.toml:/etc/frp/frps.toml
    command: -c /etc/frp/frps.toml
```

## 更新

每周日自动抓取 [fatedier/frp](https://github.com/fatedier/frp/releases) 最新版本并重建。
