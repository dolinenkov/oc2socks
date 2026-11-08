FROM golang:1.24-bookworm AS tun2socks-build
ARG TUN2SOCKS_VERSION=v2.6.0
RUN CGO_ENABLED=0 GOBIN=/out go install github.com/xjasonlyu/tun2socks/v2@${TUN2SOCKS_VERSION}

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ocserv iproute2 iptables ca-certificates bash tini \
    && rm -rf /var/lib/apt/lists/*
COPY --from=tun2socks-build /out/tun2socks /usr/local/bin/tun2socks
COPY config/ocserv.conf /etc/ocserv/ocserv.conf
COPY entrypoint.sh /usr/local/bin/entrypoint
RUN chmod 0755 /usr/local/bin/entrypoint
EXPOSE 443/tcp 443/udp
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
