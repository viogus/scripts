#!/bin/sh
set -eu

case "${TARGETARCH}" in
  amd64) SNELL_ARCH=amd64 ;;
  arm64) SNELL_ARCH=aarch64 ;;
  arm)
    if [ "${TARGETVARIANT}" = "v7" ]; then
      SNELL_ARCH=armv7l
    else
      echo "Unsupported arm variant: ${TARGETVARIANT}" >&2; exit 1
    fi
    ;;
  *)
    echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1
    ;;
esac

URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
echo "[snell] downloading v${SNELL_VERSION} for linux/${SNELL_ARCH}"

for i in 1 2 3; do
  if curl -fsSL --connect-timeout 10 --max-time 120 \
    -o /tmp/snell.zip "$URL"; then
    break
  fi
  echo "[snell] attempt $i failed, retrying..." >&2
  sleep 5
done

[ -f /tmp/snell.zip ] || { echo "[snell] download failed" >&2; exit 1; }

unzip -q /tmp/snell.zip -d /tmp/snell
cp /tmp/snell/snell-server /usr/local/bin/snell-server
chmod +x /usr/local/bin/snell-server

rm -rf /tmp/snell /tmp/snell.zip

echo "[snell] version: $(/usr/local/bin/snell-server --version 2>&1 || true)"
