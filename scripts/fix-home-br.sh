#!/usr/bin/env bash
# fix-home-br.sh — Restore Home-BR when AP clients have no internet/dashboard
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

INSTALL="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
ENV="/etc/pi-vpn-gateway/env"
AP_IF="${IFACE_AP:-wlan1}"
AP_IP="${AP_IP:-192.168.50.1}"
VPN_IF=tun0

[[ -f "$ENV" ]] && source "$ENV"

log() { echo "[fix-home-br] $*"; }

log "Stopping broken WireGuard (NordLynx not available on this network)..."
systemctl stop wg-quick@wg0 2>/dev/null || true
systemctl disable wg-quick@wg0 2>/dev/null || true

log "Ensuring AP interface is up..."
ip link set "$AP_IF" up
ip addr show dev "$AP_IF" | grep -q "${AP_IP}/" || ip addr add "${AP_IP}/24" dev "$AP_IF"

log "Restarting AP services..."
systemctl restart hostapd
sleep 2
systemctl restart pi-vpn-gateway-dhcp
systemctl restart pi-vpn-gateway-dashboard 2>/dev/null || true

log "Starting OpenVPN (br93)..."
systemctl enable openvpn-brazil 2>/dev/null || true
systemctl restart openvpn-brazil
sleep 5

if ! ip link show tun0 &>/dev/null; then
  log "ERROR: tun0 not up — check: journalctl -u openvpn-brazil -n 20"
  exit 1
fi

VPN_IF=tun0
sed -i 's/^WG_INTERFACE=.*/WG_INTERFACE="tun0"/' "$ENV" 2>/dev/null || true
sed -i 's/^VPN_SERVICE=.*/VPN_SERVICE="openvpn-brazil"/' "$ENV" 2>/dev/null || true

log "Fixing routing and firewall..."
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w "net.ipv4.conf.${AP_IF}.rp_filter=2"
sysctl -w "net.ipv4.conf.tun0.rp_filter=2"

if [[ -f /etc/nftables.d/pi-vpn-gateway.nft ]]; then
  sed -i "s/define VPN_IFACE = .*/define VPN_IFACE = tun0/" /etc/nftables.d/pi-vpn-gateway.nft
  nft -f /etc/nftables.conf 2>/dev/null || true
fi

cat > /etc/pi-vpn-gateway/dnsmasq-vpn-dns.conf <<EOF
server=1.1.1.1@tun0
server=1.0.0.1@tun0
EOF
systemctl restart pi-vpn-gateway-dhcp

WG_INTERFACE=tun0 VPN_INTERFACE=tun0 "$INSTALL/firewall/vpn-route.sh" up

IP=$(curl -sf --max-time 8 --interface tun0 http://ifconfig.me || echo unknown)
log "VPN exit IP: $IP"
log "Status:"
systemctl is-active hostapd pi-vpn-gateway-dhcp openvpn-brazil
ip route show table 100
echo ""
echo "Reconnect phone to Home-BR, then: https://ifconfig.me"
