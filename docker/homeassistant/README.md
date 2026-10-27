# Home Assistant on Alpine (musl) — 自建 ghcr 镜像

把 [`kurapov/alpine-homeassistant`](https://hub.docker.com/r/kurapov/alpine-homeassistant)（源码：[2sheds/alpine-homeassistant](https://github.com/2sheds/alpine-homeassistant)）的 Dockerfile 拿来自己构建，推到 `ghcr.io` 上，摆脱 Docker Hub 的限流和“上游哪天不构建了”的风险。

顺便说清楚这镜像是什么：**不是**官方 HA 镜像（官方是 Debian + Python venv，~1.3 GB），而是把一个只剩 HA 的 musl 运行时装进 Alpine，压缩体积 ~421 MB（官方镜像 2.3 GB）。代价见下面「已知代价」。

## 镜像

| 项 | 值 |
|----|----|
| 镜像 | `ghcr.io/viogus/homeassistant` |
| tag | `:latest` `:2026.10` `:2026.10.4`（跟着 HA 版本走） |
| 平台 | linux/amd64, linux/arm64（armv7 已丢弃：QEMU 下构建慢且没人验过） |
| 基础镜像 | `python:3.14-alpine`（HA 2026.10 要求 ≥3.14.2） |
| 入口 | `/usr/local/bin/docker-entrypoint.sh` → `hass --config=<配置目录>` |
| 配置目录 | 默认 `/config`（HA 惯例，与官方镜像一致）；`/data` 自动软链到它，老用法照旧 |
| 端口 | 8123 |
| 预装集成 | [Xiaomi Home](https://github.com/XiaoMi/ha_xiaomi_home) `v0.5.0`（小米官方，`custom_components` 形式） |
| 用户 | 默认 root（容器内另有 `hass` 用户，uid/gid 1000，可用 `--user` 切） |
| 健康检查 | `GET /manifest.json`，`start-period=180s` |

构建与推送完全在 GitHub Actions 上做，见 [`.github/workflows/build-homeassistant.yml`](../../.github/workflows/build-homeassistant.yml)：

* HA 版本默认取 PyPI 上最新的**正式版**（自动跳过 `b`/`rc`）；Xiaomi Home 版本默认取 GitHub 最新 release，两者都能在 dispatch 时手动指定；
* ghcr 上已有同名 tag，**并且**镜像 label 里的 Xiaomi Home 版本与本次解析的一致，才跳过 —— 只比 HA 版本会漏掉“HA 没动、小米集成发新版”的情况；
* 双架构一次构建约 50–70 分钟，arm64 走 QEMU；
* 推完镜像会在 amd64 上真跑一遍（`docker/homeassistant/smoke-test.sh`）：配置目录是 `/config` 且 `/data` 指向它、集成被播种、`default_config` 不因缺包 setup 失败、`xiaomi_home` 在 flow_handlers 里且能起 flow、前端首屏的 websocket 命令正常，全过才算发布成功。

## 用

```bash
docker run -d --name homeassistant \
  --restart=unless-stopped \
  --network=host \
  -e TZ=Asia/Shanghai \
  -v /var/opt/docker/homeassistant:/config \
  -v /etc/localtime:/etc/localtime:ro \
  ghcr.io/viogus/homeassistant:2026.10.4
```

打开 `http://<host>:8123` 就是 onboarding 页面。

`docker compose up -d`（本目录的 compose 默认就是 host 网络 + `./config`）：

```yaml
services:
  homeassistant:
    image: ghcr.io/viogus/homeassistant:2026.10.4
    container_name: homeassistant
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
    environment:
      TZ: Asia/Shanghai
```

挂 `/config`（HA 惯例，和官方镜像一致）或挂 `/data`（上游 kurapov 的用法）都行：entrypoint 启动时看哪个目录有配置就用哪个，并把另一个软链过去。从官方镜像切过来时不会出现“配置突然变空、实体全没了”，因为两边都落在同一份数据上。

* **host 网络**是推荐做法：mDNS / SSDP / 局域网广播这类设备自动发现，桥接网络下基本残废。要隔离就用 `ports: ["8123:8123"]`，发现能力会打折。
* 升级：改 tag 再 `docker compose up -d`。配置、数据库、备份都在卷上，不会丢。
* 以非 root 跑：`chown -R 1000:1000 ./config` 后加 `user: "1000:1000"`。注意 nmap 的 SYN 扫描和部分设备追踪需要 root，切了会退化。

## 预装集成：Xiaomi Home

镜像里已经装好小米官方的 [Xiaomi Home](https://github.com/XiaoMi/ha_xiaomi_home)（当前 `v0.5.0`），**不用 HACS、也不用再联网从 GitHub 装一遍**。HA 起来之后直接去「设置 → 设备与服务 → 添加集成 → 搜 Xiaomi Home」登录小米账号就行。

它是怎么塞进去的：

* 集成代码解压在镜像里的 `/usr/local/share/homeassistant/custom_components/xiaomi_home`；
* entrypoint 每次启动把它**拷**进 `<config>/custom_components/`，已有同名目录则原样不动；
* 为什么不在构建时直接写配置目录：它几乎总是 bind mount，镜像里写的东西会被挂载点整个盖住（named volume 也只在首次创建时拷一份）。所以必须在挂载之后补。

换版本：

```bash
docker build --build-arg XIAOMI_HOME_VERSION=v0.6.0 ...        # 本机构建
gh workflow run build-homeassistant.yml -f xiaomi_home_version=v0.6.0   # CI
```

已经在跑的容器换了新镜像后，`custom_components/xiaomi_home` **不会**自动更新（entrypoint 只补缺、不覆盖）。想跟着镜像走就删掉再重启：

```bash
docker exec homeassistant rm -rf /config/custom_components/xiaomi_home
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
| `ENTRYPOINT` 换成 `/usr/local/bin/docker-entrypoint.sh`：选配置目录（`/config` 优先，`/data` 兼容）、把另一个路径软链过去、播种集成，然后 exec `hass --config=<那个目录>` | `custom_components` 必须落在挂载后的配置目录里；`/config` 与 `/data` 指向同一份数据才不会出现“换镜像后配置变空” |

`LD_PRELOAD=/usr/lib/libjemalloc.so.2` 保留（HA 的小对象分配多，jemalloc 比 musl malloc 稳）。

## 已知代价

* **没有 HA Supervisor / Add-ons**。Add-on 是官方 HA OS 那一套的东西，这个镜像只有 HA Core。要装集成请走 HACS 或直接装到 `custom_components`。
* **musl 上没有预编译 wheel 的包要现场编译**。构建里带了 `build-base cargo cmake libjpeg-turbo-dev` 等编译依赖（同一层装完再 `apk del`，不进最终镜像），所以构建慢；正好撞上这种包时，armv7 的 QEMU 构建会更慢。
* **armv7 只是“能构建出来”**，没有在真机上验过。32 位 ARM 上 HA 的 Python 依赖覆盖本来就不如 64 位，真要用建议 arm64。
* **体积 ~421 MB**：`ffmpeg`（apk 装完 142 MB，压缩后约 60 MB，小米集成的硬依赖）+ 让 `default_config` 跑通的那批 Python 包装进去约 40 MB。相比官方 2.3 GB 还是小一个量级，但已经不是“只剩 HA 本体”的 ~310 MB 了。
* **`default_config` 现在只有 `go2rtc` 一项会报错**（`Could not find go2rtc docker binary`）。`go2rtc` 是 HA 2026.10 才进 `default_config` 的，官方 core 镜像的 Dockerfile 里同样没有这个二进制，属于与官方一致的已知项；要摄像头转流就自己下载一个静态 `go2rtc` 放到 `PATH` 里，或忽略它。除它之外的 `conversation` / `tts` / `ssdp` / `usb` / `dhcp` / `analytics` / `mobile_app` / `infrared` / `radio_frequency` 依赖都已装齐。
* **`pymicro-vad` / `pyspeex-noise` 没有 musllinux wheel**，在构建期的编译层现场编译（`build-dependencies` 在同一层装完再删），所以主层构建时间比纯 wheel 方案长几分钟。
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

这个脚本就是 CI 里跑的那个：起容器、等 HTTP 起来、确认 `/config` 与 `/data` 是同一份数据、集成被播种、`default_config` 没有 setup 失败、`xiaomi_home` 在 flow_handlers 里且能起 flow、前端首屏的 websocket 命令正常。全程不需要小米账号。

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
