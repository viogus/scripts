# snell-server Docker

[Snell](https://manual.nssurge.com/others/snell.html) 多架构 Docker 镜像。

## 镜像

| 标签 | 基础 | 说明 |
|------|------|------|
| `:latest` `:v5` `:v4` | scratch | 挂载配置文件 |
| `:busybox` `:v5-busybox` `:v4-busybox` | busybox | env 变量 |

## 用法

### 挂载配置

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

### env 变量

```yaml
services:
  snell-server:
    image: ghcr.io/viogus/snell-server:busybox
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=9102
      - PSK=your_psk
      - OBFS=off
```

| 变量 | 默认 |
|------|------|
| `PORT` | 随机 |
| `PSK` | 随机 32 位 |
| `OBFS` | `off` |

## 更新

每周日自动抓取最新 v4/v5 版本并重建。
