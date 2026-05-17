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

  mkdir -p /runtime/root/usr/local/bin /runtime/root/lib /runtime/root/usr/lib
  cp /tmp/snell/snell-server /runtime/root/usr/local/bin/snell-server
  chmod +x /runtime/root/usr/local/bin/snell-server

  LIB_DIR=/lib/${GNU_TRIPLET}
  USR_LIB_DIR=/usr/lib/${GNU_TRIPLET}

  # dynamic linker
  LD_SRC="${LIB_DIR}/$(basename ${LD_DST})"
  mkdir -p "$(dirname /runtime/root${LD_DST})"
  if [ -e "$LD_SRC" ]; then
    cp -a "$LD_SRC" "/runtime/root${LD_DST}"
  else
    echo "[snell] WARNING: ld not at $LD_SRC, trying $LD_DST" >&2
    cp -a "$LD_DST" "/runtime/root${LD_DST}"
  fi

  # core glibc + gcc runtime
  for lib in \
    "${LIB_DIR}/libc.so.6" \
    "${LIB_DIR}/libm.so.6" \
    "${USR_LIB_DIR}/libstdc++.so.6" \
    "${LIB_DIR}/libgcc_s.so.1"; do
    if [ -e "$lib" ]; then cp -L "$lib" /runtime/root/lib/; fi
  done

  # libdl/libpthread merged into libc since glibc 2.34 — symlink stubs
  for stub in libdl.so.2 libpthread.so.0; do
    ln -sf libc.so.6 "/runtime/root/lib/${stub}"
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
