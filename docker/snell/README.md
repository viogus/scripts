# snell-server Docker

[Snell](https://manual.nssurge.com/others/snell.html) 多架构 Docker 镜像。

## 镜像

`ghcr.io/viogus/snell-server` — linux/amd64, arm64, arm/v7

| 标签 | 说明 |
|------|------|
| `:latest` `:v5` | 最新 v5.x |
| `:v4` | 最新 v4.x |
| `:v5.0.1` | 精确版本 |

## 用法

### env 变量（无需配置文件）

```yaml
services:
  snell-server:
    image: ghcr.io/viogus/snell-server:latest
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=9102
      - PSK=your_psk
      - OBFS=off
```

| 变量 | 默认 | 说明 |
|------|------|------|
| `PORT` | 随机 1025-65535 | 监听端口 |
| `PSK` | 随机 32 位 | 预共享密钥 |
| `OBFS` | `off` | `off` 或 `http` |

### 挂载配置文件

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

检测到已挂载配置文件时，自动跳过 env 生成。

## 构建

```bash
docker build --build-arg SNELL_VERSION=5.0.1 -t snell-server docker/snell
```

## 更新

每周日自动抓取最新 v4/v5 版本并重建。
