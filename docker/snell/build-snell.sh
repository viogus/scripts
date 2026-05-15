#!/bin/sh
set -eu

case "${TARGETARCH}" in
  amd64)
    SNELL_ARCH=amd64
    GNU_TRIPLET=x86_64-linux-gnu
    LD_PATH=/lib64/ld-linux-x86-64.so.2
    ;;
  arm64)
    SNELL_ARCH=aarch64
    GNU_TRIPLET=aarch64-linux-gnu
    LD_PATH=/lib/ld-linux-aarch64.so.1
    ;;
  arm)
    if [ "${TARGETVARIANT}" = "v7" ]; then
      SNELL_ARCH=armv7l
      GNU_TRIPLET=arm-linux-gnueabihf
      LD_PATH=/lib/ld-linux-armhf.so.3
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
  if wget -q --timeout=60 -O /tmp/snell.zip "$URL"; then
    break
  fi
  echo "[snell] attempt $i failed, retrying..." >&2
  sleep 5
done

[ -f /tmp/snell.zip ] || { echo "[snell] download failed" >&2; exit 1; }

unzip -q /tmp/snell.zip -d /tmp/snell
mkdir -p /runtime/root/usr/local/bin
cp /tmp/snell/snell-server /runtime/root/usr/local/bin/snell-server
chmod +x /runtime/root/usr/local/bin/snell-server

# Ensure glibc ABI: copy all needed .so files + dynamic linker from builder
# libdl may be an ld script (glibc 2.34+) or absent entirely
LIB_DIR=/lib/${GNU_TRIPLET}
USR_LIB_DIR=/usr/lib/${GNU_TRIPLET}

for dst in /runtime/root/lib /runtime/root/usr/lib; do
  mkdir -p "$dst"
done

# Copy dynamic linker to its hardcoded path (read from ELF INTERP)
mkdir -p "$(dirname /runtime/root${LD_PATH})"
cp -a "$LD_PATH" "/runtime/root${LD_PATH}"

# Copy core glibc + gcc runtime
for lib in \
  "${LIB_DIR}/libc.so.6" \
  "${LIB_DIR}/libm.so.6" \
  "${LIB_DIR}/libpthread.so.0" \
  "${LIB_DIR}/libdl.so.2" \
  "${LIB_DIR}/libgcc_s.so.1" \
  "${USR_LIB_DIR}/libstdc++.so.6"; do
  if [ -e "$lib" ]; then
    cp -a "$lib" /runtime/root/lib/
  else
    echo "[snell] skip $lib (not present)"
  fi
done

# Busybox needs /lib64 on amd64 for ld-linux
if [ "${TARGETARCH}" = "amd64" ]; then
  mkdir -p /runtime/root/lib64
  cp -a "$LD_PATH" /runtime/root/lib64/
fi

rm -rf /tmp/snell /tmp/snell.zip
apt-get purge -y wget unzip && apt-get autoremove -y && apt-get clean
rm -rf /var/lib/apt/lists/*
