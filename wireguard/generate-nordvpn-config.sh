#!/usr/bin/env bash
# generate-nordvpn-config.sh — Build wg0.conf from NordVPN NordLynx credentials
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
VPN_COUNTRY="${VPN_COUNTRY:-Brazil}"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

log() { echo "[generate-wg] $*"; }
die() { log "ERROR: $*"; exit 1; }

: "${NORDVPN_PRIVATE_KEY:?NORDVPN_PRIVATE_KEY required}"

curl_nord() {
  curl -sf --connect-timeout 10 "$@"
}

ensure_nordvpn_dns() {
  grep -q 'api.nordvpn.com' /etc/hosts 2>/dev/null || {
    log "Adding NordVPN API to /etc/hosts (router DNS may block nordvpn.com)"
    tee -a /etc/hosts > /dev/null <<'EOF'
104.16.208.203 api.nordvpn.com
104.16.208.203 nordvpn.com
EOF
  }
}

# Resolve server if not provided
if [[ -z "${NORDVPN_SERVER_HOSTNAME:-}" ]]; then
  log "Looking up WireGuard server for $VPN_COUNTRY..."
  ensure_nordvpn_dns
  SERVERS_JSON=$(curl_nord -g \
    "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=30&filters[servers_technologies][identifier]=wireguard_udp&limit=1")
  NORDVPN_SERVER_HOSTNAME=$(echo "$SERVERS_JSON" | jq -r '.[0].hostname // empty')
  [[ -n "$NORDVPN_SERVER_HOSTNAME" ]] || die "No server found for $VPN_COUNTRY"
fi

log "Using server: $NORDVPN_SERVER_HOSTNAME"

# Get server WireGuard public key and endpoint from NordVPN API
ensure_nordvpn_dns
SERVER_JSON=$(curl_nord \
  "https://api.nordvpn.com/v1/servers?filters[servers][hostname]=${NORDVPN_SERVER_HOSTNAME}")
SERVER_PUBKEY=$(echo "$SERVER_JSON" | jq -r \
  '.[0].technologies[] | select(.identifier=="wireguard_udp") | .metadata[] | select(.name=="public_key") | .value')
SERVER_IP=$(echo "$SERVER_JSON" | jq -r \
  '.[0].technologies[] | select(.identifier=="wireguard_udp") | .metadata[] | select(.name=="ip") | .value')

[[ -n "$SERVER_PUBKEY" ]] || die "Could not parse server WireGuard public key"

# Fallback to station IP if wireguard metadata has no dedicated IP field
if [[ -z "$SERVER_IP" || "$SERVER_IP" == "null" ]]; then
  SERVER_IP=$(echo "$SERVER_JSON" | jq -r '.[0].station // empty')
fi
[[ -n "$SERVER_IP" ]] || die "Could not determine server endpoint IP"

mkdir -p /etc/wireguard

install -m 600 /dev/stdin "/etc/wireguard/${WG_INTERFACE}.conf" <<EOF
[Interface]
PrivateKey = ${NORDVPN_PRIVATE_KEY}
Address = 10.5.0.2/32
DNS = 1.1.1.1, 1.0.0.1
Table = off
PostUp = /opt/pi-vpn-gateway/firewall/vpn-route.sh up
PostDown = /opt/pi-vpn-gateway/firewall/vpn-route.sh down

[Peer]
PublicKey = ${SERVER_PUBKEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${SERVER_IP}:51820
PersistentKeepalive = 25
EOF

log "WireGuard config written to /etc/wireguard/${WG_INTERFACE}.conf"
