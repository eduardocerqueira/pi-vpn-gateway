#!/usr/bin/env bash
# configure.sh — Interactive configuration for Pi NordVPN Wi-Fi Gateway
set -euo pipefail

INSTALL_ROOT="${INSTALL_ROOT:-/opt/pi-vpn-gateway}"
CONFIG_DIR="${CONFIG_DIR:-/etc/pi-vpn-gateway}"
ENV_FILE="$CONFIG_DIR/env"
TEMPLATE_DIR="$INSTALL_ROOT"

log() { echo "[configure] $*"; }
die() { log "ERROR: $*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
}

prompt() {
  local var="$1" prompt_text="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    read -rp "$prompt_text [$default]: " value
    value="${value:-$default}"
  else
    read -rp "$prompt_text: " value
  fi
  printf -v "$var" '%s' "$value"
}

prompt_secret() {
  local var="$1" prompt_text="$2"
  read -rsp "$prompt_text: " value
  echo
  printf -v "$var" '%s' "$value"
}

load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
  fi
}

save_env() {
  mkdir -p "$CONFIG_DIR"
  cat > "$ENV_FILE" <<EOF
# Pi VPN Gateway configuration — generated $(date -Iseconds)
IFACE_UPLINK="${IFACE_UPLINK}"
IFACE_AP="${IFACE_AP}"
HOME_SSID="${HOME_SSID}"
AP_SSID="${AP_SSID}"
AP_PASSPHRASE="${AP_PASSPHRASE}"
AP_SUBNET="${AP_SUBNET}"
AP_IP="${AP_IP}"
AP_DHCP_START="${AP_DHCP_START}"
AP_DHCP_END="${AP_DHCP_END}"
VPN_COUNTRY="${VPN_COUNTRY}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8080}"
EOF
  chmod 600 "$ENV_FILE"
}

render_template() {
  local template="$1" output="$2"
  envsubst < "$template" > "$output"
}

configure_uplink() {
  log "Configuring uplink ($IFACE_UPLINK) → $HOME_SSID"

  # Skip if already connected to the target network
  local current_ssid
  current_ssid=$(nmcli -t -f ACTIVE,SSID dev wifi | grep '^yes' | cut -d: -f2 | head -1)
  if [[ "$current_ssid" == "$HOME_SSID" ]] && nmcli -t -f DEVICE,STATE dev status | grep -q "^${IFACE_UPLINK}:connected"; then
    log "Uplink already connected to $HOME_SSID — skipping reconnect"
    nmcli con modify "$HOME_SSID" connection.autoconnect yes 2>/dev/null || true
    return
  fi

  # Reuse stored NetworkManager password when not provided
  if [[ -z "${HOME_WIFI_PASSWORD:-}" ]]; then
    HOME_WIFI_PASSWORD=$(nmcli -s -g 802-11-wireless-security.psk connection show "$HOME_SSID" 2>/dev/null || true)
  fi
  [[ -n "${HOME_WIFI_PASSWORD:-}" ]] || die "HOME_WIFI_PASSWORD required (not found in NetworkManager)"

  nmcli radio wifi on 2>/dev/null || true
  rfkill unblock wifi 2>/dev/null || true

  # Remove stale connection profiles for this interface
  nmcli -t -f NAME,DEVICE con show | while IFS=: read -r name device; do
    [[ "$device" == "$IFACE_UPLINK" ]] && nmcli con delete "$name" 2>/dev/null || true
  done

  nmcli dev wifi rescan ifname "$IFACE_UPLINK" 2>/dev/null || true
  sleep 2

  nmcli dev wifi connect "$HOME_SSID" password "$HOME_WIFI_PASSWORD" ifname "$IFACE_UPLINK"
  nmcli con modify "$HOME_SSID" connection.autoconnect yes 2>/dev/null || \
    nmcli con modify "$(nmcli -t -f NAME,DEVICE con show | awk -F: -v d="$IFACE_UPLINK" '$2==d{print $1; exit}')" connection.autoconnect yes

  log "Uplink connected."
}

configure_ap_unmanaged() {
  log "Excluding $IFACE_AP from NetworkManager..."
  mkdir -p /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/99-pi-vpn-gateway.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${IFACE_AP}
EOF
  systemctl reload NetworkManager || systemctl restart NetworkManager
}

