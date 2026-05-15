#!/bin/sh
set -eu

case "${TARGETARCH}" in
  amd64) GOARCH=amd64 ;;
  arm64) GOARCH=arm64 ;;
  arm)
    GOARCH=arm
    GOARM="${TARGETVARIANT#v}"
    [ -z "$GOARM" ] && GOARM=7
    ;;
  *)
    echo "Unsupported arch: ${TARGETARCH}" >&2
    exit 1
    ;;
esac

git clone --depth 1 --branch "v${FRP_VERSION}" \
  https://github.com/fatedier/frp.git /src/frp
cd /src/frp

GOOS=linux GOARCH="$GOARCH" GOARM="${GOARM:-}" \
  go build -v -trimpath -ldflags "-s -w" -o /frps ./cmd/frps
GOOS=linux GOARCH="$GOARCH" GOARM="${GOARM:-}" \
  go build -v -trimpath -ldflags "-s -w" -o /frpc ./cmd/frpc
