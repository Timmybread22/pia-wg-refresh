FROM ghcr.io/ccarpinteri/pia-wg-config:v1.5.0 AS pia

FROM alpine:3.20

# wireguard-tools-wg, iproute2 and jq are for REGION_SELECT=fastest (speedtest.sh, server list parsing)
RUN apk add --no-cache ca-certificates docker-cli curl jq iproute2 wireguard-tools-wg

# Pin compose to the host's version so config hashes match the host's `docker compose`.
# Alpine 3.20's docker-cli-compose is 2.27.0, which hashes services differently and made
# the watchdog recreate (and kill) itself via gluetun's depends_on.
ARG COMPOSE_VERSION=5.1.3
ARG TARGETARCH
RUN case "$TARGETARCH" in arm64) a=aarch64;; amd64) a=x86_64;; *) echo "unsupported arch $TARGETARCH" >&2; exit 1;; esac \
 && mkdir -p /usr/local/lib/docker/cli-plugins \
 && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${a}" \
 && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
 && docker compose version

WORKDIR /app

COPY --from=pia /usr/local/bin/pia-wg-config /usr/local/bin/pia-wg-config
RUN chmod +x /usr/local/bin/pia-wg-config

COPY entrypoint.sh /app/entrypoint.sh
COPY refresh-loop.sh /app/refresh-loop.sh
COPY speedtest.sh /app/speedtest.sh

RUN chmod +x /app/entrypoint.sh /app/refresh-loop.sh /app/speedtest.sh

ENTRYPOINT ["/app/entrypoint.sh"]