configure_hostapd() {
  log "Configuring hostapd on $IFACE_AP (SSID: $AP_SSID)..."
  export IFACE_AP AP_SSID AP_PASSPHRASE
  render_template "$TEMPLATE_DIR/hostapd/hostapd.conf.template" /etc/hostapd/hostapd.conf

  cat > /etc/default/hostapd <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF
}

configure_dnsmasq() {
  log "Configuring dnsmasq for AP clients..."
  export AP_IP AP_DHCP_START AP_DHCP_END IFACE_AP IFACE_UPLINK
  render_template "$TEMPLATE_DIR/dnsmasq/dnsmasq.conf.template" /etc/dnsmasq.d/pi-vpn-gateway.conf

  # Disable distro default dnsmasq config that binds to all interfaces
  if [[ -f /etc/dnsmasq.conf ]] && ! grep -q 'pi-vpn-gateway' /etc/dnsmasq.conf; then
    echo "# Managed by pi-vpn-gateway — see /etc/dnsmasq.d/pi-vpn-gateway.conf" >> /etc/dnsmasq.conf
  fi
}

append_wg_hooks() {
  local conf="$1"
  grep -q 'vpn-route.sh' "$conf" && return
  cat >> "$conf" <<'EOF'

PostUp = /opt/pi-vpn-gateway/firewall/vpn-route.sh up
PostDown = /opt/pi-vpn-gateway/firewall/vpn-route.sh down
EOF
}

configure_wireguard() {
  log "Setting up WireGuard ($WG_INTERFACE) for $VPN_COUNTRY..."
  export WG_INTERFACE VPN_COUNTRY NORDVPN_TOKEN NORDVPN_PRIVATE_KEY

  if [[ -n "${NORDVPN_WG_CONF:-}" && -f "$NORDVPN_WG_CONF" ]]; then
    install -m 600 "$NORDVPN_WG_CONF" "/etc/wireguard/${WG_INTERFACE}.conf"
    append_wg_hooks "/etc/wireguard/${WG_INTERFACE}.conf"
  elif [[ -n "${NORDVPN_TOKEN:-}" ]]; then
    "$INSTALL_ROOT/wireguard/fetch-nordvpn-config.sh"
  elif [[ -n "${NORDVPN_PRIVATE_KEY:-}" ]]; then
    "$INSTALL_ROOT/wireguard/generate-nordvpn-config.sh"
  else
    die "Provide NORDVPN_WG_CONF, NORDVPN_TOKEN, or NORDVPN_PRIVATE_KEY"
  fi
}

configure_firewall() {
  log "Installing nftables firewall (kill switch)..."
  export IFACE_AP IFACE_UPLINK WG_INTERFACE AP_SUBNET
  "$INSTALL_ROOT/firewall/install-rules.sh"
}

configure_ap_interface() {
  log "Bringing up $IFACE_AP with IP $AP_IP..."
  ip link set "$IFACE_AP" up
  ip addr flush dev "$IFACE_AP"
  ip addr add "${AP_IP}/24" dev "$IFACE_AP"
}

enable_services() {
  log "Enabling and starting services..."

  systemctl unmask hostapd dnsmasq 2>/dev/null || true
  systemctl enable hostapd dnsmasq
  systemctl enable "wg-quick@${WG_INTERFACE}"
  systemctl enable pi-vpn-gateway.service
  systemctl enable pi-vpn-gateway-firewall.service
  systemctl enable pi-vpn-gateway-dashboard.service 2>/dev/null || true
  systemctl enable pi-vpn-gateway-health.timer

  systemctl restart pi-vpn-gateway-firewall.service
  systemctl restart "wg-quick@${WG_INTERFACE}"
  systemctl restart hostapd
  systemctl restart dnsmasq
  systemctl restart pi-vpn-gateway.service
  systemctl restart pi-vpn-gateway-dashboard.service 2>/dev/null || true
  systemctl start pi-vpn-gateway-health.timer
}

print_summary() {
  cat <<EOF

=== Configuration complete ===

Uplink:  $IFACE_UPLINK → $HOME_SSID
AP:      $IFACE_AP → SSID "$AP_SSID" (${AP_IP}/24)
VPN:     $WG_INTERFACE → $VPN_COUNTRY (WireGuard/NordLynx)
Dashboard: http://${AP_IP}:${DASHBOARD_PORT}

Wi-Fi QR code saved to: $CONFIG_DIR/wifi-qr.png

Useful commands:
  systemctl status pi-vpn-gateway.service
  systemctl status wg-quick@${WG_INTERFACE}
  journalctl -u pi-vpn-gateway.service -f
  $INSTALL_ROOT/backup.sh

EOF
}

