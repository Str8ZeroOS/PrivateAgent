#!/usr/bin/env bash
# Start the Mac helper over SSH. Default hop: ssh -p 2222 USER@192.168.12.110
set -euo pipefail

SSH_USER="${1:-${PRIVATEAGENT_SSH_USER:-}}"
SSH_HOST="${PRIVATEAGENT_SSH_HOST:-192.168.12.110}"
SSH_PORT="${PRIVATEAGENT_SSH_PORT:-2222}"
REMOTE_DIR="${PRIVATEAGENT_REMOTE_DIR:-~/PrivateAgent}"

if [[ -z "${SSH_USER}" ]]; then
  echo "Username was not provided."
  echo "Usage: $0 <mac-username>"
  echo "Example: $0 jay"
  echo
  echo "Default hop is ssh -p ${SSH_PORT} USER@${SSH_HOST}"
  echo "This Cloud Agent cannot open that hop from the public internet."
  exit 2
fi

echo "Connecting to ${SSH_USER}@${SSH_HOST}:${SSH_PORT} ..."
exec ssh -p "${SSH_PORT}" \
  -o ConnectTimeout=8 \
  -o BatchMode=yes \
  "${SSH_USER}@${SSH_HOST}" \
  "cd ${REMOTE_DIR} && ./Scripts/start-mac-bridge.sh"
