#!/usr/bin/env bash
# health-check.sh — Verify VPN connectivity and restart if needed
set -euo pipefail

CONFIG_DIR="/etc/pi-vpn-gateway"
[[ -f "$CONFIG_DIR/env" ]] && source "$CONFIG_DIR/env"

VPN_INTERFACE="${VPN_INTERFACE:-${WG_INTERFACE:-tun0}}"
VPN_SERVICE="${VPN_SERVICE:-openvpn-brazil}"
LOG_TAG="pi-vpn-gateway-health"

log() { logger -t "$LOG_TAG" "$*"; }

restart_vpn() {
  if systemctl list-unit-files "$VPN_SERVICE.service" &>/dev/null; then
    systemctl restart "$VPN_SERVICE"
  elif systemctl list-unit-files "wg-quick@${VPN_INTERFACE}.service" &>/dev/null; then
    systemctl restart "wg-quick@${VPN_INTERFACE}"
  fi
  /opt/pi-vpn-gateway/firewall/vpn-route.sh up || true
}

# Check interface exists and is up
if ! ip link show "$VPN_INTERFACE" up &>/dev/null; then
  log "VPN interface $VPN_INTERFACE down — restarting $VPN_SERVICE"
  restart_vpn
  exit 0
fi

# Ping test through VPN
if ! ping -c 1 -W 5 -I "$VPN_INTERFACE" 1.1.1.1 &>/dev/null; then
  log "VPN tunnel unhealthy — restarting $VPN_SERVICE"
  restart_vpn
  exit 0
fi

log "VPN healthy"
