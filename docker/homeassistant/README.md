# Home Assistant on Alpine (musl) — 自建 ghcr 镜像

把 [`kurapov/alpine-homeassistant`](https://hub.docker.com/r/kurapov/alpine-homeassistant)（源码：[2sheds/alpine-homeassistant](https://github.com/2sheds/alpine-homeassistant)）的 Dockerfile 拿来自己构建，推到 `ghcr.io` 上，摆脱 Docker Hub 的限流和“上游哪天不构建了”的风险。

顺便说清楚这镜像是什么：**不是**官方 HA 镜像（官方是 Debian + Python venv，~1.3 GB），而是把一个只剩 HA 的 musl 运行时装进 Alpine，压缩体积 ~372 MB（其中约 65 MB 是小米集成带来的 ffmpeg + numpy）。代价见下面「已知代价」。

## 镜像

| 项 | 值 |
|----|----|
| 镜像 | `ghcr.io/viogus/homeassistant` |
| tag | `:latest` `:2026.10` `:2026.10.4`（跟着 HA 版本走） |
| 平台 | linux/amd64, linux/arm64, linux/arm/v7 |
| 基础镜像 | `python:3.14-alpine`（HA 2026.10 要求 ≥3.14.2） |
| 入口 | `/usr/local/bin/docker-entrypoint.sh` → `hass --config=/data` |
| 端口 | 8123 |
| 预装集成 | [Xiaomi Home](https://github.com/XiaoMi/ha_xiaomi_home) `v0.5.0`（小米官方，`custom_components` 形式） |
| 用户 | 默认 root（容器内另有 `hass` 用户，uid/gid 1000，可用 `--user` 切） |
| 健康检查 | `GET /manifest.json`，`start-period=180s` |

构建与推送完全在 GitHub Actions 上做，见 [`.github/workflows/build-homeassistant.yml`](../../.github/workflows/build-homeassistant.yml)：

* HA 版本默认取 PyPI 上最新的**正式版**（自动跳过 `b`/`rc`）；Xiaomi Home 版本默认取 GitHub 最新 release，两者都能在 dispatch 时手动指定；
* ghcr 上已有同名 tag，**并且**镜像 label 里的 Xiaomi Home 版本与本次解析的一致，才跳过 —— 只比 HA 版本会漏掉“HA 没动、小米集成发新版”的情况；
* 三架构一次构建约 75 分钟（上游同配置实测 05:03 → 06:16 UTC），arm64 / armv7 走 QEMU；
* 推完镜像会在 amd64 上真跑一遍：等 `/manifest.json` 回 200，再验证集成被播种进挂载的 `/data`、依赖 import 得动、并且真能从 websocket 起一个 `xiaomi_home` config flow，全过才算发布成功（`docker/homeassistant/smoke-test.sh`）。

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

## 预装集成：Xiaomi Home

镜像里已经装好小米官方的 [Xiaomi Home](https://github.com/XiaoMi/ha_xiaomi_home)（当前 `v0.5.0`），**不用 HACS、也不用再联网从 GitHub 装一遍**。HA 起来之后直接去「设置 → 设备与服务 → 添加集成 → 搜 Xiaomi Home」登录小米账号就行。

它是怎么塞进去的：

* 集成代码解压在镜像里的 `/usr/local/share/homeassistant/custom_components/xiaomi_home`；
* entrypoint 每次启动把它**拷**进 `<config>/custom_components/`，已有同名目录则原样不动；
* 为什么不在构建时直接写 `/data`：`/data` 几乎总是 bind mount，镜像里写的东西会被挂载点整个盖住（named volume 也只在首次创建时拷一份）。所以必须在挂载之后补。

换版本：

```bash
docker build --build-arg XIAOMI_HOME_VERSION=v0.6.0 ...        # 本机构建
gh workflow run build-homeassistant.yml -f xiaomi_home_version=v0.6.0   # CI
```

已经在跑的容器换了新镜像后，`custom_components/xiaomi_home` **不会**自动更新（entrypoint 只补缺、不覆盖）。想跟着镜像走就删掉再重启：

```bash
docker exec homeassistant rm -rf /data/custom_components/xiaomi_home
docker restart homeassistant        # entrypoint 会重新播种
```

如果你自己用 HACS 装过、想自己管版本，那就什么都不用做，镜像不会覆盖它。

两个坑镜像里已经处理掉了：

* **`ffmpeg` 不是“只有摄像头才要”的可选包**。集成 manifest 把 `ffmpeg` 列为 dependency，而 HA 的 ffmpeg 集成在 setup 时会跑一次 `ffmpeg -version`，二进制缺席直接抛异常，`xiaomi_home` 就整块加载失败。所以镜像里 `apk add ffmpeg` —— 体积代价见「已知代价」。
* **集成自带的 Python 依赖**在构建期就装好：`construct` / `paho-mqtt` / `numpy` / `psutil` 都从 HA 自己的 `requirements_all.txt` 里取版本（`cryptography` 本来就是 HA core 的依赖，不用重复装），不指望容器启动时联网 pip。

## 和上游 Dockerfile 的差异

只有这几处，其余（基础镜像、`apk add` 包列表、插件清单）原样保留：

| 差异 | 原因 |
|------|------|
| jemalloc 用 Alpine main 仓库的 `jemalloc` 包，不再 `FROM kurapov/alpine-jemalloc:5.3.0` 只为了拷一个 `libjemalloc.so.2` | 少一个第三方镜像依赖；`v3.23`/`v3.24` 的 x86_64 / aarch64 / armhf main 仓库里都有这个包 |
| 基础镜像 `python:3.14-alpine`，不是上游 2026-10-25 起用的 `python:3.15.0-alpine` | `python:3.15.0-alpine` **没有 linux/arm/v7**（buildx 报 `no match for platform`，实测过）；HA 2026.10 要求 ≥3.14.2 且只声明支持 3.14，cp314 的 musllinux wheel 也齐得多 |
| 默认 `VERSION` / OCI labels 换成本仓库的构建值 | CI 会用 `--build-arg VERSION=...` 覆盖 |
| 多装 `ffmpeg` 二进制、`ha-ffmpeg` / `construct` / `paho-mqtt` / `numpy` / `psutil` 等 pip 包，并预置 `custom_components/xiaomi_home` | 小米官方集成的运行前提，见上一节；`ha-ffmpeg` 等版本跟 HA 自己的 `requirements_all.txt` 走，不另立一套 |
| `ENTRYPOINT` 换成 `/usr/local/bin/docker-entrypoint.sh`，由它播种集成后 exec `hass --config=/data` | `custom_components` 必须落在挂载后的配置目录里 |

`LD_PRELOAD=/usr/lib/libjemalloc.so.2` 保留（HA 的小对象分配多，jemalloc 比 musl malloc 稳）。

## 已知代价

* **没有 HA Supervisor / Add-ons**。Add-on 是官方 HA OS 那一套的东西，这个镜像只有 HA Core。要装集成请走 HACS 或直接装到 `custom_components`。
* **musl 上没有预编译 wheel 的包要现场编译**。构建里带了 `build-base cargo cmake libjpeg-turbo-dev` 等编译依赖（同一层装完再 `apk del`，不进最终镜像），所以构建慢；正好撞上这种包时，armv7 的 QEMU 构建会更慢。
* **armv7 只是“能构建出来”**，没有在真机上验过。32 位 ARM 上 HA 的 Python 依赖覆盖本来就不如 64 位，真要用建议 arm64。
* **体积从 ~307 MB 涨到 ~372 MB**，主要是 `ffmpeg`（apk 装完 142 MB，压缩后约 60 MB）和 `numpy`。前者是 `xiaomi_home` 的硬依赖（见上一节），后者是它 manifest 里声明要的。不想要这些只能自己改 Dockerfile 去掉集成。
* **HA 的可选集成依赖仍然不全**：`ssdp` / `bluetooth` / `tts` 这几个默认集成启动时会因为缺 `async_upnp_client` / `pyusb` / `mutagen` 报 ERROR。这不影响 `xiaomi_home`（它走小米云 + 局域网 MQTT，不依赖 HA 的蓝牙/USB），真要用那些集成就往 `custom_components` 补依赖或往 `PLUGINS` 里加。
* 版本号是 HA Core 的版本；镜像 tag 与 PyPI 上的 `homeassistant` 版本一一对应。

## 本地构建（可选）

本机 Docker 拉 Docker Hub 被墙的话，先把基础镜像从镜像站拉下来改 tag：

```bash
docker pull docker.m.daocloud.io/library/python:3.14-alpine
docker tag  docker.m.daocloud.io/library/python:3.14-alpine python:3.14-alpine

docker build \
  --build-arg VERSION=2026.10.4 \
  --build-arg XIAOMI_HOME_VERSION=v0.5.0 \
  -t ghcr.io/viogus/homeassistant:2026.10.4 \
  docker/homeassistant
```

单架构（本机架构）构建，arm64 上大约 20–40 分钟。构建完可以本地验一遍集成：

```bash
bash docker/homeassistant/smoke-test.sh ghcr.io/viogus/homeassistant:2026.10.4 v0.5.0
```

这个脚本就是 CI 里跑的那个：起容器、等 HTTP 起来、确认集成被播种进挂载的 `/data`、依赖 import 得动，最后走 onboarding 拿 token，从 websocket 起一个 `xiaomi_home` config flow。全程不需要小米账号。

国内网络下 `raw.githubusercontent.com` / `codeload.github.com` 的解析经常被污染，本地构建会卡在 `wget` 上（CI 的 runner 不受影响）。两个绕法：

```bash
# 1) 给 tarball 域名钉一个能连的 IP（取自 `dig codeload.github.com`）
# 2) requirements_all.txt 换个来源（GitHub API 的 raw 模式，内容逐字节相同）
docker build --progress=plain \
  --add-host codeload.github.com:20.205.243.165 \
  --build-arg "HA_REQUIREMENTS_URL=https://api.github.com/repos/home-assistant/core/contents/requirements_all.txt?ref=2026.10.4" \
  --build-arg VERSION=2026.10.4 \
  --build-arg XIAOMI_HOME_VERSION=v0.5.0 \
  -t ghcr.io/viogus/homeassistant:2026.10.4 \
  docker/homeassistant
```

## 上游与许可

* Dockerfile 来源：[2sheds/alpine-homeassistant](https://github.com/2sheds/alpine-homeassistant)（MIT），作者 Oleg Kurapov。
* Home Assistant 本体：[home-assistant/core](https://github.com/home-assistant/core)，Apache-2.0。
* 本仓库只做重新构建与发布，`Dockerfile` 头部的注释标了改动点。
