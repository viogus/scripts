#
# snell-server，以 Tiny Core Linux 为底座
#
#   docker build docker/snell -t snell-server:tinycore \
#     --build-arg SNELL_VERSION=5.0.1
#   # 想保留完整 Tiny Core 用户态（不精简）就加 --build-arg TC_SLIM=0
#
# 底座选择（实测，docker save 逐层相加，压缩后的单平台镜像大小 MiB；amd64 / arm64 / armv7）：
#   Tiny Core + musl entrypoint（本文件）  v5 3.853 / 3.642 / 2.985   v6 3.991 / 3.746 / —
#   scratch + musl entrypoint（variants）  v5 3.606 / 3.295 / —       v6 3.746 / 3.399 / —
#   原 scratch + glibc entrypoint（旧版）  v5 3.899 / ≈3.59 / —       v6 4.038 / ≈3.69 / —
#   alpine-glibc / alpine-gcompat          v5 7.069 / 7.197 / —       v6 7.206 / 6.215 / —
# 即：Tiny Core 底座在 amd64 上比旧版略小、arm64 上略大，换来的是完整的 busybox 用户态
# （sh/ls/nc/wget/tar...，旧 scratch 版 `docker exec` 进去什么都没有）；真正省体积的是
# musl 静态 entrypoint（40KB vs glibc -static 680KB）。要绝对最小可用 variants 里的
# scratch + musl 组合（不含任何用户态工具）。
#
# 架构：
#   linux/amd64   CorePure64 16.x（x86_64 通用 rootfs，cpio.gz）
#   linux/arm64   piCore64   16.x（Tiny Core 的 aarch64 只以树莓派整盘镜像分发，
#                  rootfs 在启动分区 FAT32 里，需要先从 .img.gz 里取出来）
#   linux/arm/v7  piCore     16.x（同上，armhf 版，Snell v4/v5 有 armv7l 包）
#   v6 官方无 armv7l 包，构建时直接报错退出。
#
# 为什么不需要再叠一份 glibc：Tiny Core 自带 glibc（系统 libc 就是 glibc）与
# libstdc++。snell v5 的 ELF 自称 static 但运行时 dlopen loader，v6 是普通 glibc
# 动态链接，两者都靠底座里的 glibc 原生运行，不需要 gcompat 之类的垫片。
# entrypoint 用 musl 静态编译（Alpine 的 gcc + musl-dev），任何底座都能跑。

ARG ALPINE_VERSION=3.20
ARG DEBIAN_VERSION=stable-slim

# ---------------------------------------------------------------- entrypoint
# musl 静态（约 40KB）。它是目标架构的二进制，交叉构建时这一步走 QEMU。
FROM alpine:${ALPINE_VERSION} AS entrypoint

ARG SNELL_VERSION=6.0.0rc2

RUN apk add --no-cache gcc musl-dev
COPY entrypoint.c /tmp/entrypoint.c
RUN gcc -static -s -O2 -D"SNELL_VERSION=\"${SNELL_VERSION}\"" -o /entrypoint /tmp/entrypoint.c

# ------------------------------------------------------------- Tiny Core rootfs
# 下载与解包只处理字节，与执行架构无关 ⇒ 固定在构建机上原生执行（交叉构建时不必走 QEMU）。
FROM --platform=$BUILDPLATFORM debian:${DEBIAN_VERSION} AS tinycore

ARG TARGETARCH TARGETVARIANT
# tinycorelinux.net 的目录以主版本命名：16.x / 15.x / ...
ARG TC_MAJOR=16
# piCore 整盘镜像的版本号（与 TC_MAJOR 不同，形如 16.0.0）
ARG PICORE_VERSION=16.0.0
# 1 = 精简掉容器用不到的 Tiny Core 系统工具与依赖库
ARG TC_SLIM=1

RUN <<'SRC'
set -eu

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates cpio gzip mtools

mkdir -p /rootfs

