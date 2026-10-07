FROM alpine:latest AS builder
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
    && rm -rf /tmp/patches /opt/aimilivpn/.git

FROM alpine:latest
RUN <<'SRC'
  set -eu
  apk add --no-cache \
    openvpn python3 curl ca-certificates iptables iproute2 procps

  # strip unused Python stdlib (~20MB)
  rm -rf /usr/lib/python3.*/{turtledemo,idlelib,test,lib2to3,ensurepip}
  find /usr/lib/python3.* -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
  find /usr/lib/python3.* -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete 2>/dev/null || true

  mkdir -p /opt/aimilivpn/vpngate_data
SRC

COPY --from=builder /opt/aimilivpn /opt/aimilivpn
WORKDIR /opt/aimilivpn

# the patched sources must still be valid Python
RUN python3 -c "import ast, pathlib; ast.parse(pathlib.Path('vpngate_manager.py').read_text(encoding='utf-8'))"

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
