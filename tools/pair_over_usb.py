"""Create a RemotePairing pairing over USB lockdown, then test the RSD tunnel over Tailscale.

The lockdown control channel (com.apple.dt.remotepairingdeviced.lockdown) speaks the same
RemotePairing protocol as the network service, and pair-setup there is promptless. The record it
produces is what the network tunnel services consume.
"""
import asyncio, os, plistlib, sys, traceback
from pathlib import Path

UDID = "00008150-001139383A52401C"
TS_IP = "100.65.154.94"
LAN_IP = "192.168.4.22"
PORT = 49152

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.common import TunnelProtocol
from pymobiledevice3.exceptions import RemotePairingCompletedError
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD


def list_records():
    home = Path(os.environ.get("USERPROFILE", "")) / ".pymobiledevice3"
    if not home.is_dir():
        return []
    return sorted(home.glob("*.plist"))


async def main():
    print("=== records before:", [p.name for p in list_records()])

    print("\n=== pair-setup over USB lockdown")
    lockdown = await create_using_usbmux(serial=UDID, autopair=False)
    try:
        svc = await T.RemotePairingLockdownService.create(lockdown)
        try:
            await svc.connect(autopair=True)
            print("  connected (already paired?)")
        except RemotePairingCompletedError:
            print("  PAIRING COMPLETED (device closes the connection after pair-setup, as expected)")
        except Exception as e:
            print("  pair attempt:", type(e).__name__, e)
        finally:
            try:
                await svc.close()
            except Exception:
                pass
    finally:
        try:
            await lockdown.close()
        except Exception:
            pass

    recs = list_records()
    print("\n=== records after:", [p.name for p in recs])
    for p in recs:
        try:
            d = plistlib.loads(p.read_bytes())
            print(f"  {p.name}: keys={sorted(d.keys())}")
        except Exception as e:
            print(f"  {p.name}: unreadable {e}")

    # The record filename carries the device identifier; use it as remote_identifier.
    ids = [p.stem.replace("remote_", "") for p in recs]
    if not ids:
        print("\nno record produced — stopping")
        return
    remote_id = ids[0]
    print(f"\n=== RSD tunnel test with remote_identifier={remote_id}")

    for label, host in (("tailscale", TS_IP), ("lan", LAN_IP)):
        print(f"\n--- {label} {host}:{PORT}")
        s = T.RemotePairingTunnelService(remote_id, host, PORT)
        try:
            async with s:
                await s.connect(autopair=False)
                print("  pair-verify OK")
                async with T.start_tunnel_over_remotepairing(s, max_idle_timeout=60, protocol=TunnelProtocol.TCP) as tun:
                    print(f"  TUNNEL UP rsd={tun.address}")
                    rsd = RSD(tun.address)
                    try:
                        await rsd.connect()
                        names = []
                        try:
                            names = [x.get("ServiceName") for x in rsd.all_services]
                        except Exception:
                            d = getattr(rsd, "services", {})
                            names = list(d.keys()) if hasattr(d, "keys") else []
                        print(f"  RSD services: {len(names)}")
                        if "com.apple.mobile.installation_proxy" in names:
                            c = await rsd.connect_service("com.apple.mobile.installation_proxy")
                            resp = await c.send_recv_plist({"Command": "Lookup", "ClientOptions": {"ApplicationType": "User"}})
                            apps = resp.get("LookupResult", {})
                            print(f"  installation_proxy Lookup -> {len(apps)} user apps")
                            for b in list(apps)[:6]:
                                print("     -", b)
                            await c.close()
                    except Exception as e:
                        print("  RSD error:", type(e).__name__, e)
                    finally:
                        try:
                            await rsd.close()
                        except Exception:
                            pass
        except Exception as e:
            print("  tunnel failed:", type(e).__name__, e)


asyncio.run(main())
