#!/bin/sh
set -eu

case "${TARGETARCH}" in
  amd64)
    SNELL_ARCH=amd64
    GNU_TRIPLET=x86_64-linux-gnu
    # ELF INTERP = /lib64/ld-linux-x86-64.so.2, busybox /lib64->/lib
    LD_DST=/lib/ld-linux-x86-64.so.2
    ;;
  arm64)
    SNELL_ARCH=aarch64
    GNU_TRIPLET=aarch64-linux-gnu
    LD_DST=/lib/ld-linux-aarch64.so.1
    ;;
  arm)
    if [ "${TARGETVARIANT}" = "v7" ]; then
      SNELL_ARCH=armv7l
      GNU_TRIPLET=arm-linux-gnueabihf
      LD_DST=/lib/ld-linux-armhf.so.3
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

apt-get update && apt-get install -y --no-install-recommends wget unzip ca-certificates binutils libstdc++6

for i in 1 2 3; do
  if wget -q --timeout=60 -O /tmp/snell.zip "$URL"; then
    break
  fi
  echo "[snell] attempt $i failed, retrying..." >&2
  sleep 5
done

[ -f /tmp/snell.zip ] || { echo "[snell] download failed" >&2; exit 1; }

unzip -q /tmp/snell.zip -d /tmp/snell

strip --strip-all /tmp/snell/snell-server

mkdir -p /runtime/root/usr/local/bin
cp /tmp/snell/snell-server /runtime/root/usr/local/bin/snell-server
chmod +x /runtime/root/usr/local/bin/snell-server

# Collect glibc .so files + dynamic linker from builder
LIB_DIR=/lib/${GNU_TRIPLET}

mkdir -p /runtime/root/lib /runtime/root/usr/lib

# Dynamic linker: source from GNU triplet dir, dest at ELF INTERP path
LD_SRC="${LIB_DIR}/$(basename ${LD_DST})"
mkdir -p "$(dirname /runtime/root${LD_DST})"
if [ -e "$LD_SRC" ]; then
  cp -a "$LD_SRC" "/runtime/root${LD_DST}"
else
  echo "[snell] WARNING: ld not at $LD_SRC, trying $LD_DST" >&2
  cp -a "$LD_DST" "/runtime/root${LD_DST}"
fi

ldd /runtime/root/usr/local/bin/snell-server \
  | grep '=> /' \
  | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p' \
  | sort -u \
  | while read -r lib; do
      echo "[snell]   $lib"
      cp -L "$lib" /runtime/root/lib/
    done

echo "[snell] libraries staged:"
ls -la /runtime/root/lib/

echo "[snell] verifying runtime deps:"
ldd /runtime/root/usr/local/bin/snell-server 2>&1 || true

rm -rf /tmp/snell /tmp/snell.zip
apt-get purge -y wget unzip && apt-get autoremove -y && apt-get clean
rm -rf /var/lib/apt/lists/*
