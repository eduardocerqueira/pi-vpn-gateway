#!/usr/bin/env python3
"""Simple web dashboard for Pi VPN Gateway."""

import json
import os
import subprocess
from pathlib import Path

from flask import Flask, jsonify, render_template_string

CONFIG_DIR = Path("/etc/pi-vpn-gateway")
ENV_FILE = CONFIG_DIR / "env"
INSTALL_ROOT = Path("/opt/pi-vpn-gateway")

app = Flask(__name__)


def load_env():
    env = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"')
    return env


def run_cmd(cmd):
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=10, check=False
        )
        return result.stdout.strip() if result.returncode == 0 else ""
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""


def wg_status(iface="wg0"):
    output = run_cmd(["wg", "show", iface])
    if not output:
        return {"up": False, "details": ""}
    return {"up": True, "details": output}


def iface_is_up(iface):
    output = run_cmd(["ip", "-br", "link", "show", iface])
    if not output:
        return False
    parts = output.split()
    if len(parts) < 2:
        return False
    state = parts[1]
    # tun/wg point-to-point links report UNKNOWN when working
    if iface.startswith(("tun", "wg")):
        return state in ("UP", "UNKNOWN")
    return state == "UP"


def vpn_status(env):
    """Report VPN status for WireGuard or OpenVPN (tun0)."""
    iface = env.get("VPN_INTERFACE", env.get("WG_INTERFACE", "tun0"))
    service = env.get("VPN_SERVICE", "")

    if iface.startswith("tun") or service.startswith("openvpn"):
        svc = service if service.startswith("openvpn") else "openvpn-brazil"
        up = service_status(svc) or iface_is_up(iface)
        details = run_cmd(["ip", "-br", "addr", "show", iface])
        return {"up": up, "details": details, "type": "openvpn", "iface": iface, "service": svc}

    vpn = wg_status(iface)
    svc = service if service.startswith("wg-quick") else f"wg-quick@{iface}"
    vpn["type"] = "wireguard"
    vpn["iface"] = iface
    vpn["service"] = svc
    if not vpn["up"]:
        vpn["up"] = service_status(svc)
    return vpn


def public_ip_via_vpn(iface="tun0"):
    # HTTP — HTTPS often fails when bound to tun on the Pi
    return run_cmd(
        ["curl", "-sf", "--max-time", "8", "--interface", iface, "http://ifconfig.me"]
    )


def connected_clients(ap_iface="wlan1"):
    clients = []
    output = run_cmd(["iw", "dev", ap_iface, "station", "dump"])
    if not output:
        return clients

    station = {}
    for line in output.splitlines():
        if line.startswith("Station"):
            if station:
                clients.append(station)
            station = {"mac": line.split()[1]}
        elif "signal:" in line:
            station["signal"] = line.split("signal:")[1].strip().split()[0]
        elif "connected time:" in line:
            station["connected"] = line.split("connected time:")[1].strip()
    if station:
        clients.append(station)
    return clients


def dhcp_leases():
    lease_file = Path("/var/lib/misc/dnsmasq.leases")
    if not lease_file.exists():
        return []
    leases = []
    for line in lease_file.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 4:
            leases.append(
                {
                    "expiry": parts[0],
                    "mac": parts[1],
                    "ip": parts[2],
                    "hostname": parts[3] if parts[3] != "*" else "",
                }
            )
    return leases


def service_status(name):
    active = run_cmd(["systemctl", "is-active", name])
    return active == "active"


HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Pi VPN Gateway</title>
  <style>
    :root { font-family: system-ui, sans-serif; color: #1a1a1a; background: #f4f6f8; }
    body { max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
    h1 { font-size: 1.5rem; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1rem; }
    .card { background: #fff; border-radius: 8px; padding: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
    .ok { color: #0a7; font-weight: 600; }
    .bad { color: #c33; font-weight: 600; }
    table { width: 100%; border-collapse: collapse; margin-top: .5rem; font-size: .9rem; }
    th, td { text-align: left; padding: .4rem .5rem; border-bottom: 1px solid #eee; }
    pre { background: #f0f0f0; padding: .75rem; border-radius: 4px; overflow-x: auto; font-size: .8rem; }
    img { max-width: 200px; border: 1px solid #ddd; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>Pi VPN Gateway — {{ ap_ssid }}</h1>
  <div class="grid">
    <div class="card">
      <h2>VPN</h2>
      <p class="{{ 'ok' if vpn.up else 'bad' }}">{{ 'Connected' if vpn.up else 'Down' }}</p>
      <p><small>{{ vpn_country }} · {{ public_ip or 'IP unknown' }}</small></p>
    </div>
    <div class="card">
      <h2>Services</h2>
      <ul style="list-style:none;padding:0;margin:0">
        {% for name, ok in services.items() %}
        <li class="{{ 'ok' if ok else 'bad' }}">{{ name }}: {{ 'active' if ok else 'inactive' }}</li>
        {% endfor %}
      </ul>
    </div>
    <div class="card">
      <h2>AP Clients</h2>
      <p>{{ clients|length }} connected · {{ leases|length }} DHCP leases</p>
    </div>
  </div>

  <div class="card" style="margin-top:1rem">
    <h2>Connected Wi-Fi Clients</h2>
    {% if clients %}
    <table>
      <tr><th>MAC</th><th>Signal</th><th>Connected</th></tr>
      {% for c in clients %}
      <tr><td>{{ c.mac }}</td><td>{{ c.get('signal', '—') }} dBm</td><td>{{ c.get('connected', '—') }}</td></tr>
      {% endfor %}
    </table>
    {% else %}<p>No clients connected.</p>{% endif %}
  </div>

  <div class="card" style="margin-top:1rem">
    <h2>DHCP Leases</h2>
    {% if leases %}
    <table>
      <tr><th>IP</th><th>MAC</th><th>Hostname</th></tr>
      {% for l in leases %}
      <tr><td>{{ l.ip }}</td><td>{{ l.mac }}</td><td>{{ l.hostname or '—' }}</td></tr>
      {% endfor %}
    </table>
    {% else %}<p>No leases.</p>{% endif %}
  </div>

  {% if qr_exists %}
  <div class="card" style="margin-top:1rem">
    <h2>Wi-Fi QR Code</h2>
    <img src="/wifi-qr.png" alt="Wi-Fi QR code">
  </div>
  {% endif %}

  <p style="margin-top:2rem;color:#666;font-size:.85rem">
    <a href="/api/status">JSON API</a> · auto-refresh in 30s
  </p>
  <script>setTimeout(() => location.reload(), 30000);</script>
</body>
</html>
"""


@app.route("/")
def index():
    env = load_env()
    ap_iface = env.get("IFACE_AP", "wlan1")
    vpn = vpn_status(env)
    vpn_iface = vpn.get("iface", "tun0")
    vpn_service = vpn.get("service", env.get("VPN_SERVICE", "openvpn-brazil"))

    return render_template_string(
        HTML,
        ap_ssid=env.get("AP_SSID", "Home-BR"),
        vpn_country=env.get("VPN_COUNTRY", "Brazil"),
        vpn=vpn,
        public_ip=public_ip_via_vpn(vpn_iface) if vpn["up"] else "",
        services={
            "hostapd": service_status("hostapd"),
            "pi-vpn-gateway-dhcp": service_status("pi-vpn-gateway-dhcp"),
            vpn_service: service_status(vpn_service),
            "pi-vpn-gateway": service_status("pi-vpn-gateway"),
        },
        clients=connected_clients(ap_iface),
        leases=dhcp_leases(),
        qr_exists=(CONFIG_DIR / "wifi-qr.png").exists(),
    )


@app.route("/api/status")
def api_status():
    env = load_env()
    ap_iface = env.get("IFACE_AP", "wlan1")
    vpn = vpn_status(env)
    vpn_iface = vpn.get("iface", "tun0")
    return jsonify(
        {
            "vpn": vpn,
            "public_ip": public_ip_via_vpn(vpn_iface) if vpn["up"] else None,
            "clients": connected_clients(ap_iface),
            "leases": dhcp_leases(),
            "env": {k: v for k, v in env.items() if "PASS" not in k and "KEY" not in k and "TOKEN" not in k},
        }
    )


@app.route("/wifi-qr.png")
def wifi_qr():
    from flask import send_file

    qr = CONFIG_DIR / "wifi-qr.png"
    if qr.exists():
        return send_file(qr, mimetype="image/png")
    return ("Not found", 404)


if __name__ == "__main__":
    env = load_env()
    port = int(env.get("DASHBOARD_PORT", os.environ.get("DASHBOARD_PORT", 8080)))
    app.run(host="0.0.0.0", port=port, debug=False)
