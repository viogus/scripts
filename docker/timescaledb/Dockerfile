# TimescaleDB full build (Apache core + Timescale License: compression, retention
# policies, continuous aggregates) on Alpine, installed into the official
# postgres:18-alpine image.
#
# Why this image exists:
#   - Timescale's official Docker images are glibc/Debian only (~1 GB unpacked) and
#     ship timescaledb-toolkit. Alpine has no official timescaledb image.
#   - Alpine community `postgresql-timescaledb` is built with -DAPACHE_ONLY=ON, so it
#     LACKS compression and retention policies — the exact features NodeGet needs to
#     cap monitoring-disk growth. See https://pkgs.alpinelinux.org/package/edge/community/
#   - So we compile the upstream default build (which includes the TSL directory) against
#     postgresql18-dev — PostgreSQL 18.6 headers that match the official image bit-for-bit —
#     and drop only the .so/.sql into the official postgres:18-alpine image.
#
# Result: full TimescaleDB functionality (hypertable + zstd compression + retention) at a
# fraction of the official image size (no Debian base, no Rust toolkit — not needed by
# NodeGet). License note: this includes the Timescale Community License parts (free for
# self-hosted use); the Apache-2.0 source lives under apache/, TSL under tsl/ upstream.
#
# Runtime: shared_preload_libraries=timescaledb is required, e.g.
#   command: ["postgres", "-c", "shared_preload_libraries=timescaledb"]
FROM alpine:3.24 AS builder

RUN apk add --no-cache cmake ninja gcc g++ make linux-headers postgresql18-dev openssl-dev ca-certificates

ARG TS_VERSION=2.25.2
RUN wget -qO /tmp/ts.tar.gz https://github.com/timescale/timescaledb/archive/refs/tags/${TS_VERSION}.tar.gz \
 && mkdir -p /tmp/src \
 && tar xzf /tmp/ts.tar.gz -C /tmp/src --strip-components=1

WORKDIR /tmp/src
# Upstream default build includes tsl/ (no -DAPACHE_ONLY): compression + retention enabled.
RUN cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DPG_CONFIG=/usr/bin/pg_config \
      -DREGRESS_CHECKS=OFF -DTAP_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF \
 && cmake --build build \
 && cmake --install build

FROM postgres:18-alpine
# Bridge Alpine-package layout (/usr/lib|share/postgresql18) into the official image
# (compiled PG under /usr/local). Full build splits TSL into a separate
# timescaledb-tsl-<ver>.so, so copy every timescaledb*.so.
COPY --from=builder /usr/lib/postgresql18/timescaledb*.so /usr/local/lib/postgresql/
COPY --from=builder /usr/share/postgresql18/extension/timescaledb.control /usr/share/postgresql18/extension/timescaledb--*.sql /usr/local/share/postgresql/extension/
