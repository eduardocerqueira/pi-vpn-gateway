#!/usr/bin/env bash
# vpn-route.sh — Policy routing and DNS for AP clients when VPN is up/down
set -eu

CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"

_saved_vpn="${VPN_INTERFACE:-}"
_saved_wg="${WG_INTERFACE:-}"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "$_saved_vpn" ]] && VPN_INTERFACE="$_saved_vpn"
[[ -n "$_saved_wg" ]] && WG_INTERFACE="$_saved_wg"

IFACE_AP="${IFACE_AP:-wlan1}"
VPN_INTERFACE="${VPN_INTERFACE:-${WG_INTERFACE:-tun0}}"
AP_IP="${AP_IP:-192.168.50.1}"
AP_SUBNET="${AP_SUBNET:-192.168.50.0/24}"
ROUTING_TABLE="${ROUTING_TABLE:-100}"
ACTION="${1:-up}"

log() { logger -t pi-vpn-gateway "$*"; echo "[vpn-route] $*"; }

setup_policy_routing() {
  ip route flush table "$ROUTING_TABLE" 2>/dev/null || true
  local gw added=0
  gw=$(ip -4 route show dev "$VPN_INTERFACE" 2>/dev/null | awk '/^default via/{print $3; exit}')
  # WireGuard/NordLynx: route via peer, not a synthetic gateway
  if [[ "$VPN_INTERFACE" == wg* ]]; then
    ip route add default dev "$VPN_INTERFACE" table "$ROUTING_TABLE" 2>/dev/null && added=1
  elif [[ "$VPN_INTERFACE" == tun* ]]; then
    if [[ -z "$gw" ]]; then
      gw=$(ip -4 addr show dev "$VPN_INTERFACE" 2>/dev/null | awk '/inet /{split($2,a,"/"); n=split(a[1],b,"."); print b[1]"."b[2]"."b[3]".1"}')
    fi
    if [[ -n "$gw" ]]; then
      ip route add default via "$gw" dev "$VPN_INTERFACE" table "$ROUTING_TABLE" 2>/dev/null && added=1
    fi
  elif [[ -n "$gw" ]]; then
    ip route add default via "$gw" dev "$VPN_INTERFACE" table "$ROUTING_TABLE" 2>/dev/null && added=1
  fi
  if [[ "$added" -eq 0 ]]; then
    ip route add default dev "$VPN_INTERFACE" table "$ROUTING_TABLE" 2>/dev/null || true
  fi
  ip rule del iif "$IFACE_AP" lookup "$ROUTING_TABLE" 2>/dev/null || true
  ip rule del from "$AP_IP" lookup main 2>/dev/null || true
  ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
  # Pi services on AP_IP (dnsmasq, dashboard) use home uplink for upstream DNS
  ip rule add from "$AP_IP" lookup main priority 90 2>/dev/null || true
  # Forwarded AP client traffic uses VPN
  ip rule add from "$AP_SUBNET" lookup "$ROUTING_TABLE" priority 100 2>/dev/null || true
}

teardown_policy_routing() {
  ip rule del iif "$IFACE_AP" lookup "$ROUTING_TABLE" 2>/dev/null || true
  ip rule del from "$AP_IP" lookup main 2>/dev/null || true
  ip rule del from "$AP_SUBNET" lookup "$ROUTING_TABLE" 2>/dev/null || true
  ip route flush table "$ROUTING_TABLE" 2>/dev/null || true
}

update_dns_upstream() {
  local dns_conf="/etc/pi-vpn-gateway/dnsmasq-vpn-dns.conf"
  local iface="${VPN_INTERFACE:-tun0}"
  if [[ "$ACTION" == "up" ]]; then
    cat > "$dns_conf" <<EOF
# Auto-generated — DNS via VPN (prevents US CDN / geo mismatch for streaming)
server=1.1.1.1@${iface}
server=1.0.0.1@${iface}
EOF
  else
    rm -f "$dns_conf"
  fi
  systemctl restart pi-vpn-gateway-dhcp 2>/dev/null || true
}

case "$ACTION" in
  up)
    log "VPN up — policy routing AP subnet ($AP_SUBNET) through $VPN_INTERFACE"
    update_dns_upstream

    ip link set "$IFACE_AP" up 2>/dev/null || true
    ip addr show dev "$IFACE_AP" | grep -q "${AP_IP}/" || \
      ip addr add "${AP_IP}/24" dev "$IFACE_AP" 2>/dev/null || true

    setup_policy_routing

    # Policy routing + VPN forwarding breaks with strict reverse-path filtering
    sysctl -w net.ipv4.conf.all.rp_filter=2 2>/dev/null || true
    sysctl -w net.ipv4.conf.default.rp_filter=2 2>/dev/null || true
    sysctl -w "net.ipv4.conf.${IFACE_AP}.rp_filter=2" 2>/dev/null || true
    sysctl -w "net.ipv4.conf.${VPN_INTERFACE}.rp_filter=2" 2>/dev/null || true

    # Firewall is managed by pi-vpn-gateway-firewall.service — do not reload here
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
