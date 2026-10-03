#
# PostgreSQL 18 + TimescaleDB 2.30（Apache 核心 + Timescale License：压缩、保留
# 策略、连续聚合），以 Tiny Core Linux 为底座，产物是 FROM scratch 的极简镜像。
#
#   docker build -f docker/timescaledb/Dockerfile docker/timescaledb -t timescaledb:tinycore
#
# 为什么需要自建：
#   * Timescale 官方镜像是 glibc/Debian，解压约 1GB，还带 Rust toolkit；
#   * Alpine 社区包的 postgresql-timescaledb 是 -DAPACHE_ONLY=ON，缺压缩与保留
#     策略——正是 NodeGet 用来限制监控数据盘增长的功能；
#   * 所以这里自己编上游默认构建（含 tsl/），PostgreSQL 18.6 与 TimescaleDB
#     2.30.0 均从源码编译（同一套选项，见下），再把结果放进极简底座。
#   License 备注：包含 Timescale Community License 部分（自托管免费），Apache-2.0
#   源码在 apache/、TSL 在 tsl/。
#
# 架构支持（TARGETARCH）：
#   linux/amd64  CorePure64 16.x（x86_64 通用 rootfs，cpio.gz）      ← 必需，CI 构建
#   linux/arm64  piCore64   16.x（aarch64 只以树莓派整盘镜像分发，rootfs 在
#                启动分区 FAT32 里的 rootfs-piCore64-<ver>.gz）      ← 必需，CI 构建
#   其它架构构建时报错退出。Tiny Core 16.x 只有 x86_64 / aarch64 / armhf / x86 四种
#   rootfs，后两种是 32 位，装不下这条技术栈：PostgreSQL 18 与 TimescaleDB 2.30 都是
#   64 位目标（Timescale 只发 x86_64 与 aarch64 的包；Debian 已把 x86-32 移出发布架构，
#   PostgreSQL 社区也在讨论放弃 32 位）。
#   需要 32 位或 riscv64/ppc64le/s390x 等架构时走 musl 路线：
#     ./build.sh alpine-lean <arch>   （Dockerfile.alpine-lean；能否成功取决于上游
#                                      PostgreSQL / TimescaleDB 是否支持该架构）
#
# 与官方 postgres:18-alpine / 旧版 alpine 镜像的关键差异（体积来源）：
#   * 底座：Tiny Core 自带 glibc 2.40 与 libstdc++，不需要额外的 glibc 层
#   * 构建选项：不编 LLVM JIT（其运行时 libLLVM 压缩后约 59MB）、不编 ICU
#     （icu-data 压缩后约 12MB）、不编 bitcode（约 12MB）、不编 PL/Perl-Python-Tcl
#     ——这几项就是旧镜像 117.5MiB 里的 93MiB
#   * 保留常用能力：openssl / zlib / lz4 / zstd / readline / 全部 contrib
#
# 已知取舍：无 LLVM JIT、无 ICU 排序规则、无 uuid-ossp（未链 libuuid）、无
# ldap/gssapi/libcurl 等企业特性；TimescaleDB 2.30.0（含 TSL 闭源扩展）完整。
# 升级兼容：镜像带 glibc 的 C.utf8 与 en_US.UTF-8 locale 数据（ARG LOCALES 可加更多），
#   因此旧 Alpine/musl 镜像 initdb 出来的数据目录（conf 里 lc_*= 'en_US.utf8'、
#   pg_database.datcollate='en_US.utf8'）能直接启动，不需要动数据（详见 README）。
# 运行时参数：shared_preload_libraries=timescaledb，例如
#   command: ["postgres", "-c", "shared_preload_libraries=timescaledb"]
#
# 体积对比与实测数据见 docker/timescaledb/README.md。

ARG DEBIAN_RELEASE=bookworm

# ------------------------------------------------------------- Tiny Core rootfs
FROM debian:${DEBIAN_RELEASE}-slim AS tinycore

ARG TARGETARCH
# tinycorelinux.net 目录以主版本命名：16.x / 15.x / ...
ARG TC_MAJOR=16
# piCore64 整盘镜像版本号（与 TC_MAJOR 不同，形如 16.0.0）
ARG PICORE_VERSION=16.0.0
# 1 = 在完整 rootfs 基础上精简掉容器不需要的部分
ARG TC_SLIM=1

