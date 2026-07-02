#!/usr/bin/env bash
# set-ap-password.sh — Update Home-BR Wi-Fi password and restart AP
set -euo pipefail

CONFIG="${CONFIG:-/etc/pi-vpn-gateway/env}"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0 [new-password]"; exit 1; }
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG"; exit 1; }

NEW_PASS="${1:-}"
[[ -n "$NEW_PASS" ]] || read -rsp "New AP passphrase: " NEW_PASS; echo
[[ -n "$NEW_PASS" ]] || { echo "Password cannot be empty"; exit 1; }

# shellcheck source=/dev/null
source "$CONFIG"
AP_SSID="${AP_SSID:-Home-BR}"

# Update env (quoted for shell)
if grep -q '^AP_PASSPHRASE=' "$CONFIG"; then
  sed -i "s|^AP_PASSPHRASE=.*|AP_PASSPHRASE=\"${NEW_PASS}\"|" "$CONFIG"
else
  echo "AP_PASSPHRASE=\"${NEW_PASS}\"" >> "$CONFIG"
fi

# hostapd reads the value literally — do NOT wrap in quotes (that becomes part of the PSK)
if [[ -f /etc/hostapd/hostapd.conf ]]; then
  grep -v '^wpa_passphrase=' /etc/hostapd/hostapd.conf > /etc/hostapd/hostapd.conf.tmp
  printf 'wpa_passphrase=%s\n' "$NEW_PASS" >> /etc/hostapd/hostapd.conf.tmp
  mv /etc/hostapd/hostapd.conf.tmp /etc/hostapd/hostapd.conf
fi

# Wi-Fi QR (escape ; : \ , for WPA QR format)
if command -v qrencode &>/dev/null; then
  qr_pass="$NEW_PASS"
  qr_pass="${qr_pass//\\/\\\\}"
  qr_pass="${qr_pass//;/\\;}"
  qr_pass="${qr_pass//:/\\:}"
  qr_pass="${qr_pass//,/\\,}"
  qrencode -o "$(dirname "$CONFIG")/wifi-qr.png" -s 8 \
    "WIFI:T:WPA;S:${AP_SSID};P:${qr_pass};;"
fi

systemctl restart hostapd
echo "AP password updated for SSID ${AP_SSID}. hostapd restarted."
