#!/usr/bin/env bash
# switch-to-nordlynx.sh — Migrate AP VPN from OpenVPN TCP to NordLynx (WireGuard)
# Same protocol as the NordVPN phone app — required for Amazon Prime / CazeTV.
#
# Usage (on Pi):
#   sudo NORDVPN_TOKEN="..." bash /opt/pi-vpn-gateway/scripts/switch-to-nordlynx.sh
# Or with a pre-fetched private key:
#   sudo NORDVPN_PRIVATE_KEY="..." bash /opt/pi-vpn-gateway/scripts/switch-to-nordlynx.sh
#
# Get token: https://my.nordaccount.com/dashboard/nordvpn/access-tokens/
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

INSTALL="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
VPN_SERVER="${NORDVPN_SERVER_HOSTNAME:-}"

log() { echo "[nordlynx] $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

ensure_nordvpn_dns() {
  # Home routers often NXDOMAIN-block nordvpn.com — use Cloudflare IPs
  grep -q 'api.nordvpn.com' /etc/hosts 2>/dev/null || {
    log "Adding NordVPN API hosts entries (router DNS blocks nordvpn.com)"
    tee -a /etc/hosts > /dev/null <<'EOF'
104.16.208.203 api.nordvpn.com
104.16.208.203 nordvpn.com
EOF
  }
}

fetch_private_key() {
  if [[ -n "${NORDVPN_PRIVATE_KEY:-}" ]]; then
    return 0
  fi
  if [[ -f "$CONFIG_DIR/nordlynx.key" ]]; then
    NORDVPN_PRIVATE_KEY=$(tr -d '[:space:]' < "$CONFIG_DIR/nordlynx.key")
    return 0
  fi
  if [[ -z "${NORDVPN_TOKEN:-}" ]]; then
    die "No NordLynx key on Pi. Run on your Mac:
  NORDVPN_TOKEN=\"...\" bash scripts/fetch-nordlynx-key.sh
Or: sudo NORDVPN_PRIVATE_KEY=\"...\" bash $0"
  fi

  ensure_nordvpn_dns
  log "Fetching NordLynx private key..."
  local creds key
  creds=$(curl -sf -u "token:${NORDVPN_TOKEN}" \
    "https://api.nordvpn.com/v1/users/services/credentials") \
    || die "Could not reach NordVPN credentials API — try from your Mac and copy nordlynx.key to the Pi"
  key=$(echo "$creds" | jq -r '.nordlynx_private_key // empty')
  [[ -n "$key" ]] || die "No nordlynx_private_key in API response — check token"
  NORDVPN_PRIVATE_KEY="$key"
  install -m 600 /dev/null "$CONFIG_DIR/nordlynx.key"
  echo "$NORDVPN_PRIVATE_KEY" > "$CONFIG_DIR/nordlynx.key"
  chmod 600 "$CONFIG_DIR/nordlynx.key"
}

pick_server() {
  if [[ -n "$VPN_SERVER" ]]; then
    return 0
  fi
  ensure_nordvpn_dns
  log "Selecting Brazil NordLynx server..."
  # Prefer servers outside datacenter ranges Amazon often blocks (185.153.x, 84.20.x)
  VPN_SERVER=$(curl -sf -g \
    "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=30&filters[servers_technologies][identifier]=wireguard_udp&limit=20" \
    | jq -r '
      [.[] | select(.load < 60) |
        select(.station | test("^(185\\.153\\.|84\\.20\\.)") | not)] |
      sort_by(.load) | .[0].hostname // empty' 2>/dev/null)
  if [[ -z "$VPN_SERVER" ]]; then
    VPN_SERVER=$(curl -sf -g \
      "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=30&filters[servers_technologies][identifier]=wireguard_udp&limit=5" \
      | jq -r '[.[] | select(.load < 50)][0].hostname // empty' 2>/dev/null)
  fi
  [[ -n "$VPN_SERVER" ]] || die "No Brazil WireGuard server found"
  log "Server: $VPN_SERVER"
}

generate_wg_config() {
  export NORDVPN_PRIVATE_KEY VPN_SERVER
  export NORDVPN_SERVER_HOSTNAME="$VPN_SERVER"
  export WG_INTERFACE
  "$INSTALL/wireguard/generate-nordvpn-config.sh"
}

update_env() {
  log "Updating gateway env for WireGuard..."
  if [[ -f "$ENV_FILE" ]]; then
    sed -i "s/^WG_INTERFACE=.*/WG_INTERFACE=\"${WG_INTERFACE}\"/" "$ENV_FILE"
    sed -i 's/^VPN_SERVICE=.*/VPN_SERVICE="wg-quick@wg0"/' "$ENV_FILE"
    grep -q '^VPN_INTERFACE=' "$ENV_FILE" || \
      echo "VPN_INTERFACE=\"${WG_INTERFACE}\"" >> "$ENV_FILE"
    sed -i "s/^VPN_INTERFACE=.*/VPN_INTERFACE=\"${WG_INTERFACE}\"/" "$ENV_FILE"
  fi
}

reload_firewall() {
  local vpn_iface="$WG_INTERFACE"
  if [[ -f /etc/nftables.d/pi-vpn-gateway.nft ]]; then
    sed -i "s/define VPN_IFACE = .*/define VPN_IFACE = ${vpn_iface}/" /etc/nftables.d/pi-vpn-gateway.nft
    nft -f /etc/nftables.conf 2>/dev/null || true
  fi
  if [[ -x "$INSTALL/firewall/install-rules.sh" ]]; then
    WG_INTERFACE="$vpn_iface" "$INSTALL/firewall/install-rules.sh" 2>/dev/null || true
  fi
}

switch_vpn() {
  log "Stopping OpenVPN..."
  systemctl stop openvpn-brazil 2>/dev/null || true
  systemctl disable openvpn-brazil 2>/dev/null || true

  log "Starting NordLynx ($WG_INTERFACE)..."
  systemctl enable "wg-quick@${WG_INTERFACE}" 2>/dev/null || true
  systemctl restart "wg-quick@${WG_INTERFACE}"

  sleep 3
  if ! ip link show "$WG_INTERFACE" &>/dev/null; then
    die "Interface $WG_INTERFACE not up — check: journalctl -u wg-quick@${WG_INTERFACE} -n 30"
  fi

  export WG_INTERFACE
  "$INSTALL/firewall/vpn-route.sh" up

  reload_firewall

  local exit_ip
  exit_ip=$(curl -sf --max-time 10 --interface "$WG_INTERFACE" https://ifconfig.me 2>/dev/null || echo "unknown")
  log "NordLynx exit IP: $exit_ip"
  log "Done. Connect TV to Home-BR and test Amazon Prime."
}

main() {
  fetch_private_key
  pick_server
  generate_wg_config
  update_env
  switch_vpn
}

main "$@"
