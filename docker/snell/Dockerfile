FROM --platform=$BUILDPLATFORM alpine:latest AS downloader

ARG TARGETARCH TARGETVARIANT
ARG SNELL_VERSION=5.0.1

RUN apk add --no-cache curl unzip

COPY build-snell.sh /tmp/
RUN sh /tmp/build-snell.sh

FROM scratch

COPY --from=downloader /usr/local/bin/snell-server /usr/local/bin/snell-server

ENTRYPOINT ["/usr/local/bin/snell-server"]
CMD ["-c", "/app/snell-server.conf"]
