FROM alpine:latest AS downloader
ARG NODEGET_VERSION=0.2.11
ARG TARGETARCH
ARG NODEGET_COMPONENT=nodeget-server

RUN apk add --no-cache curl binutils gcc musl-dev

COPY build-nodeget.sh /tmp/
RUN sh /tmp/build-nodeget.sh

COPY entrypoint.c /tmp/
RUN gcc -static -s -O2 -o /entrypoint /tmp/entrypoint.c && \
    strip --strip-all /entrypoint || true

FROM scratch
ARG NODEGET_COMPONENT=nodeget-server

COPY --from=downloader /usr/bin/nodeget /usr/bin/nodeget
COPY --from=downloader /entrypoint /entrypoint
COPY --from=downloader /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

ENV NODEGET_COMPONENT=$NODEGET_COMPONENT \
    NODEGET_PORT=2211 \
    NODEGET_LOG_FILTER=info \
    NODEGET_CONFIG_PATH=/etc/nodeget/config.toml \
    NODEGET_DATA_DIR=/var/lib/nodeget \
    NODEGET_DATABASE_URL=sqlite:///var/lib/nodeget/nodeget.db?mode=rwc

ENTRYPOINT ["/entrypoint"]
