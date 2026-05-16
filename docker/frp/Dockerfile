FROM alpine:latest AS downloader
ARG FRP_VERSION=0.68.1
ARG TARGETARCH
ARG FRP_COMPONENT=frps

RUN apk add --no-cache curl tar binutils

COPY build-frp.sh /tmp/
RUN sh /tmp/build-frp.sh

FROM busybox:stable

COPY --from=downloader /usr/bin/frp /usr/bin/frp
COPY --from=downloader /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

RUN <<'RUNTIME'
  set -eu
  mkdir -p /usr/local/bin
  cat > /usr/local/bin/frp-entrypoint.sh << 'EP'
#!/bin/sh
set -eu

CONF="${CONF:-/app/frps.toml}"
BIN="/usr/bin/frp"

if [ -f "$CONF" ]; then
  echo "[frp] using existing config: $CONF"
  exec "$BIN" -c "$CONF"
fi

BIND_PORT="${BIND_PORT:-}"
AUTH_TOKEN="${AUTH_TOKEN:-}"

if [ -z "$BIND_PORT" ]; then
  BIND_PORT=$(od -An -N2 -i /dev/urandom | tr -d ' ')
  BIND_PORT=$(( (BIND_PORT % 64510) + 1025 ))
fi
if [ -z "$AUTH_TOKEN" ]; then
  AUTH_TOKEN=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)
fi

echo "[frp] generating config: $CONF"
umask 077
cat > "$CONF" << CFG
bindPort = ${BIND_PORT}
auth.token = "${AUTH_TOKEN}"
CFG

if [ -n "${DASHBOARD_PORT:-}" ]; then
  echo "dashboardPort = ${DASHBOARD_PORT}" >> "$CONF"
fi
if [ -n "${DASHBOARD_USER:-}" ]; then
  echo "dashboardUser = \"${DASHBOARD_USER}\"" >> "$CONF"
fi
if [ -n "${DASHBOARD_PWD:-}" ]; then
  echo "dashboardPwd = \"${DASHBOARD_PWD}\"" >> "$CONF"
fi
if [ -n "${VHOST_HTTP_PORT:-}" ]; then
  echo "vhostHTTPPort = ${VHOST_HTTP_PORT}" >> "$CONF"
fi
if [ -n "${VHOST_HTTPS_PORT:-}" ]; then
  echo "vhostHTTPSPort = ${VHOST_HTTPS_PORT}" >> "$CONF"
fi

echo "[frp] bind_port=${BIND_PORT} auth_token=***"
exec "$BIN" -c "$CONF"
EP
  chmod +x /usr/local/bin/frp-entrypoint.sh
  mkdir -p /app
RUNTIME

ENV BIND_PORT=""
ENV AUTH_TOKEN=""
ENV DASHBOARD_PORT=""
ENV DASHBOARD_USER=""
ENV DASHBOARD_PWD=""
ENV VHOST_HTTP_PORT=""
ENV VHOST_HTTPS_PORT=""

ENTRYPOINT ["/usr/local/bin/frp-entrypoint.sh"]
