FROM alpine:latest AS downloader
ARG FRP_VERSION=0.68.1
ARG TARGETARCH
ARG FRP_COMPONENT=frps

RUN apk add --no-cache curl tar

COPY build-frp.sh /tmp/
RUN sh /tmp/build-frp.sh

FROM scratch
COPY --from=downloader /usr/bin/frp /usr/bin/frp
COPY --from=downloader /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENTRYPOINT ["/usr/bin/frp"]
