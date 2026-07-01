#!/usr/bin/env bash
# fix-ssh-access.sh — Restore SSH/ping from home LAN after Wi-Fi role swap
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo $0"; exit 1; }

INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
CONFIG="${CONFIG:-/etc/pi-vpn-gateway/env}"

echo "=== Flushing firewall (immediate SSH access) ==="
nft flush ruleset 2>/dev/null || true
systemctl stop pi-vpn-gateway-firewall 2>/dev/null || true

if [[ -f "$CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG"
  builtin="" usb="" _ifname="" driver=""
  for _path in /sys/class/net/wl*; do
    [[ -e "$_path" ]] || continue
    _ifname="${_path##*/}"
    driver=$(basename "$(readlink -f "/sys/class/net/$_ifname/device/driver" 2>/dev/null)" 2>/dev/null || true)
    case "$driver" in
      brcmfmac|brcm*) builtin="$_ifname" ;;
      rt2800usb|rt2x00*) usb="$_ifname" ;;
    esac
  done
  if [[ -n "$builtin" && -n "$usb" ]]; then
    sed -i "s/^IFACE_AP=.*/IFACE_AP=\"$builtin\"/" "$CONFIG"
    sed -i "s/^IFACE_UPLINK=.*/IFACE_UPLINK=\"$usb\"/" "$CONFIG"
    echo "Updated env: AP=$builtin, uplink=$usb"
  fi
fi

if [[ -x "$INSTALL_ROOT/firewall/install-rules.sh" ]]; then
  echo "=== Reinstalling firewall rules ==="
  "$INSTALL_ROOT/firewall/install-rules.sh"
  systemctl start pi-vpn-gateway-firewall
fi

echo "=== Done — try SSH from your Mac ==="
ip -br addr show | grep -E 'wlan|eth'
