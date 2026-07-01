#!/usr/bin/env bash
# backup.sh — Backup Pi VPN Gateway configuration
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
BACKUP_DIR="${1:-./backups/pi-vpn-gateway-$(date +%Y%m%d-%H%M%S)}"

log() { echo "[backup] $*"; }

mkdir -p "$BACKUP_DIR"

log "Backing up to $BACKUP_DIR"

# Environment and secrets (restricted permissions preserved)
[[ -f "$CONFIG_DIR/env" ]] && cp -a "$CONFIG_DIR/env" "$BACKUP_DIR/"
[[ -f "$CONFIG_DIR/wifi-qr.png" ]] && cp -a "$CONFIG_DIR/wifi-qr.png" "$BACKUP_DIR/"

# Service configs (WireGuard key material included — keep reading)
for f in \
  /etc/hostapd/hostapd.conf \
  /etc/dnsmasq.d/pi-vpn-gateway.conf \
  /etc/wireguard/wg0.conf \
  /etc/nftables.conf \
  /etc/nftables.d/pi-vpn-gateway.nft \
  /etc/NetworkManager/conf.d/99-pi-vpn-gateway.conf \
  /etc/sysctl.d/99-pi-vpn-gateway.conf; do
  [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/$(basename "$f")"
done

# NetworkManager uplink profile
nmcli -t -f NAME,TYPE con show | while IFS=: read -r name type; do
  [[ "$type" == "802-11-wireless" ]] || continue
  nmcli con export "$name" "$BACKUP_DIR/nm-${name}.nmconnection" 2>/dev/null || true
done

# Systemd unit list
systemctl list-unit-files 'pi-vpn-gateway*' 'wg-quick@wg0' hostapd dnsmasq \
  --no-pager > "$BACKUP_DIR/systemd-units.txt" 2>/dev/null || true

tar -czf "${BACKUP_DIR}.tar.gz" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
rm -rf "$BACKUP_DIR"

log "Backup archive: ${BACKUP_DIR}.tar.gz"
echo "${BACKUP_DIR}.tar.gz"
