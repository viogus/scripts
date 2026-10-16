# Our own shadowsocks-rust image: upstream image + current Alpine security packages.
#
# Why: upstream ghcr.io/shadowsocks/ssserver-rust:latest (shadowsocks-rust 1.25.0)
# was last built 2026-08-26 on Alpine 3.24.1 and still ships openssl 3.5.7-r0 and
# zlib 1.3.2-r0, which Trivy reports as 21 fixable findings (CVE-2026-14456 high
# on libcrypto3/libssl3, CVE-2026-63072 / 63076 / 18798 / 85091 medium, ...).
# Upstream has not rebuilt since (arm64 manifest digest still
# sha256:22240c07d8ce3a36421ede770bd775dcc5fc56d5d829943196957b05452dc36f),
# so `docker pull` cannot fix it -- we republish with the fixed packages instead.
#
# Build (multi-arch, push straight to GHCR):
#   docker buildx build --platform linux/arm64,linux/amd64 \
#     -t ghcr.io/viogus/shadowsocks-server-rust:latest \
#     -t ghcr.io/viogus/shadowsocks-server-rust:1.25.0 --push .
#
# Keep the upstream tag unpinned so a rebuild picks up new shadowsocks-rust
# binaries automatically; `apk upgrade` then only refreshes the OS packages.
FROM ghcr.io/shadowsocks/ssserver-rust:latest

# openssl 3.5.7-r0 -> 3.5.9-r0 (fixes the high CVE), zlib 1.3.2-r0 -> 1.3.2-r1
# (from the Alpine v3.24 repos; the base image was built from 3.24.1).
RUN apk upgrade --no-cache
