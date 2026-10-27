#!/usr/bin/env bash
# 冒烟测试：把镜像真跑起来，确认这些事
#   1. 配置目录跟随 HA 惯例 `/config`，并且 `/data` 软链到同一份数据（老用法兼容）；
#   2. entrypoint 把预装的 custom_components 播种进了挂载的配置目录；
#   3. HA 的 default_config 不再因为缺 Python 包而 setup 失败
#      （go2rtc 例外：官方 core 镜像同样没有它的二进制）；
#   4. xiaomi_home 被 HA 真正注册：flow_handlers 里有它，并且能起一个 config flow；
#   5. 前端首屏用的 websocket 命令（manifest/list、get_panels、
#      config_entries/subscribe）都能正常返回 —— 上一版只看 REST，前端转圈就发现不了。
#
# 用法: smoke-test.sh <image-ref> [expected-xiaomi-version]
set -euo pipefail

IMAGE="${1:?usage: smoke-test.sh <image-ref> [expected-xiaomi-version]}"
WANT_XM="${2:-}"
SLIM="${SMOKE_SLIM:-0}"
NAME="hass-smoke-$$"
PORT="${SMOKE_PORT:-18123}"
DATA="$(mktemp -d)"

cleanup() {
    # 收尾失败不该把整个测试判成红的
    set +e
    docker rm -f "$NAME" >/dev/null 2>&1
    if [ -d "$DATA" ]; then
        # HA 在容器里以 root 跑，bind mount 出来的文件属于 root：Linux runner 上
        # 宿主机用户直接 rm 会 permission denied，所以借镜像自己（root）清空。
        docker run --rm -v "$DATA:/config" --entrypoint sh "$IMAGE" \
            -c 'rm -rf /config/* /config/.[!.]* /config/..?*' >/dev/null 2>&1
        rm -rf "$DATA" >/dev/null 2>&1
    fi
    set -e
}
trap cleanup EXIT

fail() {
    echo "!! $*" >&2
    echo "=== container logs (tail) ===" >&2
    docker logs --tail 150 "$NAME" >&2 || true
    exit 1
}

echo "==> starting $IMAGE  (config dir: $DATA -> /config, port: $PORT)"
docker run -d --name "$NAME" -p "${PORT}:8123" -v "$DATA:/config" "$IMAGE" >/dev/null

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

echo "==> config dir is /config and /data points at the same place"
docker logs "$NAME" 2>&1 | grep -q "config dir: /config" \
    || fail "entrypoint did not pick /config as the config dir"
[ "$(docker exec "$NAME" readlink /data)" = "/config" ] \
    || fail "/data is not linked to /config"

if [ "$SLIM" = "1" ]; then
    echo "==> slim: seeded configuration.yaml without default_config"
    docker exec "$NAME" test -f /config/configuration.yaml \
        || fail "slim image did not seed configuration.yaml"
    docker exec "$NAME" grep -q "^history:" /config/configuration.yaml \
        || fail "slim configuration.yaml missing history:"
    if docker exec "$NAME" grep -q "^default_config:" /config/configuration.yaml; then
        fail "slim configuration.yaml still contains default_config:"
    fi
fi

echo "==> custom components were seeded into the mounted config dir"
docker exec "$NAME" test -f /config/custom_components/xiaomi_home/manifest.json \
    || fail "custom_components/xiaomi_home/manifest.json missing in /config"
docker exec "$NAME" test -f /data/custom_components/xiaomi_home/manifest.json \
    || fail "/data did not resolve to the same config dir"

GOT_XM=$(docker exec "$NAME" python3 -c \
    'import json;print(json.load(open("/config/custom_components/xiaomi_home/manifest.json"))["version"])')
echo "    integration manifest version: $GOT_XM"
if [ -n "$WANT_XM" ] && [ "${GOT_XM#v}" != "${WANT_XM#v}" ]; then
    fail "integration version mismatch: want $WANT_XM, got $GOT_XM"
fi

