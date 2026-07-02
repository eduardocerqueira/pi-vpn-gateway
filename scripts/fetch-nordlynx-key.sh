#!/usr/bin/env bash
# fetch-nordlynx-key.sh — Run on your Mac to get NordLynx key and copy to Pi
# (Pi router DNS / Cloudflare often blocks the credentials API)
#
# Usage:
#   NORDVPN_TOKEN="..." bash scripts/fetch-nordlynx-key.sh
#   NORDVPN_TOKEN="..." PI_HOST=eduardo@192.168.100.218 bash scripts/fetch-nordlynx-key.sh
set -euo pipefail

: "${NORDVPN_TOKEN:?Set NORDVPN_TOKEN from https://my.nordaccount.com/dashboard/nordvpn/access-tokens/}"

PI_HOST="${PI_HOST:-eduardo@192.168.100.218}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
OUT="${OUT:-./nordlynx.key}"

echo "Fetching NordLynx private key..."
CREDS=$(curl -sf -u "token:${NORDVPN_TOKEN}" \
  "https://api.nordvpn.com/v1/users/services/credentials")

KEY=$(echo "$CREDS" | jq -r '.nordlynx_private_key // empty')
[[ -n "$KEY" ]] || { echo "ERROR: no nordlynx_private_key — check token"; exit 1; }

umask 077
echo "$KEY" > "$OUT"
echo "Saved to $OUT"

echo "Copying to Pi and running NordLynx switch..."
scp -i "$SSH_KEY" "$OUT" "${PI_HOST}:/tmp/nordlynx.key"
ssh -i "$SSH_KEY" "$PI_HOST" "sudo install -m600 /tmp/nordlynx.key /etc/pi-vpn-gateway/nordlynx.key && rm /tmp/nordlynx.key && sudo bash /opt/pi-vpn-gateway/scripts/switch-to-nordlynx.sh"

echo "Done. Reconnect phone to Home-BR and test Amazon."
