FROM --platform=$BUILDPLATFORM golang:alpine AS builder
ENV CGO_ENABLED=0

ARG TARGETOS TARGETARCH TARGETVARIANT
ARG FRP_VERSION=0.68.1

WORKDIR /src

RUN apk add --no-cache git

# Cross-compile frp for target architecture
COPY build-frp.sh /tmp/
RUN sh /tmp/build-frp.sh

FROM alpine:latest

COPY --from=builder /frps /frpc /usr/bin/
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

RUN mkdir -p /etc/frp

ENTRYPOINT ["/usr/bin/frps", "-c", "/etc/frp/frps.toml"]
