#!/bin/sh
# 量一个 timescaledb 镜像的体积构成：
#   1) docker save 出来的 OCI 归档：各层压缩/解压大小（单平台口径）
#   2) 镜像内主要目录的 du
#
#   ./inspect-image.sh ghcr.io/viogus/timescaledb:2.30.0-pg18 user-arm64
set -eu

IMG="${1:?用法: $0 <image> [label]}"
LABEL="${2:-image}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${TMPDIR:-/tmp}/ts-${LABEL}.tar"
rm -f "$OUT"
docker save "$IMG" -o "$OUT"
python3 "${HERE}/measure-image-size.py" "$OUT"
rm -f "$OUT"

echo "--- ${LABEL} 镜像内目录（MB） ---"
docker run --rm --entrypoint sh "$IMG" -c '
  du -sm /usr/local /usr/lib /usr/local/lib /lib /usr/share /bin /usr/bin 2>/dev/null | sort -rn
'
