# syntax=docker/dockerfile:1.7

FROM golang:1.24-alpine AS builder

ARG TARGETOS TARGETARCH TARGETVARIANT
ARG OPENSNELL_VERSION=main
ARG GOARM

RUN apk add --no-cache git ca-certificates gcc musl-dev binutils

WORKDIR /src
RUN git clone --depth 1 --branch "${OPENSNELL_VERSION}" \
    https://github.com/missuo/opensnell.git . && \
    go mod download

RUN <<'SRC'
  set -eu

  case "${TARGETVARIANT}" in
    v7) GOARM=7 ;;
    "") ;;
    *) echo "Unsupported variant: ${TARGETVARIANT}" >&2; exit 1 ;;
  esac

  CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" GOARM="${GOARM:-}" \
    go build -trimpath -ldflags="-s -w -X main.version=${OPENSNELL_VERSION}" \
    -o /out/snell-server ./cmd/snell-server

  strip --strip-all /out/snell-server || true
SRC

COPY entrypoint.c /tmp/
RUN gcc -static -s -O2 -o /entrypoint /tmp/entrypoint.c && \
    strip --strip-all /entrypoint || true

FROM scratch

COPY --from=builder /out/snell-server /usr/local/bin/snell-server
COPY --from=builder /entrypoint /entrypoint
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

ENV SNELL_LISTEN=0.0.0.0:2333 \
    SNELL_PSK="" \
    SNELL_OBFS=off \
    SNELL_UDP=true \
    SNELL_QUIC=true \
    SNELL_IPV6=true \
    SNELL_TFO=false \
    SNELL_CONF=/etc/snell-server/snell-server.conf

EXPOSE 2333/tcp 2333/udp

ENTRYPOINT ["/entrypoint"]
