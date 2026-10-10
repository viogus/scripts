# Docker 底座选型：Tiny Core vs Alpine vs scratch

Status: 结论已定稿（2026-10-07）。本仓库 **不改动** nodeget / opensnell / frp 的现网
`scratch` 底座；snell、timescaledb 已经运行在 Tiny Core 底座上。本文归档全仓库的选型依据与
实测数据，避免以后重复试。

## 一句话规律

> **Tiny Core 的收益 ∝ 载荷对额外 glibc / 共享库的“自包含”程度。**
>
> 载荷自己带得越全（纯静态），Tiny Core 越是纯负担；载荷越依赖那份 glibc（glibc 动态小二进制），
> Tiny Core 越划算；载荷依赖一大堆额外 so 时，收益缩水到零头。

| 载荷类型 | 例子 | Tiny Core 效果 |
|---|---|---|
| glibc 动态、体积小且自包含 | **snell** | **大赢**：省掉整份 glibc 层 |
| glibc 动态、但依赖大量额外 so | **timescaledb** | **小赢**：底座省 glibc，但 openssl/zlib/lz4/zstd/locale… 仍要自带，净省 ~1.5 MiB |
| 纯静态 | **nodeget / opensnell / frp** | **纯亏**：底座完全用不到，白加 2.41 MiB（arm64） |
| 全量运行时 | oci-helper / tradingagents / aimili-vpngate | **不可行**：Tiny Core 没有 JRE/Python/openvpn 生态 |

## 口径

- 体积均为 **单平台压缩体积**（= registry 上真正传输的 layer 字节之和），不是 `docker images` 的
  SIZE（containerd 下会把多平台 manifest 一起算）。`amd64` / `arm64` 分列，单位 MiB。
- 逐层实测用 `docker/snell/variants/measure-image-size.py`（`docker save` → OCI blob）。
- 现网镜像体积用 GHCR manifest：

  ```bash
  img=viogus/nodeget-server; tag=latest; arch=arm64
  TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:${img}:pull&service=ghcr.io" | jq -r .token)
  IDX=$(curl -fsSL -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "https://ghcr.io/v2/${img}/manifests/${tag}")
  DG=$(echo "$IDX" | jq -r --arg a "$arch" '.manifests[]|select(.platform.architecture==$a)|.digest' | head -1)
  curl -fsSL -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/${img}/manifests/${DG}" | jq '[.layers[].size]|add/1048576'
  ```

## 1. 全仓库镜像总表

| 镜像 | 运行时底座 | 载荷形态 / 链接方式 | amd64 | arm64 | Tiny Core 判定 |
|---|---|---|---|---|---|
| `nodeget-server` | **scratch** | Rust musl 静态（UPX、无 section） | 6.46 | 5.86 | ❌ 实测 +2.41 → 8.28 |
| `nodeget-agent` | **scratch** | 同上 | 2.28 | 2.07 | ❌ 估算 +2.41（还需补 CA 证书层） |
| `opensnell-server` | **scratch** | Go 静态（`CGO_ENABLED=0`） | 2.05 | 1.90 | ❌ 实测 +2.29 → 4.19 |
| `frps` | **scratch** | Rust musl 静态 | 3.49 | 3.47 | ❌ 实测 +2.41 → 5.86 |
| `frpc` | **scratch** | Rust musl 静态 | 2.93 | 2.91 | ❌ 估算 +2.41 → ~5.32 |
| `snell-server` v6 | **Tiny Core** | glibc 动态 | 3.99 | 3.75 | ✅ 已迁移 |
| `snell-server` v5 | **Tiny Core** | glibc 动态（static-pie + dlopen loader） | 3.85 | 3.64 | ✅ 已迁移 |
| `timescaledb` | **Tiny Core** | glibc 动态（源码编译 + 额外 so） | 22.23 | 22.04 | ✅ 已迁移（省 ~1.5 vs alpine-lean） |
| `oci-helper` | eclipse-temurin:21-jre-alpine | JVM + jar | 167.84 | 167.20 | ❌ 不适用（需完整 JRE） |
| `aimili-vpngate` | alpine | openvpn + python3 + iptables | 19.80 | 20.24 | ❌ 不适用（aarch64 有 python3.11/openvpn，但 `python3.11.tcz` 单包 20.4MB、连依赖 ~25–28MB，远超 alpine 整个运行层 6.34MB 压缩） |
| `tradingagents` | python:3.12-slim | Python venv | 258.81 | 253.55 | ❌ 不适用（需完整 Python） |

## 2. 实测：Tiny Core 变体（本次新增，arm64，逐层压缩 MiB）

| 镜像 | 底座层 | 载荷层 | entrypoint | 合计 | vs 现网 scratch |
|---|---|---|---|---|---|
| nodeget-server | 2.414 | 5.832 | 0.028 | **8.275** | 5.863 → **+2.412 (+41%)** |
| opensnell-server | 2.414 | 1.745 | 0.027 | **4.186** | 1.900 → **+2.286 (+120%)**¹ |
| frps | 2.414 | 3.420 | 0.029 | **5.862** | 3.449 → **+2.413 (+70%)** |

¹ opensnell 变体未叠 CA 证书（+0.123）与 runtime-etc，叠上后 4.309，结论不变。

三个变体都已实际构建 + 冒烟通过：nodeget 监听 2299、opensnell 监听 2399、frps 与 scratch 版
行为一致（无 token 时同样报 `security misconfiguration` 退出）。变体代码：

```
docker/nodeget/variants/Dockerfile.tinycore
docker/opensnell/variants/Dockerfile.tinycore
docker/frp/variants/Dockerfile.tinycore
```

## 3. 底座成本（arm64，压缩 / 解压 MiB）

