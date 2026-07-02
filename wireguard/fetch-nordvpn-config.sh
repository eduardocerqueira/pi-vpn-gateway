#!/usr/bin/env bash
# fetch-nordvpn-config.sh — Download NordVPN WireGuard config for a country
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
VPN_COUNTRY="${VPN_COUNTRY:-Brazil}"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

log() { echo "[fetch-nordvpn] $*"; }
die() { log "ERROR: $*"; exit 1; }

if [[ -z "${NORDVPN_TOKEN:-}" && -f "$CONFIG_DIR/nordlynx.key" ]]; then
  export NORDVPN_PRIVATE_KEY=$(tr -d '[:space:]' < "$CONFIG_DIR/nordlynx.key")
  export NORDVPN_SERVER_HOSTNAME="${NORDVPN_SERVER_HOSTNAME:-}"
  exec "$(dirname "$0")/generate-nordvpn-config.sh"
fi

: "${NORDVPN_TOKEN:?NORDVPN_TOKEN required (or place key in $CONFIG_DIR/nordlynx.key)}"

log "Fetching WireGuard server for $VPN_COUNTRY..."

grep -q 'api.nordvpn.com' /etc/hosts 2>/dev/null || tee -a /etc/hosts > /dev/null <<'EOF'
104.16.208.203 api.nordvpn.com
104.16.208.203 nordvpn.com
EOF

# Public NordVPN servers API
SERVERS_JSON=$(curl -sf -g \
  "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=30&filters[servers_technologies][identifier]=wireguard_udp&limit=1")

SERVER_HOSTNAME=$(echo "$SERVERS_JSON" | jq -r '.[0].hostname // empty')
[[ -n "$SERVER_HOSTNAME" ]] || die "No WireGuard server found for $VPN_COUNTRY"

log "Selected server: $SERVER_HOSTNAME"

# NordVPN credentials endpoint returns WireGuard private key when authenticated
CREDS=$(curl -sf \
  -u "token:${NORDVPN_TOKEN}" \
  "https://api.nordvpn.com/v1/users/services/credentials")

WG_PRIVATE_KEY=$(echo "$CREDS" | jq -r '.nordlynx_private_key // empty')
[[ -n "$WG_PRIVATE_KEY" ]] || die "Could not retrieve NordLynx private key — check token"

export NORDVPN_PRIVATE_KEY="$WG_PRIVATE_KEY"
export NORDVPN_SERVER_HOSTNAME="$SERVER_HOSTNAME"
exec "$(dirname "$0")/generate-nordvpn-config.sh"
