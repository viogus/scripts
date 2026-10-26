# syntax=docker/dockerfile:1
#
# Home Assistant on Alpine / musl.
#
# Rebuilt from kurapov/alpine-homeassistant
#   source : https://github.com/2sheds/alpine-homeassistant
#   image  : https://hub.docker.com/r/kurapov/alpine-homeassistant
# and published to ghcr.io instead of Docker Hub.
#
# 与上游 Dockerfile 的差异只有三处：
#   1. jemalloc 直接用 Alpine main 仓库里的 `jemalloc` 包，不再 FROM 一个第三方
#      镜像（kurapov/alpine-jemalloc）只为了拷一个 .so —— 少一个上游依赖，且
#      x86_64 / aarch64 / armhf 三个架构的 main 仓库里都有这个包；
#   2. 基础镜像用 python:3.14-alpine 而不是上游现在的 3.15.0-alpine：
#      python 3.15 的镜像已经没有 linux/arm/v7 了（buildx 直接
#      "no match for platform"），而 HA 2026.10 要求 >=3.14.2 且支持 3.14，
#      3.14 的 cp314 musllinux wheel 覆盖也比刚出的 3.15 更全；
#   3. 默认 VERSION / OCI labels 换成本仓库的构建值（CI 会覆盖 VERSION）。
# 基础镜像、包列表、插件清单、entrypoint 全部保持上游原样。
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
ARG PLUGINS="home-assistant-frontend|PyNaCl|defusedxml|distro|zeroconf|hass-nabucasa|aiohttp_cors|scapy|aiodiscover|psutil-home-assistant|securetar"

ENV WHEELS_INDEX="https://wheels.home-assistant.io/musllinux-index/"

LABEL \
  org.opencontainers.image.authors="viogus (rebuild of Oleg Kurapov's kurapov/alpine-homeassistant)" \
  org.opencontainers.image.title="${NAME}" \
  org.opencontainers.image.created="${BUILD_DATE}" \
  org.opencontainers.image.revision="${COMMIT}" \
  org.opencontainers.image.version="${VERSION}" \
  org.opencontainers.image.source="${VCS_URL}" \
  org.opencontainers.image.base.name="docker.io/library/python:3.14-alpine"

RUN apk add --no-cache git nmap iputils tzdata libturbojpeg jemalloc && \
    apk add --no-cache --virtual=build-dependencies build-base libffi-dev ${DEPS} && \
    addgroup -g ${GUID} hass && \
    adduser -h /data -D -G hass -s /bin/sh -u ${UID} hass && \
    wget -q "https://raw.githubusercontent.com/home-assistant/home-assistant/${VERSION}/requirements_all.txt" -P /usr/src/ && \
    grep -w -E "${PLUGINS}" /usr/src/requirements_all.txt | grep -v '#' > /tmp/requirements_plugins.txt && \
    pip3 install --no-cache-dir homeassistant=="${VERSION}" && \
    pip3 install --no-cache-dir --prefer-binary --extra-index-url ${WHEELS_INDEX} -r /tmp/requirements_plugins.txt && \
    apk del build-dependencies && \
    rm -rf /tmp/* /var/tmp/* /var/cache/apk/*

# musl 的 malloc 对 HA 这种大量小对象的负载不太友好，上游同样挂 jemalloc。
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

EXPOSE 8123

# 首次启动要写配置、跑 onboarding，给 3 分钟预热再算失败。
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8123/manifest.json || exit 1

ENTRYPOINT ["hass", "--config=/data"]
