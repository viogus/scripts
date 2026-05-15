FROM alpine:latest

ARG FRP_VERSION=0.68.1
ARG TARGETARCH

RUN apk add --no-cache curl tar

COPY build-frp.sh /tmp/
RUN sh /tmp/build-frp.sh

ENTRYPOINT ["/usr/bin/frps", "-c", "/etc/frp/frps.toml"]
