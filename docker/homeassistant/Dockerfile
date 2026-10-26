# 不用 `# syntax=docker/dockerfile:1`：本 Dockerfile 没有用到 dockerfile:1 的新
# 语法，却会让每次构建都去 Docker Hub 拉 docker/dockerfile 前端镜像 —— 被墙的
# 本机构建会直接卡在这一步。
#
# Home Assistant on Alpine / musl.
#
# Rebuilt from kurapov/alpine-homeassistant
#   source : https://github.com/2sheds/alpine-homeassistant
#   image  : https://hub.docker.com/r/kurapov/alpine-homeassistant
# and published to ghcr.io instead of Docker Hub.
#
# 与上游 Dockerfile 的差异：
#   1. jemalloc 直接用 Alpine main 仓库里的 `jemalloc` 包，不再 FROM 一个第三方
#      镜像（kurapov/alpine-jemalloc）只为了拷一个 .so —— 少一个上游依赖，且
#      x86_64 / aarch64 / armhf 三个架构的 main 仓库里都有这个包；
#   2. 基础镜像用 python:3.14-alpine 而不是上游现在的 3.15.0-alpine：
#      python 3.15 的镜像已经没有 linux/arm/v7 了（buildx 直接
#      "no match for platform"），而 HA 2026.10 要求 >=3.14.2 且支持 3.14，
#      3.14 的 cp314 musllinux wheel 覆盖也比刚出的 3.15 更全；
#   3. 默认 VERSION / OCI labels 换成本仓库的构建值（CI 会覆盖 VERSION）；
#   4. 预装小米官方的 Xiaomi Home 集成（https://github.com/XiaoMi/ha_xiaomi_home），
#      连同它声明的依赖一起装进镜像，见下面 “Xiaomi Home 集成” 那一段。
# 其余包列表、插件清单保持上游原样。
#
# 上游能把 HA 装进 musl 的关键是两条：homeassistant 本体走 PyPI 的 musllinux
# wheel，requirements_all.txt 里那批插件走 wheels.home-assistant.io 的 musllinux
# index；实在没有 wheel 的包由 build-base / cargo / cmake 现场编译（编译依赖在
# 同一层里装完再 apk del，不进最终镜像）。

FROM python:3.14-alpine

LABEL Description="Home Assistant"

ARG BRANCH="none"
ARG COMMIT="local-build"
ARG BUILD_DATE="1970-01-01T00:00:00Z"
ARG NAME="viogus/homeassistant"
ARG VCS_URL="https://github.com/viogus/scripts"

ARG UID=1000
ARG GUID=1000
ARG MAKEFLAGS=-j4
ARG VERSION="2026.10.4"
ARG DEPS="openssl-dev cargo zlib-dev libjpeg-turbo-dev cmake"
# PLUGINS：从 HA 的 requirements_all.txt 里挑出来预装的包。末尾几个是 Xiaomi Home
# 集成声明要的（construct / paho-mqtt / numpy / psutil），py 版本直接跟 HA 为同一
# 批库钉的值走；cryptography 属于 HA core 自带依赖，不需要在这里列。
ARG PLUGINS="home-assistant-frontend|PyNaCl|defusedxml|distro|zeroconf|hass-nabucasa|aiohttp_cors|scapy|aiodiscover|psutil-home-assistant|securetar|ha-ffmpeg|construct|paho-mqtt|numpy|psutil"

# requirements_all.txt 的来源。默认走上游 raw（CI 上没问题）；国内本机构建时
# raw.githubusercontent.com 常常解析被污染，可以换成任何能拿到同一份文件的地址，
# 例如 GitHub API 的 raw 模式：
#   --build-arg "HA_REQUIREMENTS_URL=https://api.github.com/repos/home-assistant/core/contents/requirements_all.txt?ref=2026.10.4"
ARG HA_REQUIREMENTS_URL=""

# Xiaomi Home 集成（小米官方，custom_components 形式分发，不在 PyPI 上）。
ARG XIAOMI_HOME_REPO="XiaoMi/ha_xiaomi_home"
ARG XIAOMI_HOME_VERSION="v0.5.0"

ENV WHEELS_INDEX="https://wheels.home-assistant.io/musllinux-index/"

