FROM debian:stable-slim AS builder

ARG TARGETARCH TARGETVARIANT
ARG SNELL_VERSION=5.0.1

RUN <<'SRC'
  set -eu

  case "${TARGETARCH}" in
    amd64)
      SNELL_ARCH=amd64
      GNU_TRIPLET=x86_64-linux-gnu
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
    *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;;
  esac

  apt-get update && apt-get install -y --no-install-recommends wget unzip ca-certificates libstdc++6

  URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
  echo "[snell] downloading v${SNELL_VERSION} for linux/${SNELL_ARCH}"

  for i in 1 2 3; do
    if wget -q --timeout=60 -O /tmp/snell.zip "$URL"; then break; fi
    echo "[snell] attempt $i failed, retrying..." >&2
    sleep 5
  done
  [ -f /tmp/snell.zip ] || { echo "[snell] download failed" >&2; exit 1; }

  unzip -q /tmp/snell.zip -d /tmp/snell

  mkdir -p /runtime/root/usr/local/bin /runtime/root/lib /runtime/root/usr/lib
  cp /tmp/snell/snell-server /runtime/root/usr/local/bin/snell-server
  chmod +x /runtime/root/usr/local/bin/snell-server

  LIB_DIR=/lib/${GNU_TRIPLET}
  USR_LIB_DIR=/usr/lib/${GNU_TRIPLET}

  # dynamic linker: source from GNU triplet dir, dest at ELF INTERP path
  LD_SRC="${LIB_DIR}/$(basename ${LD_DST})"
  mkdir -p "$(dirname /runtime/root${LD_DST})"
  if [ -e "$LD_SRC" ]; then
    cp -a "$LD_SRC" "/runtime/root${LD_DST}"
  else
    echo "[snell] WARNING: ld not at $LD_SRC, trying $LD_DST" >&2
    cp -a "$LD_DST" "/runtime/root${LD_DST}"
  fi

  # core glibc + gcc runtime (libdl may be ld script or absent on glibc 2.34+)
  # cp -L follows symlinks so versioned targets (e.g. libstdc++.so.6.0.33) land too
  for lib in \
    "${LIB_DIR}/libc.so.6" \
    "${LIB_DIR}/libm.so.6" \
    "${LIB_DIR}/libpthread.so.0" \
    "${LIB_DIR}/libdl.so.2" \
    "${LIB_DIR}/libgcc_s.so.1" \
    "${USR_LIB_DIR}/libstdc++.so.6"; do
    if [ -e "$lib" ]; then cp -L "$lib" /runtime/root/lib/; fi
  done

  echo "[snell] libraries staged:"
  ls -la /runtime/root/lib/

  echo "[snell] verifying runtime deps:"
  ldd /runtime/root/usr/local/bin/snell-server 2>&1 || true

  rm -rf /tmp/snell /tmp/snell.zip
  apt-get purge -y wget unzip && apt-get autoremove -y && apt-get clean
  rm -rf /var/lib/apt/lists/*
SRC

FROM busybox:stable

COPY --from=builder /runtime/root/ /

RUN <<'RUNTIME'
  set -eu
  cat > /usr/local/bin/snell-entrypoint.sh << 'EP'
#!/bin/sh
set -eu

CONF="${CONF:-/app/snell-server.conf}"
BIN="/usr/local/bin/snell-server"

if [ -f "$CONF" ]; then
  echo "[snell] using existing config: $CONF"
  exec "$BIN" -c "$CONF"
fi

PORT="${PORT:-}"
PSK="${PSK:-}"
OBFS="${OBFS:-off}"

if [ -z "$PORT" ]; then
  PORT=$(od -An -N2 -i /dev/urandom | tr -d ' ')
  PORT=$(( (PORT % 64510) + 1025 ))
fi
if [ -z "$PSK" ]; then
  PSK=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)
fi

echo "[snell] generating config: $CONF"
umask 077
cat > "$CONF" << CFG
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
CFG

if [ "$OBFS" != "off" ]; then
  if [ -n "${OBFS_HOST:-}" ]; then
    echo "obfs = ${OBFS}" >> "$CONF"
    echo "obfs-host = ${OBFS_HOST}" >> "$CONF"
  else
    echo "[snell] WARNING: OBFS=${OBFS} but OBFS_HOST not set, obfs disabled" >&2
  fi
fi

echo "[snell] port=${PORT} psk=*** obfs=${OBFS}"
exec "$BIN" -c "$CONF"
EP
  chmod +x /usr/local/bin/snell-entrypoint.sh
  mkdir -p /app
RUNTIME

ENV PORT=""
ENV PSK=""
ENV OBFS="off"

ENTRYPOINT ["/usr/local/bin/snell-entrypoint.sh"]
