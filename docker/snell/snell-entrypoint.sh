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
cat > "$CONF" << EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
EOF

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
