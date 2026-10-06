# Mac + iPhone pairing

## Pairing with a code (current)

You don't paste tokens anymore. The bridge prints a 6-digit one-time code, and **Check Bridge** in the app exchanges it for a token, which it keeps in the iOS Keychain.

1. Start the bridge on the computer:
   - **Windows 11** (Python 3 from python.org):
     ```powershell
     cd PrivateAgent
     powershell -ExecutionPolicy Bypass -File Scripts\start-bridge-windows.ps1
     ```
     or just `py Bridge\mac_bridge_helper.py`. Allow it on **Private** networks when Windows Firewall asks.
   - **Mac** (works with the system Python 2.7 on old macOS like Sierra, or Python 3):
     ```bash
     cd ~/PrivateAgent
     python Bridge/mac_bridge_helper.py          # or ./Scripts/start-mac-bridge.sh on macOS 15+
     ```
2. The window shows something like:
   ```text
   ============================================================
     Str8ZeRO pairing code: 482 913   (valid 5 min, one use)
     iPhone: Agent Mode > Mac Bridge > Check Bridge > enter code > Pair
     Or open on the iPhone: privateagent://pair?host=192.168.12.141&port=8765&code=482913
   ============================================================
   ```
3. In Str8ZeRO > Agent Mode > **Mac Bridge**, set Host to that computer's LAN IP (for example `192.168.12.141` for the Windows PC, `192.168.12.110` for the Mac) and Port `8765`. Tap **Check Bridge**.
4. The status reads *Reachable, not paired* and a code field appears. Type the code and tap **Pair** (or **Check Bridge** again). The status turns *Paired*.

Status meanings:

| Status | Meaning | Fix |
|---|---|---|
| Unreachable | No answer from host:port | Bridge not running, wrong IP, firewall, or iOS Local Network permission off (Settings > Privacy & Security > Local Network > Str8ZeRO) |
| Reachable, not paired | The bridge is running and needs a code | Enter the code from the bridge window |
| Paired | Token accepted | — |
| Token invalid | The bridge rejected the saved token (it was reset with `--forget-devices`, or a different bridge now answers at that address) | Enter the current code |
| Wrong code / Code expired / Pairing locked | Pairing failed | Use the current code; restart the bridge if it's locked |

The code changes every 5 minutes and after each successful pairing. Pairing survives bridge restarts, because the bridge remembers token hashes in `~/.privateagent/bridge_devices.json`. To revoke every phone, run the bridge with `--forget-devices`. On Windows the bridge handles health, pairing, and opening URLs. iPhone Mirroring and Accessibility control need a Mac.

---

## Legacy notes (SSH bootstrap)


The MacBook is on the LAN at `192.168.12.110`, with SSH on port `2222`.

A Cursor Cloud Agent is a separate Linux VM. From this VM:

- ping `192.168.12.110` loses every packet
- `ssh -p 2222 192.168.12.110` times out
- no SSH keys or username are present in the agent environment

USB / iPhone Mirroring still only exist on that Mac. This VM cannot open the SSH hop from the public internet.

## Already logged in from Windows

A Windows SSH/Remote Desktop session to the Mac does not give the Cloud Agent a tunnel. Paste this **on the Mac** (in that login):

```bash
curl -fsSL https://raw.githubusercontent.com/Str8ZeroOS/PrivateAgent/cursor/ios-closed-loop-agent-2cc6/Scripts/bootstrap-mac-from-ssh.sh | bash
```

Or, if the repo is already on the Mac:

```bash
cd ~/PrivateAgent
git fetch origin
git checkout cursor/ios-closed-loop-agent-2cc6
./Scripts/bootstrap-mac-from-ssh.sh
```

Keep that session open. The helper stays in the foreground. Then enter the printed pairing code in Str8ZeRO (Check Bridge).

## From a machine that *can* reach the LAN

```bash
ssh -p 2222 jay@192.168.12.110
cd ~/PrivateAgent   # or the real clone path
./Scripts/start-mac-bridge.sh
```

Or, if this repo is already on the Mac at `~/PrivateAgent`:

```bash
./Scripts/ssh-start-mac-bridge.sh USER
```

`start-mac-bridge.sh` writes host/port to `~/.privateagent/bridge.env`, opens iPhone Mirroring, starts the helper on `0.0.0.0:8765`, and prints a one-time pairing code plus a `privateagent://pair?host=…&port=…&code=…` link. It does not print a token.

Probe from a LAN machine (no token needed to see whether the bridge is up and unpaired):

```bash
python3 Scripts/probe-mac-bridge.py --host 192.168.12.110
```

If `observation.source` is `iphoneMirroring`, the mirrored window is frontmost.

## Grant on the Mac

- System Settings → Privacy & Security → Accessibility: allow Terminal or Python
- Keep iPhone Mirroring frontmost while Agent Mode runs a goal
- The iPhone must be able to reach `192.168.12.110:8765`

## Username

The Mac account is `jay`. Expected host key:

```text
ED25519 SHA256:emqKZwPshfgeWHiI35S8DIbs3PiMU5ZIo/4PZJCz67Q
```

That fingerprint only verifies the Mac. It is not a private key and cannot log this Cloud Agent in.

From a LAN machine:

```bash
ssh -p 2222 jay@192.168.12.110
```

This Cloud Agent still cannot open that private hop (TCP 2222 times out; no `id_ed25519` is installed here).
