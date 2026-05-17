#!/bin/sh
set -eu

CONFIG="${NODEGET_CONFIG_PATH:-/etc/nodeget/config.toml}"

if [ ! -f "$CONFIG" ]; then
  echo "[nodeget] generating config at $CONFIG from env vars"
  mkdir -p "$(dirname "$CONFIG")"

  cat > "$CONFIG" << EOF
server_uuid = "auto_gen"
ws_listener = "0.0.0.0:${NODEGET_PORT:-2211}"

[logging]
log_filter = "${NODEGET_LOG_FILTER:-info}"

[database]
database_url = "${NODEGET_DATABASE_URL:-sqlite:///var/lib/nodeget/nodeget.db?mode=rwc}"
EOF
fi

exec /usr/bin/nodeget -c "$CONFIG" "$@"
