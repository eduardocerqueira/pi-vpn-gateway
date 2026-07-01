# Pi VPN Gateway

A dedicated Raspberry Pi appliance that broadcasts a **Brazil-only Wi-Fi network** for Samsung Tizen TVs. TVs connect to the Pi's access point; all their traffic routes through NordVPN WireGuard (NordLynx) while your home network stays untouched.

## Architecture

```text
                Internet
                    |
              ISP Router
             Wi-Fi: Home
                    ^
                    |
          Raspberry Pi 3B
      +-----------------------+
      | wlan0 (built-in)      |  ← connects to home Wi-Fi (uplink)
      +-----------------------+
                 |
          WireGuard/NordVPN
                 |
      +-----------------------+
      | wlan1 (RT5370 USB)    |  ← AP: Home-BR
      +-----------------------+
                 |
        Samsung TVs connect here
```

## Hardware

| Component | Notes |
|-----------|-------|
| Raspberry Pi 3 Model B | Raspberry Pi OS Lite (64-bit recommended) |
| RT5370 USB Wi-Fi adapter | AP mode on `wlan1` |
| Built-in Wi-Fi | Uplink to home router on `wlan0` |
| NordVPN subscription | WireGuard / NordLynx credentials |

## Quick Start

### 1. Flash Raspberry Pi OS Lite

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/). Enable SSH and set hostname (e.g. `pi-vpn-gateway`).

### 2. Clone and install

```bash
git clone https://github.com/eduardo/pi-vpn-gateway.git
cd pi-vpn-gateway
sudo ./install.sh
```

### 3. Configure

```bash
sudo ./configure.sh
```

You'll be prompted for:

- Home Wi-Fi SSID and password (uplink)
- AP passphrase for `Home-BR`
- NordVPN WireGuard credentials (token, private key, or `.conf` file)

### 4. Connect TVs

On your Samsung TV, connect to Wi-Fi **`Home-BR`**. Traffic will egress from Brazil via NordVPN.

Dashboard: `http://192.168.50.1:8080`

## Repository Layout

```text
pi-vpn-gateway/
├── README.md
├── install.sh              # Package install + deploy
├── configure.sh            # Interactive setup
├── backup.sh               # Config backup
├── docs/
│   ├── configuration.md
│   ├── recovery.md
│   ├── upgrade.md
│   └── troubleshooting.md
├── hostapd/
├── dnsmasq/
├── wireguard/
├── firewall/
├── systemd/
└── dashboard/
```

## Features

- **Split routing** — only AP clients use VPN; Pi uplink stays on home network
- **Kill switch** — nftables blocks AP traffic if VPN drops
- **DNS through VPN** — dnsmasq forwards to NordVPN DNS when tunnel is up
- **Auto-reconnect** — health timer restarts WireGuard on failure
- **Boot persistence** — all services enabled via systemd
- **Web dashboard** — VPN status, clients, DHCP leases, Wi-Fi QR code

## Useful Commands

```bash
# Service status
systemctl status pi-vpn-gateway wg-quick@wg0 hostapd dnsmasq

# Live logs
journalctl -u pi-vpn-gateway -f
journalctl -u wg-quick@wg0 -f

# Manual backup
sudo ./backup.sh

# Restart VPN
sudo systemctl restart wg-quick@wg0
```

## Documentation

- [Configuration guide](docs/configuration.md)
- [Recovery instructions](docs/recovery.md)
- [Upgrade guide](docs/upgrade.md)
- [Troubleshooting](docs/troubleshooting.md)

## License

MIT
