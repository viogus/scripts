# Docker Image Size Optimization — Snell & FRP

Status: PARTIALLY IMPLEMENTED (2026-05-28 last update)

## Snell

### Done

1. **glibc stub symlinks** — `libdl.so.2` and `libpthread.so.0` are symlinked to `libc.so.6` in runtime stage. These libs were merged into libc on glibc 2.34+, so stubs satisfy the linker without copying real .so files.

2. **Verification** — `ldd` check after library copy fails build if any dep unresolved.

3. **busybox removed** — entrypoint rewritten in C (`entrypoint.c`), compiled statically. Eliminates busybox (~1MB) from final image.

4. **FROM scratch** — final stage is `FROM scratch`, no base image overhead.

### NOT done (de-prioritized)

1. **ldd-based lib discovery** — lib list is still hardcoded (4 libraries: libc, libm, libstdc++, libgcc_s). ldd-based discovery was reverted because snell v5 binary is fully statically linked — confirmed by [opensnell](https://github.com/missuo/opensnell) analysis: libuv and OpenSSL are compiled in, section headers stripped. ldd outputs nothing for a static binary, so it can't drive library discovery.

2. **strip --strip-all on snell-server** — snell binary is distributed pre-stripped by Surge. Running strip on an already-stripped binary is a no-op.

### Current size: ~9.7MB

---

## FRP

### Done

1. **strip binary** — `strip --strip-all /usr/bin/frp` in `build-frp.sh`. Go release binaries include DWARF debug data; stripping removes it.

2. **UPX compression** — `upx --best --lzma /usr/bin/frp`. Further compresses the Go binary (~12MB stripped → ~5MB).

3. **entrypoint + config generation** — full C entrypoint (`entrypoint.c`) supports env-var-based auto-config for both frps and frpc:

   **frps** env vars: `FRP_BIND_ADDR`, `FRP_BIND_PORT`, `FRP_AUTH_TOKEN`, `FRP_DASHBOARD_PORT`, `FRP_DASHBOARD_ADDR`, `FRP_DASHBOARD_USER`, `FRP_DASHBOARD_PWD`, `FRP_SUBDOMAIN_HOST`, `FRP_TLS_CERT_FILE`, `FRP_TLS_KEY_FILE`

   **frpc** env vars: `FRP_SERVER_ADDR`, `FRP_SERVER_PORT`, `FRP_AUTH_TOKEN`, `FRP_TUNNEL_NAME`, `FRP_TUNNEL_LOCAL_PORT`, `FRP_TUNNEL_REMOTE_PORT`, `FRP_TUNNEL_TYPE`, `FRP_TUNNEL_LOCAL_IP`, `FRP_TUNNEL_BANDWIDTH_LIMIT`

   Auto-generates `/app/frp.toml` when no config file is mounted. Passes through `-h`/`--help`/`--version` directly to frp binary. Respects user-supplied `-c`/`--config` flags.

4. **FROM scratch** — final stage is `FROM scratch` with only the binary, entrypoint, and ca-certificates.

5. **multi-arch** — amd64, arm64, armv7 via `TARGETARCH`/`TARGETVARIANT`.

### Current size: ~5MB (frps with UPX)

---

## Files changed

| File | Changes |
|------|---------|
| `docker/snell/Dockerfile` | Dynamic linker logic, libc stub symlinks, C entrypoint build |
| `docker/snell/entrypoint.c` | New — C entrypoint replacing busybox shell script |
| `docker/frp/Dockerfile` | UPX compression, C entrypoint build |
| `docker/frp/build-frp.sh` | strip step, retry download logic |
| `docker/frp/entrypoint.c` | New — full C entrypoint with frps/frpc config generation |
