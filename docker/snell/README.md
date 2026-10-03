# snell-server Docker

[Snell](https://manual.nssurge.com/others/snell.html) 多架构 Docker 镜像。

## 镜像

`ghcr.io/viogus/snell-server` — linux/amd64, arm64（v6 无官方 armv7l 构建，v4/v5 另含 arm/v7）；
底座为 Tiny Core Linux + musl 静态 entrypoint，压缩后约 3~4 MB（[底座与体积](#底座与体积tiny-core--musl实测)）。

| 标签 | 说明 |
|------|------|
| `:latest` `:v5` | 最新 v5.x（稳定主线） |
| `:v6` | 最新 Snell v6（RC/beta，无 armv7l） |
| `:v4` | 最新 v4.x |
| `:v5.0.1` `:v6.0.0rc2` | 精确版本 |

entrypoint 会在构建时注入 `SNELL_VERSION`，据此自动生成 **v4/v5**（`obfs`）或 **v6**（`mode` / `dns-ip-preference`）配置，无需区分镜像内容。

## 用法

### env 变量（无需配置文件）

```yaml
services:
  snell-server:
    image: ghcr.io/viogus/snell-server:v6
    restart: unless-stopped
    network_mode: host
    environment:
      - PORT=9102
      - PSK=your_psk_at_least_16_chars   # v6 要求 ≥16 字符
      - MODE=default
```

| 变量 | 默认 | 适用 | 说明 |
|------|------|------|------|
| `PORT` | 随机 1025-65535 | v4/v5/v6 | 监听端口 |
| `PSK` | 随机 32 位 | v4/v5/v6 | 预共享密钥（v6 要求 ≥16 字符，否则启动报错） |
| `MODE` | `default` | v6 | `default` / `unshaped` / `unsafe-raw`，须与客户端一致 |
| `DNS_IP_PREFERENCE` | `default` | v6 | `default` / `prefer-ipv4` / `prefer-ipv6` / `ipv4-only` / `ipv6-only` |
| `IPV6` | `off` | v6 | `on` 时监听 `0.0.0.0:PORT,[::]:PORT` 双栈 |
| `OBFS` | `off` | v4/v5 | `off` / `http` / `tls`（v6 不支持，被忽略） |
| `OBFS_HOST` | — | v4/v5 | OBFS 伪装域名（OBFS≠off 时建议设置） |

### 挂载配置文件

```yaml
services:
  snell-server:
    image: ghcr.io/viogus/snell-server:v6
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./snell-server.conf:/app/snell-server.conf
    command: -c /app/snell-server.conf
```

`snell-server.conf`（v6 示例）：
```ini
[snell-server]
listen = 0.0.0.0:9102,[::]:9102
psk = your_psk_at_least_16_chars
mode = default
dns-ip-preference = default
```

检测到已挂载配置文件时，自动跳过 env 生成。

## 构建

```bash
# 单架构
docker build --build-arg SNELL_VERSION=5.0.1 -t snell-server docker/snell

# 多架构（v6 无 armv7l，去掉 linux/arm/v7）
docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 \
  --build-arg SNELL_VERSION=5.0.1 -t snell-server docker/snell
```

| build-arg | 默认 | 说明 |
|-----------|------|------|
| `SNELL_VERSION` | `6.0.0rc2` | 决定下载的包与 entrypoint 生成的配置格式（v4/v5 vs v6） |
| `SNELL_BASE_URL` | `https://dl.nssurge.com/snell` | 下载源（可用内网镜像） |
| `TC_MAJOR` | `16` | Tiny Core 主版本，对应 `tinycorelinux.net/16.x/` |
| `PICORE_VERSION` | `16.0.0` | piCore 整盘镜像版本（arm64 / armv7 走它取 rootfs） |
| `TC_SLIM` | `1` | `0` = 保留完整 Tiny Core 用户态，不精简 |
| `ALPINE_VERSION` | `3.20` | entrypoint 编译阶段（musl 静态） |
| `DEBIAN_VERSION` | `stable-slim` | 下载/解包与打包阶段 |

v6 无官方 armv7l 二进制，构建 arm 平台会直接报错；v4/v5 仍支持 `linux/arm/v7`。

冒烟测试（起容器 → 检查 entrypoint 生成的配置、监听日志、宿主 TCP 可达、底座可用性）：

```bash
sh docker/snell/smoke-snell.sh snell-server:local
PLATFORM=linux/arm/v7 sh docker/snell/smoke-snell.sh snell-server:local   # 跨架构需 qemu binfmt
```

### 底座与体积（Tiny Core + musl，实测）

最终镜像 = 精简后的 **Tiny Core Linux 16.x rootfs** + **musl 静态 entrypoint**（约 40 KB，
`FROM scratch` 收尾）。Tiny Core 自带 glibc 与 libstdc++，snell v5（ELF 自称 static、运行时
dlopen loader）与 v6（普通 glibc 动态链接）都直接原生运行，Alpine 方案里的 gcompat/glibc
垫片整个不需要；同时保留了完整 busybox 用户态（`docker exec` 进去有 sh/ls/nc/wget/tar）。

单平台压缩后大小（`docker save` 逐层相加，MiB）：

| 底座方案 | 文件 | snell v5<br>amd64 / arm64 / armv7 | snell v6<br>amd64 / arm64 |
|----------|------|-----------------------------------|---------------------------|
| **Tiny Core + musl（本目录，默认）** | `Dockerfile` | **3.85 / 3.64 / 2.99** | **3.99 / 3.75** |
| scratch + musl（绝对最小，无用户态） | `variants/Dockerfile.scratch` | 3.61 / 3.30 / — | 3.75 / 3.40 |
| 旧版 scratch + glibc entrypoint | —（已替换） | 3.90 / ≈3.59 / — | 4.04 / ≈3.69 |
| Alpine + 一份 Debian glibc | `variants/Dockerfile.alpine-glibc` | 7.07 / 7.20 / — | 7.21 / — |
| Alpine + gcompat | `variants/Dockerfile.alpine-gcompat` | — | 5.79 / 6.22 |

- 换底座只值 ±0.05 MiB（amd64 略小于旧版、arm64 略大），真正省体积的是 musl 静态
  entrypoint（40 KB vs glibc `-static` 680 KB，约占整镜像 7%）。
- 与 Alpine 方案相比体积约一半（Tiny Core 精简底座 2.67 MB < `alpine:3.20` 自身 3.46 MB）。
- 各方案的逐层拆解、踩坑与复现步骤见 [`variants/README.md`](variants/README.md)。

## 更新

每周自动抓取最新 v4/v5/v6 版本并重建（`build-snell.yml`，数据源为官方 KB release notes）。v6 标签随 RC 更新滚动；`latest`/`stable` 保持指向 v5，待 v6 正式发布后再迁移。
