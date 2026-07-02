#!/usr/bin/env bash
# switch-to-brazil-udp.sh — Quick fix: OpenVPN UDP on br120 (different exit IP pool)
# Not as good as NordLynx for streaming — use switch-to-nordlynx.sh when you have a token.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

INSTALL="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
OVPN_SRC="$INSTALL/openvpn/brazil-udp.conf.template"
OVPN_DST="/etc/openvpn/client/brazil.conf"
CA_URL="https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/br120.nordvpn.com.udp.ovpn"

log() { echo "[brazil-udp] $*"; }

log "Downloading br120 UDP template from NordVPN..."
tmp=$(mktemp)
curl -sfL --interface tun0 "$CA_URL" -o "$tmp" 2>/dev/null \
  || curl -sfL "$CA_URL" -o "$tmp"

# Keep certs from official bundle, add our routing hooks
if grep -q '<ca>' "$tmp"; then
  cp "$tmp" "$OVPN_DST"
else
  [[ -f "$OVPN_SRC" ]] || { log "Missing template and download failed"; exit 1; }
  cp "$OVPN_SRC" "$OVPN_DST"
fi

# Force auth file and split routing (never prompt on headless Pi)
sed -i 's|^auth-user-pass.*|auth-user-pass /etc/openvpn/client/auth.txt|' "$OVPN_DST"
grep -q route-nopull "$OVPN_DST" || echo route-nopull >> "$OVPN_DST"
grep -q vpn-route.sh "$OVPN_DST" || {
  cat >> "$OVPN_DST" <<'EOF'
script-security 2
up "/opt/pi-vpn-gateway/firewall/vpn-route.sh up"
down "/opt/pi-vpn-gateway/firewall/vpn-route.sh down"
EOF
}

chmod 600 "$OVPN_DST"
systemctl restart openvpn-brazil
sleep 4
/opt/pi-vpn-gateway/firewall/vpn-route.sh up

ip=$(curl -sf --max-time 10 --interface tun0 https://ifconfig.me 2>/dev/null || echo "unknown")
log "OpenVPN UDP exit IP: $ip"
log "For Amazon Prime, run switch-to-nordlynx.sh with your NordVPN access token."
