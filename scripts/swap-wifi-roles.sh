#!/usr/bin/env bash
# swap-wifi-roles.sh — Use built-in Wi-Fi for AP (range), USB adapter for uplink
# Run ON THE PI with local console or after USB uplink is confirmed working.
set -euo pipefail

CONFIG="${CONFIG:-/etc/pi-vpn-gateway/env}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG — run configure.sh first"; exit 1; }
# shellcheck source=/dev/null
source "$CONFIG"

BUILTIN="" USB=""
for _path in /sys/class/net/wl*; do
  [[ -e "$_path" ]] || continue
  ifname="${_path##*/}"
  driver=$(basename "$(readlink -f "/sys/class/net/$ifname/device/driver" 2>/dev/null)" 2>/dev/null || true)
  case "$driver" in
    brcmfmac|brcm*) BUILTIN="$ifname" ;;
    rt2800usb|rt2x00*) USB="$ifname" ;;
  esac
done

[[ -n "$BUILTIN" && -n "$USB" ]] || { echo "Need both built-in and USB Wi-Fi"; exit 1; }
IFACE_AP="$BUILTIN"
IFACE_UPLINK="$USB"

echo "AP (built-in): $IFACE_AP"
echo "Uplink (USB):  $IFACE_UPLINK"

HOME_PASS=$(nmcli -s -g 802-11-wireless-security.psk connection show "$HOME_SSID" 2>/dev/null || true)
[[ -n "$HOME_PASS" ]] || read -rsp "Home Wi-Fi password for $HOME_SSID: " HOME_PASS; echo

echo "=== 1. Connect USB uplink first (keep current SSH path alive) ==="
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-pi-vpn-gateway.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${IFACE_AP}
EOF
systemctl reload NetworkManager
sleep 3
nmcli dev wifi rescan ifname "$IFACE_UPLINK" 2>/dev/null || true
sleep 2
nmcli dev wifi connect "$HOME_SSID" password "$HOME_PASS" ifname "$IFACE_UPLINK" name "${HOME_SSID}-usb" || true
nmcli con modify "${HOME_SSID}-usb" connection.autoconnect yes 2>/dev/null || true

UPLINK_IP=""
for _ in $(seq 1 30); do
  UPLINK_IP=$(nmcli -t -f IP4.ADDRESS dev show "$IFACE_UPLINK" 2>/dev/null | cut -d/ -f1 | head -1)
  [[ -n "$UPLINK_IP" ]] && break
  sleep 2
done
echo "Uplink IP on $IFACE_UPLINK: ${UPLINK_IP:-FAILED}"
[[ -n "$UPLINK_IP" ]] || { echo "USB uplink failed — aborting before touching AP interface"; exit 1; }

echo "=== 2. Write config ==="
sed -i "s/^IFACE_UPLINK=.*/IFACE_UPLINK=\"$IFACE_UPLINK\"/" "$CONFIG"
sed -i "s/^IFACE_AP=.*/IFACE_AP=\"$IFACE_AP\"/" "$CONFIG"
# shellcheck source=/dev/null
source "$CONFIG"

export IFACE_AP AP_SSID AP_PASSPHRASE IFACE_UPLINK AP_IP AP_DHCP_START AP_DHCP_END WG_INTERFACE AP_SUBNET
envsubst < "$INSTALL_ROOT/hostapd/hostapd.conf.template" > /etc/hostapd/hostapd.conf

mkdir -p /etc/systemd/system/hostapd.service.d
cat > /etc/systemd/system/hostapd.service.d/regdomain.conf <<EOF
[Service]
ExecStartPre=/usr/sbin/iw reg set BR
ExecStartPre=/bin/sh -c '/usr/sbin/ip link set ${IFACE_AP} down 2>/dev/null; sleep 1; /usr/sbin/ip link set ${IFACE_AP} up'
ExecStartPre=/bin/sleep 2
EOF

envsubst < "$INSTALL_ROOT/dnsmasq/dnsmasq.conf.template" > /etc/dnsmasq.d/pi-vpn-gateway.conf
export IFACE_AP IFACE_UPLINK WG_INTERFACE AP_SUBNET AP_IP
envsubst '${IFACE_AP} ${IFACE_UPLINK} ${WG_INTERFACE} ${AP_SUBNET} ${AP_IP}' \
  < "$INSTALL_ROOT/firewall/pi-vpn-gateway.nft.template" \
  > /etc/nftables.d/pi-vpn-gateway.nft

echo "=== 3. Switch AP to built-in Wi-Fi ==="
systemctl stop hostapd
nmcli dev disconnect "$IFACE_AP" 2>/dev/null || true
sleep 2
ip addr flush dev "$IFACE_AP" 2>/dev/null || true
ip link set "$IFACE_AP" up
ip addr add "${AP_IP}/24" dev "$IFACE_AP"

systemctl daemon-reload
systemctl restart hostapd
sleep 4
systemctl restart pihole-FTL 2>/dev/null || systemctl restart dnsmasq 2>/dev/null || true
systemctl restart pi-vpn-gateway-firewall
systemctl restart pi-vpn-gateway
"$INSTALL_ROOT/firewall/vpn-route.sh" up || true

echo "=== Done ==="
hostapd_cli -i "$IFACE_AP" status 2>/dev/null | grep -E "state|ssid|channel" || true
iw dev "$IFACE_AP" info | grep -E "ssid|type|txpower"
nmcli -t dev status | grep wlan
echo "SSH via home LAN should use uplink IP: $UPLINK_IP"
