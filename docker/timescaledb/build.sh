#!/bin/sh
# 构建 timescaledb 的精简变体镜像。
#
#   ./build.sh tinycore        # Tiny Core Linux 底座（生产镜像，见 README.md）
#   ./build.sh alpine-lean     # alpine:3.24 底座 + 同样的精简构建选项（对照用）
#   ./build.sh tinycore arm64  # 只构一个架构
#
# 默认构 amd64 + arm64（与上游 CI 的平台一致）。
set -eu

VARIANT="${1:-tinycore}"
ARCHS="${2:-amd64 arm64}"

case "$VARIANT" in
  tinycore)     FILE=Dockerfile ;;
  alpine-lean)  FILE=Dockerfile.alpine-lean ;;
  *) echo "未知变体: $VARIANT（可选 tinycore / alpine-lean）" >&2; exit 1 ;;
esac

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for arch in $ARCHS; do
  echo "==> 构建 $VARIANT ($arch)"
  DOCKER_BUILDKIT=1 docker build \
    --platform "linux/$arch" \
    -f "$DIR/$FILE" \
    -t "timescaledb-${VARIANT}:${arch}" \
    "$DIR"
done

echo "==> 完成。镜像体积:"
docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | grep "timescaledb-${VARIANT}" || true
