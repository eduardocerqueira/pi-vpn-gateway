#!/usr/bin/env bash
# gateway-start.sh — Bring up AP interface and verify VPN path
set -eu

CONFIG_DIR="/etc/pi-vpn-gateway"
[[ -f "$CONFIG_DIR/env" ]] && source "$CONFIG_DIR/env"

IFACE_AP="${IFACE_AP:-wlan1}"
AP_IP="${AP_IP:-192.168.50.1}"
VPN_INTERFACE="${VPN_INTERFACE:-${WG_INTERFACE:-tun0}}"

logger -t pi-vpn-gateway "Starting gateway"

ip link set "$IFACE_AP" up
ip addr show dev "$IFACE_AP" | grep -q "${AP_IP}/" || ip addr add "${AP_IP}/24" dev "$IFACE_AP"

for i in $(seq 1 30); do
  ip link show "$VPN_INTERFACE" &>/dev/null && break
  sleep 2
done

/opt/pi-vpn-gateway/firewall/vpn-route.sh up || true
logger -t pi-vpn-gateway "Gateway started"
