#!/bin/sh
set -e
# NAT for VPN clients (VPN_POOL must match swanctl pools)
WAN_IF=$(ip route show default | awk '{print $5; exit}')
iptables -t nat -C POSTROUTING -s "${VPN_POOL:-192.168.90.128/25}" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "${VPN_POOL:-192.168.90.128/25}" -o "$WAN_IF" -j MASQUERADE
iptables -C FORWARD -s "${VPN_POOL:-192.168.90.128/25}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "${VPN_POOL:-192.168.90.128/25}" -j ACCEPT
iptables -C FORWARD -d "${VPN_POOL:-192.168.90.128/25}" -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "${VPN_POOL:-192.168.90.128/25}" -j ACCEPT
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
mkdir -p /run/vici
/usr/sbin/charon-systemd &
PID=$!
for i in $(seq 1 30); do swanctl --stats >/dev/null 2>&1 && break; sleep 1; done
swanctl --load-all || true
trap 'kill $PID' TERM INT
wait $PID
