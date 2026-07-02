#!/usr/bin/env bash
# console-stabilize.sh — Run on the Pi with keyboard/monitor when SSH/AP keeps breaking
# Usage: sudo bash console-stabilize.sh [home-wifi-password]
# Pass your real CASITA Wi-Fi password, or omit to skip uplink reconnect.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
CONFIG="/etc/pi-vpn-gateway/env"
AP_PASS='Brasil*2026'
HOME_SSID="${HOME_SSID:-CASITA}"
HOME_WIFI_PASSWORD="${1:-}"

if [[ "$HOME_WIFI_PASSWORD" == "YOUR_CASITA_WIFI_PASSWORD" || "$HOME_WIFI_PASSWORD" == "YOUR_PASSWORD" ]]; then
  echo "ERROR: Replace the placeholder with your real CASITA Wi-Fi password."
  echo "Example: sudo bash $0 'myActualPassword'"
  exit 1
fi

log() { echo "[stabilize] $*"; }

log "Stopping health timer (stops VPN restart loops every 3 min)..."
systemctl stop pi-vpn-gateway-health.timer 2>/dev/null || true
systemctl disable pi-vpn-gateway-health.timer 2>/dev/null || true

log "Loading config..."
mkdir -p /etc/pi-vpn-gateway
if [[ -f "$CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG"
fi
HOME_SSID="${HOME_SSID:-CASITA}"
AP_SSID="${AP_SSID:-Home-BR}"

# Detect interfaces: built-in = AP, USB = uplink
BUILTIN="" USB=""
for _path in /sys/class/net/wl*; do
  [[ -e "$_path" ]] || continue
  _if="${_path##*/}"
  driver=$(basename "$(readlink -f "/sys/class/net/$_if/device/driver" 2>/dev/null)" 2>/dev/null || true)
  case "$driver" in
    brcmfmac|brcm*) BUILTIN="$_if" ;;
    rt2800usb|rt2x00*) USB="$_if" ;;
  esac
done
IFACE_AP="${BUILTIN:-wlan0}"
IFACE_UPLINK="${USB:-wlan1}"

log "AP=$IFACE_AP (built-in), uplink=$IFACE_UPLINK (USB)"

cat > "$CONFIG" <<EOF
IFACE_UPLINK="$IFACE_UPLINK"
IFACE_AP="$IFACE_AP"
HOME_SSID="$HOME_SSID"
AP_SSID="$AP_SSID"
AP_PASSPHRASE="$AP_PASS"
AP_SUBNET="192.168.50.0/24"
AP_IP="192.168.50.1"
AP_DHCP_START="192.168.50.10"
AP_DHCP_END="192.168.50.200"
VPN_COUNTRY="Brazil"
WG_INTERFACE="tun0"
VPN_SERVICE="openvpn-brazil"
DASHBOARD_PORT="8080"
EOF
chmod 600 "$CONFIG"

log "NetworkManager: manage uplink only, not AP..."
tee /etc/NetworkManager/conf.d/99-pi-vpn-gateway.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:${IFACE_AP}
EOF
systemctl reload NetworkManager 2>/dev/null || true
sleep 2

