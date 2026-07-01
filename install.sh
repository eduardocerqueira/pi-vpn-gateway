#!/usr/bin/env bash
# install.sh — Automated installer for Pi NordVPN Wi-Fi Gateway
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
LOG_FILE="/var/log/pi-vpn-gateway-install.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

detect_interfaces() {
  # Built-in Wi-Fi is usually wlan0; USB adapter wlan1
  IFACE_UPLINK="${IFACE_UPLINK:-wlan0}"
  IFACE_AP="${IFACE_AP:-wlan1}"

  if ! ip link show "$IFACE_UPLINK" &>/dev/null; then
    die "Uplink interface $IFACE_UPLINK not found"
  fi
  if ! ip link show "$IFACE_AP" &>/dev/null; then
    log "WARNING: AP interface $IFACE_AP not found — plug in RT5370 before configure.sh"
  fi
}

install_packages() {
  log "Updating package lists..."
  apt-get update -qq

  log "Installing required packages..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    network-manager \
    hostapd \
    dnsmasq \
    wireguard \
    wireguard-tools \
    nftables \
    curl \
    jq \
    qrencode \
    python3 \
    python3-flask \
    iw \
    rfkill \
    rsync \
    gettext-base \
    openresolv

  # Prevent hostapd/dnsmasq from starting with distro defaults before we configure
  systemctl stop hostapd dnsmasq 2>/dev/null || true
  systemctl disable hostapd dnsmasq 2>/dev/null || true
  systemctl mask hostapd dnsmasq 2>/dev/null || true
}

deploy_files() {
  log "Deploying to $INSTALL_ROOT..."
  mkdir -p "$INSTALL_ROOT" "$CONFIG_DIR" /var/log/pi-vpn-gateway

  rsync -a --delete \
    --exclude '.git' \
    --exclude 'Raspberry_Pi_NordVPN_WiFi_Gateway_Project.md' \
    "$SCRIPT_DIR/" "$INSTALL_ROOT/"

  chmod +x "$INSTALL_ROOT"/install.sh \
             "$INSTALL_ROOT"/configure.sh \
             "$INSTALL_ROOT"/backup.sh \
             "$INSTALL_ROOT"/wireguard/*.sh \
             "$INSTALL_ROOT"/firewall/*.sh \
             "$INSTALL_ROOT"/systemd/*.sh 2>/dev/null || true
  ln -sfn "$INSTALL_ROOT" /opt/pi-vpn-gateway 2>/dev/null || true
}

enable_sysctl() {
  log "Enabling IP forwarding..."
  cat > /etc/sysctl.d/99-pi-vpn-gateway.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl -p /etc/sysctl.d/99-pi-vpn-gateway.conf
}

install_systemd_units() {
  log "Installing systemd units..."
  for unit in "$INSTALL_ROOT"/systemd/*.service "$INSTALL_ROOT"/systemd/*.timer; do
    [[ -f "$unit" ]] || continue
    install -m 644 "$unit" "/etc/systemd/system/$(basename "$unit")"
  done
  systemctl daemon-reload
}

main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  log "=== Pi VPN Gateway installer ==="

  detect_interfaces
  install_packages
  deploy_files
  enable_sysctl
  install_systemd_units

  log "Installation complete."
  log "Next step: sudo $INSTALL_ROOT/configure.sh"
  echo ""
  echo "Installation finished. Run configure.sh to set up Wi-Fi, VPN, and firewall:"
  echo "  sudo $INSTALL_ROOT/configure.sh"
}

main "$@"
