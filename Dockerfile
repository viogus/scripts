FROM --platform=$BUILDPLATFORM golang:alpine AS builder
ENV CGO_ENABLED=0

ARG TARGETOS TARGETARCH TARGETVARIANT
ARG FRP_VERSION=0.68.1

WORKDIR /src

RUN apk add --no-cache git

RUN <<SETUP
  set -eu
  case "${TARGETARCH}" in
    amd64) GOARCH=amd64 ;;
    arm64) GOARCH=arm64 ;;
    arm)   GOARCH=arm
           GOARM=${TARGETVARIANT#v}
           : ${GOARM:=7} ;;
    *)     echo "Unsupported arch: ${TARGETARCH}"; exit 1 ;;
  esac

  git clone --depth 1 --branch "v${FRP_VERSION}" \
    https://github.com/fatedier/frp.git /src/frp
  cd /src/frp

  GOOS=linux GOARCH=$GOARCH GOARM=${GOARM:-} \
    go build -v -trimpath -ldflags "-s -w" -o /frps ./cmd/frps
  GOOS=linux GOARCH=$GOARCH GOARM=${GOARM:-} \
    go build -v -trimpath -ldflags "-s -w" -o /frpc ./cmd/frpc
SETUP

FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /frps /frpc /usr/bin/

ENTRYPOINT ["/usr/bin/frps", "-c", "/etc/frp/frps.toml"]