# piCore 只有树莓派整盘镜像，rootfs 在启动分区（FAT32）里，用 MBR 分区表算出偏移，
# 不依赖 fdisk / loop 设备；CorePure64 则是现成的 cpio.gz。
picore() {
  IMG="http://tinycorelinux.net/${TC_MAJOR}.x/${1}/release/RPi/${2}-${PICORE_VERSION}.img.gz"
  echo "[tinycore] ${IMG}"
  curl -fsSL --retry 3 --max-time 900 -o /tmp/pi.img.gz "$IMG"
  gzip -dc /tmp/pi.img.gz > /tmp/pi.img
  rm -f /tmp/pi.img.gz

  # 分区表第 1 项在 446 字节处，start LBA 在 +8、扇区数在 +12（小端 u32）
  SKIP=$(od -An -tu4 -j 454 -N4 /tmp/pi.img | tr -d ' \n')
  CNT=$(od -An -tu4 -j 458 -N4 /tmp/pi.img | tr -d ' \n')
  [ -n "$SKIP" ] && [ -n "$CNT" ] && [ "$CNT" -gt 0 ] || {
    echo "[tinycore] ERROR: 无法解析 piCore 镜像的分区表" >&2; exit 1; }
  echo "[tinycore] 启动分区: LBA ${SKIP} + ${CNT} 扇区"
  if [ $((SKIP % 2048)) -eq 0 ] && [ $((CNT % 2048)) -eq 0 ]; then
    dd if=/tmp/pi.img of=/tmp/boot.fat bs=1048576 \
       skip=$((SKIP / 2048)) count=$((CNT / 2048)) 2>/dev/null
  else
    dd if=/tmp/pi.img of=/tmp/boot.fat bs=512 skip="${SKIP}" count="${CNT}" 2>/dev/null
  fi
  rm -f /tmp/pi.img

  # 启动分区里还有 kernel/modules/firmware，只要 rootfs-*.gz 那一个
  mcopy -o -i /tmp/boot.fat "::/rootfs-*.gz" /tmp/
  rm -f /tmp/boot.fat
  mv /tmp/rootfs-*.gz /tmp/rootfs.gz
}

case "${TARGETARCH:-amd64}" in
  amd64)
    URL="http://tinycorelinux.net/${TC_MAJOR}.x/x86_64/release/distribution_files/corepure64.gz"
    echo "[tinycore] ${URL}"
    curl -fsSL --retry 3 --max-time 600 -o /tmp/rootfs.gz "$URL"
    ;;
  arm64)
    picore aarch64 piCore64
    ;;
  arm)
    [ "${TARGETVARIANT:-v7}" = "v7" ] || {
      echo "[tinycore] ERROR: 只支持 linux/arm/v7，收到 linux/arm/${TARGETVARIANT}" >&2; exit 1; }
    picore armhf piCore
    ;;
  *)
    echo "[tinycore] ERROR: Tiny Core 没有 linux/${TARGETARCH} 的 rootfs" >&2
    echo "[tinycore]        已支持 linux/amd64 / linux/arm64 / linux/arm/v7" >&2
    exit 1
    ;;
esac

cd /rootfs
gzip -dc /tmp/rootfs.gz | cpio -idmu --quiet
rm -f /tmp/rootfs.gz

# 容器里永远用不到内核模块与固件（CorePure64 中它们占 ~15MB）
rm -rf /rootfs/lib/modules /rootfs/lib/firmware /rootfs/usr/local/lib/firmware

# x86-64 glibc 的约定路径、以及 snell v6 的 PT_INTERP / v5 运行时 dlopen 用的都是
# /lib64/ld-linux-x86-64.so.2，而 Tiny Core 把 loader 放在 /lib 下，补软链。
# arm64/armhf 的 loader 路径（/lib/ld-linux-aarch64.so.1、/lib/ld-linux-armhf.so.3）
# 本来就是标准位置，无需处理。
if [ "${TARGETARCH:-amd64}" = "amd64" ]; then
  mkdir -p /rootfs/lib64
  ln -sf ../lib/ld-linux-x86-64.so.2 /rootfs/lib64/ld-linux-x86-64.so.2
fi

echo "[tinycore] rootfs 大小:"
du -sh /rootfs
SRC

# 精简（与下载/解包分层，改 TC_SLIM 时不必重新下载整盘镜像）
RUN <<'SRC'
set -eu

