#!/bin/sh
# 量一个镜像内部各路径的体积构成：
#   * 表观大小 = ls -l 求和（避免 du 的硬链接去重与块对齐误差，容器镜像里 apk/dpkg
#     会留下大量硬链接，du 结果随遍历顺序变化，不可比）
#   * gzip -9 成本 = 把该路径单独打成一层时的压缩体积，即它给镜像增加多少
#
#   ./measure-composition.sh ghcr.io/viogus/timescaledb:2.30.0-pg18
#   ./measure-composition.sh <image> "/usr/lib /usr/local"
set -eu

IMG="${1:?用法: $0 <image> [路径列表]}"
PATHS="${2:-/usr/lib/libLLVM.so.21.1 /usr/lib/llvm21 /usr/share/icu /usr/local/lib/postgresql/bitcode /usr/local/lib/postgresql /usr/local/share/postgresql /usr/local/include /usr/local/bin /usr/local/lib /usr/local/share /usr/lib /usr/share /usr/bin /usr/sbin /bin /sbin /lib /etc}"

docker run --rm --entrypoint sh -e PATHS="$PATHS" "$IMG" -c '
  . /etc/os-release 2>/dev/null || true
  printf "镜像: %s  架构: %s  发行版: %s\n" "'"$IMG"'" "$(uname -m)" "${PRETTY_NAME:-?}"
  printf "%12s %12s  %s\n" "表观MB" "gzipMB" "路径"
  for p in $PATHS; do
    if [ ! -e "$p" ]; then printf "%12s %12s  %s\n" "-" "-" "$p(不存在)"; continue; fi
    if [ -d "$p" ]; then
      raw=$(ls -lR "$p" 2>/dev/null | awk "{s+=\$5} END{print s+0}")
    else
      raw=$(ls -l "$p" | awk "{print \$5}")
    fi
    comp=$(tar cf - -C / "${p#/}" 2>/dev/null | gzip -9 -c | wc -c)
    awk -v r="$raw" -v c="$comp" -v p="$p" "BEGIN{printf \"%12.2f %12.2f  %s\n\", r/1048576, c/1048576, p}"
  done
'
