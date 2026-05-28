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
    wget unzip ca-certificates gcc libc6-dev binutils

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

  mkdir -p /runtime/root/lib

  # discover and copy dynamic linker + shared libs via readelf
  BIN=/runtime/root/usr/local/bin/snell-server

  # 1. 从 ELF .interp 读取动态链接器路径
  INTERP=$(readelf -l "$BIN" 2>/dev/null \
    | awk '/Requesting program interpreter:/ {gsub(/.*: /, ""); gsub(/]/, ""); print}')

  # 2. 从 ELF .dynamic 读取 NEEDED 共享库
  NEEDED=$(readelf -d "$BIN" 2>/dev/null \
    | grep 'NEEDED' \
    | awk '{gsub(/\[|\]/, ""); print $NF}' \
    | sort -u)

  if [ -z "$INTERP" ] && [ -z "$NEEDED" ]; then
    echo "[snell] static binary, no libs needed"
  else
    if [ -n "$INTERP" ] && [ -e "$INTERP" ]; then
      mkdir -p "/runtime/root$(dirname "$INTERP")"
      cp -L "$INTERP" "/runtime/root${INTERP}"
      echo "[snell] ld: $INTERP"
    elif [ -n "$INTERP" ]; then
      echo "[snell] WARN: INTERP=$INTERP not found on builder" >&2
    fi

    if [ -n "$NEEDED" ]; then
      echo "[snell] NEEDED: $NEEDED"
      for lib in $NEEDED; do
        LIB_PATH=$(ldconfig -p 2>/dev/null \
          | grep -F "$lib" | head -1 \
          | awk '{for(i=1;i<=NF;i++) if($i=="=>") {print $(i+1); exit}}')
        if [ -n "$LIB_PATH" ] && [ -e "$LIB_PATH" ]; then
          cp -L "$LIB_PATH" /runtime/root/lib/
          echo "[snell] lib: $lib -> $LIB_PATH"
        else
          echo "[snell] WARN: cannot resolve $lib" >&2
        fi
      done
    fi
  fi

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
