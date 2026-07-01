# Configuration Guide

## Prerequisites

1. Raspberry Pi OS Lite installed and updated (`sudo apt update && sudo apt full-upgrade`)
2. RT5370 USB adapter plugged in (should appear as `wlan1`)
3. NordVPN account with WireGuard / NordLynx access

## Network Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `IFACE_UPLINK` | `wlan0` | Built-in Wi-Fi → home router |
| `IFACE_AP` | `wlan1` | RT5370 USB → access point |
| `AP_SSID` | `Home-BR` | Broadcast SSID for TVs |
| `AP_IP` | `192.168.50.1` | Gateway IP for AP subnet |
| `AP_SUBNET` | `192.168.50.0/24` | AP client subnet |
| `AP_DHCP_START` | `192.168.50.10` | DHCP range start |
| `AP_DHCP_END` | `192.168.50.200` | DHCP range end |
| `VPN_COUNTRY` | `Brazil` | NordVPN server country |
| `WG_INTERFACE` | `wg0` | WireGuard interface name |
| `DASHBOARD_PORT` | `8080` | Web dashboard port |

All values are stored in `/etc/pi-vpn-gateway/env` after running `configure.sh`.

## NordVPN WireGuard Credentials

Choose one of three methods during `configure.sh`:

### Option A — Access token (recommended)

1. Log in at [Nord Account](https://my.nordaccount.com/)
2. Go to **NordVPN → Access Tokens** and create a token
3. Paste the token when prompted

The installer fetches your NordLynx private key and a Brazil WireGuard server automatically.

### Option B — NordLynx private key

1. In Nord Account → **Manual Setup → NordLynx**, copy your private key
2. Choose option 3 in `configure.sh`

### Option C — Manual `.conf` file

1. Download a Brazil WireGuard config from Nord Account manual setup
2. Provide the file path when prompted

PostUp/PostDown hooks are appended automatically for kill-switch integration.

## Non-interactive Configuration

Set environment variables before running `configure.sh`:

```bash
export HOME_SSID="YourHomeWiFi"
export HOME_WIFI_PASSWORD="your-password"
export AP_PASSPHRASE="your-ap-password"
export NORDVPN_TOKEN="your-nordvpn-token"
export VPN_COUNTRY="Brazil"

sudo -E ./configure.sh
```

## Changing Settings Later

Edit `/etc/pi-vpn-gateway/env`, then re-run the relevant step:

```bash
# Change AP password
sudo nano /etc/hostapd/hostapd.conf   # update wpa_passphrase
sudo systemctl restart hostapd

# Change VPN country
sudo nano /etc/pi-vpn-gateway/env     # set VPN_COUNTRY
sudo /opt/pi-vpn-gateway/wireguard/generate-nordvpn-config.sh
sudo systemctl restart wg-quick@wg0

# Change home Wi-Fi
sudo nmcli dev wifi connect "NewSSID" password "newpass" ifname wlan0
```

## Verifying Configuration

```bash
# AP is broadcasting
iw dev wlan1 info
systemctl status hostapd

# VPN tunnel up
wg show wg0
curl --interface wg0 https://ifconfig.me

# Kill switch active (should fail when wg0 is down)
sudo systemctl stop wg-quick@wg0
# TVs should lose internet; home network unaffected

sudo systemctl start wg-quick@wg0
```

## Firewall Rules

Rules live in `/etc/nftables.d/pi-vpn-gateway.nft`:

- AP clients (`192.168.50.0/24`) may forward **only** to `wg0`
- Traffic from AP to uplink (`wlan0`) is **dropped** (kill switch)
- NAT masquerade on `wg0` for AP subnet

## Files Reference

| File | Purpose |
|------|---------|
| `/etc/pi-vpn-gateway/env` | Main configuration |
| `/etc/hostapd/hostapd.conf` | AP settings |
| `/etc/dnsmasq.d/pi-vpn-gateway.conf` | DHCP/DNS for TVs |
| `/etc/wireguard/wg0.conf` | WireGuard tunnel |
| `/etc/nftables.d/pi-vpn-gateway.nft` | Firewall + kill switch |
| `/var/log/pi-vpn-gateway/` | Application logs |
