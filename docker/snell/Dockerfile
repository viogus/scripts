FROM --platform=$BUILDPLATFORM debian:stable-slim AS builder

ARG TARGETARCH TARGETVARIANT
ARG SNELL_VERSION=5.0.1

COPY build-snell.sh /tmp/
RUN sh /tmp/build-snell.sh

FROM busybox:stable-glibc

COPY --from=builder /usr/local/bin/snell-server /usr/local/bin/snell-server
COPY --from=builder /runtime/lib/ /lib/

COPY snell-entrypoint.sh /usr/local/bin/snell-entrypoint.sh
RUN chmod +x /usr/local/bin/snell-entrypoint.sh \
 && mkdir -p /app

ENV PORT=""
ENV PSK=""
ENV OBFS="off"

ENTRYPOINT ["/usr/local/bin/snell-entrypoint.sh"]
