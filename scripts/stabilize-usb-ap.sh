#!/usr/bin/env bash
# stabilize-usb-ap.sh — Stable layout: wlan0=uplink (built-in), wlan1=AP (USB)
# Run on Pi: sudo bash /opt/pi-vpn-gateway/scripts/stabilize-usb-ap.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

PASS="${AP_PASSPHRASE:-Brasil2026}"
IFACE_AP=wlan1
IFACE_UPLINK=wlan0
AP_IP=192.168.50.1
AP_SUBNET=192.168.50.0/24
VPN_IF=tun0
INSTALL="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"

log() { echo "[stabilize] $*"; }

log "Stopping health timer and legacy WireGuard..."
systemctl stop pi-vpn-gateway-health.timer 2>/dev/null || true
systemctl disable pi-vpn-gateway-health.timer 2>/dev/null || true
systemctl stop wg-quick@wg0 2>/dev/null || true
systemctl disable wg-quick@wg0 2>/dev/null || true

mkdir -p /etc/pi-vpn-gateway /var/log/pi-vpn-gateway
tee /etc/pi-vpn-gateway/env > /dev/null <<EOF
IFACE_UPLINK="${IFACE_UPLINK}"
IFACE_AP="${IFACE_AP}"
HOME_SSID="CASITA"
AP_SSID="Home-BR"
AP_PASSPHRASE="${PASS}"
AP_SUBNET="${AP_SUBNET}"
AP_IP="${AP_IP}"
AP_DHCP_START="192.168.50.10"
AP_DHCP_END="192.168.50.200"
VPN_COUNTRY="Brazil"
WG_INTERFACE="${VPN_IF}"
VPN_SERVICE="openvpn-brazil"
DASHBOARD_PORT="8080"
EOF
chmod 600 /etc/pi-vpn-gateway/env

tee /etc/NetworkManager/conf.d/99-pi-vpn-gateway.conf > /dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:${IFACE_AP}
EOF
systemctl reload NetworkManager
sleep 2

tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=${IFACE_AP}
driver=nl80211
ctrl_interface=/run/hostapd
ctrl_interface_group=0
ssid=Home-BR
hw_mode=g
channel=6
ieee80211n=0
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${PASS}
ignore_broadcast_ssid=0
beacon_int=100
EOF
echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' > /etc/default/hostapd

mkdir -p /etc/systemd/system/hostapd.service.d
tee /etc/systemd/system/hostapd.service.d/regdomain.conf > /dev/null <<'EOF'
[Service]
ExecStartPre=/usr/sbin/iw reg set BR
ExecStartPre=/bin/sleep 1
EOF

tee /etc/pi-vpn-gateway/dnsmasq-dhcp.conf > /dev/null <<EOF
port=0
interface=${IFACE_AP}
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.200,255.255.255.0,12h
dhcp-option=option:router,${AP_IP}
dhcp-option=option:dns-server,${AP_IP}
dhcp-leasefile=/var/lib/misc/dnsmasq.leases
log-dhcp
log-facility=/var/log/pi-vpn-gateway/dnsmasq-dhcp.log
EOF

if [[ -f /etc/pihole/setupVars.conf ]]; then
  sed -i 's/^DHCP_ACTIVE=.*/DHCP_ACTIVE=false/' /etc/pihole/setupVars.conf
fi
mv /etc/dnsmasq.d/02-pihole-dhcp.conf /etc/dnsmasq.d/02-pihole-dhcp.conf.disabled 2>/dev/null || true
tee /etc/dnsmasq.d/pi-vpn-gateway.conf > /dev/null <<EOF
interface=${IFACE_AP}
bind-interfaces
listen-address=${AP_IP}
no-dhcp-interface=${IFACE_UPLINK}
no-resolv
server=1.1.1.1
server=1.0.0.1
EOF

# Firewall — DHCP must allow 0.0.0.0 (clients have no IP yet)
tee /etc/nftables.d/pi-vpn-gateway.nft > /dev/null <<EOF
#!/usr/sbin/nft -f
define AP_IFACE = ${IFACE_AP}
define UPLINK_IFACE = ${IFACE_UPLINK}
define VPN_IFACE = ${VPN_IF}
define AP_NET = ${AP_SUBNET}
define AP_IP = ${AP_IP}

table inet pi_vpn_gateway {
  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state established,related accept
    iifname \$AP_IFACE udp dport 67 accept
    iifname \$AP_IFACE ip saddr \$AP_NET accept
    ip saddr != \$AP_NET tcp dport 22 accept
    ip saddr != \$AP_NET icmp type echo-request accept
    iifname \$UPLINK_IFACE tcp dport 22 accept
    iifname \$UPLINK_IFACE icmp type echo-request accept
    iifname \$UPLINK_IFACE udp dport 68 accept
  }
  chain forward {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    iifname \$AP_IFACE oifname \$VPN_IFACE tcp flags syn tcp option maxseg size set rt mtu
    iifname \$AP_IFACE oifname \$VPN_IFACE ip saddr \$AP_NET accept
    iifname \$AP_IFACE oifname \$UPLINK_IFACE ip saddr \$AP_NET drop
    iifname \$VPN_IFACE oifname \$AP_IFACE accept
  }
  chain output {
    type filter hook output priority filter; policy accept;
  }
}
table ip pi_vpn_gateway_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname \$VPN_IFACE ip saddr \$AP_NET masquerade
  }
}
EOF
tee /etc/nftables.conf > /dev/null <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/pi-vpn-gateway.nft"
EOF

systemctl stop hostapd pi-vpn-gateway-dhcp 2>/dev/null || true
ip link set "${IFACE_AP}" up
ip addr flush dev "${IFACE_AP}" 2>/dev/null || true
ip addr add "${AP_IP}/24" dev "${IFACE_AP}"
iw dev "${IFACE_AP}" set power_save off 2>/dev/null || true
sysctl -w "net.ipv6.conf.${IFACE_AP}.disable_ipv6=1"

systemctl daemon-reload
systemctl enable hostapd pi-vpn-gateway-dhcp pi-vpn-gateway-firewall openvpn-brazil 2>/dev/null || true
systemctl disable --now dnsmasq 2>/dev/null || true
systemctl mask dnsmasq 2>/dev/null || true
systemctl restart hostapd
sleep 3
systemctl restart pi-vpn-gateway-dhcp
systemctl restart pihole-FTL
nft -f /etc/nftables.conf
systemctl restart openvpn-brazil
sleep 3
ip rule del iif wlan0 lookup 100 2>/dev/null || true
ip rule del iif wlan1 lookup 100 2>/dev/null || true
ip rule del from "${AP_SUBNET}" lookup 100 2>/dev/null || true
"${INSTALL}/firewall/vpn-route.sh" up 2>/dev/null || true

UPLINK_IP=$(ip -4 addr show "${IFACE_UPLINK}" | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
echo ""
echo "============================================"
echo " Home-BR password : ${PASS}"
echo " AP (${IFACE_AP})   : ${AP_IP}"
echo " Uplink IP        : ${UPLINK_IP:-NOT CONNECTED}"
echo "============================================"
systemctl is-active hostapd pi-vpn-gateway-dhcp pihole-FTL openvpn-brazil
hostapd_cli -i "${IFACE_AP}" status 2>/dev/null | grep -E "state|ssid" || true
