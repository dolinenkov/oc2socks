#!/usr/bin/env bash
set -Eeuo pipefail

: "${SOCKS5_PROXY:?Set SOCKS5_PROXY to a socks5://host:port URL}"
case "$SOCKS5_PROXY" in socks5://*) ;; *) echo 'SOCKS5_PROXY must start with socks5://' >&2; exit 1;; esac
for file in /etc/ocserv/secrets/{server-cert.pem,server-key.pem,ocpasswd}; do
    [[ -r "$file" ]] || { echo "Missing or unreadable $file" >&2; exit 1; }
done

# Keep this subnet synchronized with ocserv.conf. Policy routing applies only
# to packets from VPN clients, so the proxy connection itself uses the main table.
ip tuntap add dev socks-tun mode tun
ip link set socks-tun up
ip route add default dev socks-tun table 100
ip rule add priority 1000 from 10.77.0.0/24 lookup 100
# Never forward client traffic via the normal Docker interface, including if
# the policy route disappears. Do not expose container-local services either.
iptables -I INPUT 1 -s 10.77.0.0/24 -j DROP
iptables -I FORWARD 1 -s 10.77.0.0/24 ! -o socks-tun -j DROP
iptables -I FORWARD 1 -s 10.77.0.0/24 -o socks-tun -j ACCEPT
iptables -I FORWARD 1 -i socks-tun -d 10.77.0.0/24 -j ACCEPT

tun2socks -device socks-tun -proxy "$SOCKS5_PROXY" &
tun_pid=$!
ocserv -f -c /etc/ocserv/ocserv.conf &
oc_pid=$!
cleanup() {
    kill "$tun_pid" "$oc_pid" 2>/dev/null || true
    wait "$tun_pid" "$oc_pid" 2>/dev/null || true
}
trap 'cleanup; exit 0' TERM INT
trap cleanup EXIT
# Treat either process exiting as failure, including an unexpected clean exit.
wait -n "$tun_pid" "$oc_pid" || true
exit 1
