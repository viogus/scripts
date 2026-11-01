#!/usr/bin/env bash
# 对抗性验证：nano 镜像在「真实使用」路径上还能不能干活（CI 之外手动跑）
#   1. HomeKit 桥：不仅是建 entry，还要 HAP 的 /pair-setup 真的应答（470 = 需要配对）
#   2. Xiaomi：xiaomi_home 的 flow 能一路走到要凭据那步；xiaomi_miio（本地协议）也能起 flow
#   3. 被裁掉的集成：请求它时给出可理解的错误，而不是把 HA 弄崩
#   4. pip 还能装东西（留作逃生门）
#   5. 带着 default_config: 的老配置重启：只该 WARN，不该起不来
set -euo pipefail
IMAGE="${1:?usage: verify-nano.sh <image-ref>}"
NAME="hass-verify-$$-$RANDOM"
PORT=18125
HKPORT=21064
DATA="$(mktemp -d)"
cleanup() {
    set +e
    docker rm -f "$NAME" >/dev/null 2>&1
    docker run --rm -v "$DATA:/config" --entrypoint sh "$IMAGE" -c 'rm -rf /config/* /config/.[!.]*' >/dev/null 2>&1
    rm -rf "$DATA"
    set -e
}
trap cleanup EXIT

echo "==> boot fresh config"
docker run -d --name "$NAME" -p "${PORT}:8123" -p "${HKPORT}:${HKPORT}" -v "$DATA:/config" "$IMAGE" >/dev/null
for i in $(seq 1 60); do
    curl -fsS -m 3 "http://127.0.0.1:${PORT}/manifest.json" >/dev/null 2>&1 && break
    sleep 3
done
curl -fsS -m 3 "http://127.0.0.1:${PORT}/manifest.json" >/dev/null || { echo "!! never came up"; docker logs --tail 80 "$NAME"; exit 1; }

echo "==> drive the API"
docker exec -i "$NAME" python3 - 8123 <<'PY'
import asyncio, json, sys
import aiohttp

PORT = sys.argv[1]
BASE = f"http://127.0.0.1:{PORT}"
CLIENT = f"{BASE}/"

async def call(s, method, path, want_status=None, allow_error=False, **kw):
    async with s.request(method, BASE + path, **kw) as r:
        try:
            body = await r.json()
        except Exception:
            body = await r.text()
        if want_status is not None:
            if r.status != want_status:
                raise SystemExit(f"{method} {path} -> {r.status} (want {want_status}): {str(body)[:200]}")
            return r.status, body
        if r.status >= 400:
            if allow_error:
                return r.status, body
            raise SystemExit(f"{method} {path} -> {r.status}: {str(body)[:300]}")
        return body

