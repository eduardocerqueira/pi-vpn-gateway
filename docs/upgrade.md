# Upgrade Guide

## Updating the Gateway Software

### Standard upgrade (recommended)

```bash
cd ~/pi-vpn-gateway   # or wherever you cloned the repo
git pull

sudo ./install.sh     # updates packages and redeploys files
```

`install.sh` is idempotent — safe to re-run. It updates packages, syncs files to `/opt/pi-vpn-gateway`, and refreshes systemd units.

### After upgrading

```bash
# Reload systemd if units changed
sudo systemctl daemon-reload

# Restart services
sudo systemctl restart pi-vpn-gateway-firewall
sudo systemctl restart wg-quick@wg0
sudo systemctl restart hostapd dnsmasq
sudo systemctl restart pi-vpn-gateway pi-vpn-gateway-dashboard

# Verify
systemctl status pi-vpn-gateway wg-quick@wg0 hostapd
```

## Upgrading Raspberry Pi OS

Upgrade the base OS separately from the gateway software:

```bash
sudo apt update
sudo apt full-upgrade
sudo reboot
```

After reboot, verify all services came back:

```bash
systemctl is-active hostapd dnsmasq wg-quick@wg0 pi-vpn-gateway
```

## Upgrading NordVPN Server

To switch Brazil servers or refresh WireGuard keys:

```bash
# Edit country if needed
sudo nano /etc/pi-vpn-gateway/env

# Regenerate WireGuard config
sudo /opt/pi-vpn-gateway/wireguard/generate-nordvpn-config.sh
sudo systemctl restart wg-quick@wg0
```

If NordVPN rotated your NordLynx private key, update `NORDVPN_PRIVATE_KEY` in env or re-run `configure.sh` with a fresh token.

## Configuration Migration

When moving to a new SD card or Pi:

1. Run `sudo ./backup.sh` on the old system
2. Flash fresh Raspberry Pi OS on new SD card
3. Clone repo and run `install.sh` + restore backup (see [recovery.md](recovery.md))

## Version Pinning

To stay on a known-good release:

```bash
git checkout v1.0.0   # replace with tag
sudo ./install.sh
```

## Pre-upgrade Backup

Always backup before major changes:

```bash
sudo ./backup.sh /home/pi/backups/pre-upgrade
```

## Changelog

Track changes in git:

```bash
git log --oneline
```

When upgrading across major versions, read the README and docs for breaking changes.
