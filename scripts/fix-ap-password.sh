#!/usr/bin/env bash
# fix-ap-password.sh — Reset Home-BR Wi-Fi password (run on Pi console when phone says wrong password)
# Usage: sudo bash fix-ap-password.sh [new-password]
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

CONFIG="/etc/pi-vpn-gateway/env"
HOSTAPD="/etc/hostapd/hostapd.conf"
NEW_PASS="${1:-HomeBR2026}"

if [[ ${#NEW_PASS} -lt 8 || ${#NEW_PASS} -gt 63 ]]; then
  echo "Password must be 8–63 characters (WPA2 requirement)."
  exit 1
fi

AP_IF=""
for _path in /sys/class/net/wl*; do
  [[ -e "$_path" ]] || continue
  _if="${_path##*/}"
  driver=$(basename "$(readlink -f "/sys/class/net/$_if/device/driver" 2>/dev/null)" 2>/dev/null || true)
  case "$driver" in
    brcmfmac|brcm*) AP_IF="$_if" ;;
  esac
done
AP_IF="${AP_IF:-wlan0}"

echo "=== Current password on Pi ==="
grep '^wpa_passphrase=' "$HOSTAPD" 2>/dev/null || echo "(no hostapd.conf)"
grep '^AP_PASSPHRASE=' "$CONFIG" 2>/dev/null || echo "(no env file)"

echo ""
echo "=== Setting new AP password on $AP_IF ==="

mkdir -p /etc/pi-vpn-gateway
if [[ -f "$CONFIG" ]]; then
  if grep -q '^AP_PASSPHRASE=' "$CONFIG"; then
    sed -i "s|^AP_PASSPHRASE=.*|AP_PASSPHRASE=\"${NEW_PASS}\"|" "$CONFIG"
  else
    echo "AP_PASSPHRASE=\"${NEW_PASS}\"" >> "$CONFIG"
  fi
else
  cat > "$CONFIG" <<EOF
IFACE_AP="$AP_IF"
IFACE_UPLINK="wlan1"
AP_SSID="Home-BR"
AP_PASSPHRASE="$NEW_PASS"
EOF
  chmod 600 "$CONFIG"
fi

if [[ -f "$HOSTAPD" ]]; then
  grep -v '^wpa_passphrase=' "$HOSTAPD" > "${HOSTAPD}.tmp"
  printf 'wpa_passphrase=%s\n' "$NEW_PASS" >> "${HOSTAPD}.tmp"
  mv "${HOSTAPD}.tmp" "$HOSTAPD"
  sed -i "s|^interface=.*|interface=${AP_IF}|" "$HOSTAPD"
else
  cat > "$HOSTAPD" <<EOF
interface=${AP_IF}
driver=nl80211
ctrl_interface=/run/hostapd
ssid=Home-BR
hw_mode=g
channel=6
ieee80211n=0
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${NEW_PASS}
ignore_broadcast_ssid=0
beacon_int=100
EOF
fi

# Avoid sshd hanging on reverse DNS (banner exchange timeout from Mac)
if grep -q '^#UseDNS' /etc/ssh/sshd_config 2>/dev/null; then
  sed -i 's/^#UseDNS.*/UseDNS no/' /etc/ssh/sshd_config
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
fi

systemctl restart hostapd
sleep 2

echo ""
echo "=== hostapd status ==="
hostapd_cli -i "$AP_IF" status 2>&1 | grep -E 'state|ssid' || journalctl -u hostapd -n 5 --no-pager

if command -v qrencode &>/dev/null; then
  qrencode -t ANSIUTF8 "WIFI:T:WPA;S:Home-BR;P:${NEW_PASS};;"
  qrencode -o /etc/pi-vpn-gateway/wifi-qr.png -s 8 "WIFI:T:WPA;S:Home-BR;P:${NEW_PASS};;"
  echo "(QR saved to /etc/pi-vpn-gateway/wifi-qr.png)"
fi

echo ""
echo "============================================"
echo "  SSID:     Home-BR"
echo "  Password: ${NEW_PASS}"
echo "============================================"
echo "On iPhone: Forget Home-BR, then join with the password above."
