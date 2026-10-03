#!/bin/sh
# snell 镜像冒烟测试：<image> [container-name]
#
#   1. entrypoint 用环境变量生成 /app/snell-server.conf 并 exec snell-server
#   2. snell-server 真的在监听（日志 + 宿主 TCP 连接）
#   3. 底座可用（Tiny Core 版应有 busybox 用户态）
#
# 测非本地架构时用环境变量指定平台（需要 qemu binfmt）：
#   PLATFORM=linux/arm64 sh smoke-snell.sh ghcr.io/viogus/snell-server:v5
#
# 退出码 0 = PASS。
set -eu

IMAGE="${1:?用法: smoke-snell.sh <image> [name]}"
NAME="${2:-snell-smoke-$$}"
PLATFORM="${PLATFORM:-}"
PULL_ARGS=""
RUN_ARGS=""
if [ -n "$PLATFORM" ]; then
  PULL_ARGS="--platform $PLATFORM"
  RUN_ARGS="--platform $PLATFORM"
fi
# Snell 要求 PSK >= 16 字符
PSK="smoke-test-psk-0123456789"
PORT=9102

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

fail() { echo "[smoke] FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -20 >&2 || true; exit 1; }

echo "[smoke] 镜像: ${IMAGE}${PLATFORM:+ (${PLATFORM})}"
docker rm -f "$NAME" >/dev/null 2>&1 || true
# shellcheck disable=SC2086
[ -z "$PULL_ARGS" ] || docker pull $PULL_ARGS "$IMAGE" >/dev/null 2>&1 || true
# shellcheck disable=SC2086
docker run -d --name "$NAME" $RUN_ARGS -e PORT="$PORT" -e PSK="$PSK" -p 127.0.0.1::"$PORT" "$IMAGE" >/dev/null

# 等 snell 报出监听行（最多 30s）
i=0
while [ "$i" -lt 30 ]; do
  if docker logs "$NAME" 2>&1 | grep -q "Start snell server on 0.0.0.0:${PORT}"; then break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then
    fail "容器退出（未进入监听状态）"
  fi
  i=$((i + 1)); sleep 1
done
[ "$i" -lt 30 ] || fail "30s 内没有出现监听日志"

echo "[smoke] 版本行: $(docker logs "$NAME" 2>&1 | grep -m1 'snell-server v' || echo '(无)')"
echo "[smoke] 监听行: $(docker logs "$NAME" 2>&1 | grep -m1 'Start snell server on' || echo '(无)')"

# 配置文件确实由 entrypoint 生成（scratch 类镜像没有用户态，跳过这项）
if CONF=$(docker exec "$NAME" cat /app/snell-server.conf 2>/dev/null); then
  echo "$CONF" | grep -q "listen = 0.0.0.0:${PORT}" || fail "配置里的 listen 不对: ${CONF}"
  echo "$CONF" | grep -q "psk = ${PSK}" || fail "配置里的 psk 不对"
  echo "[smoke] 配置: $(echo "$CONF" | tr '\n' ' ')"
else
  echo "[smoke] 配置: 镜像内无 shell（scratch 类），跳过 /app/snell-server.conf 检查"
fi

# 宿主侧 TCP 连接（映射端口）
MAPPED=$(docker port "$NAME" "${PORT}/tcp" | head -1 | sed 's/.*://')
[ -n "$MAPPED" ] || fail "取不到映射端口"
nc -z -w 3 127.0.0.1 "$MAPPED" || fail "TCP 连接 127.0.0.1:${MAPPED} 失败"
echo "[smoke] TCP 127.0.0.1:${MAPPED} 可连接"

# 底座用户态（Tiny Core 版有 busybox；scratch 版没有）
# 注：docker CLI 把 "OCI runtime exec failed" 打到 stdout，所以两边都要吞掉
if docker exec "$NAME" test -x /bin/busybox >/dev/null 2>&1; then
  U=$(docker exec "$NAME" sh -c 'busybox 2>&1 | head -1' 2>/dev/null || true)
  echo "[smoke] 底座: busybox 用户态可用（${U}）"
else
  echo "[smoke] 底座: 无 busybox（scratch 类镜像）"
fi

# 进程还在跑
[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = "true" ] || fail "容器不再运行"
echo "[smoke] PASS"
