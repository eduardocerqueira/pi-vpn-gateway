# Troubleshooting

## Diagnostic Commands

```bash
# Full status overview
systemctl status pi-vpn-gateway hostapd dnsmasq wg-quick@wg0 pi-vpn-gateway-firewall

# Network interfaces
ip -br addr
iw dev

# VPN tunnel
wg show
curl --interface wg0 -s https://ifconfig.me

# Firewall
sudo nft list ruleset

# Logs
journalctl -u pi-vpn-gateway -u wg-quick@wg0 -u hostapd --since "1 hour ago"
tail -f /var/log/pi-vpn-gateway/dnsmasq.log
```

---

## AP Not Broadcasting (`Home-BR` invisible)

**Symptoms:** SSID not visible on TV or phone.

**Checks:**

```bash
ip link show wlan1          # must be UP
iw dev wlan1 info           # type AP
systemctl status hostapd
journalctl -u hostapd -n 30
```

**Common fixes:**

| Cause | Fix |
|-------|-----|
| RT5370 not detected | `lsusb`, replug adapter, reboot |
| NetworkManager conflicts | Confirm `/etc/NetworkManager/conf.d/99-pi-vpn-gateway.conf` exists |
| Wrong interface name | Update `IFACE_AP` in `/etc/pi-vpn-gateway/env` |
| Regulatory domain | `sudo iw reg set BR` and reboot |
| Channel conflict | Change `channel=` in `/etc/hostapd/hostapd.conf` |

---

## Pi Can't Connect to Home Wi-Fi

**Symptoms:** No uplink; `nmcli` shows disconnected.

```bash
nmcli dev status
nmcli dev wifi list ifname wlan0
sudo nmcli dev wifi connect "SSID" password "pass" ifname wlan0
```

Ensure 2.4 GHz home network (Pi 3 built-in Wi-Fi is 2.4 GHz only).

---

## VPN Won't Connect

**Symptoms:** `wg show` empty; `wg-quick@wg0` failed.

```bash
journalctl -u wg-quick@wg0 -n 50
sudo wg-quick up wg0    # manual test — shows errors directly
```

**Common fixes:**

| Error | Fix |
|-------|-----|
| Invalid private key | Re-fetch credentials from Nord Account |
| DNS resolution failed | Check uplink: `ping 1.1.1.1` |
| Endpoint unreachable | Regenerate config for different server |
| Permission denied | Config must be `chmod 600` |

---

## TVs Connect but No Internet

**Symptoms:** Wi-Fi connected on TV, apps won't load.

1. **VPN up?** `wg show wg0`
2. **IP forwarding?** `sysctl net.ipv4.ip_forward`
3. **DHCP working?** TV should get `192.168.50.x` gateway `192.168.50.1`
4. **Kill switch blocking?** If VPN is down, this is expected behavior

```bash
# From Pi — simulate client path
sudo ip netns add test 2>/dev/null || true
ping -I wg0 -c 3 1.1.1.1
```

5. **DNS issues:**

```bash
dig @192.168.50.1 google.com
cat /etc/dnsmasq.d/pi-vpn-gateway-upstream.conf
```

---

## Traffic Leak (Not Egressing from Brazil)

**Symptoms:** Streaming apps show wrong region.

```bash
# Check public IP through VPN
curl --interface wg0 https://ifconfig.me
curl --interface wg0 https://ipinfo.io/country

# Verify kill switch — stop VPN, TVs should lose internet
sudo systemctl stop wg-quick@wg0
```

If TVs still have internet with VPN down, firewall is not active:

```bash
sudo systemctl status pi-vpn-gateway-firewall
sudo nft list ruleset
```

---

## Dashboard Not Loading

```bash
systemctl status pi-vpn-gateway-dashboard
curl http://192.168.50.1:8080/api/status
```

Connect from a device on the `Home-BR` network. The dashboard is only exposed on the AP interface by design.

---

## High Latency / Buffering on TVs

- Pi 3B has limited throughput (~20–40 Mbps over VPN)
- Use WireGuard (NordLynx), not OpenVPN
- Pick a geographically closer Brazil server
- Reduce connected clients
- Set `channel=` to least congested Wi-Fi channel

---

## Services Not Starting on Boot

```bash
systemctl is-enabled hostapd dnsmasq wg-quick@wg0 pi-vpn-gateway pi-vpn-gateway-firewall
```

Re-enable:

```bash
sudo systemctl enable hostapd dnsmasq wg-quick@wg0 pi-vpn-gateway \
  pi-vpn-gateway-firewall pi-vpn-gateway-health.timer pi-vpn-gateway-dashboard
```

Check boot order issues:

```bash
systemd-analyze blame
journalctl -b | grep -i failed
```

---

## Getting Help

When opening an issue, include:

```bash
sudo ./backup.sh /tmp/debug-backup
journalctl -u pi-vpn-gateway -u wg-quick@wg0 -u hostapd --since today > /tmp/logs.txt
wg show
ip -br addr
sudo nft list ruleset
```

**Do not share** WireGuard private keys, Wi-Fi passwords, or NordVPN tokens.