LABEL \
  org.opencontainers.image.authors="viogus (rebuild of Oleg Kurapov's kurapov/alpine-homeassistant)" \
  org.opencontainers.image.title="${NAME}" \
  org.opencontainers.image.created="${BUILD_DATE}" \
  org.opencontainers.image.revision="${COMMIT}" \
  org.opencontainers.image.version="${VERSION}" \
  org.opencontainers.image.source="${VCS_URL}" \
  org.opencontainers.image.base.name="docker.io/library/python:3.14-alpine" \
  org.opencontainers.image.xiaomi_home.version="${XIAOMI_HOME_VERSION}"

RUN apk add --no-cache git nmap iputils tzdata libturbojpeg jemalloc && \
    apk add --no-cache --virtual=build-dependencies build-base libffi-dev ${DEPS} && \
    addgroup -g ${GUID} hass && \
    adduser -h /data -D -G hass -s /bin/sh -u ${UID} hass && \
    REQ_URL="${HA_REQUIREMENTS_URL:-https://raw.githubusercontent.com/home-assistant/home-assistant/${VERSION}/requirements_all.txt}" && \
    wget -q --header="Accept: application/vnd.github.raw" -O /usr/src/requirements_all.txt "$REQ_URL" && \
    grep -w -E "${PLUGINS}" /usr/src/requirements_all.txt | grep -v '#' > /tmp/requirements_plugins.txt || \
      { echo "ERROR: no plugin pins matched in requirements_all.txt (source: $REQ_URL)" >&2; head -5 /usr/src/requirements_all.txt >&2; exit 1; } && \
    pip3 install --no-cache-dir homeassistant=="${VERSION}" && \
    pip3 install --no-cache-dir --prefer-binary --extra-index-url ${WHEELS_INDEX} -r /tmp/requirements_plugins.txt && \
    apk del build-dependencies && \
    rm -rf /tmp/* /var/tmp/* /var/cache/apk/*

# musl 的 malloc 对 HA 这种大量小对象的负载不太友好，上游同样挂 jemalloc。
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

# ---------------------------------------------------------------------------
# Xiaomi Home 集成（小米官方，以 custom_components 形式分发，不在 PyPI 上）
# ---------------------------------------------------------------------------
# 单独占一层：改集成版本时只重建这层，HA 本体那一大层的缓存不受影响。
#
#   * `ffmpeg` 二进制不是“只有摄像头才要”的可选包：集成 manifest 把 `ffmpeg`
#     列为 dependency，而 HA 的 ffmpeg 集成在 setup 时会跑一次 `ffmpeg -version`
#     （haffmpeg 的 FFmpegManager.async_get_version）。二进制不在就抛异常，于是
#     xiaomi_home 因为依赖没起来而整块加载失败。`ha-ffmpeg` 这个 pip 包已加进
#     上面的 PLUGINS，跟着 HA 版本走。
#   * 集成自己的 requirements（construct / paho-mqtt / numpy / psutil）也走 PLUGINS，
#     取的正是 HA 官方为同一批库钉的版本，不另立一套；cryptography 是 HA core
#     自带依赖。py 3.14 的 musllinux wheel 由 ${WHEELS_INDEX} 兜底。
#   * 解压到 /usr/local/share/homeassistant/custom_components，再由 entrypoint
#     播种到 /data/custom_components：配置目录通常是 bind mount，镜像里直接往
#     /data 写东西会被挂载点盖住。
RUN apk add --no-cache ffmpeg && \
    mkdir -p /usr/local/share/homeassistant/custom_components && \
    wget -q -O /tmp/xiaomi_home.tar.gz \
      "https://github.com/${XIAOMI_HOME_REPO}/archive/refs/tags/${XIAOMI_HOME_VERSION}.tar.gz" && \
    tar xzf /tmp/xiaomi_home.tar.gz -C /tmp && \
    cp -a /tmp/ha_xiaomi_home-*/custom_components/xiaomi_home \
      /usr/local/share/homeassistant/custom_components/ && \
    python3 -c "import construct, paho.mqtt.client, haffmpeg, numpy, cryptography, psutil; print('xiaomi_home deps ok')" && \
    test -f /usr/local/share/homeassistant/custom_components/xiaomi_home/manifest.json && \
    rm -rf /tmp/* /var/tmp/* /var/cache/apk/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh

EXPOSE 8123

# 首次启动要写配置、跑 onboarding，给 3 分钟预热再算失败。
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8123/manifest.json || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