echo "==> integration requirements importable in the image"
docker exec "$NAME" python3 -c \
    'import construct, paho.mqtt.client, haffmpeg, numpy, cryptography, psutil; print("    deps ok")' \
    || fail "cannot import one of construct / paho.mqtt / haffmpeg / numpy / cryptography / psutil"

echo "==> default_config did not fail on missing packages"
# go2rtc 是唯一允许的例外：官方 core 镜像同样没有 go2rtc 二进制。
BAD=$(docker logs "$NAME" 2>&1 | grep -E "Setup failed for '" | grep -v "go2rtc" || true)
if [ -n "$BAD" ]; then
    echo "$BAD" >&2
    fail "integrations failed to set up (missing packages?)"
fi
if docker logs "$NAME" 2>&1 | grep -E "No module named '"; then
    fail "missing Python modules in the image"
fi

echo "==> xiaomi_home registered; frontend websocket commands work"
# 容器内监听 8123；宿主机映射到 $PORT。
docker exec -i "$NAME" python3 - 8123 "$SLIM" <<'PY' || fail "integration or frontend websocket check failed"
import asyncio
import json
import sys

import aiohttp

PORT = sys.argv[1] if len(sys.argv) > 1 else "8123"
SLIM = len(sys.argv) > 2 and sys.argv[2] == "1"
BASE = f"http://127.0.0.1:{PORT}"
CLIENT_ID = f"{BASE}/"


async def call(session, method, path, **kwargs):
    async with session.request(method, BASE + path, **kwargs) as resp:
        try:
            body = await resp.json()
        except Exception:  # noqa: BLE001
            body = await resp.text()
        if resp.status >= 400:
            raise SystemExit(f"{method} {path} -> {resp.status}: {body}")
        return body


async def main():
    async with aiohttp.ClientSession() as session:
        async with session.get(BASE + "/") as resp:
            if resp.status != 200:
                raise SystemExit(f"GET / -> {resp.status}")
            html = await resp.text()
            print(f"    GET / -> 200 ({len(html)} bytes)")

        # 全新配置目录 → onboarding 拿 token
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
        if flow.get("flow_id"):
            await call(
                session,
                "DELETE",
                f"/api/config/config_entries/flow/{flow['flow_id']}",
                headers=headers,
            )

        # 前端首屏会发的几条 websocket 命令
        async with session.ws_connect(f"{BASE}/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": token["access_token"]})
            auth = await ws.receive_json()
            if auth.get("type") != "auth_ok":
                raise SystemExit(f"ws auth failed: {auth}")

            if SLIM:
                from_slim_panels = set()
                await ws.send_json({"id": 90, "type": "get_panels"})
                res = await ws.receive_json()
                if res.get("success"):
                    from_slim_panels = set(res["result"])
                missing = {"history", "logbook", "energy"} - from_slim_panels
                if missing:
                    raise SystemExit(f"slim panels missing: {sorted(missing)}")
                print(f"    slim panels ok ({len(from_slim_panels)} panels)")

                await ws.send_json({"id": 91, "type": "get_states"})
                res = await ws.receive_json()
                if not res.get("success") or not any(
                    s.get("entity_id") == "sun.sun" for s in res["result"]
                ):
                    raise SystemExit("slim: sun.sun missing (configuration.yaml?)")
                print("    slim sun.sun present")

            commands = [
                ("manifest/list", {"type": "manifest/list"}),
                ("get_panels", {"type": "get_panels"}),
                ("config_entries/subscribe", {"type": "config_entries/subscribe"}),
            ]
            first_id = 100 if SLIM else 1
            for i, (name, payload) in enumerate(commands, start=first_id):
                await ws.send_json({"id": i, **payload})
                res = await ws.receive_json()
                if not res.get("success"):
                    raise SystemExit(f"ws {name} failed: {json.dumps(res.get('error'))}")
                if name == "manifest/list":
                    print(f"    ws manifest/list -> {len(res['result'])} integrations")
                else:
                    print(f"    ws {name} -> ok")


asyncio.run(main())
PY

echo "==> smoke test passed"
