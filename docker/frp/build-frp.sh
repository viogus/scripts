#!/bin/sh
set -euo pipefail

COMPONENT="${FRP_COMPONENT:-frps}"

case "${TARGETARCH}" in
  amd64) RUST_TARGET="x86_64-unknown-linux-musl" ;;
  arm64) RUST_TARGET="aarch64-unknown-linux-musl" ;;
  arm)   RUST_TARGET="armv7-unknown-linux-musleabihf" ;;
  *)
    echo "Unsupported arch: ${TARGETARCH}" >&2
    exit 1
    ;;
esac

URL="https://github.com/viogus/frp-rs/releases/download/v${FRP_VERSION}/frp-rs_v${FRP_VERSION}_${RUST_TARGET}.tar.gz"

echo "[frp-rs] downloading ${COMPONENT} v${FRP_VERSION} for ${RUST_TARGET}"

for i in 1 2 3; do
  if curl -fsSL --connect-timeout 10 --max-time 120 \
    -o /tmp/frp-rs.tar.gz "$URL"; then
    break
  fi
  echo "[frp-rs] attempt $i failed, retrying..." >&2
  sleep 5
done

[ -f /tmp/frp-rs.tar.gz ] || { echo "[frp-rs] download failed" >&2; exit 1; }

# frp-rs tarball extracts binaries at top level (frps, frpc)
tar -xzf /tmp/frp-rs.tar.gz -C /tmp/
[ -f "/tmp/${COMPONENT}" ] || { echo "[frp-rs] component not found: ${COMPONENT}" >&2; ls -la /tmp/ >&2; exit 1; }

cp "/tmp/${COMPONENT}" /usr/bin/frp
strip --strip-all /usr/bin/frp || echo "WARN: strip frp failed" >&2
chmod +x /usr/bin/frp

rm -rf /tmp/frp-rs.tar.gz /tmp/frps /tmp/frpc

echo "[frp-rs] ${COMPONENT}: $(/usr/bin/frp --version 2>&1 || true)"