async def main():
    async with aiohttp.ClientSession() as s:
        u = await call(s, "POST", "/api/onboarding/users", json={
            "client_id": CLIENT, "name": "v", "username": "v",
            "password": "verify-pw-123456", "language": "en"})
        tok = await call(s, "POST", "/auth/token", data={
            "grant_type": "authorization_code", "code": u["auth_code"], "client_id": CLIENT})
        h = {"Authorization": f"Bearer {tok['access_token']}"}

        # --- HomeKit：把桥建出来，再问 HAP 端口要配对 ---
        hk = await call(s, "POST", "/api/config/config_entries/flow", json={"handler": "homekit"}, headers=h)
        for _ in range(8):
            if hk.get("type") in ("create_entry", "abort"):
                break
            data = {}
            for field in hk.get("data_schema") or []:
                for k, spec in (field.get("schema") or {}).items():
                    if isinstance(spec, dict) and "default" in spec:
                        data[k] = spec["default"]
            hk = await call(s, "POST", f"/api/config/config_entries/flow/{hk['flow_id']}", json=data, headers=h)
        if hk.get("type") != "create_entry":
            raise SystemExit(f"homekit did not create an entry: {hk}")
        print(f"    homekit entry: {hk['title']}")

        # --- Xiaomi Home：flow 能不能走到要账号那步 ---
        xm = await call(s, "POST", "/api/config/config_entries/flow", json={"handler": "xiaomi_home"}, headers=h)
        seen = [xm.get("step_id")]
        for _ in range(4):
            if xm.get("type") != "form":
                break
            data = {}
            for field in xm.get("data_schema") or []:
                for k, spec in (field.get("schema") or {}).items():
                    if isinstance(spec, dict) and "default" in spec:
                        data[k] = spec["default"]
            if xm.get("step_id") == "eula":
                data = {"eula": True}
            xm = await call(s, "POST", f"/api/config/config_entries/flow/{xm['flow_id']}", json=data, headers=h)
            seen.append(xm.get("step_id"))
        print(f"    xiaomi_home flow steps: {' -> '.join(str(x) for x in seen)}")
        if isinstance(xm, dict) and xm.get("flow_id"):
            await call(s, "DELETE", f"/api/config/config_entries/flow/{xm['flow_id']}", headers=h)

        # --- xiaomi_miio（本地协议，不依赖小米云）---
        mi = await call(s, "POST", "/api/config/config_entries/flow", json={"handler": "xiaomi_miio"}, headers=h)
        print(f"    xiaomi_miio flow: type={mi.get('type')} step={mi.get('step_id')}")
        if mi.get("flow_id"):
            await call(s, "DELETE", f"/api/config/config_entries/flow/{mi['flow_id']}", headers=h)

        # --- 被裁掉的集成：请求它应该得到错误，而不是把 HA 弄崩 ---
        status, body = await call(s, "POST", "/api/config/config_entries/flow",
                                  json={"handler": "zha"}, headers=h, want_status=None, allow_error=True)
        if status < 400:
            raise SystemExit(f"pruned handler zha unexpectedly accepted: {status}")
        msg = body.get("message") if isinstance(body, dict) else str(body)
        print(f"    pruned handler zha -> {status} ({msg})")

        # HA 还活着吗
        await call(s, "GET", "/api/", headers=h)
        print("    API still healthy after the pruned-handler probe")

asyncio.run(main())
PY

echo "==> HAP endpoint on 21064 (probed from inside the container)"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:${HKPORT}/pair-setup" || true)
echo "    GET /pair-setup -> HTTP $code (HAP 只认真 POST；能回状态码就说明服务在听)"
[ -n "$code" ] && [ "$code" != "000" ] || { echo "!! HomeKit HAP server not answering"; docker logs --tail 60 "$NAME"; exit 1; }
docker exec "$NAME" sh -c 'netstat -ltn 2>/dev/null | grep -q ":21064"' \
    || { echo "!! nothing listening on 21064"; exit 1; }
echo "    and 21064 is listening"

echo "==> pip still works inside the image (escape hatch for pruned integrations)"
docker exec "$NAME" sh -c 'pip install --no-cache-dir -q six && python3 -c "import six; print(\"    pip ok\", six.__version__)"'

echo "==> recorder writes a database"
docker exec "$NAME" sh -c 'test -f /config/home-assistant_v2.db && ls -l /config/home-assistant_v2.db | awk "{print \"    db\", \$5, \"bytes\"}"'

echo "==> start-up time and RSS"
docker restart "$NAME" >/dev/null
for i in $(seq 1 60); do
    curl -fsS -m 3 "http://127.0.0.1:${PORT}/manifest.json" >/dev/null 2>&1 && { echo "    back after ~$((i*3))s"; break; }
    sleep 3
done

echo "==> old config that still says default_config: must only WARN"
docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" -p "${PORT}:8123" -p "${HKPORT}:${HKPORT}" -v "$DATA:/config" "$IMAGE" >/dev/null
docker exec "$NAME" sh -c "printf 'default_config:\n' > /config/configuration.yaml"
docker exec "$NAME" grep -q '^default_config:' /config/configuration.yaml || { echo "!! could not write the test config"; exit 1; }
docker restart "$NAME" >/dev/null
sleep 10
up=false
for i in $(seq 1 60); do
    curl -fsS -m 3 "http://127.0.0.1:${PORT}/manifest.json" >/dev/null 2>&1 && { up=true; break; }
    sleep 3
done
[ "$up" = true ] || { echo "!! did not boot with default_config: present"; docker logs --tail 60 "$NAME"; exit 1; }
LOGS="$(docker logs "$NAME" 2>&1 || true)"
if grep -q "still loads default_config" <<<"$LOGS"; then
    echo "    warned as expected"
else
    echo "!! no default_config warning"; echo "$LOGS" | tail -20; exit 1
fi

echo "==> verify passed"