| 底座 | 压缩 | 解压 | 说明 |
|---|---|---|---|
| Tiny Core `TC_SLIM=1` | **2.414** | 6.512 | glibc 2.40 + libstdc++ + libgcc + busybox（~130 applet 软链） |
| Tiny Core 完整 | 4.018 | 11.030 | 多出 e2fsprogs/udev/tce* 等，容器用不到 |
| `alpine:3.20` 自身 | 3.903 | 8.686 | musl，不含 glibc |
| 一份 Debian glibc 叠加层 | 2.067 | 4.914 | alpine-glibc 方案额外叠的 |
| musl 静态 entrypoint | 0.021 | 0.042 | 真正省体积的一项（glibc 静态版 0.313） |

> amd64 对应：Tiny Core slim rootfs 2.673 / 6.789（完整 3.774 / 9.373），alpine:3.20 自身
> 3.462 / 7.717。静态二进制的 Tiny Core 开销在 amd64 约 +2.67。

## 4. 两个 glibc 案例

### snell（大赢的极端）

snell 是 glibc 动态：v5 自称 static 但运行时 `open("/lib64/ld-linux-x86-64.so.2")`，v6 是普通
动态链接；两者都需要完整 glibc + libstdc++。Tiny Core 的系统 libc 就是 glibc 且自带 libstdc++，
所以不用再叠一份 glibc，也不需要 gcompat 垫片。现网已切 Tiny Core + **musl 静态 entrypoint**。

| amd64 | 压缩 MiB |
|---|---|
| alpine + 一份 Debian glibc（alpine-glibc） | 7.069 |
| alpine + gcompat（仅 v6） | 5.790 |
| 旧 scratch + glibc 静态 entrypoint | 3.899 |
| 现网 Tiny Core slim + musl 静态 entrypoint | 3.853 |
| scratch + 外置 glibc libs + musl entrypoint（最小但有取舍） | 3.606 |

即 Tiny Core 与旧 scratch 基本持平（±1%），**真正省体积的是 musl 静态 entrypoint（-0.29 MiB）**；
选 Tiny Core 是为了换来完整可调试的 busybox 用户态。详见 `docker/snell/variants/README.md`。

### timescaledb（小赢的中间地带）

`docker/timescaledb/Dockerfile` 已经是 Tiny Core 生产镜像（`FROM debian ... AS tinycore` →
运行时 `FROM scratch` 叠 rootfs）。它是 glibc 栈，底座省掉 glibc，但 Postgres 需要的
openssl/zlib/lz4/zstd/readline/locale/nss_wrapper 等 Tiny Core 都不带，仍要自带约 2.59 MiB
的 `extralib` + locale 层。

| 方案 | 底座 | 压缩 MiB |
|---|---|---|
| alpine + 全套构建选项 | alpine | 117.53 |
| alpine-lean（musl，同样精简选项） | alpine | 23.52 |
| **现网 Tiny Core** | Tiny Core | **22.04**（arm64）/ 22.23（amd64） |

结论：**换底座只省约 1.5 MiB（相对 alpine-lean ~6%）**，那 96 MiB 的大头来自构建选项
（libLLVM 59MB、ICU 14MB、bitcode 12MB 等）。Tiny Core 的 rootfs 只占 2.57 / 22.04 MiB。
详见 `docker/timescaledb/README.md`。

## 5. 为什么不给 nodeget / opensnell / frp 换底座

三者的二进制都是静态（`file` 分别输出 `statically linked`），`scratch` + musl 静态 entrypoint
已经是最小集合；再叠 Tiny Core 的 glibc/busybox 用户态纯属负担，且带来限制：

- Tiny Core 无通用 **armv7** rootfs（piCore armhf 是树莓派整盘镜像），而现网三个镜像都支持
  `linux/arm/v7`。
- Tiny Core 不带 `/etc/ssl`，`nodeget-agent` 走 WSS 需要的 CA 包得另叠。
- 精简后没有 `tce*`，镜像不可运行时扩展。

## 6. 复现

```bash
# 现网底座（scratch）
docker build --platform linux/arm64 -f docker/nodeget/Dockerfile docker/nodeget \
  --build-arg NODEGET_VERSION=0.5.18 --build-arg NODEGET_COMPONENT=nodeget-server -t nodeget-eval:scratch
# Tiny Core 变体
docker build --platform linux/arm64 -f docker/nodeget/variants/Dockerfile.tinycore docker/nodeget \
  --build-arg NODEGET_VERSION=0.5.18 --build-arg NODEGET_COMPONENT=nodeget-server -t nodeget-eval:tinycore
# 量体积
docker save nodeget-eval:scratch  -o /tmp/a.tar
docker save nodeget-eval:tinycore -o /tmp/b.tar
python3 docker/snell/variants/measure-image-size.py /tmp/a.tar /tmp/b.tar
```

opensnell / frp 同理，分别换 `docker/opensnell`（`OPENSNELL_VERSION=v1.0.4`）与
`docker/frp`（`FRP_VERSION=0.71.0`、`FRP_COMPONENT=frps`）。opensnell 变体的 builder 阶段额外
加了 `ENV GOPROXY=https://goproxy.cn,direct`，仅为 CN 网络下拉依赖，不影响产物大小。

## 7. 变更清单

| 文件 | 说明 |
|---|---|
| `docker/nodeget/variants/Dockerfile.tinycore` | 实验变体（不接 CI） |
| `docker/opensnell/variants/Dockerfile.tinycore` | 实验变体 |
| `docker/frp/variants/Dockerfile.tinycore` | 实验变体 |
| `docker/{nodeget,opensnell,frp}/variants/README.md` | 各自对比与复现 |
| 本文 | 全仓库选型总表 |
| 现网 `docker/{nodeget,opensnell,frp}/Dockerfile` | **未改动**（保持 scratch） |
