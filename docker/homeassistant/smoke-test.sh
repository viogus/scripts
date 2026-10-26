#!/usr/bin/env bash
# 冒烟测试：把镜像真跑起来，确认三件事
#   1. entrypoint 把预装的 custom_components 播种进了 bind mount 的配置目录
#      （这是最容易错的一环：镜像里写 /data 会被挂载点盖住）；
#   2. 集成的依赖在容器里 import 得动（construct / paho-mqtt / numpy / psutil …）；
#   3. HA 真的把 xiaomi_home 注册进来了 —— 先看 config_entries/flow_handlers
#      里有没有它，再真的 POST 一个 flow 出来。不碰小米账号，也不需要设备。
#
# 用法: smoke-test.sh <image-ref> [expected-xiaomi-version]
#   expected-xiaomi-version 可写 v0.5.0 或 0.5.0，只比版本号。
set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref> [expected-xiaomi-version]}"
WANT_XM="${2:-}"
NAME="hass-smoke-$$"
PORT="${SMOKE_PORT:-18123}"
DATA="$(mktemp -d)"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$DATA"
}
trap cleanup EXIT

fail() {
    echo "!! $*" >&2
    echo "=== container logs (tail) ===" >&2
    docker logs --tail 120 "$NAME" >&2 || true
    exit 1
}

echo "==> starting $IMAGE  (config dir: $DATA, port: $PORT)"
docker run -d --name "$NAME" -p "${PORT}:8123" -v "$DATA:/data" "$IMAGE" >/dev/null

echo "==> waiting for /manifest.json"
up=false
for i in $(seq 1 90); do
    if curl -fsS -m 5 "http://127.0.0.1:${PORT}/manifest.json" >/dev/null 2>&1; then
        echo "    up after ~$((i * 4))s"
        up=true
        break
    fi
    sleep 4
done
[ "$up" = true ] || fail "Home Assistant never answered on port $PORT"

echo "==> custom components were seeded into the mounted config dir"
docker exec "$NAME" test -f /data/custom_components/xiaomi_home/manifest.json \
    || fail "custom_components/xiaomi_home/manifest.json missing in /data"

GOT_XM=$(docker exec "$NAME" python3 -c \
    'import json;print(json.load(open("/data/custom_components/xiaomi_home/manifest.json"))["version"])')
echo "    integration manifest version: $GOT_XM"
if [ -n "$WANT_XM" ] && [ "${GOT_XM#v}" != "${WANT_XM#v}" ]; then
    fail "integration version mismatch: want $WANT_XM, got $GOT_XM"
fi

echo "==> integration requirements importable in the image"
docker exec "$NAME" python3 -c \
    'import construct, paho.mqtt.client, haffmpeg, numpy, cryptography, psutil; print("    deps ok")' \
    || fail "cannot import one of construct / paho.mqtt / haffmpeg / numpy / cryptography / psutil"

echo "==> Home Assistant registered the integration (flow handlers + real flow)"
# 容器内监听 8123；宿主机映射到 $PORT。
docker exec -i "$NAME" python3 - 8123 <<'PY' || fail "xiaomi_home config flow did not start"
import asyncio
import sys

import aiohttp

PORT = sys.argv[1] if len(sys.argv) > 1 else "8123"
BASE = f"http://127.0.0.1:{PORT}"
CLIENT_ID = f"{BASE}/"


async def call(session, method, path, **kwargs):
    async with session.request(method, BASE + path, **kwargs) as resp:
        try:
            body = await resp.json()
        except Exception:  # noqa: BLE001 - 非 JSON 响应就原样报出来
            body = await resp.text()
        if resp.status >= 400:
            raise SystemExit(f"{method} {path} -> {resp.status}: {body}")
        return body


async def main():
    async with aiohttp.ClientSession() as session:
        # 全新配置目录 → 先跑 onboarding 拿一个 access token。
        users = await call(
            session,
            "POST",
            "/api/onboarding/users",
            json={
                "client_id": CLIENT_ID,
                "name": "smoke",
                "username": "smoke",
                "password": "smoke-test-pw",
                "language": "en",
            },
        )
        token = await call(
            session,
            "POST",
            "/auth/token",
            data={
                "grant_type": "authorization_code",
                "code": users["auth_code"],
                "client_id": CLIENT_ID,
            },
        )
        headers = {"Authorization": f"Bearer {token['access_token']}"}

        handlers = await call(
            session, "GET", "/api/config/config_entries/flow_handlers", headers=headers
        )
        if "xiaomi_home" not in handlers:
            raise SystemExit(
                f"xiaomi_home missing from flow handlers ({len(handlers)} registered)"
            )
        print(f"    {len(handlers)} flow handlers registered, xiaomi_home included")

        flow = await call(
            session,
            "POST",
            "/api/config/config_entries/flow",
            json={"handler": "xiaomi_home"},
            headers=headers,
        )
        print(f"    flow started: type={flow.get('type')} step={flow.get('step_id')}")

        # 把测试用的 flow 删掉，别留在配置里。
        if flow.get("flow_id"):
            await call(
                session,
                "DELETE",
                f"/api/config/config_entries/flow/{flow['flow_id']}",
                headers=headers,
            )


asyncio.run(main())
PY

echo "==> no xiaomi_home errors in the log"
if docker logs "$NAME" 2>&1 | grep -iE 'xiaomi_home.*(error|traceback|importerror|exception)'; then
    fail "xiaomi_home errors found in the container log"
fi
echo "    clean"

echo "==> smoke test passed"
