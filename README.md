# OpenConnect through SOCKS5

A Docker gateway using [ocserv](https://ocserv.gitlab.io/www/) and [tun2socks](https://github.com/xjasonlyu/tun2socks). OpenConnect clients connect to ocserv; their IPv4 TCP and UDP traffic is sent through an upstream SOCKS5 proxy. The proxy must support UDP ASSOCIATE for UDP, including ordinary DNS, to work.

## Architecture

```text
OpenConnect client -- TLS/DTLS --> ocserv -- client TUN --> Linux routing
                                                            |
                                               source-based policy route
                                                            v
                                  SOCKS5 proxy <-- tun2socks <-- socks-tun
                                        |
                                     Internet
```

ocserv allocates addresses in `10.77.0.0/24`. A policy rule routes packets from that subnet to the tun2socks TUN interface; tun2socks creates separate outbound connections to the proxy using the container's ordinary route. A forwarding firewall rule prevents that subnet from escaping through another interface, and client access to container-local services is blocked. The VPN is IPv4-only; the server does not provide an IPv6 tunnel. ICMP and other non-TCP/UDP protocols are not carried by SOCKS5. Whether clients also send traffic outside the VPN, especially IPv6 traffic, depends on the client and its local configuration.

The multi-stage image compiles tun2socks v2.6.0 from Go modules and installs Debian Bookworm's ocserv package in the runtime stage. Versions of Debian packages and base images can change when rebuilding. The Go build stage is discarded from the final image, although Docker may retain it in its build cache. The container requires Linux TUN, `NET_ADMIN`, IPv4 forwarding, and relaxed reverse-path filtering in its own network namespace. Do not use host networking: the routing and firewall rules would affect the host.

## Build and configure

```sh
docker build -t oc2socks .
mkdir -p secrets
chmod 700 secrets
```

Place a TLS certificate chain and its unencrypted private key in `secrets/server-cert.pem` and `secrets/server-key.pem`. Use a certificate valid for the public DNS name clients will connect to. Create a password file interactively (the directory must be writable by the container):

```sh
docker run --rm -it --entrypoint ocpasswd \
  -v "$PWD/secrets:/secrets" oc2socks -c /secrets/ocpasswd alice
chmod 600 secrets/server-key.pem secrets/ocpasswd
```

Start the gateway, replacing the proxy address with an upstream reachable **from the container**, and publishing the VPN port on the host:

```sh
docker run -d --name oc2socks --restart unless-stopped \
  --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.rp_filter=0 \
  --sysctl net.ipv4.conf.default.rp_filter=0 \
  -p 443:443/tcp -p 443:443/udp \
  -v "$PWD/secrets:/etc/ocserv/secrets:ro" \
  -e 'SOCKS5_PROXY=socks5://192.0.2.10:1080' oc2socks
```

Open TCP 443 and UDP 443 on the server's firewall; UDP is used for DTLS and TCP provides the VPN connection and fallback. On Docker Desktop, `/dev/net/tun` and network capabilities must be available inside its Linux VM; a native Linux host is recommended. A proxy on the host's loopback is not reachable as `127.0.0.1` inside the container. Proxy credentials may be supplied as `socks5://user:password@host:port` with URL-encoded special characters, but environment variables are visible to users who can inspect the container. Protect Docker access and the secrets directory.

Connect using an OpenConnect-compatible client, for example:

```sh
sudo openconnect --protocol=anyconnect vpn.example.com --user=alice
```

Check `docker logs oc2socks` and verify the client sees the proxy's public IP, and test DNS and UDP with your actual proxy. If the proxy is unavailable, traffic should fail rather than fall back to direct forwarding. The proxy sees destinations and, absent application-layer encryption, their contents. This setup does not guarantee a client-side kill switch.

## Configuration

The example advertises DNS `1.1.1.1` and a default IPv4 route. Change settings by bind-mounting a complete ocserv configuration over `/etc/ocserv/ocserv.conf`. Keep the VPN subnet exactly `10.77.0.0/24`: the policy and firewall rules in `entrypoint.sh` depend on it. Choose a subnet that does not overlap client networks or Docker networks; changing it requires updating both files. Do not configure an IPv6 pool without implementing and testing equivalent IPv6 routing and firewall rules. See the [ocserv sample configuration](https://gitlab.com/openconnect/ocserv/-/blob/master/doc/sample.config) and [tun2socks usage](https://github.com/xjasonlyu/tun2socks/wiki) for more options.

The entrypoint stops the container when either process exits, so the configured Docker restart policy can restart both. Updating a certificate or password file requires a container restart. The image contains no credentials; keep secrets out of the build context and source control.
