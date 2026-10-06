#!/usr/bin/env bash
# Start the PrivateAgent Mac helper for an iPhone that is already mirrored
# on this MacBook. This must run on macOS, not in the Cloud Agent Linux VM.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script has to run on the MacBook Pro that is mirroring the iPhone."
  echo "This Cloud Agent is a Linux VM and cannot see USB or iPhone Mirroring."
  echo
  echo "On a machine that can reach the MacBook LAN:"
  echo "  ssh -p 2222 jay@192.168.12.110"
  echo "  ./Scripts/start-mac-bridge.sh"
  echo "  Then enter the printed 6-digit pairing code in Str8ZeRO (Check Bridge)"
  echo
  echo "Or: ./Scripts/ssh-start-mac-bridge.sh USER"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${HOME}/.privateagent"
ENV_FILE="${STATE}/bridge.env"
mkdir -p "${STATE}"

HOST="$(ipconfig getifaddr en0 2>/dev/null || true)"
if [[ -z "${HOST}" ]]; then
  HOST="$(ipconfig getifaddr en1 2>/dev/null || true)"
fi
PORT="${PRIVATEAGENT_BRIDGE_PORT:-8765}"

# Older versions wrote a static PRIVATEAGENT_BRIDGE_TOKEN here and printed it
# inside a pair link. Tokens are now issued per device through a one-time
# pairing code, so only host/port are kept.
cat > "${ENV_FILE}" <<EOF
PRIVATEAGENT_BRIDGE_HOST=${HOST:-unknown}
PRIVATEAGENT_BRIDGE_PORT=${PORT}
EOF

PYTHON="$(command -v python3 || command -v python)"

echo "Opening iPhone Mirroring if it is installed..."
open -a "iPhone Mirroring" >/dev/null 2>&1 || echo "iPhone Mirroring app not found (needs macOS 15+). Continuing without it."

echo
echo "Grant Accessibility to Terminal/Python if macOS asks."
echo "On the iPhone: Str8ZeRO > Agent Mode > Mac Bridge > Host ${HOST:-<this Mac IP>}, Port ${PORT}"
echo "Tap Check Bridge, enter the 6-digit pairing code printed below, tap Pair."
echo
echo "Starting helper with iPhone Mirroring + AX observation + AX actions..."

exec "${PYTHON}" "${ROOT}/Bridge/mac_bridge_helper.py" \
  --host 0.0.0.0 \
  --port "${PORT}" \
  ${HOST:+--advertise-host "${HOST}"} \
  --enable-iphone-mirroring \
  --enable-ax-observation \
  --enable-accessibility-actions
