FROM alpine:latest AS downloader
ARG NODEGET_VERSION=0.2.11
ARG TARGETARCH
ARG NODEGET_COMPONENT=nodeget-server

RUN apk add --no-cache curl binutils

COPY build-nodeget.sh /tmp/
RUN sh /tmp/build-nodeget.sh

FROM scratch
COPY --from=downloader /usr/bin/nodeget /usr/bin/nodeget
COPY --from=downloader /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENTRYPOINT ["/usr/bin/nodeget"]
