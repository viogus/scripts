#!/bin/sh
set -eu

DATA_DIR="${VPNGATE_DATA_DIR:-/opt/aimilivpn/vpngate_data}"
AUTH_FILE="$DATA_DIR/ui_auth.json"

if [ ! -f "$AUTH_FILE" ]; then
    WEB_PORT="${WEB_PORT:-8787}"
    SECRET_PATH="${SECRET_PATH:-$(tr -dc 'a-zA-Z0-9' < /dev/urandom | dd bs=12 count=1 2>/dev/null)}"
    WEB_USERNAME="${WEB_USERNAME:-$(tr -dc 'a-zA-Z' < /dev/urandom | dd bs=12 count=1 2>/dev/null)}"
    WEB_PASSWORD="${WEB_PASSWORD:-$(tr -dc 'a-zA-Z0-9' < /dev/urandom | dd bs=12 count=1 2>/dev/null)}"

    cat > "$AUTH_FILE" << JSON
{
    "host": "0.0.0.0",
    "port": $WEB_PORT,
    "secret_path": "$SECRET_PATH",
    "username": "$WEB_USERNAME",
    "password": "$WEB_PASSWORD"
}
JSON

    echo "============================================"
    echo "  AimiliVPN — Web Panel"
    echo "  URL:      http://<host>:$WEB_PORT/$SECRET_PATH"
    echo "  Username: $WEB_USERNAME"
    echo "  Password: $WEB_PASSWORD"
    echo "  Proxy:    socks5://<host>:7928"
    echo "============================================"
fi

# Loose RPF for VPN routing
sysctl -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=2 2>/dev/null || true

exec "$@"
