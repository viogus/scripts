#!/bin/sh
set -eu

case "${TARGETARCH}" in
  amd64)
    SNELL_ARCH=amd64
    GNU_TRIPLET=x86_64-linux-gnu
    ;;
  arm64)
    SNELL_ARCH=aarch64
    GNU_TRIPLET=aarch64-linux-gnu
    ;;
  arm)
    if [ "${TARGETVARIANT}" = "v7" ]; then
      SNELL_ARCH=armv7l
      GNU_TRIPLET=arm-linux-gnueabihf
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

apt-get update && apt-get install -y --no-install-recommends wget unzip ca-certificates

for i in 1 2 3; do
  if wget -q --timeout=30 -O /tmp/snell.zip "$URL"; then
    break
  fi
  echo "[snell] attempt $i failed, retrying..." >&2
  sleep 5
done

[ -f /tmp/snell.zip ] || { echo "[snell] download failed" >&2; exit 1; }

unzip -q /tmp/snell.zip -d /tmp/snell
cp /tmp/snell/snell-server /usr/local/bin/snell-server
chmod +x /usr/local/bin/snell-server

# Collect .so files missing from busybox:stable-glibc
# libdl merged into libc in glibc 2.34+, skip if absent
mkdir -p /runtime/lib
for lib in \
  /lib/${GNU_TRIPLET}/libdl.so.2 \
  /lib/${GNU_TRIPLET}/libgcc_s.so.1 \
  /usr/lib/${GNU_TRIPLET}/libstdc++.so.6; do
  if [ -f "$lib" ]; then
    cp "$lib" /runtime/lib/
  fi
done

rm -rf /tmp/snell /tmp/snell.zip
apt-get purge -y wget unzip && apt-get autoremove -y
