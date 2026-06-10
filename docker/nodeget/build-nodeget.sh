#!/bin/sh
set -eu

COMPONENT="${NODEGET_COMPONENT:-nodeget-server}"

case "${TARGETARCH}" in
  amd64) ARCH=x86_64 ;;
  arm64) ARCH=aarch64 ;;
  arm)   ARCH=armv7 ;;
  *)
    echo "Unsupported arch: ${TARGETARCH}" >&2
    exit 1
    ;;
esac

BIN="nodeget-server-linux-${ARCH}-musl"
[ "$COMPONENT" = "nodeget-agent" ] && BIN="nodeget-agent-linux-${ARCH}-musl"

# armv7: prefer musleabihf, fallback to gnueabihf (server no longer ships musl for armv7)
if [ "$ARCH" = "armv7" ]; then
  BIN_MUSL="${BIN}eabihf"
  BIN_GNU="$(echo "${BIN}" | sed 's/-musl$/-gnueabihf/')"
  BIN="${BIN_MUSL}"
  FALLBACK_URL="${BIN_GNU}"
fi

URL="https://github.com/GenshinMinecraft/NodeGet/releases/download/v${NODEGET_VERSION}/${BIN}"

echo "[nodeget] downloading ${COMPONENT} v${NODEGET_VERSION} for linux/${ARCH}"

for i in 1 2 3; do
  if curl -fsSL --connect-timeout 10 --max-time 120 \
    -o /tmp/nodeget "$URL"; then
    break
  fi
  echo "[nodeget] attempt $i failed, retrying..." >&2
  sleep 5
done

# armv7 fallback: try gnueabihf if musleabihf not found
if [ ! -f /tmp/nodeget ] && [ -n "${FALLBACK_URL:-}" ]; then
  echo "[nodeget] musl not found, trying gnu: ${FALLBACK_URL}" >&2
  URL="https://github.com/GenshinMinecraft/NodeGet/releases/download/v${NODEGET_VERSION}/${FALLBACK_URL}"
  for i in 1 2 3; do
    if curl -fsSL --connect-timeout 10 --max-time 120 \
      -o /tmp/nodeget "$URL"; then
      break
    fi
    sleep 5
  done
fi

[ -f /tmp/nodeget ] || { echo "[nodeget] download failed" >&2; exit 1; }

cp /tmp/nodeget /usr/bin/nodeget
chmod +x /usr/bin/nodeget
rm -f /tmp/nodeget

echo "[nodeget] ${COMPONENT}: $(/usr/bin/nodeget --version 2>&1 || true)"