generate_wifi_qr() {
  if command -v qrencode &>/dev/null; then
    qrencode -o "$CONFIG_DIR/wifi-qr.png" \
      "WIFI:T:WPA;S:${AP_SSID};P:${AP_PASSPHRASE};;"
    log "Wi-Fi QR code: $CONFIG_DIR/wifi-qr.png"
  fi
}

main() {
  require_root
  [[ -d "$INSTALL_ROOT" ]] || die "Run install.sh first"

  load_env

  IFACE_UPLINK="${IFACE_UPLINK:-wlan0}"
  IFACE_AP="${IFACE_AP:-wlan1}"
  AP_SSID="${AP_SSID:-Home-BR}"
  AP_SUBNET="${AP_SUBNET:-192.168.50.0/24}"
  AP_IP="${AP_IP:-192.168.50.1}"
  AP_DHCP_START="${AP_DHCP_START:-192.168.50.10}"
  AP_DHCP_END="${AP_DHCP_END:-192.168.50.200}"
  VPN_COUNTRY="${VPN_COUNTRY:-Brazil}"
  WG_INTERFACE="${WG_INTERFACE:-wg0}"
  DASHBOARD_PORT="${DASHBOARD_PORT:-8080}"

  echo "=== Pi VPN Gateway Configuration ==="
  echo ""

  if [[ -z "${HOME_SSID:-}" ]]; then
    HOME_SSID=$(nmcli -t -f ACTIVE,SSID dev wifi | grep '^yes' | cut -d: -f2 | head -1)
    [[ -n "$HOME_SSID" ]] && log "Detected uplink SSID: $HOME_SSID"
  fi
  if [[ -z "${HOME_SSID:-}" ]]; then
    prompt HOME_SSID "Home Wi-Fi SSID (uplink)"
    prompt_secret HOME_WIFI_PASSWORD "Home Wi-Fi password"
  else
    log "Using HOME_SSID=$HOME_SSID"
    if [[ -z "${HOME_WIFI_PASSWORD:-}" ]]; then
      HOME_WIFI_PASSWORD=$(nmcli -s -g 802-11-wireless-security.psk connection show "$HOME_SSID" 2>/dev/null || true)
      [[ -n "$HOME_WIFI_PASSWORD" ]] && log "Using stored NetworkManager password for $HOME_SSID"
    fi
  fi

  if [[ -z "${AP_PASSPHRASE:-}" ]]; then
    AP_PASSPHRASE=$(openssl rand -base64 12 | tr -d '/+=' | head -c 16)
    log "Generated AP passphrase (save this): $AP_PASSPHRASE"
  fi

  if [[ ! -f "/etc/wireguard/${WG_INTERFACE}.conf" ]]; then
    if [[ -n "${NORDVPN_WG_CONF:-}" || -n "${NORDVPN_TOKEN:-}" || -n "${NORDVPN_PRIVATE_KEY:-}" ]]; then
      log "Using WireGuard credentials from environment"
    else
    echo ""
    echo "WireGuard setup — choose one:"
    echo "  1) Paste path to existing NordVPN .conf file"
    echo "  2) Fetch via NordVPN access token (from nordvpn.com account)"
    echo "  3) Generate from NordVPN private key (NordLynx)"
    read -rp "Choice [2]: " wg_choice
    wg_choice="${wg_choice:-2}"

    case "$wg_choice" in
      1)
        prompt NORDVPN_WG_CONF "Path to WireGuard .conf file"
        [[ -f "$NORDVPN_WG_CONF" ]] || die "File not found: $NORDVPN_WG_CONF"
        ;;
      2)
        prompt NORDVPN_TOKEN "NordVPN access token"
        ;;
      3)
        prompt NORDVPN_PRIVATE_KEY "NordVPN WireGuard private key"
        ;;
      *) die "Invalid choice" ;;
    esac
    fi
  fi

  save_env
  configure_ap_unmanaged
  configure_uplink
  configure_ap_interface
  configure_hostapd
  configure_dnsmasq
  configure_wireguard
  configure_firewall
  enable_services
  generate_wifi_qr
  print_summary
}

main "$@"
