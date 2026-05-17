FROM alpine:latest AS downloader
ARG NODEGET_VERSION=0.2.11
ARG TARGETARCH
ARG NODEGET_COMPONENT=nodeget-server

RUN apk add --no-cache curl binutils

COPY build-nodeget.sh /tmp/
RUN sh /tmp/build-nodeget.sh

FROM alpine:latest
ARG NODEGET_COMPONENT=nodeget-server

COPY --from=downloader /usr/bin/nodeget /usr/bin/nodeget
COPY entrypoint.sh /entrypoint.sh

ENV NODEGET_PORT=2211 \
    NODEGET_LOG_FILTER=info \
    NODEGET_CONFIG_PATH=/etc/nodeget/config.toml \
    NODEGET_DATABASE_URL=sqlite:///var/lib/nodeget/nodeget.db?mode=rwc

RUN mkdir -p /etc/nodeget /var/lib/nodeget && \
    chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
