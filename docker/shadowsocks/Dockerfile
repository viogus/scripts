# shadowsocks-rust server on a scratch base: 4.1 MB compressed instead of the
# upstream image's 8.1 MB (and ~8.4 MB unpacked, of which 8.3 MB is the binary
# itself), with no OS packages at all.
#
# Why: the upstream Alpine image's only runtime payload is a statically linked
# `ssserver` (ELF, statically linked, stripped); the rest is an Alpine userland
# upstream has not rebuilt since 2026-08-26 -- it still ships openssl 3.5.7-r0 /
# zlib 1.3.2-r0, i.e. 21 fixable Trivy findings (CVE-2026-14456 high) that
# `docker pull` cannot fix. Copying that one binary onto an empty base removes
# the packages, the CVEs and ~4 MB of image.
#
# No shell, no libc, no package manager, no timezone data: log timestamps are
# UTC, exactly as they were in the upstream image (pass `--log-without-time`
# if you would rather not print them at all).
#
# Build (multi-arch, push straight to GHCR):
#   docker buildx build --platform linux/arm64,linux/amd64 \
#     -t ghcr.io/viogus/shadowsocks-server-rust:latest --push .

# Upstream publish. Everything below is copied out of it, so a rebuild follows
# the upstream binary automatically, and moving /usr/bin/ssserver fails loudly.
FROM ghcr.io/shadowsocks/ssserver-rust:latest AS upstream

FROM scratch
COPY --from=upstream /usr/bin/ssserver /usr/bin/ssserver
# upstream's own passwd, so its `-a nobody` default keeps working
COPY --from=upstream /etc/passwd /etc/passwd
COPY --from=upstream /etc/shadowsocks-rust/config.json /etc/shadowsocks-rust/config.json

# The entrypoint takes flags directly (no shell, no legacy `ssserver` prefix):
#   docker run ... <image> -U -s 0.0.0.0:24000 -m chacha20-ietf-poly1305 -k ...
ENTRYPOINT ["/usr/bin/ssserver"]
CMD ["-c", "/etc/shadowsocks-rust/config.json"]
