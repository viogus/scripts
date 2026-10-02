#!/bin/sh
# 对任意 PostgreSQL 18 + TimescaleDB 镜像做端到端冒烟测试：
#   起容器 -> CREATE EXTENSION timescaledb -> 建 hypertable -> 插入/查询 -> 打印版本
#
#   ./smoke-timescaledb.sh ghcr.io/viogus/timescaledb:2.30.0-pg18
#
# 通过 `postgres -c shared_preload_libraries=timescaledb` 启动（TimescaleDB 要求
# 预加载，官方 timescaledb 镜像也是这么配的），不修改镜像内文件。
set -eu

IMAGE="${1:?用法: $0 <image> [name]}"
NAME="${2:-ts-smoke-$$}"
PGDATA_DIR=/var/lib/postgresql/18/docker   # 两个镜像都用这个 PGDATA

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker rm -f "$NAME" >/dev/null 2>&1 || true
echo "[smoke] $IMAGE -> $NAME"
docker run -d --name "$NAME" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=demo \
  "$IMAGE" postgres -c shared_preload_libraries=timescaledb >/dev/null

echo -n "[smoke] 等待就绪"
i=0
while [ "$i" -lt 90 ]; do
  if docker exec "$NAME" psql -U postgres -d demo -c 'SELECT 1' >/dev/null 2>&1; then
    echo " OK"
    break
  fi
  i=$((i + 1))
  [ "$i" -eq 90 ] && { echo " 超时"; docker logs "$NAME" 2>&1 | tail -30; exit 1; }
  sleep 1
done

psql_() { docker exec "$NAME" psql -U postgres -d demo -v ON_ERROR_STOP=1 -tAc "$1"; }

echo "[smoke] 服务器版本: $(psql_ 'SHOW server_version')"
echo "[smoke] CREATE EXTENSION timescaledb"
psql_ "CREATE EXTENSION IF NOT EXISTS timescaledb" >/dev/null
echo "[smoke] 扩展: $(psql_ "SELECT extname || ' ' || extversion FROM pg_extension WHERE extname='timescaledb'")"

echo "[smoke] 建 hypertable + 写入 + 查询"
psql_ "CREATE TABLE metrics(ts timestamptz NOT NULL, v double precision)" >/dev/null
psql_ "SELECT create_hypertable('metrics','ts')" >/dev/null
psql_ "INSERT INTO metrics SELECT g, random() FROM generate_series(now() - interval '1 day', now(), interval '1 hour') g" >/dev/null
echo "[smoke] 行数: $(psql_ 'SELECT count(*) FROM metrics')"
echo "[smoke] chunk 数: $(psql_ "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name='metrics'")"
echo "[smoke] 压缩/连续聚合可用性: $(psql_ "SELECT count(*) FROM pg_proc WHERE proname IN ('compress_chunk','add_continuous_aggregate_policy')")"

echo "[smoke] 内置函数 TIMESCALEDB 版本: $(psql_ "SELECT extversion FROM pg_extension WHERE extname='timescaledb'")"
echo "[smoke] PASS"
