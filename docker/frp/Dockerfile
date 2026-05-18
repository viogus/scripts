ARG FRP_VERSION=0.68.1
ARG FRP_MODE=frps

FROM debian:stable-slim AS builder

ARG FRP_VERSION
ARG FRP_MODE
ARG TARGETARCH=amd64

RUN set -eu && \
  case "${TARGETARCH}" in \
    amd64) FRP_ARCH=amd64 ;; \
    arm64) FRP_ARCH=arm64 ;; \
    arm)   FRP_ARCH=arm ;; \
    *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
  esac && \
  apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates gcc libc6-dev && \
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz" && \
  echo "[frp] downloading ${FRP_MODE} v${FRP_VERSION} for linux/${FRP_ARCH}" && \
  for i in 1 2 3; do \
    if wget -q --timeout=60 -O /tmp/frp.tar.gz "$URL"; then break; fi; \
    echo "[frp] attempt $i failed, retrying..." >&2; \
    sleep 5; \
  done && \
  [ -f /tmp/frp.tar.gz ] || { echo "[frp] download failed" >&2; exit 1; } && \
  mkdir -p /tmp/frp && \
  tar -xzf /tmp/frp.tar.gz -C /tmp/frp && \
  EXTRACT_DIR="/tmp/frp/frp_${FRP_VERSION}_linux_${FRP_ARCH}" && \
  [ -d "$EXTRACT_DIR" ] || { echo "[frp] extract dir not found: $EXTRACT_DIR" >&2; ls -la /tmp/frp/ >&2; exit 1; } && \
  cp "$EXTRACT_DIR/${FRP_MODE}" /usr/bin/frp && \
  chmod +x /usr/bin/frp && \
  strip --strip-all /usr/bin/frp || true && \
  rm -rf /tmp/frp /tmp/frp.tar.gz && \
  echo "[frp] binary: $(/usr/bin/frp --version 2>&1 || true)"

COPY entrypoint.c /tmp/
RUN gcc -static -s -O2 -o /entrypoint /tmp/entrypoint.c && \
    strip --strip-all /entrypoint || true

FROM scratch

ARG FRP_MODE

COPY --from=builder /usr/bin/frp /usr/bin/frp
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /entrypoint /entrypoint

ENV FRP_MODE=${FRP_MODE} \
    FRP_CONF=/app/frp.toml

ENTRYPOINT ["/entrypoint"]
