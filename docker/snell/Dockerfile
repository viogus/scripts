FROM debian:stable-slim AS builder

ARG TARGETARCH TARGETVARIANT
ARG SNELL_VERSION=5.0.1

RUN <<'SRC'
  set -eu

  case "${TARGETARCH}" in
    amd64)   SNELL_ARCH=amd64 ;;
    arm64)   SNELL_ARCH=aarch64 ;;
    arm)
      if [ "${TARGETVARIANT}" = "v7" ]; then
        SNELL_ARCH=armv7l
      else
        echo "Unsupported arm variant: ${TARGETVARIANT}" >&2; exit 1
      fi
      ;;
    *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;;
  esac

  apt-get update && apt-get install -y --no-install-recommends \
    wget unzip ca-certificates gcc libc6-dev

  URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
  echo "[snell] downloading v${SNELL_VERSION} for linux/${SNELL_ARCH}"

  for i in 1 2 3; do
    if wget -q --timeout=60 -O /tmp/snell.zip "$URL"; then break; fi
    echo "[snell] attempt $i failed, retrying..." >&2
    sleep 5
  done
  [ -f /tmp/snell.zip ] || { echo "[snell] download failed" >&2; exit 1; }

  unzip -q /tmp/snell.zip -d /tmp/snell

  mkdir -p /runtime/root/usr/local/bin /runtime/root/lib
  cp /tmp/snell/snell-server /runtime/root/usr/local/bin/snell-server
  chmod +x /runtime/root/usr/local/bin/snell-server
  strip --strip-all /runtime/root/usr/local/bin/snell-server || echo "[snell] WARN: strip binary failed" >&2

  mkdir -p /runtime/root/lib

  # discover and copy dynamic linker + shared libs via ldd
  LDD_OUT=$(ldd /runtime/root/usr/local/bin/snell-server)

  LD_PATH=$(echo "$LDD_OUT" | awk '/^\s+\// && !/=>/ {print $1; exit}')
  if [ -z "$LD_PATH" ] || [ ! -e "$LD_PATH" ]; then
    echo "[snell] ERROR: cannot find dynamic linker" >&2
    echo "$LDD_OUT" >&2; exit 1
  fi
  mkdir -p "/runtime/root$(dirname "$LD_PATH")"
  cp -L "$LD_PATH" "/runtime/root${LD_PATH}"
  echo "[snell] ld: $LD_PATH"

  for lib in $(echo "$LDD_OUT" | awk '/=> \// {print $3}'); do
    cp -L "$lib" /runtime/root/lib/
    echo "[snell] lib: $lib"
  done

  echo "[snell] libraries staged:"
  ls -la /runtime/root/lib/

  echo "[snell] verifying runtime deps:"
  ldd /runtime/root/usr/local/bin/snell-server 2>&1 || true

  rm -rf /tmp/snell /tmp/snell.zip
SRC

COPY entrypoint.c /tmp/
RUN gcc -static -s -O2 -o /entrypoint /tmp/entrypoint.c && \
    strip --strip-all /entrypoint || true

FROM scratch

COPY --from=builder /runtime/root/ /
COPY --from=builder /entrypoint /entrypoint

ENV PORT="" \
    PSK="" \
    OBFS="off" \
    OBFS_HOST="" \
    CONF="/app/snell-server.conf"

ENTRYPOINT ["/entrypoint"]
