FROM alpine:latest AS downloader
ARG FRP_VERSION
ARG TARGETARCH
ARG FRP_COMPONENT=frps

RUN apk add --no-cache curl tar binutils gcc musl-dev

COPY build-frp.sh /tmp/
RUN sh /tmp/build-frp.sh

COPY entrypoint.c /tmp/
RUN gcc -static -s -O2 -DFRP_MODE=\"${FRP_COMPONENT}\" -o /entrypoint /tmp/entrypoint.c && \
    strip --strip-all /entrypoint || echo "WARN: strip entrypoint failed" >&2

FROM scratch
COPY --from=downloader /usr/bin/frp /usr/bin/frp
COPY --from=downloader /entrypoint /entrypoint
ENV FRP_CONF=/app/frp.toml
ENTRYPOINT ["/entrypoint"]
