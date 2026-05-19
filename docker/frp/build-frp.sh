#!/bin/sh
set -eu

COMPONENT="${FRP_COMPONENT:-frps}"

case "${TARGETARCH}" in
  amd64) ARCH=amd64 ;;
  arm64) ARCH=arm64 ;;
  arm)   ARCH=arm ;;
  *)
    echo "Unsupported arch: ${TARGETARCH}" >&2
    exit 1
    ;;
esac

URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"

echo "[frp] downloading ${COMPONENT} v${FRP_VERSION} for linux/${ARCH}"

for i in 1 2 3; do
  if curl -fsSL --connect-timeout 10 --max-time 120 \
    -o /tmp/frp.tar.gz "$URL"; then
    break
  fi
  echo "[frp] attempt $i failed, retrying..." >&2
  sleep 5
done

[ -f /tmp/frp.tar.gz ] || { echo "[frp] download failed" >&2; exit 1; }

mkdir -p /tmp/frp
tar -xzf /tmp/frp.tar.gz -C /tmp/frp

EXTRACT_DIR="/tmp/frp/frp_${FRP_VERSION}_linux_${ARCH}"
[ -d "$EXTRACT_DIR" ] || { echo "[frp] extract dir not found: $EXTRACT_DIR" >&2; ls -la /tmp/frp/ >&2; exit 1; }

cp "$EXTRACT_DIR/${COMPONENT}" /usr/bin/frp
strip --strip-all /usr/bin/frp || true
chmod +x /usr/bin/frp

rm -rf /tmp/frp /tmp/frp.tar.gz

echo "[frp] ${COMPONENT}: $(/usr/bin/frp --version 2>&1 || true)"
