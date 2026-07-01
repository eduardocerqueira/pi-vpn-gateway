#!/usr/bin/env bash
# vpn-route.sh — Policy routing and DNS for AP clients when VPN is up/down
set -eu

CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

IFACE_AP="${IFACE_AP:-wlan1}"
VPN_INTERFACE="${VPN_INTERFACE:-${WG_INTERFACE:-tun0}}"
AP_IP="${AP_IP:-192.168.50.1}"
AP_SUBNET="${AP_SUBNET:-192.168.50.0/24}"
ROUTING_TABLE="${ROUTING_TABLE:-100}"
ACTION="${1:-up}"

log() { logger -t pi-vpn-gateway "$*"; echo "[vpn-route] $*"; }

setup_policy_routing() {
  ip route flush table "$ROUTING_TABLE" 2>/dev/null || true
  ip route add default dev "$VPN_INTERFACE" table "$ROUTING_TABLE" 2>/dev/null || true
  ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
  ip rule add from "$AP_SUBNET" lookup "$ROUTING_TABLE" priority 100 2>/dev/null || true
}

teardown_policy_routing() {
  ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
  ip route flush table "$ROUTING_TABLE" 2>/dev/null || true
}

update_dns_upstream() {
  local dns_conf="/etc/dnsmasq.d/pi-vpn-gateway-upstream.conf"
  if [[ "$ACTION" == "up" ]]; then
    cat > "$dns_conf" <<EOF
# Auto-generated when VPN is up
server=1.1.1.1
EOF
  else
    rm -f "$dns_conf"
  fi
  if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
    systemctl reload pihole-FTL 2>/dev/null || systemctl restart pihole-FTL 2>/dev/null || true
  else
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null || true
  fi
}

case "$ACTION" in
  up)
    log "VPN up — policy routing AP subnet ($AP_SUBNET) through $VPN_INTERFACE"
    update_dns_upstream

    ip link set "$IFACE_AP" up 2>/dev/null || true
    ip addr show dev "$IFACE_AP" | grep -q "${AP_IP}/" || \
      ip addr add "${AP_IP}/24" dev "$IFACE_AP" 2>/dev/null || true

    setup_policy_routing
    nft -f /etc/nftables.conf 2>/dev/null || true
    exit 0
    ;;

  down)
    log "VPN down — AP clients blocked by kill switch"
    teardown_policy_routing
    update_dns_upstream
    exit 0
    ;;

  *)
    echo "Usage: $0 {up|down}"
    exit 0
    ;;
esac
