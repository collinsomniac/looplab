# Wireless installation over Tailscale — findings and plan (2026-10-10)

Goal: after the agent builds and publishes an IPA, it should install on the phone with no cable.
Everything below was tested on this machine and this phone; "works" means observed, not assumed.

## What we established

| fact | evidence |
|---|---|
| **The phone's device services are reachable over Tailscale.** | TCP to `100.65.154.94:49152` (RemotePairing) and `:62078` (lockdown) both connect from the desktop across the tailnet, identically to the LAN. |
| The RemotePairing client can be pointed at an explicit address — no Bonjour needed. | `RemotePairingTunnelService(remote_identifier, hostname, port)` in pymobiledevice3. Bonjour is only used to *discover* the address, and the port is fixed (49152). |
| The phone advertises RemotePairing on the LAN. | mDNS browse from the desktop: `_remotepairing._tcp` → `006A7A56-A979-4D4B-88B0-F3D4F4DE6163`, port 49152, 192.168.4.22; `_apple-mobdev2._tcp` with `supportsRP-26`. |
| The legacy lockdown port is a dead end for now. | `62078` accepts TCP then immediately closes: Wi-Fi sync (`EnableWifiConnections`) is off, and modern iOS routes developer services through RemotePairing. |
| pymobiledevice3's own mDNS **publisher** does not work on this Windows host. | `serve_pairable_host` advertises but nothing appears on the network; its `MDNSResponder` fails silently. |
| …but the **zeroconf** library publishes fine here. | With `register_service(..., strict=False)` (Apple's service label `remotepairing-pairable-host` is 27 bytes, over the 15-byte DNS-SD limit) the advertisement is visible on the LAN at 192.168.4.28:45999. |
| The phone does **not** browse for pairable hosts on the screen we can reach. | With a confirmed-live advertisement, Settings › Developer › **Paired Computers** showed only the existing `iloader-41c9d0` entry — no "Other Devices" section, no code prompt. |
| iloader's stored RemotePairing key is **stale**. | Its record (Windows Credential Manager, `rppairing1.1_file_<udid>`: Ed25519 key + host identifier `04feb2d8-…`, label `iloader-41c9d0`) is accepted for TLS setup but the phone terminates the connection during pair-verify — the phone holds a different public key for that label. iloader caches the label and the key pair separately, so a regenerated key pair keeps the old name on the device. |

## Consequence

A **first** pairing cannot be created without a cable on this phone/iOS build. That is the same
constraint Apple imposes on its own wireless debugging: pair once by cable, then go wireless. It is a
one-time step, not a recurring one.

## Plan

### Step 1 — bootstrap (one cable, ~60 seconds, once)
With the phone connected by USB and unlocked:
```
pymobiledevice3 usbmux list                      # the phone appears
pymobiledevice3 remote pair                      # valid RemotePairing record for this host
pymobiledevice3 lockdown wifi-connections on     # also enable Wi-Fi sync (second, independent path)
```
Unplug. From then on both of these should work over Tailscale:
- **RSD tunnel** (`49152`) → all developer services, including `installation_proxy`.
- **lockdown over TCP** (`62078`) → the classic path, which is what SideStore/AltStore use.

### Step 2 — the deploy worker
Signing is the remaining piece: an IPA must be signed with a provisioning profile tied to the user's
Apple ID, which is what iloader does with `isideload`. `isideload` ships a working example CLI
(`examples/minimal/src/main.rs`: Apple ID + password + .app → signed and installed) and its
`Sideloader` is transport-agnostic.

So the worker is a small Rust CLI:
1. take an IPA (local path or the newest GitHub release asset),
2. sign it with `isideload` (credentials from the Windows keyring, 2FA via prompt or a stored session),
3. install it over the RSD tunnel built against the Tailscale address,
4. read the installed version back (`installation_proxy` Lookup) and report success.

### Step 3 — wire it into the loop
`tools/deploy.py` on the desktop polls for a new release, calls the worker, and writes the outcome to
the terminal log the app already reads, so a build's install state shows up next to its benchmark runs.

## Tools written during this investigation (in `tools/`)
| file | purpose |
|---|---|
| `net_probe.py` | lockdownd over TCP using an existing pair record |
| `pair_and_prove.py` | advertise as a pairable host (pymobiledevice3 responder), then tunnel + list services |
| `pair_zeroconf.py` | same, but publishing the advertisement with zeroconf (works on Windows) |
| `diag_pair.py` | handshake diagnostics over both Tailscale and LAN addresses |
| `read_rp_record.py` | read iloader's RemotePairing record from Windows Credential Manager |
| `enum_creds.py` | enumerate Windows Credential Manager via the Win32 API (needed: keyring from an SSH session fails with error 1312) |
| `browse_mdns.py` | list mDNS services from the desktop (phone discovery, advertisement verification) |
| `net_install.py` | build a pymobiledevice3 record from iloader's key and attempt the tunnel |
