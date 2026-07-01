#!/usr/bin/env bash
# gateway-stop.sh — Tear down gateway routing hooks
set -euo pipefail

logger -t pi-vpn-gateway "Stopping gateway"
/opt/pi-vpn-gateway/firewall/vpn-route.sh down || true
