#!/usr/bin/env bash
# vpn-route.sh — Policy routing and DNS for AP clients when VPN is up/down
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

IFACE_AP="${IFACE_AP:-wlan1}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
AP_IP="${AP_IP:-192.168.50.1}"
AP_SUBNET="${AP_SUBNET:-192.168.50.0/24}"
ROUTING_TABLE="${ROUTING_TABLE:-100}"
ACTION="${1:-up}"

log() { logger -t pi-vpn-gateway "$*"; echo "[vpn-route] $*"; }

setup_policy_routing() {
  ip route flush table "$ROUTING_TABLE" 2>/dev/null || true
  ip route add default dev "$WG_INTERFACE" table "$ROUTING_TABLE"
  ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
  ip rule add from "$AP_SUBNET" lookup "$ROUTING_TABLE" priority 100
}

teardown_policy_routing() {
  ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
  ip route flush table "$ROUTING_TABLE" 2>/dev/null || true
}

update_dnsmasq_upstream() {
  local dns_conf="/etc/dnsmasq.d/pi-vpn-gateway-upstream.conf"
  if [[ "$ACTION" == "up" ]]; then
    local vpn_dns
    vpn_dns=$(grep -i '^DNS' "/etc/wireguard/${WG_INTERFACE}.conf" 2>/dev/null \
      | head -1 | cut -d= -f2 | tr -d ' ' | cut -d, -f1)
    vpn_dns="${vpn_dns:-1.1.1.1}"
    cat > "$dns_conf" <<EOF
# Auto-generated when VPN is up
server=${vpn_dns}
EOF
  else
    rm -f "$dns_conf"
  fi
  systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq 2>/dev/null || true
}

case "$ACTION" in
  up)
    log "VPN up — policy routing AP subnet ($AP_SUBNET) through $WG_INTERFACE"
    update_dnsmasq_upstream

    ip link set "$IFACE_AP" up 2>/dev/null || true
    ip addr show dev "$IFACE_AP" | grep -q "${AP_IP}/" || \
      ip addr add "${AP_IP}/24" dev "$IFACE_AP" 2>/dev/null || true

    setup_policy_routing
    nft -f /etc/nftables.conf 2>/dev/null || true
    ;;

  down)
    log "VPN down — AP clients blocked by kill switch"
    teardown_policy_routing
    update_dnsmasq_upstream
    ;;

  *)
    echo "Usage: $0 {up|down}"
    exit 1
    ;;
esac