# Skip uplink reconnect if already on home LAN
UPLINK_IP_NOW=$(ip -4 addr show "$IFACE_UPLINK" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
if [[ -n "$UPLINK_IP_NOW" ]]; then
  log "Uplink already has IP $UPLINK_IP_NOW — skipping Wi-Fi connect"
elif [[ -n "$HOME_WIFI_PASSWORD" ]]; then
  log "Connecting $IFACE_UPLINK to $HOME_SSID (30s timeout)..."
  nmcli dev wifi rescan ifname "$IFACE_UPLINK" 2>/dev/null || true
  sleep 2
  timeout 30 nmcli dev wifi connect "$HOME_SSID" password "$HOME_WIFI_PASSWORD" \
    ifname "$IFACE_UPLINK" name "${HOME_SSID}-pi" 2>/dev/null || \
    timeout 15 nmcli con up "${HOME_SSID}-pi" 2>/dev/null || \
    log "WARNING: uplink connect failed — continuing anyway (fix with nmcli later)"
  nmcli con modify "${HOME_SSID}-pi" connection.autoconnect yes 2>/dev/null || true
else
  HOME_WIFI_PASSWORD=$(nmcli -s -g 802-11-wireless-security.psk connection show "$HOME_SSID" 2>/dev/null || \
    nmcli -s -g 802-11-wireless-security.psk connection show "${HOME_SSID}-pi" 2>/dev/null || \
    nmcli -s -g 802-11-wireless-security.psk connection show "${HOME_SSID}-usb" 2>/dev/null || true)
  if [[ -n "$HOME_WIFI_PASSWORD" ]]; then
    log "Connecting $IFACE_UPLINK to $HOME_SSID from saved password (30s timeout)..."
    timeout 30 nmcli dev wifi connect "$HOME_SSID" password "$HOME_WIFI_PASSWORD" \
      ifname "$IFACE_UPLINK" name "${HOME_SSID}-pi" 2>/dev/null || \
      log "WARNING: uplink connect failed — continuing anyway"
    nmcli con modify "${HOME_SSID}-pi" connection.autoconnect yes 2>/dev/null || true
  else
    log "WARNING: No home Wi-Fi password — connect $IFACE_UPLINK manually:"
    log "  nmcli dev wifi connect \"$HOME_SSID\" password \"YOUR_PASSWORD\" ifname $IFACE_UPLINK"
  fi
fi

log "Configuring hostapd (no country_code — prevents stuck AP)..."
tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=${IFACE_AP}
driver=nl80211
ctrl_interface=/run/hostapd
ctrl_interface_group=0
ssid=${AP_SSID}
hw_mode=g
channel=1
ieee80211n=0
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${AP_PASS}
ignore_broadcast_ssid=0
beacon_int=100
EOF

tee /etc/default/hostapd > /dev/null <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

# Do NOT bounce interface on every hostapd start — that drops AP/SSH
mkdir -p /etc/systemd/system/hostapd.service.d
tee /etc/systemd/system/hostapd.service.d/regdomain.conf > /dev/null <<'EOF'
[Service]
ExecStartPre=/usr/sbin/iw reg set BR
ExecStartPre=/bin/sleep 1
EOF

echo 'options cfg80211 ieee80211_regdom=BR' > /etc/modprobe.d/cfg80211-regdomain.conf
echo 'REGDOMAIN=BR' > /etc/default/crda

log "AP DHCP (isolated dnsmasq)..."
mkdir -p /var/log/pi-vpn-gateway
tee /etc/pi-vpn-gateway/dnsmasq-dhcp.conf > /dev/null <<EOF
port=0
interface=${IFACE_AP}
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.200,255.255.255.0,12h
dhcp-option=option:router,192.168.50.1
dhcp-option=option:dns-server,192.168.50.1
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
log-dhcp
log-facility=/var/log/pi-vpn-gateway/dnsmasq-dhcp.log
EOF

tee /etc/systemd/system/pi-vpn-gateway-dhcp.service > /dev/null <<'EOF'
[Unit]
Description=Pi VPN Gateway — DHCP for AP clients
After=hostapd.service network.target
Wants=hostapd.service

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq -C /etc/pi-vpn-gateway/dnsmasq-dhcp.conf -k
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

log "Pi-hole DNS only (disable its DHCP)..."
if [[ -f /etc/pihole/setupVars.conf ]]; then
  sed -i 's/^DHCP_ACTIVE=.*/DHCP_ACTIVE=false/' /etc/pihole/setupVars.conf
fi
mv /etc/dnsmasq.d/02-pihole-dhcp.conf /etc/dnsmasq.d/02-pihole-dhcp.conf.disabled 2>/dev/null || true

tee /etc/dnsmasq.d/pi-vpn-gateway.conf > /dev/null <<EOF
interface=${IFACE_AP}
bind-interfaces
listen-address=192.168.50.1
no-dhcp-interface=${IFACE_UPLINK}
no-resolv
server=1.1.1.1
server=1.0.0.1
EOF

log "Firewall..."
if [[ -f "$INSTALL_ROOT/firewall/install-rules.sh" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG"
  export IFACE_AP IFACE_UPLINK WG_INTERFACE AP_SUBNET AP_IP
  envsubst '${IFACE_AP} ${IFACE_UPLINK} ${WG_INTERFACE} ${AP_SUBNET} ${AP_IP}' \
    < "$INSTALL_ROOT/firewall/pi-vpn-gateway.nft.template" \
    > /etc/nftables.d/pi-vpn-gateway.nft 2>/dev/null || \
  nft flush ruleset
else
  nft flush ruleset 2>/dev/null || true
fi

log "Bringing up AP interface..."
ip link set "$IFACE_AP" up
ip addr flush dev "$IFACE_AP" 2>/dev/null || true
ip addr add 192.168.50.1/24 dev "$IFACE_AP" 2>/dev/null || true

systemctl disable --now dnsmasq 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true
systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd pi-vpn-gateway-dhcp pi-vpn-gateway-firewall openvpn-brazil 2>/dev/null || true

systemctl daemon-reload
systemctl restart hostapd
sleep 3
systemctl restart pi-vpn-gateway-dhcp
systemctl restart pihole-FTL 2>/dev/null || true
systemctl restart pi-vpn-gateway-firewall 2>/dev/null || true
systemctl restart openvpn-brazil 2>/dev/null || true
systemctl restart pi-vpn-gateway 2>/dev/null || true
systemctl restart pi-vpn-gateway-dashboard 2>/dev/null || true

UPLINK_IP=$(ip -4 addr show "$IFACE_UPLINK" | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

echo ""
echo "============================================"
echo " STABILIZE COMPLETE"
echo "============================================"
echo " Home-BR password : $AP_PASS"
echo " AP (${IFACE_AP})   : 192.168.50.1"
echo " Uplink IP        : ${UPLINK_IP:-NOT CONNECTED — run nmcli manually}"
echo ""
echo " SSH from Mac:"
echo "  ssh -i ~/.ssh/id_rsa eduardo@${UPLINK_IP:-192.168.100.230}"
echo ""
echo " Dashboard tunnel:"
echo "  ssh -i ~/.ssh/id_rsa -L 8080:127.0.0.1:8080 eduardo@${UPLINK_IP:-192.168.100.230}"
echo ""
systemctl is-active hostapd pi-vpn-gateway-dhcp openvpn-brazil 2>/dev/null | paste - - - || true
hostapd_cli -i "$IFACE_AP" status 2>/dev/null | grep -E "state|ssid" || iw dev "$IFACE_AP" info | grep -E "ssid|type"
echo "============================================"
