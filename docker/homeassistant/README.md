# Home Assistant on Alpine (musl) — 自建 ghcr 镜像

把 [`kurapov/alpine-homeassistant`](https://hub.docker.com/r/kurapov/alpine-homeassistant)（源码：[2sheds/alpine-homeassistant](https://github.com/2sheds/alpine-homeassistant)）的 Dockerfile 拿来自己构建，推到 `ghcr.io` 上，摆脱 Docker Hub 的限流和“上游哪天不构建了”的风险。

顺便说清楚这镜像是什么：**不是**官方 HA 镜像（官方是 Debian + Python venv，~1.3 GB），而是把一个只剩 HA 的 musl 运行时装进 Alpine，压缩体积 ~310 MB。代价见下面「已知代价」。

## 镜像

| 项 | 值 |
|----|----|
| 镜像 | `ghcr.io/viogus/homeassistant` |
| tag | `:latest` `:2026.10` `:2026.10.4`（跟着 HA 版本走） |
| 平台 | linux/amd64, linux/arm64, linux/arm/v7 |
| 基础镜像 | `python:3.15.0-alpine` |
| 入口 | `hass --config=/data` |
| 端口 | 8123 |
| 用户 | 默认 root（容器内另有 `hass` 用户，uid/gid 1000，可用 `--user` 切） |
| 健康检查 | `GET /manifest.json`，`start-period=180s` |

构建与推送完全在 GitHub Actions 上做，见 [`.github/workflows/build-homeassistant.yml`](../../.github/workflows/build-homeassistant.yml)：

* 版本默认取 PyPI 上 HA 最新的**正式版**（自动跳过 `b`/`rc`），也可以 dispatch 时手动指定；
* ghcr 上已有同名 tag 就直接跳过，周一 cron 只在 HA 发新版时真正干活；
* 三架构一次构建约 75 分钟（上游同配置实测 05:03 → 06:16 UTC），arm64 / armv7 走 QEMU；
* 推完镜像会在 amd64 上真跑一遍，等 `/manifest.json` 回 200 才算发布成功，失败会打日志并让 job 红。

## 用

```bash
docker run -d --name homeassistant \
  --restart=unless-stopped \
  --network=host \
  -e TZ=Asia/Shanghai \
  -v /var/opt/docker/homeassistant:/data \
  -v /etc/localtime:/etc/localtime:ro \
  ghcr.io/viogus/homeassistant:2026.10.4
```

打开 `http://<host>:8123` 就是 onboarding 页面。

`docker compose up -d`（本目录的 compose 默认就是 host 网络 + `./data`）：

```yaml
services:
  homeassistant:
    image: ghcr.io/viogus/homeassistant:2026.10.4
    container_name: homeassistant
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./data:/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      TZ: Asia/Shanghai
```

* **host 网络**是推荐做法：mDNS / SSDP / 局域网广播这类设备自动发现，桥接网络下基本残废。要隔离就用 `ports: ["8123:8123"]`，发现能力会打折。
* 升级：改 tag 再 `docker compose up -d`。`/data` 里的配置、数据库、备份都在卷上，不会丢。
* 以非 root 跑：`chown -R 1000:1000 ./data` 后加 `user: "1000:1000"`。注意 nmap 的 SYN 扫描和部分设备追踪需要 root，切了会退化。

## 和上游 Dockerfile 的差异

只有两处，其余（基础镜像、`apk add` 包列表、插件清单、entrypoint）原样保留：

| 差异 | 原因 |
|------|------|
| jemalloc 用 Alpine main 仓库的 `jemalloc` 包，不再 `FROM kurapov/alpine-jemalloc:5.3.0` 只为了拷一个 `libjemalloc.so.2` | 少一个第三方镜像依赖；`v3.23`/`v3.24` 的 x86_64 / aarch64 / armhf main 仓库里都有这个包 |
| 默认 `VERSION` / OCI labels 换成本仓库的构建值 | CI 会用 `--build-arg VERSION=...` 覆盖 |

`LD_PRELOAD=/usr/lib/libjemalloc.so.2` 保留（HA 的小对象分配多，jemalloc 比 musl malloc 稳）。

## 已知代价

* **没有 HA Supervisor / Add-ons**。Add-on 是官方 HA OS 那一套的东西，这个镜像只有 HA Core。要装集成请走 HACS 或直接装到 `custom_components`。
* **musl 上没有预编译 wheel 的包要现场编译**。构建里带了 `build-base cargo cmake libjpeg-turbo-dev` 等编译依赖（同一层装完再 `apk del`，不进最终镜像），所以构建慢；正好撞上这种包时，armv7 的 QEMU 构建会更慢。
* **armv7 只是“能构建出来”**，没有在真机上验过。32 位 ARM 上 HA 的 Python 依赖覆盖本来就不如 64 位，真要用建议 arm64。
* 版本号是 HA Core 的版本；镜像 tag 与 PyPI 上的 `homeassistant` 版本一一对应。

## 本地构建（可选）

本机 Docker 拉 Docker Hub 被墙的话，先把基础镜像从镜像站拉下来改 tag：

```bash
docker pull docker.m.daocloud.io/library/python:3.15.0-alpine
docker tag  docker.m.daocloud.io/library/python:3.15.0-alpine python:3.15.0-alpine

docker build \
  --build-arg VERSION=2026.10.4 \
  -t ghcr.io/viogus/homeassistant:2026.10.4 \
  docker/homeassistant
```

单架构（本机架构）构建，arm64 上大约 20–40 分钟。

## 上游与许可

* Dockerfile 来源：[2sheds/alpine-homeassistant](https://github.com/2sheds/alpine-homeassistant)（MIT），作者 Oleg Kurapov。
* Home Assistant 本体：[home-assistant/core](https://github.com/home-assistant/core)，Apache-2.0。
* 本仓库只做重新构建与发布，`Dockerfile` 头部的注释标了改动点。
