FROM --platform=$BUILDPLATFORM debian:stable-slim AS builder

ARG TARGETARCH TARGETVARIANT
ARG SNELL_VERSION=5.0.1

RUN <<'SETUP'
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
      echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;;
  esac

  apt-get update && apt-get install -y --no-install-recommends wget unzip ca-certificates

  URL="https://dl.nssurge.com/snell/snell-server-v${SNELL_VERSION}-linux-${SNELL_ARCH}.zip"
  echo "[snell] downloading v${SNELL_VERSION} for ${SNELL_ARCH}"
  wget -q "$URL" -O /tmp/snell.zip
  unzip -q /tmp/snell.zip -d /tmp/snell
  cp /tmp/snell/snell-server /usr/local/bin/snell-server
  chmod +x /usr/local/bin/snell-server

  # Collect extra .so files not in busybox:stable-glibc
  mkdir -p /runtime/lib /runtime/usr/lib
  cp /lib/${GNU_TRIPLET}/libdl.so.2           /runtime/lib/
  cp /lib/${GNU_TRIPLET}/libgcc_s.so.1         /runtime/lib/
  cp /usr/lib/${GNU_TRIPLET}/libstdc++.so.6    /runtime/usr/lib/

  rm -rf /tmp/snell /tmp/snell.zip
  apt-get purge -y wget unzip && apt-get autoremove -y
SETUP

FROM busybox:stable-glibc

COPY --from=builder /usr/local/bin/snell-server /usr/local/bin/snell-server
COPY --from=builder /runtime/lib/     /lib/
COPY --from=builder /runtime/usr/lib/ /usr/lib/

ENTRYPOINT ["/usr/local/bin/snell-server"]
CMD ["-c", "/app/snell-server.conf"]
