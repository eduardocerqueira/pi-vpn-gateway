#!/usr/bin/env bash
# health-check.sh — Verify VPN connectivity and restart if needed
set -euo pipefail

CONFIG_DIR="/etc/pi-vpn-gateway"
[[ -f "$CONFIG_DIR/env" ]] && source "$CONFIG_DIR/env"

WG_INTERFACE="${WG_INTERFACE:-wg0}"
VPN_COUNTRY="${VPN_COUNTRY:-Brazil}"
LOG_TAG="pi-vpn-gateway-health"

log() { logger -t "$LOG_TAG" "$*"; }

# Check interface exists and is up
if ! ip link show "$WG_INTERFACE" up &>/dev/null; then
  log "VPN interface $WG_INTERFACE down — restarting wg-quick"
  systemctl restart "wg-quick@${WG_INTERFACE}"
  exit 0
fi

# Ping test through VPN (NordVPN DNS or Cloudflare)
if ! ping -c 1 -W 5 -I "$WG_INTERFACE" 1.1.1.1 &>/dev/null; then
  log "VPN tunnel unhealthy — restarting wg-quick"
  systemctl restart "wg-quick@${WG_INTERFACE}"
  /opt/pi-vpn-gateway/firewall/vpn-route.sh up
  exit 0
fi

log "VPN healthy"