RUN <<'SRC'
set -eu

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates cpio gzip mtools

mkdir -p /rootfs

case "${TARGETARCH:-amd64}" in
  amd64)
    URL="http://tinycorelinux.net/${TC_MAJOR}.x/x86_64/release/distribution_files/corepure64.gz"
    echo "[tinycore] ${URL}"
    curl -fsSL --retry 3 --max-time 600 -o /tmp/rootfs.gz "$URL"
    ;;
  arm64)
    IMG="http://tinycorelinux.net/${TC_MAJOR}.x/aarch64/release/RPi/piCore64-${PICORE_VERSION}.img.gz"
    echo "[tinycore] ${IMG}"
    curl -fsSL --retry 3 --max-time 900 -o /tmp/pi.img.gz "$IMG"
    gzip -dc /tmp/pi.img.gz > /tmp/pi.img
    rm -f /tmp/pi.img.gz

    # 用 MBR 分区表算启动分区（FAT32）偏移，不依赖 fdisk / loop 设备：
    # 第 1 个分区表项在 446 字节处，start LBA 在 +8、扇区数在 +12（小端 u32）。
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

    # 启动分区里除 rootfs-piCore64-<ver>.gz 外还有 kernel/modules/firmware，不要
    mcopy -o -i /tmp/boot.fat "::/rootfs-*.gz" /tmp/
    rm -f /tmp/boot.fat
    mv /tmp/rootfs-*.gz /tmp/rootfs.gz
    ;;
  *)
    echo "[tinycore] ERROR: Tiny Core 底座只支持 linux/amd64 与 linux/arm64，当前 TARGETARCH=${TARGETARCH}" >&2
    echo "[tinycore]        Tiny Core 16.x 的 rootfs 只有 x86_64 / aarch64 / armhf / x86，" >&2
    echo "[tinycore]        后两种是 32 位，PostgreSQL 18 + TimescaleDB 2.30 不支持 32 位。" >&2
    echo "[tinycore]        其它架构请走 musl 路线: ./build.sh alpine-lean ${TARGETARCH}" >&2
    exit 1
    ;;
esac

cd /rootfs
gzip -dc /tmp/rootfs.gz | cpio -idmu --quiet
rm -f /tmp/rootfs.gz

# 容器里永远用不到内核模块与固件（CorePure64 中它们占 ~15MB）
rm -rf /rootfs/lib/modules /rootfs/lib/firmware /rootfs/usr/local/lib/firmware

# amd64：Tiny Core 把 loader 放在 /lib/ld-linux-x86-64.so.2，而 x86-64 glibc 的
# 约定路径是 /lib64/ld-linux-x86-64.so.2（Debian 编出来的二进制 PT_INTERP 就是
# 它），必须补上这个软链。arm64 的 /lib/ld-linux-aarch64.so.1 本来就是标准路径。
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
  # Tiny Core 把大部分命令做成指向 /bin/busybox 的 applet 软链（usr/bin、
  # usr/sbin、sbin 合计 200+ 个：awk/sed/grep/find/tar/wget/vi...），软链本身
  # 不占空间，只有常规文件（e2fsprogs、udev、tce* 脚本等）才是体积来源
  # ⇒ 只删常规文件和非 busybox 软链。
  for d in usr/bin usr/sbin sbin; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f -delete
    find "$d" -maxdepth 1 -type l ! -lname '*busybox*' -delete
  done
  rm -rf usr/share usr/local
  rm -rf etc/init.d etc/skel etc/pcmcia etc/sysconfig etc/udev etc/profile.d
  # 只被上面那些工具使用的库
  rm -rf usr/lib/gconv usr/lib/sudo_noexec.so usr/lib/sudoers.so
  rm -f usr/lib/libsysfs.so* usr/lib/libffi.so*
  rm -f lib/libext2fs.so* lib/libe2p.so* lib/libblkid.so* lib/libuuid.so*
  rm -f lib/libcom_err.so* lib/libnsl.so*
  # 注意：必须保留 libcrypt.so.1（busybox 的 NEEDED）、libz.so.1（postgres
  # --with-zlib）、libmvec.so.1（glibc >= 2.35 的 libm 依赖它）、libstdc++ /
  # libgcc_s。Tiny Core 没有 /usr/share/zoneinfo，postgres 自带 tzdata。
