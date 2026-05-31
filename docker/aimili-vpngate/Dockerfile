FROM alpine:latest AS builder
RUN apk add --no-cache git \
    && git clone --depth=1 https://github.com/baoweise-bot/aimili-vpngate.git /opt/aimilivpn \
    && rm -rf /opt/aimilivpn/.git

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
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV VPNGATE_DATA_DIR=/opt/aimilivpn/vpngate_data \
    LOCAL_PROXY_HOST=::

EXPOSE 8787 7928
ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "vpngate_manager.py"]
