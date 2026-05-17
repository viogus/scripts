#!/bin/sh
set -eu

COMPONENT="${NODEGET_COMPONENT:-nodeget-server}"
CONFIG="${NODEGET_CONFIG_PATH:-/etc/nodeget/config.toml}"

if [ ! -f "$CONFIG" ]; then
  case "$COMPONENT" in
    nodeget-server)
      echo "[nodeget] generating server config at $CONFIG"
      mkdir -p "$(dirname "$CONFIG")"
      mkdir -p /var/lib/nodeget

      cat > "$CONFIG" << EOF
server_uuid = "auto_gen"
ws_listener = "0.0.0.0:${NODEGET_PORT:-2211}"

[logging]
log_filter = "${NODEGET_LOG_FILTER:-info}"

[database]
database_url = "${NODEGET_DATABASE_URL:-sqlite:///var/lib/nodeget/nodeget.db?mode=rwc}"
EOF
      ;;

    nodeget-agent)
      echo "[nodeget] agent requires a config file, mount one at $CONFIG" >&2
      echo "[nodeget] see: https://github.com/NodeSeekDev/NodeGet" >&2
      exit 1
      ;;
  esac
fi

exec /usr/bin/nodeget -c "$CONFIG" "$@"