fi

echo "[tinycore] rootfs 大小:"
du -sh /rootfs
ls /rootfs
SRC

# --------------------------------------------------------- PostgreSQL 18 编译
FROM debian:${DEBIAN_RELEASE} AS pgbuild

ARG PG_VERSION=18.6
# 并行度：默认跟 CPU 数；在 qemu 模拟的异构构建（比如 arm64 主机构 amd64）里
# 高并行会让 qemu 下的 cc1 偶发段错误，可以 --build-arg MAKE_JOBS=2 降低。
ARG MAKE_JOBS=

RUN <<'SRC'
set -eu

apt-get update
apt-get install -y --no-install-recommends \
    build-essential bison flex pkg-config \
    libreadline-dev zlib1g-dev libssl-dev liblz4-dev libzstd-dev \
    curl ca-certificates xz-utils
rm -rf /var/lib/apt/lists/*

echo "[postgres] 下载 v${PG_VERSION}"
curl -fsSL --retry 3 --max-time 900 \
  -o /tmp/pg.tar.bz2 \
  "https://ftp.postgresql.org/pub/source/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.bz2"

mkdir -p /usr/src/pg
tar xjf /tmp/pg.tar.bz2 -C /usr/src/pg --strip-components=1
rm -f /tmp/pg.tar.bz2
cd /usr/src/pg

# 与官方镜像的差别就是这里：去掉 LLVM（JIT）与 ICU。
# 不传 --disable-rpath：glibc 不像 musl 那样默认搜 /usr/local/lib，而 Tiny Core
# 没有 ldconfig 缓存（musl 的默认搜索路径就含 /usr/local/lib，所以 Alpine 版
# 不需要这一步），保留 rpath 让 /usr/local/bin 下的客户端工具能找到 libpq。
# PL/Perl、PL/Python、PL/Tcl 也显式关掉：用户镜像虽然构建时开了这三个，但运行期
# 没有 libperl.so / libpython3.so / libtcl.so，plperl/plpython3/pltcl 加载必然失败。
./configure \
  --prefix=/usr/local \
  --with-openssl --with-zlib --with-lz4 --with-zstd --with-readline \
  --without-llvm --without-icu \
  --without-perl --without-python --without-tcl \
  --enable-thread-safety

make -j"${MAKE_JOBS:-$(nproc)}" world-bin
# 一次装进镜像（TimescaleDB 编译要用其中的 pg_config 与 server 头文件）
make install-world-bin
# 再装一份到 /out 供最终镜像使用
make install-world-bin DESTDIR=/out
SRC

# ------------------------------------------------------------ TimescaleDB 编译
FROM pgbuild AS tsbuild

ARG TS_VERSION=2.30.0

RUN <<'SRC'
set -eu

apt-get update
apt-get install -y --no-install-recommends cmake ninja-build
rm -rf /var/lib/apt/lists/*

echo "[timescaledb] 下载 ${TS_VERSION}"
curl -fsSL --retry 3 --max-time 600 \
  -o /tmp/ts.tar.gz \
  "https://codeload.github.com/timescale/timescaledb/tar.gz/refs/tags/${TS_VERSION}"

mkdir -p /usr/src/ts
tar xzf /tmp/ts.tar.gz -C /usr/src/ts --strip-components=1
rm -f /tmp/ts.tar.gz
cd /usr/src/ts

cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPG_CONFIG=/usr/local/bin/pg_config \
  -DREGRESS_CHECKS=OFF -DTAP_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF \
  -DSEND_TELEMETRY_DEFAULT=OFF \
  -DAPACHE_ONLY=OFF

cmake --build build
DESTDIR=/out cmake --install build

echo "[timescaledb] 产物:"
find /out/usr/local/lib/postgresql -name 'timescaledb*'
SRC

# ------------------------------------------------------------------ 运行环境组装
FROM debian:${DEBIAN_RELEASE}-slim AS assemble

ARG TARGETARCH
ARG GOSU_VERSION=1.19
ARG PG_SLIM=1
# 额外编译进镜像的 glibc locale（空格分隔，名字用 <语言>.<编码> 形式）。
# en_US.UTF-8 是必须的：旧 Alpine/musl 镜像 initdb 出来的数据目录里
# lc_messages/lc_monetary/lc_numeric/lc_time 都是 'en_US.utf8'，glibc 底座少了这份
# 数据就起不来。要别的 locale：--build-arg LOCALES="en_US.UTF-8 de_DE.UTF-8"。
ARG LOCALES="en_US.UTF-8"

# postgres 运行时需要的系统库（glibc 本体由 Tiny Core 提供，绝不能混 Debian 的：
# loader 与 libc.so.6 必须同源）；bash 是 docker-entrypoint.sh 的解释器；
# binutils 只为下面 readelf 求依赖闭包用；locales 提供 localedef 的源数据
# （只管编译期，不进最终镜像——最终只拷编译好的 /usr/lib/locale/<name>/）。
RUN <<'SRC'
set -eu
apt-get update
apt-get install -y --no-install-recommends \
    libssl3 zlib1g libzstd1 liblz4-1 libreadline8 libtinfo6 bash \
    libnss-wrapper locales \
    binutils curl ca-certificates
rm -rf /var/lib/apt/lists/*
SRC

COPY --from=tinycore /rootfs/ /rootfs/
COPY --from=pgbuild /out/ /rootfs/
COPY --from=tsbuild /out/ /rootfs/
COPY docker-entrypoint.sh docker-ensure-initdb.sh /rootfs/usr/local/bin/

RUN <<'SRC'
set -eu

# gosu：官方 entrypoint 在 root 下用它降权到 postgres
case "${TARGETARCH:-amd64}" in
  amd64) G=amd64 ;;
  arm64) G=arm64 ;;
  *) echo "[gosu] unsupported arch: ${TARGETARCH}" >&2; exit 1 ;;
esac
curl -fsSL --retry 3 --max-time 300 \
  -o /rootfs/usr/local/bin/gosu \
  "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${G}"
chmod 0755 /rootfs/usr/local/bin/gosu /rootfs/usr/local/bin/docker-entrypoint.sh \
             /rootfs/usr/local/bin/docker-ensure-initdb.sh

# docker-entrypoint.sh 的 shebang 是 "#!/usr/bin/env bash"，而 Tiny Core 只有
# busybox ash ⇒ 必须把 Debian 的 bash 带进镜像（libtinfo/libc 由下面的闭包补齐）
cp /bin/bash /rootfs/bin/bash
chmod 0755 /rootfs/bin/bash

# 与官方 postgres 镜像对齐：以「非 root 且 uid 不在 /etc/passwd」运行（OpenShift
# 那类随机 uid）时，entrypoint 会 LD_PRELOAD 一个 nss_wrapper 假造该用户，否则
# initdb 会以 "user does not exist" 失败。Debian 的 libnss-wrapper 体积很小，
# 放到 /usr/lib/libnss_wrapper.so（entrypoint 的搜索路径之一）。
mkdir -p /rootfs/usr/lib
cp -L /usr/lib/*/libnss_wrapper.so /rootfs/usr/lib/libnss_wrapper.so
chmod 0644 /rootfs/usr/lib/libnss_wrapper.so

