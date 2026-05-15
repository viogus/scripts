#!/bin/sh
set -eu

# Map docker TARGETARCH to frp release arch name
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

echo "[frp] downloading v${FRP_VERSION} for linux/${ARCH}"
echo "[frp] url: ${URL}"

for i in 1 2 3; do
  if curl -fsSL --connect-timeout 10 --max-time 120 \
    -o /tmp/frp.tar.gz "$URL"; then
    break
  fi
  echo "[frp] attempt $i failed, retrying..." >&2
  sleep 5
done

if [ ! -f /tmp/frp.tar.gz ]; then
  echo "[frp] download failed" >&2
  exit 1
fi

mkdir -p /tmp/frp
tar -xzf /tmp/frp.tar.gz -C /tmp/frp

# frp tarball extracts to frp_${VERSION}_linux_${ARCH}/
EXTRACT_DIR="/tmp/frp/frp_${FRP_VERSION}_linux_${ARCH}"

if [ ! -d "$EXTRACT_DIR" ]; then
  echo "[frp] extract dir not found: $EXTRACT_DIR" >&2
  ls -la /tmp/frp/ >&2
  exit 1
fi

cp "$EXTRACT_DIR/frps" /usr/bin/frps
cp "$EXTRACT_DIR/frpc" /usr/bin/frpc
chmod +x /usr/bin/frps /usr/bin/frpc

rm -rf /tmp/frp /tmp/frp.tar.gz

echo "[frp] frps: $(/usr/bin/frps --version 2>&1 || true)"
echo "[frp] frpc: $(/usr/bin/frpc --version 2>&1 || true)"
