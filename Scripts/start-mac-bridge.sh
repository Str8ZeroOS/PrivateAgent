#!/usr/bin/env bash
# Start the PrivateAgent Mac helper for an iPhone that is already mirrored
# on this MacBook. This must run on macOS, not in the Cloud Agent Linux VM.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script has to run on the MacBook Pro that is mirroring the iPhone."
  echo "This Cloud Agent is a Linux VM and cannot see USB or iPhone Mirroring."
  echo
  echo "On a machine that can reach the MacBook LAN:"
  echo "  ssh -p 2222 USER@192.168.12.110"
  echo "  ./Scripts/start-mac-bridge.sh"
  echo "  Then open the printed privateagent://pair link on the iPhone"
  echo
  echo "Or: ./Scripts/ssh-start-mac-bridge.sh USER"
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="${HOME}/.privateagent"
ENV_FILE="${STATE}/bridge.env"
mkdir -p "${STATE}"

if [[ ! -f "${ENV_FILE}" ]]; then
  TOKEN="$(openssl rand -hex 16)"
  HOST="$(ipconfig getifaddr en0 2>/dev/null || true)"
  if [[ -z "${HOST}" ]]; then
    HOST="$(ipconfig getifaddr en1 2>/dev/null || true)"
  fi
  if [[ -z "${HOST}" ]]; then
    HOST="192.168.12.110"
  fi
  cat > "${ENV_FILE}" <<EOF
PRIVATEAGENT_BRIDGE_HOST=${HOST}
PRIVATEAGENT_BRIDGE_PORT=8765
PRIVATEAGENT_BRIDGE_TOKEN=${TOKEN}
EOF
  echo "Wrote ${ENV_FILE}"
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

PAIR_URL="privateagent://pair?host=${PRIVATEAGENT_BRIDGE_HOST}&port=${PRIVATEAGENT_BRIDGE_PORT}&token=${PRIVATEAGENT_BRIDGE_TOKEN}"

echo "Opening iPhone Mirroring if it is installed..."
open -a "iPhone Mirroring" >/dev/null 2>&1 || echo "iPhone Mirroring app not found. Open it manually."

echo
echo "Grant Accessibility to Terminal/Python if macOS asks."
echo "Bridge: http://${PRIVATEAGENT_BRIDGE_HOST}:${PRIVATEAGENT_BRIDGE_PORT}"
echo "Pair on iPhone: ${PAIR_URL}"
echo
echo "Starting helper with iPhone Mirroring + AX observation + AX actions..."

exec python3 "${ROOT}/Bridge/mac_bridge_helper.py" \
  --host 0.0.0.0 \
  --port "${PRIVATEAGENT_BRIDGE_PORT}" \
  --token "${PRIVATEAGENT_BRIDGE_TOKEN}" \
  --enable-iphone-mirroring \
  --enable-ax-observation \
  --enable-accessibility-actions