# Tiny Core 的 busybox 没有 mountpoint applet，而 docker-entrypoint.sh 会调用它
# 判断 /var/lib/postgresql/data 是不是挂载点（失败时它自己还有 awk 兜底，但会在
# 日志里留一行 command not found）。这里补一个语义一致的 3 行垫片，只在 -q 模式
# 下用，等价于 entrypoint 里那句 awk。
cat > /rootfs/usr/local/bin/mountpoint <<'EOF'
#!/bin/sh
# 兼容 docker-entrypoint.sh 的 mountpoint -q <dir>：查 /proc/self/mountinfo
[ "${1:-}" = "-q" ] && shift
[ $# -eq 1 ] || exit 2
exec awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo
EOF
chmod 0755 /rootfs/usr/local/bin/mountpoint

chmod 1777 /rootfs/tmp

# Tiny Core 完全没有 /usr/lib/locale，glibc 就解析不了 locale 名：initdb 直接报
# "invalid locale settings"；**已经存在的库更严重**——旧镜像（Alpine/musl）不校验
# locale，initdb 会把 lc_messages/lc_monetary/lc_numeric/lc_time = 'en_US.utf8'
# 写进 postgresql.conf，换成 glibc 底座后如果没有这份数据，容器会以
#   LOG: invalid value for parameter "lc_messages": "en_US.utf8"
#   FATAL: configuration file ".../postgresql.conf" contains errors
# 反复重启（升级路径断掉）。Debian 的 libc-bin 自带编译好的 C.utf8（392K，实测能
# 被 Tiny Core 的 glibc 2.40 正常加载），en_US.UTF-8 用 localedef 现编（源数据来自
# 编译期的 locales 包）。目录名用 Debian 风格的小写编码（en_US.utf8）——glibc 会把
# en_US.UTF-8 归一化成同一个名字，两种写法都能命中。
mkdir -p /rootfs/usr/lib/locale
cp -a /usr/lib/locale/C.utf8 /rootfs/usr/lib/locale/
for loc in ${LOCALES}; do
  input="${loc%%.*}"
  charset="${loc#*.}"
  norm="$(printf '%s' "$charset" | tr 'A-Z' 'a-z' | tr -d '-')"
  out="/rootfs/usr/lib/locale/${input}.${norm}"
  echo "[locale] localedef ${loc} -> ${out}"
  localedef -c -i "$input" -f "$charset" "$out"
  [ -f "${out}/LC_CTYPE" ] || { echo "[locale] 生成失败: ${loc}" >&2; exit 1; }
done

# Tiny Core 的 busybox 没编 getent，而官方 docker-entrypoint.sh 在以「非 root
# 且 uid 不在 /etc/passwd」运行时要用 `getent passwd <uid>` 判断该 uid 是否存在
# （决定要不要走 nss_wrapper）。Debian 的 libc-bin 自带 getent（69K，实测在
# Tiny Core 的 glibc 2.40 + /lib/libnss_files.so.2 下工作正常）。
mkdir -p /rootfs/usr/bin
cp /usr/bin/getent /rootfs/usr/bin/getent
chmod 0755 /rootfs/usr/bin/getent

# Tiny Core 也没有 `locale` 命令，PG 18 的 initdb 在导入系统 collation 时会
# popen("locale -a") 失败，于是打一行 "no usable system locales were found"。
# 补一个只支持 -a 的垫片，直接列出 /usr/lib/locale 下实际装了哪些（所以
# --build-arg LOCALES 加了新 locale 后这里自动跟着变）。
cat > /rootfs/usr/local/bin/locale <<'EOF'
#!/bin/sh
# 兼容 PG 18 initdb 的 `locale -a`
case "${1:-}" in
  -a|--all-locales) printf 'C\nPOSIX\n'; ls /usr/lib/locale 2>/dev/null ;;
  *) echo "locale: only -a is supported in this image" >&2; exit 1 ;;
