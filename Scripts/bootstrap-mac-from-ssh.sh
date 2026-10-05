#!/usr/bin/env bash
# Paste this on the MacBook after you are already logged in from Windows
# (ssh -p 2222 USER@192.168.12.110). It clones/updates PrivateAgent and
# starts the iPhone Mirroring helper.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this inside the MacBook SSH session, not on Windows or the Cloud Agent VM."
  exit 1
fi

REPO="${PRIVATEAGENT_REMOTE_DIR:-${HOME}/PrivateAgent}"
BRANCH="${PRIVATEAGENT_BRANCH:-cursor/ios-closed-loop-agent-2cc6}"

if [[ ! -d "${REPO}/.git" ]]; then
  git clone https://github.com/Str8ZeroOS/PrivateAgent.git "${REPO}"
fi

cd "${REPO}"
git fetch origin
if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
  git checkout -B "${BRANCH}" "origin/${BRANCH}"
else
  git checkout main
  git pull --ff-only origin main
fi

chmod +x Scripts/start-mac-bridge.sh Scripts/probe-mac-bridge.py Scripts/ssh-start-mac-bridge.sh
exec ./Scripts/start-mac-bridge.sh
