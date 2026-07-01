# Recovery Instructions

Use this guide when the gateway is misconfigured, unresponsive, or needs a clean rebuild.

## Quick Recovery Checklist

1. Can you SSH to the Pi via home network (`wlan0` IP)?
2. Is the RT5370 plugged in? (`ip link show wlan1`)
3. Are core services running?

```bash
systemctl status hostapd dnsmasq wg-quick@wg0 pi-vpn-gateway nftables
```

## Restore from Backup

If you ran `backup.sh` previously:

```bash
# On your laptop — copy backup to Pi
scp backups/pi-vpn-gateway-*.tar.gz pi@pi-vpn-gateway:/tmp/

# On the Pi
cd /tmp
tar -xzf pi-vpn-gateway-*.tar.gz
cd pi-vpn-gateway-*

sudo cp env /etc/pi-vpn-gateway/
sudo cp hostapd.conf /etc/hostapd/
sudo cp pi-vpn-gateway.conf /etc/dnsmasq.d/ 2>/dev/null || \
  sudo cp dnsmasq*.conf /etc/dnsmasq.d/pi-vpn-gateway.conf
sudo cp wg0.conf /etc/wireguard/
sudo cp pi-vpn-gateway.nft /etc/nftables.d/

sudo systemctl restart pi-vpn-gateway-firewall hostapd dnsmasq wg-quick@wg0 pi-vpn-gateway
```

## Reset NetworkManager Uplink

If the Pi lost home Wi-Fi connectivity:

```bash
# Connect via Ethernet or console
sudo nmcli radio wifi on
sudo nmcli dev wifi list ifname wlan0
sudo nmcli dev wifi connect "YourHomeSSID" password "yourpassword" ifname wlan0
```

## Reset Access Point

```bash
sudo ip link set wlan1 down
sudo ip addr flush dev wlan1
sudo ip link set wlan1 up
sudo ip addr add 192.168.50.1/24 dev wlan1
sudo systemctl restart hostapd dnsmasq
```

## Reset WireGuard

```bash
sudo systemctl stop wg-quick@wg0
sudo wg-quick down wg0 2>/dev/null || true

# Re-generate config
sudo /opt/pi-vpn-gateway/wireguard/generate-nordvpn-config.sh
sudo systemctl start wg-quick@wg0
```

## Factory Reset (Full Reinstall)

```bash
# Stop services
sudo systemctl disable --now pi-vpn-gateway pi-vpn-gateway-dashboard \
  pi-vpn-gateway-health.timer wg-quick@wg0 hostapd dnsmasq

# Remove configs
sudo rm -rf /etc/pi-vpn-gateway /etc/nftables.d/pi-vpn-gateway.nft
sudo rm -f /etc/dnsmasq.d/pi-vpn-gateway*.conf
sudo rm -f /etc/wireguard/wg0.conf
sudo rm -f /etc/NetworkManager/conf.d/99-pi-vpn-gateway.conf

# Reinstall from repo
cd ~/pi-vpn-gateway
git pull
sudo ./install.sh
sudo ./configure.sh
```

## Recovery via SD Card (Headless)

If SSH is unavailable:

1. Remove SD card and mount `boot` partition on another machine
2. Enable SSH: create empty `ssh` file in boot partition
3. Optionally add `wpa_supplicant.conf` for temporary Wi-Fi (not needed if using Ethernet)
4. Boot Pi, find IP on router DHCP list, SSH in
5. Follow reset steps above

## When TVs Can't Connect

1. Verify SSID `Home-BR` is visible: `sudo iw dev wlan1 info`
2. Check hostapd logs: `journalctl -u hostapd -n 50`
3. Confirm country code: `iw reg get` (should include `BR`)
4. Try a different channel in `/etc/hostapd/hostapd.conf` (1, 6, or 11)

## When VPN Works but TVs Have No Internet

1. Check forwarding: `sysctl net.ipv4.ip_forward` → should be `1`
2. Check nftables: `sudo nft list ruleset`
3. Verify NAT: `sudo nft list table ip pi_vpn_gateway_nat`
4. Confirm DNS: `dig @192.168.50.1 google.com` from a client

## Emergency: Disable Kill Switch

**Only for debugging — AP traffic may leak outside VPN:**

```bash
sudo nft flush ruleset
sudo systemctl stop pi-vpn-gateway-firewall
```

Re-enable after debugging:

```bash
sudo systemctl start pi-vpn-gateway-firewall
```
