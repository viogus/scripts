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

# armv7 uses musleabihf, others use plain musl
[ "$ARCH" = "armv7" ] && BIN="${BIN}eabihf"

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

[ -f /tmp/nodeget ] || { echo "[nodeget] download failed" >&2; exit 1; }

cp /tmp/nodeget /usr/bin/nodeget
strip --strip-all /usr/bin/nodeget || true
chmod +x /usr/bin/nodeget
rm -f /tmp/nodeget

echo "[nodeget] ${COMPONENT}: $(/usr/bin/nodeget --version 2>&1 || true)"
