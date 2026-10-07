# ---- build stage: fetch upstream and apply our patches ----------------------
FROM alpine:3.24 AS builder
# Upstream tag/branch to build; pin a release tag to freeze the base revision.
ARG UPSTREAM_REF=main
COPY patches/ /tmp/patches/
RUN apk add --no-cache git patch \
    && git clone --depth=1 --branch "$UPSTREAM_REF" https://github.com/OpenMili/aimili-vpngate.git /opt/aimilivpn \
    && cd /opt/aimilivpn \
    && for patch_file in /tmp/patches/*.patch; do \
           echo ">>> applying $(basename "$patch_file")"; \
           git apply -p1 --whitespace=nowarn "$patch_file" \
               || { echo "!!! $(basename "$patch_file") no longer applies - upstream changed, rebase it in patches/"; exit 1; }; \
       done \
    && rm -rf /tmp/patches /opt/aimilivpn/.git \
    && rm -rf /opt/aimilivpn/.github /opt/aimilivpn/.gitignore /opt/aimilivpn/.dockerignore \
              /opt/aimilivpn/docs /opt/aimilivpn/tests /opt/aimilivpn/scripts \
              /opt/aimilivpn/install.sh /opt/aimilivpn/README.md /opt/aimilivpn/RELEASE_NOTES.md \
              /opt/aimilivpn/compose.yaml /opt/aimilivpn/Dockerfile
# kept on purpose: *.py, VERSION, LICENSE and mirror/ (offline node fallback,
# BUNDLED_SNAPSHOT_FILE in vpngate_manager.py).

# ---- runtime stage ----------------------------------------------------------
FROM alpine:3.24
# Packages intentionally NOT installed (checked against the upstream sources):
#   iptables  - only used by `iptables -S` inside an advisory VPS self-check that
#               is wrapped in try/except; the package is 7.8 MB of xtables exts
#   procps-ng - everything needed (sysctl) already comes from busybox
#   iproute2  - openvpn depends on iproute2-minimal, which ships /sbin/ip
RUN <<'SRC'
  set -eu
  apk add --no-cache \
    openvpn python3 ca-certificates-bundle iproute2-minimal

  # Trim the Python stdlib: nothing in *.py imports these (module list checked
  # via `grep -hE '^(import|from)' *.py`: base64 collections concurrent csv
  # hashlib http io json os pathlib queue re secrets select shlex signal socket
  # subprocess sys threading time typing urllib uuid + local modules; http/urllib
  # pull in email.*, so email must stay).
  # NOTE: /bin/sh is busybox ash and does NOT expand {...} - list paths apart.
  # NOTE: every removal below must stay in THIS RUN layer - deleting files in a
  # later layer does not shrink the image, the bytes stay in the earlier layer.
  for py in /usr/lib/python3.*; do
    rm -rf \
      "$py/ensurepip" "$py/pydoc_data" "$py/unittest" "$py/asyncio" \
      "$py/multiprocessing" "$py/turtledemo" "$py/turtle.py" \
      "$py/_pydecimal.py" "$py/xml" "$py/dbm" "$py/curses" "$py/sqlite3" \
      "$py/zoneinfo"
    rm -rf "$py"/config-*
    rm -f "$py"/lib-dynload/_test*.so "$py"/lib-dynload/_ctypes_test*.so \
          "$py"/lib-dynload/_curses*.so "$py"/lib-dynload/readline*.so \
          "$py"/lib-dynload/_sqlite3*.so "$py"/lib-dynload/_dbm*.so \
          "$py"/lib-dynload/_gdbm*.so "$py"/lib-dynload/pyexpat*.so
    # C accelerators of modules the app never imports, nor any stdlib module it
    # does import (~2.4 MB): decimal/bz2/lzma/elementtree/zoneinfo/asyncio/
    # multiprocessing/cProfile/statistics/audioop/_crypt + test helpers.
    rm -f "$py"/lib-dynload/_decimal*.so "$py"/lib-dynload/_bz2*.so \
          "$py"/lib-dynload/_lzma*.so "$py"/lib-dynload/_elementtree*.so \
          "$py"/lib-dynload/_zoneinfo*.so "$py"/lib-dynload/_asyncio*.so \
          "$py"/lib-dynload/_multiprocessing*.so "$py"/lib-dynload/_posixshmem*.so \
          "$py"/lib-dynload/_lsprof*.so "$py"/lib-dynload/_statistics*.so \
          "$py"/lib-dynload/_remote_debugging*.so "$py"/lib-dynload/_interp*.so \
          "$py"/lib-dynload/xxlimited*.so "$py"/lib-dynload/xxsubtype*.so \
          "$py"/lib-dynload/_xxtestfuzz*.so "$py"/lib-dynload/audioop*.so \
          "$py"/lib-dynload/_crypt*.so \
          "$py"/lib-dynload/_codecs_jp*.so "$py"/lib-dynload/_codecs_cn*.so \
          "$py"/lib-dynload/_codecs_hk*.so "$py"/lib-dynload/_codecs_kr*.so \
          "$py"/lib-dynload/_codecs_tw*.so "$py"/lib-dynload/_codecs_iso2022*.so \
          "$py"/lib-dynload/_multibytecodec*.so
    # legacy/CJK text codecs (~1.1 MB): the app only decodes as UTF-8
    # (22x encoding="utf-8" and no other encoding in the sources).
    rm -f "$py"/encodings/big5*.py* "$py"/encodings/cp*.py* \
          "$py"/encodings/euc*.py* "$py"/encodings/gb*.py* \
          "$py"/encodings/hz.py* "$py"/encodings/iso2022*.py* \
          "$py"/encodings/johab.py* "$py"/encodings/koi8*.py* \
          "$py"/encodings/kz1048.py* "$py"/encodings/shift_jis*.py* \
          "$py"/encodings/tis_620.py*
    find "$py" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
    find "$py" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true
  done
  # shared objects whose only consumers were removed above (~3.7 MB). Verified
  # with `scanelf -R -F "%F: %n" /usr /bin /sbin /lib`: libbz2/libffi/libexpat/
  # libgdbm/libmpdec* only serve the deleted C accelerators and libstdc++ only
  # serves libmpdec++; libncursesw's only users were the procps tools we skip.
  # libelf is deliberately NOT removed - /sbin/ip (iproute2-minimal) needs it.
  rm -f /usr/lib/libsqlite3.so.* /usr/lib/libreadline.so.* \
        /usr/lib/libncursesw.so.* /usr/lib/libpanelw.so.* \
        /usr/lib/libbz2.so.* /usr/lib/liblzma.so.* /usr/lib/libffi.so.* \
        /usr/lib/libexpat.so.* /usr/lib/libgdbm*.so.* \
        /usr/lib/libmpdec*.so.* /usr/lib/libstdc++.so.*

  # curl and its private https stack (~4.6 MB): patch 0003 replaces the only
  # curl call site (the exit-IP probe in check_proxy_health) with a stdlib
  # SOCKS5 client, so /usr/bin/curl is dead weight. `apk` was verified not to
  # link libcurl (it uses its own HTTP client); libzstd is kept because
  # /sbin/ip needs libelf, which needs libzstd.
  rm -f /usr/bin/curl /usr/lib/libcurl.so.* /usr/lib/libbrotlienc.so.* \
        /usr/lib/libbrotlidec.so.* /usr/lib/libbrotlicommon.so.* \
        /usr/lib/libcares.so.* /usr/lib/libidn2.so.* /usr/lib/libpsl.so.* \
        /usr/lib/libunistring.so.* /usr/lib/libnghttp2.so.*

  mkdir -p /opt/aimilivpn/vpngate_data
SRC

COPY --from=builder /opt/aimilivpn /opt/aimilivpn
WORKDIR /opt/aimilivpn

# the patched sources must still be valid Python (-B keeps __pycache__ out)
RUN python3 -B -c "import ast, pathlib; [ast.parse(p.read_text(encoding='utf-8')) for p in pathlib.Path('.').glob('*.py')]"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV VPNGATE_DATA_DIR=/opt/aimilivpn/vpngate_data \
    LOCAL_PROXY_HOST=:: \
    DEPLOYMENT_MODE=docker \
    PYTHONUNBUFFERED=1 \
    VPNGATE_LOG_MAX_BYTES=16777216 \
    VPNGATE_LOG_BACKUP_COUNT=3

EXPOSE 8787 7928
ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "vpngate_manager.py"]
