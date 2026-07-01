# FAQ

Common questions about the Pi VPN Gateway — access, dashboard, Wi-Fi, and SSH.

---

## How do I open the web dashboard?

There are two ways:

### Option A — From a device on `Home-BR` (phone, TV browser, laptop)

1. Connect to Wi-Fi **`Home-BR`**.
2. Open a browser and go to:

   **http://192.168.50.1:8080**

The dashboard shows VPN status, services, connected clients, DHCP leases, and a Wi-Fi QR code (if generated).

### Option B — From your Mac/PC on the home network (SSH tunnel)

The dashboard is bound to the Pi itself. You do **not** need to join `Home-BR` if you can SSH to the Pi on your LAN.

**Step 1 — Open the tunnel** (leave this terminal open):

```bash
ssh -i ~/.ssh/id_rsa -L 8080:127.0.0.1:8080 eduardo@192.168.100.230
```

Replace `192.168.100.230` with your Pi’s current home-network IP if it changes again (check your router’s DHCP list).

**Step 2 — Open the dashboard in your browser:**

**http://localhost:8080/**

Traffic flows: your browser → local port 8080 → SSH tunnel → Pi dashboard on port 8080.

**Tip:** Add `-N` if you only want the tunnel without a remote shell:

```bash
ssh -i ~/.ssh/id_rsa -N -L 8080:127.0.0.1:8080 eduardo@192.168.100.230
```

**JSON API** (same tunnel):

```bash
curl http://localhost:8080/api/status
```

---

## Why can’t I see `Home-BR` on my phone?

**Check these first:**

1. **Range** — Stand near the Pi; the AP uses the **built-in Wi-Fi** (`wlan0`) for best range.
2. **2.4 GHz** — `Home-BR` is 2.4 GHz only. Some phones hide weak networks; refresh the Wi-Fi list.
3. **Android** — Turn **Location** on (required for Wi-Fi scanning on many devices).
4. **hostapd** — On the Pi: `systemctl status hostapd` and `sudo iw dev wlan0 info` (should show `type AP` and `ssid Home-BR`).

If the AP was stuck at startup, see [Troubleshooting — AP not broadcasting](troubleshooting.md#ap-not-broadcasting-home-br-invisible).

---

## What is the `Home-BR` Wi-Fi password?

Set during `configure.sh` or with:

```bash
sudo /opt/pi-vpn-gateway/scripts/set-ap-password.sh 'your-new-password'
```

To read the current password on the Pi:

```bash
sudo grep AP_PASSPHRASE /etc/pi-vpn-gateway/env
```

---

## How do I SSH into the Pi?

From your Mac (home LAN):

```bash
ssh -i ~/.ssh/id_rsa eduardo@192.168.100.230
```

If that IP does not work:

- Check your router’s DHCP client list for the Pi hostname (e.g. `raspberrypi`).
- The uplink may be on the **USB adapter** (`wlan1`) after a Wi-Fi role swap — look for a new IP there.

---

## Which Wi-Fi card does what?

| Interface | Role | Notes |
|-----------|------|--------|
| `wlan0` (built-in) | **AP — `Home-BR`** | Better antenna and range for TVs/phones |
| `wlan1` (USB) | **Uplink — home Wi-Fi** | Connects to your router (e.g. `CASITA`) |

---

## Does my phone/TV traffic go through Brazil?

Only devices on **`Home-BR`**. Your home LAN and the Pi’s own management traffic (SSH, dashboard via tunnel) stay on the normal home network unless you explicitly route through the VPN.

Test from a device on `Home-BR`:

```bash
curl https://ifconfig.me
```

You should see a Brazilian IP when the VPN is up.

---

## The dashboard says VPN is down but the Pi seems fine

The dashboard may still check WireGuard (`wg0`) while the Pi uses **OpenVPN** (`tun0`). Verify on the Pi:

```bash
systemctl status openvpn-brazil
curl --interface tun0 -s http://ip-api.com/line/?fields=country,query
```

---

## How do I change the AP password?

```bash
sudo /opt/pi-vpn-gateway/scripts/set-ap-password.sh 'Brasil*2026!'
sudo systemctl restart hostapd
```

Devices already connected will need to reconnect with the new password.

---

## Where is more help?

- [Configuration](configuration.md)
- [Troubleshooting](troubleshooting.md)
- [Recovery](recovery.md)
- [Upgrade](upgrade.md)
