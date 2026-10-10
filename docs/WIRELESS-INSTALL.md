# Wireless installation over Tailscale — findings and plan (2026-10-10)

**Status: the transport works. We can reach the phone's install service over Tailscale with no cable.**
What remains is signing the IPA with the user's Apple ID (the deploy worker, §4).

## 1. Working recipe (verified end to end)

```
RSD over Tailscale connected
installation_proxy: 76 user apps
```

1. **Pair once over USB** (promptless — no Trust dialog):
   ```python
   lockdown = await create_using_usbmux(serial=UDID, autopair=False)
   svc = await RemotePairingLockdownService.create(lockdown)
   await svc.connect(autopair=True)      # raises RemotePairingCompletedError when done
   ```
   Writes `~/.pymobiledevice3/remote_<udid>.plist` with `private_key`, `public_key`,
   `peer_alt_irk`, `remote_unlock_host_key`.
2. **Enable Wi-Fi sync** over USB (independent second path): set `EnableWifiConnections` and
   `EnableWifi` in the `com.apple.mobile.lockdown` wireless domain.
3. **Connect over Tailscale** — pair-verify succeeds against `100.65.154.94:49152`:
   ```python
   T.USE_USERSPACE_TUNNEL = True
   svc = T.RemotePairingTunnelService(UDID, "100.65.154.94", 49152)
   await svc.connect(autopair=False)
   async with T.start_tunnel_over_remotepairing(svc, protocol=TunnelProtocol.TCP) as tun:
       tun_obj = cast(UserspaceTun, tun.client.tun); tun_obj.set_peer(tun.address)
       async with UserspaceDialPlane(tun_obj, tun.address) as plane:
           rsd = RSD((tun.address, tun.port), open_connection=plane.dial,
                     auxiliary_metadata=tun.auxiliary_metadata)
           await rsd.connect()
           ip = InstallationProxyService(rsd)      # RSD satisfies LockdownServiceProvider
           apps = await ip.get_apps(application_type="User")
   ```
   Script: `tools/rsd_apps.py`.

### Requirements and gotchas
- **Python 3.13+** for the TCP tunnel (`sslpsk_pmd3` on 3.12 fails to load its OpenSSL DLL). Installed at
  `%LOCALAPPDATA%\Programs\Python\Python313\python.exe`.
- **iOS 18.2+ removed QUIC** — the tunnel must be `protocol=TunnelProtocol.TCP`.
- The RSD address is **inside a userspace PyTCP stack** (`fd78:9b98:619e::1`), so it is not routable:
  services must be dialled through `UserspaceDialPlane.dial`, passed as `open_connection=`.
- Service names over RSD carry a **`.shim.remote` suffix**:
  `com.apple.mobile.installation_proxy.shim.remote`, `com.apple.afc.shim.remote`.
- `rsd.start_remote_service(name)` returns an unconnected connection (do not await it);
  the service classes take the RSD directly as their lockdown provider.
- A **fresh RP pairing is required**; iloader's stored key is stale (see §3).

## 2. What we established earlier

| fact | evidence |
|---|---|
| Phone device services are reachable over Tailscale | TCP to `100.65.154.94:49152` and `:62078` connects from the desktop across the tailnet |
| Bonjour is only needed for *discovery* | the port is fixed (49152) and the client takes an explicit address |
| Phone advertises `_remotepairing._tcp` (identifier `006A7A56-…`, port 49152) and `_apple-mobdev2._tcp` (`supportsRP-26`) | mDNS browse from the desktop |
| Legacy lockdown `62078` works **on the LAN** once Wi-Fi sync is on, but not over Tailscale | lockdownd closes the session; RSD is the working path |
| The phone does not browse for pairable hosts on Settings › Developer › **Paired Computers** | with a confirmed-live advertisement, no "Other Devices" section appeared |

## 3. Dead ends, and why

- **pymobiledevice3's mDNS publisher fails silently on Windows.** Its advertisement never appears.
  The `zeroconf` library publishes fine here, but needs `strict=False` (Apple's
  `remotepairing-pairable-host` label is 27 bytes, over the 15-byte DNS-SD limit).
- **iloader's stored RemotePairing key is stale.** Found in Windows Credential Manager under
  `rppairing1.1_file_<udid>` (Ed25519 key, host identifier `04feb2d8-…`, label `iloader-41c9d0`).
  The phone accepts TLS setup then terminates during pair-verify: it holds a different public key for
  that label. iloader caches the label and the key pair separately, so a regenerated key pair keeps
  the old name on the device. A fresh pairing (§1.1) fixes it.
- **Windows Credential Manager is unreadable from an SSH session** (error 1312 — credentials are bound
  to the interactive logon). Workaround: a scheduled task with `/ru <user> /it`, or the Win32
  `CredEnumerateW` API, running inside the logged-in session.

## 4. What remains: signing, then the deploy worker

An IPA must be signed with a provisioning profile tied to the user's Apple ID. `isideload` (the crate
iloader uses) does exactly that, and ships a working example CLI
(`examples/minimal/src/main.rs`: Apple ID + password + .app → signed and installed). Its `Sideloader`
is transport-agnostic.

The worker is therefore a small Rust CLI:
1. take an IPA (local path or newest GitHub release asset),
2. sign it with `isideload` (credentials from the keyring; 2FA via prompt or stored session),
3. install over the RSD tunnel against the Tailscale address (the recipe in §1),
4. read the installed version back through `installation_proxy` and report.

Then `tools/deploy.py` on the desktop polls for a new release, calls the worker, and writes the
outcome into the terminal log the app already reads, so a build's install state appears beside its
benchmark runs.

## 5. Tools written during this investigation (`tools/`)
| file | purpose |
|---|---|
| `bootstrap_wireless.py` | USB: enable Wi-Fi sync, read the RemotePairing control channel, list records |
| `pair_over_usb.py` | **create the RemotePairing pairing over USB** and test the tunnel (LAN + Tailscale) |
| `rsd_over_tailscale.py` | establish the tunnel and dial RSD through the userspace stack |
| `rsd_services.py` | list RSD services, query `installation_proxy` |
| `rsd_apps.py` | **verified end-to-end: list installed apps over Tailscale** |
| `pair_zeroconf.py` | publish a pairable-host advertisement with zeroconf (works on Windows) |
| `pair_and_prove.py` | the same using pymobiledevice3's own responder (does not publish here) |
| `diag_pair.py` | handshake diagnostics across transports |
| `read_rp_record.py`, `enum_creds.py` | read iloader's key / enumerate Credential Manager |
| `browse_mdns.py`, `net_probe.py`, `net_install.py`, `verify_wifi.py` | discovery, lockdown probes, record conversion |
