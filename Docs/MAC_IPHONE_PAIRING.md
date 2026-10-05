# Mac + iPhone pairing

The MacBook is on the LAN at `192.168.12.110`, with SSH on port `2222`.

A Cursor Cloud Agent is a separate Linux VM. From this VM:

- ping `192.168.12.110` loses every packet
- `ssh -p 2222 192.168.12.110` times out
- no SSH keys or username are present in the agent environment

USB / iPhone Mirroring still only exist on that Mac. This VM cannot open the SSH hop from the public internet.

## From a machine that *can* reach the LAN

```bash
ssh -p 2222 USER@192.168.12.110
cd ~/PrivateAgent   # or the real clone path
./Scripts/start-mac-bridge.sh
```

Or, if this repo is already on the Mac at `~/PrivateAgent`:

```bash
./Scripts/ssh-start-mac-bridge.sh USER
```

`start-mac-bridge.sh` writes `~/.privateagent/bridge.env`, opens iPhone Mirroring, starts the helper on `0.0.0.0:8765`, and prints:

```text
privateagent://pair?host=192.168.12.110&port=8765&token=...
```

Open that link on the iPhone. Agent Mode now defaults the Mac host to `192.168.12.110`.

Probe from a LAN machine:

```bash
python3 Scripts/probe-mac-bridge.py --host 192.168.12.110 --token <token>
```

If `observation.source` is `iphoneMirroring`, the mirrored window is frontmost.

## Grant on the Mac

- System Settings → Privacy & Security → Accessibility: allow Terminal or Python
- Keep iPhone Mirroring frontmost while Agent Mode runs a goal
- The iPhone must be able to reach `192.168.12.110:8765`

## Username

`ssh -p2222 @192.168.12.110` is missing the account name. The scripts take it as the first argument or `PRIVATEAGENT_SSH_USER`.
