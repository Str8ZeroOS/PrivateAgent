# Mac + iPhone pairing

USB or iPhone Mirroring on the MacBook is local to that Mac. A Cursor Cloud Agent is a separate Linux VM. It cannot see the cable, the mirrored window, or a Mac helper that is only listening on the LAN.

This was probed from the Cloud Agent: no self-hosted Cursor worker was registered, and `http://127.0.0.1:8765` / the documented LAN helper were not reachable.

## Automatic next step on the MacBook

On the MacBook Pro that already has the iPhone connected:

```bash
./Scripts/start-mac-bridge.sh
```

That script:

1. writes `~/.privateagent/bridge.env` (host, port, token) if needed
2. opens iPhone Mirroring
3. starts `Bridge/mac_bridge_helper.py` with `--enable-iphone-mirroring --enable-ax-observation --enable-accessibility-actions`
4. prints a `privateagent://pair?host=...&port=...&token=...` link

Open that link on the iPhone (or paste it into Safari). Agent Mode stores the pairing, enables Mac-assisted mode, and uses the live Mac/WDA observer.

Probe from the Mac:

```bash
python3 Scripts/probe-mac-bridge.py
```

If `observation.source` is `iphoneMirroring`, the mirrored window is frontmost.

## If this Cloud Agent should drive the Mac

Start a Cursor self-hosted worker on the MacBook (`cursor worker start`) while the helper is running. Until that worker is registered, this Linux VM cannot tap the phone.

## Grant on the Mac

- System Settings → Privacy & Security → Accessibility: allow Terminal or Python
- Keep iPhone Mirroring frontmost while Agent Mode runs a goal
- Same Wi-Fi (or reachable LAN IP) between iPhone and Mac helper