if [ "${TC_SLIM:-1}" = "1" ]; then
  echo "[tinycore] slim: 删除容器用不到的 Tiny Core 系统工具与依赖库"
  cd /rootfs
  # Tiny Core 把上百个命令（awk/sed/grep/tar/wget/vi/find...）做成指向
  # /bin/busybox 的 applet 软链，软链本身不占空间，占空间的是常规文件
  # （e2fsprogs、udev、tce* 脚本、micropython 等）⇒ 只删常规文件和非 busybox 软链。
  for d in usr/bin usr/sbin sbin; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f -delete
    find "$d" -maxdepth 1 -type l ! -lname '*busybox*' -delete
  done
  rm -rf usr/share usr/local
  rm -rf etc/init.d etc/skel etc/pcmcia etc/sysconfig etc/udev etc/profile.d
  # 只被上面那些工具使用的库
  rm -rf usr/lib/gconv usr/lib/sudo_noexec.so usr/lib/sudoers.so
  rm -f usr/lib/libsysfs.so* usr/lib/libz.so* usr/lib/libffi.so*
  rm -f lib/libext2fs.so* lib/libe2p.so* lib/libblkid.so* lib/libuuid.so*
  rm -f lib/libcom_err.so* lib/libnsl.so* lib/libmvec.so*
  # libcrypt.so.1 是 busybox 的 NEEDED；libc/libm/libdl/libpthread/libstdc++/libgcc_s
  # 是 snell 与 loader 的，必须保留
fi

# snell 需要能写/读的临时目录与配置目录
mkdir -p /rootfs/tmp /rootfs/app
chmod 1777 /rootfs/tmp

echo "[tinycore] rootfs 大小:"
du -sh /rootfs
SRC

# --------------------------------------------------------------------- snell
FROM --platform=$BUILDPLATFORM debian:${DEBIAN_VERSION} AS snell

ARG TARGETARCH TARGETVARIANT
# 不带 v 前缀（如 6.0.0rc2 / 5.0.1）
ARG SNELL_VERSION=6.0.0rc2
# 可指向镜像站（默认官方）
ARG SNELL_BASE_URL=https://dl.nssurge.com/snell

RUN <<'SRC'
set -eu

case "${SNELL_VERSION}" in
  6.*)
    case "${TARGETARCH}" in
      arm)
        echo "[snell] ERROR: Snell v6 has no official armv7l build, use v4/v5" >&2
        exit 1
        ;;
    esac
    ;;
esac

case "${TARGETARCH:-amd64}" in
  amd64) SNELL_ARCH=amd64 ;;
  arm64) SNELL_ARCH=aarch64 ;;
  arm)
    [ "${TARGETVARIANT:-v7}" = "v7" ] || {
      echo "[snell] ERROR: 只支持 linux/arm/v7，收到 linux/arm/${TARGETVARIANT}" >&2; exit 1; }
    SNELL_ARCH=armv7l
    ;;
  *) echo "[snell] unsupported arch: ${TARGETARCH}" >&2; exit 1 ;;
esac

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates unzip

URL="${SNELL_BASE_URL}/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
echo "[snell] ${URL}"
curl -fsSL --retry 3 --max-time 300 -o /tmp/snell.zip "$URL"
[ -s /tmp/snell.zip ] || { echo "[snell] download failed" >&2; exit 1; }

unzip -q /tmp/snell.zip -d /tmp/snell
mkdir -p /out/usr/local/bin
cp /tmp/snell/snell-server /out/usr/local/bin/snell-server
chmod +x /out/usr/local/bin/snell-server
rm -rf /tmp/snell /tmp/snell.zip

echo "[snell] v${SNELL_VERSION} linux/${SNELL_ARCH}:"
ls -la /out/usr/local/bin/
SRC

# ------------------------------------------------------------------- runtime
FROM scratch

COPY --from=tinycore /rootfs/ /
COPY --from=snell /out/ /
COPY --from=entrypoint /entrypoint /entrypoint

ENV PORT="" \
    PSK="" \
    MODE="default" \
    DNS_IP_PREFERENCE="default" \
    IPV6="off" \
    OBFS="off" \
    OBFS_HOST="" \
    CONF="/app/snell-server.conf"

ENTRYPOINT ["/entrypoint"]