esac
EOF
chmod 0755 /rootfs/usr/local/bin/locale

# postgres 载荷里容器用不到的部分（只是在容器里 build 扩展才需要）
if [ "${PG_SLIM:-1}" = "1" ]; then
  echo "[pg] slim: 删掉头文件/静态库/pgxs/文档"
  rm -rf /rootfs/usr/local/include
  rm -rf /rootfs/usr/local/lib/postgresql/pgxs
  find /rootfs/usr/local/lib -name '*.a' -delete
  find /rootfs/usr/local/lib -name '*.la' -delete
  find /rootfs/usr/local/share -maxdepth 1 -type d -name 'doc' -exec rm -rf {} +
fi

# ---- 依赖闭包：把 Tiny Core 里没有的 so 收集到 /extralib（最终镜像再放进 /lib）
# glibc 相关 soname（libc/libm/libpthread/libdl/librt/libutil/libresolv/libnsl/
# libanl/libcrypt/libz/libstdc++/libgcc_s...）Tiny Core 已有 ⇒ 跳过，保证
# loader 与 libc 同源。
ldconfig -p > /tmp/ldpaths
{ printf '%s\n' /rootfs/bin/bash /rootfs/usr/lib/libnss_wrapper.so; find /rootfs/usr/local -type f; } | while IFS= read -r f; do
  readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' || true
