#!/bin/sh
# 对任意 PostgreSQL 18 + TimescaleDB 镜像做端到端冒烟测试：
#   1) 起容器 -> CREATE EXTENSION timescaledb -> 建 hypertable -> 插入/查询
#   2) 升级回归：把 postgresql.conf 里的 lc_* 与 pg_database.datcollate/datctype
#      改成 'en_US.utf8'（旧 Alpine/musl 镜像 initdb 出来的数据目录就长这样）后重启，
#      必须还能起来并跑排序 —— glibc 底座少了 en_US.utf8 会以
#      `invalid value for parameter "lc_messages"` + `FATAL: configuration file
#      ".../postgresql.conf" contains errors` 反复重启
#   3) 全新 initdb：POSTGRES_INITDB_ARGS="--locale=en_US.UTF-8" 必须成功
#
#   ./smoke-timescaledb.sh ghcr.io/viogus/timescaledb:2.30.0-pg18
#
# 通过 `postgres -c shared_preload_libraries=timescaledb` 启动（TimescaleDB 要求
# 预加载，官方 timescaledb 镜像也是这么配的），不修改镜像内文件。
# musl 底座（Alpine 系）不校验 locale 名，第 2/3 步自动跳过。
set -eu

IMAGE="${1:?用法: $0 <image> [name]}"
NAME="${2:-ts-smoke-$$}"
PGDATA_DIR=/var/lib/postgresql/18/docker   # 两个镜像都用这个 PGDATA

cleanup() {
  docker rm -f "$NAME" "${NAME}-loc" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 等到 psql 能连上；失败就打印日志并返回非零
wait_ready() {
  _name="$1"; _i=0
  printf "[smoke] 等待就绪(%s)" "$_name"
  while [ "$_i" -lt 90 ]; do
    if docker exec "$_name" psql -U postgres -d demo -c 'SELECT 1' >/dev/null 2>&1; then
      echo " OK"
      return 0
    fi
    _i=$((_i + 1))
    if [ "$_i" -eq 90 ]; then
      echo " 超时"
      docker logs "$_name" 2>&1 | tail -30
      return 1
    fi
    sleep 1
  done
}

# run_container <name> [额外的 docker run 参数...]
run_container() {
  _name="$1"; shift
  docker rm -f "$_name" >/dev/null 2>&1 || true
  docker run -d --name "$_name" \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=demo "$@" \
    "$IMAGE" postgres -c shared_preload_libraries=timescaledb >/dev/null
}

echo "[smoke] $IMAGE -> $NAME"
run_container "$NAME"
wait_ready "$NAME"

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

if docker exec "$NAME" sh -c 'ls /lib/ld-musl-*.so.1 >/dev/null 2>&1'; then
  echo "[smoke] musl 底座：跳过 en_US.utf8 升级回归（musl 不做 locale 名校验）"
else
  echo "[smoke] locale -a: $(docker exec "$NAME" locale -a 2>/dev/null | tr '\n' ' ')"
  docker exec "$NAME" locale -a 2>/dev/null | tr -d '\r' | grep -qx 'en_US.utf8' \
    || { echo "[smoke] FAIL: locale -a 里没有 en_US.utf8"; exit 1; }

  # 模拟旧 Alpine/musl 镜像 initdb 出来的数据目录
  echo "[smoke] 升级回归: conf 的 lc_* 与 pg_database.datcollate 改成 en_US.utf8"
  docker exec "$NAME" sed -i \
    "s/^lc_messages = .*/lc_messages = 'en_US.utf8'/;
     s/^lc_monetary = .*/lc_monetary = 'en_US.utf8'/;
     s/^lc_numeric = .*/lc_numeric = 'en_US.utf8'/;
     s/^lc_time = .*/lc_time = 'en_US.utf8'/" "$PGDATA_DIR/postgresql.conf"
  if [ "$(docker exec "$NAME" grep -c en_US.utf8 "$PGDATA_DIR/postgresql.conf" | tr -d ' \r')" -lt 4 ]; then
    docker exec -i "$NAME" sh -c "cat >> $PGDATA_DIR/postgresql.conf" <<'CONF'
lc_messages = 'en_US.utf8'
lc_monetary = 'en_US.utf8'
lc_numeric = 'en_US.utf8'
lc_time = 'en_US.utf8'
CONF
  fi
  psql_ "UPDATE pg_database SET datcollate='en_US.utf8', datctype='en_US.utf8' WHERE datname='demo'" >/dev/null
  docker stop "$NAME" >/dev/null
  docker start "$NAME" >/dev/null
  wait_ready "$NAME" || { echo "[smoke] FAIL: 带 en_US.utf8 的旧数据目录起不来"; exit 1; }
  echo "[smoke] 重启后 lc_messages: $(psql_ 'SHOW lc_messages')"
  echo "[smoke] 重启后 datcollate: $(psql_ "SELECT datcollate FROM pg_database WHERE datname='demo'")"
  # 排序要真的用默认 collation，才能证明 glibc 解析得了 en_US.utf8
  echo "[smoke] 排序检查: $(psql_ "SELECT string_agg(x, ',' ORDER BY x) FROM (VALUES ('b'),('a'),('c')) t(x)")"

  echo "[smoke] 全新 initdb: POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8"
  run_container "${NAME}-loc" -e POSTGRES_INITDB_ARGS=--locale=en_US.UTF-8
  wait_ready "${NAME}-loc" || { echo "[smoke] FAIL: --locale=en_US.UTF-8 的 initdb 失败"; exit 1; }
  echo "[smoke] 新库编码/collate: $(docker exec "${NAME}-loc" psql -U postgres -d demo -tAc 'SHOW server_encoding') / $(docker exec "${NAME}-loc" psql -U postgres -d demo -tAc "SELECT datcollate FROM pg_database WHERE datname='demo'")"
fi

echo "[smoke] PASS"
