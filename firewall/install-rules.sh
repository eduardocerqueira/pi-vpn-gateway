#!/usr/bin/env bash
# install-rules.sh — Deploy nftables kill-switch and NAT rules
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

IFACE_AP="${IFACE_AP:-wlan1}"
IFACE_UPLINK="${IFACE_UPLINK:-wlan0}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
AP_SUBNET="${AP_SUBNET:-192.168.50.0/24}"
AP_IP="${AP_IP:-192.168.50.1}"

export IFACE_AP IFACE_UPLINK WG_INTERFACE AP_SUBNET AP_IP

mkdir -p /etc/nftables.d
envsubst '${IFACE_AP} ${IFACE_UPLINK} ${WG_INTERFACE} ${AP_SUBNET} ${AP_IP}' \
  < "$INSTALL_ROOT/firewall/pi-vpn-gateway.nft.template" \
  > /etc/nftables.d/pi-vpn-gateway.nft

cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

include "/etc/nftables.d/pi-vpn-gateway.nft"
EOF

echo "nftables rules installed to /etc/nftables.d/pi-vpn-gateway.nft"