done | sort -u > /tmp/needed

mkdir -p /extralib
queue=$(cat /tmp/needed | tr '\n' ' ')
seen=""
while [ -n "${queue% }" ]; do
  next=""
  for soname in $queue; do
    case " $seen " in *" $soname "*) continue ;; esac
    seen="$seen $soname"
    if [ -e "/rootfs/lib/$soname" ] || [ -e "/rootfs/usr/lib/$soname" ] \
       || [ -e "/rootfs/usr/local/lib/$soname" ]; then
      echo "[deps] 已提供: $soname"
      continue
    fi
    path=$(awk -v s="$soname" '$1 == s { print $NF; exit }' /tmp/ldpaths)
    if [ -z "$path" ] || [ ! -e "$path" ]; then
      echo "[deps] ERROR: 找不到 $soname" >&2
      exit 1
    fi
    cp -L "$path" "/extralib/$soname"
    echo "[deps] 补充 $path -> /lib/$soname"
    next="$next $(readelf -d "$path" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' || true)"
  done
  queue="$next"
done

# ---- 用户、目录（对齐官方 postgres 镜像）
printf 'postgres:x:70:70:PostgreSQL server:/var/lib/postgresql:/bin/sh\n' >> /rootfs/etc/passwd
printf 'postgres:x:70:\n' >> /rootfs/etc/group
# Tiny Core 没有 nsswitch.conf，glibc 就不知道用 nss_files 解析用户/主机
[ -e /rootfs/etc/nsswitch.conf ] || cat > /rootfs/etc/nsswitch.conf <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
EOF

mkdir -p /rootfs/var/lib/postgresql /rootfs/var/run/postgresql /rootfs/docker-entrypoint-initdb.d
chown -R 70:70 /rootfs/var/lib/postgresql
chmod 3775 /rootfs/var/run/postgresql

echo "[assemble] 载荷大小:"
du -sh /rootfs/usr/local /extralib
SRC

# --------------------------------------------------------------------- runtime
FROM scratch

ARG PG_VERSION=18.6
ARG TS_VERSION=2.30.0

# 底座（Tiny Core）与载荷分层，便于分别看体积
COPY --from=tinycore /rootfs/ /
COPY --from=assemble /rootfs/usr/local/ /usr/local/
COPY --from=assemble /extralib/ /lib/
# 补进去的 bash：docker-entrypoint.sh 的 shebang 是 #!/usr/bin/env bash
COPY --from=assemble /rootfs/bin/bash /bin/bash
COPY --from=assemble /rootfs/etc/passwd /etc/passwd
COPY --from=assemble /rootfs/etc/group /etc/group
COPY --from=assemble /rootfs/etc/nsswitch.conf /etc/nsswitch.conf
COPY --from=assemble /rootfs/var/ /var/
COPY --from=assemble /rootfs/docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
# glibc 的 locale 数据（C.utf8 + LOCALES 里编译的那些，默认含 en_US.UTF-8）：
# 前两者让 LANG=C.UTF-8 生效，en_US.utf8 让旧 Alpine/musl 镜像 initdb 的数据目录
# （conf 与 pg_database 里写着 en_US.utf8）能直接被 glibc 解析、正常启动
COPY --from=assemble /rootfs/usr/lib/locale/ /usr/lib/locale/
# 官方入口脚本在「非 root 用户」路径下要用的 getent
COPY --from=assemble /rootfs/usr/bin/getent /usr/bin/getent
# 随机 uid 运行时 entrypoint 用的 nss_wrapper（与官方 postgres 镜像一致）
COPY --from=assemble /rootfs/usr/lib/libnss_wrapper.so /usr/lib/libnss_wrapper.so

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    PG_MAJOR=18 \
    PG_VERSION=${PG_VERSION} \
    TS_VERSION=${TS_VERSION} \
    PGDATA=/var/lib/postgresql/18/docker

STOPSIGNAL SIGINT
EXPOSE 5432
VOLUME ["/var/lib/postgresql"]

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["postgres"]
