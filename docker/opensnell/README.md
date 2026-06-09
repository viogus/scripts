# opensnell-server Docker

[OpenSnell](https://github.com/missuo/opensnell) 是 Snell v4/v5 协议的 Go 开源实现，完全兼容官方 Surge snell-server。多架构 Docker 镜像，`FROM scratch`，C entrypoint，无运行时依赖。

## 与官方 snell-server 对比

| 维度 | OpenSnell | 官方 snell-server |
|------|-----------|-------------------|
| 实现 | Go 开源 (GPLv3) | C 闭源 |
| 并发性能 | ~98% 官方吞吐 | libuv 单线程事件循环 |
| QUIC 客户端 | 不支持（需 Surge 客户端） | 支持 |
| v1/v2/v3 | 不支持 | 向后兼容 v4 |
| 二进制 | 纯 Go 静态链接 (~6MB) | GCC 静态链接 (1.2MB) |
| 镜像大小 | ~6MB | ~10MB |
| Docker 生态 | — | — |

性能细节：N=8 并发吞吐 47.34 vs 48.19 MB/s（−1.8%），延迟不可区分。详见 [OpenSnell README](https://github.com/missuo/opensnell)。

## 镜像

`ghcr.io/viogus/opensnell-server` — linux/amd64, arm64, arm/v7

| 标签 | 说明 |
|------|------|
| `:latest` | 最新 release |
| `:v1.0.2` | 精确版本 |

## 用法

### env 变量（无需配置文件）

```yaml
services:
  opensnell-server:
    image: ghcr.io/viogus/opensnell-server:latest
    restart: unless-stopped
    network_mode: host
    environment:
      - SNELL_LISTEN=0.0.0.0:2333
      - SNELL_PSK=your_psk_here
```

| 变量 | 默认 | 说明 |
|------|------|------|
| `SNELL_LISTEN` | `0.0.0.0:2333` | 监听地址:端口 |
| `SNELL_PSK` | 随机 24 位 | 预共享密钥 |
| `SNELL_OBFS` | `off` | `off` / `http` / `tls` |
| `SNELL_UDP` | `true` | UDP-over-TCP |
| `SNELL_QUIC` | `true` | QUIC 代理模式（服务端） |
| `SNELL_IPV6` | `true` | IPv6 出站 |
| `SNELL_TFO` | `false` | TCP Fast Open（Linux only） |
| `SNELL_EGRESS_INTERFACE` | — | 出站网卡绑定 |
| `SNELL_DNS` | — | 自定义上游 DNS |

### 挂载配置文件

```yaml
services:
  opensnell-server:
    image: ghcr.io/viogus/opensnell-server:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./snell-server.conf:/etc/snell-server/snell-server.conf
    command: -c /etc/snell-server/snell-server.conf
```

`snell-server.conf`：
```ini
[snell-server]
listen = 0.0.0.0:2333
psk = your_psk_here
obfs = off
udp = true
quic = true
ipv6 = true
tfo = false
```

检测到已挂载配置文件时，自动跳过 env 生成。

## 构建

```bash
docker build --build-arg OPENSNELL_VERSION=v1.0.2 -t opensnell-server docker/opensnell
```

## 更新

每周自动检查 [OpenSnell releases](https://github.com/missuo/opensnell/releases)，有新版本即重建。
