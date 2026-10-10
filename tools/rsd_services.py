"""List RSD services properly and try installation_proxy over Tailscale."""
import asyncio, json, traceback
from typing import cast

from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.common import TunnelProtocol
from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane, UserspaceTun
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD

REMOTE_ID = "00008150-001139383A52401C"
HOST = "100.65.154.94"
PORT = 49152


async def main():
    T.USE_USERSPACE_TUNNEL = True
    svc = T.RemotePairingTunnelService(REMOTE_ID, HOST, PORT)
    async with svc:
        await svc.connect(autopair=False)
        async with T.start_tunnel_over_remotepairing(svc, max_idle_timeout=180,
                                                     protocol=TunnelProtocol.TCP) as tun:
            tun_obj = cast(UserspaceTun, tun.client.tun)
            tun_obj.set_peer(tun.address)
            async with UserspaceDialPlane(tun_obj, tun.address) as plane:
                rsd = RSD((tun.address, tun.port), open_connection=plane.dial,
                          auxiliary_metadata=tun.auxiliary_metadata)
                await rsd.connect()
                print("attributes:", [a for a in dir(rsd) if not a.startswith("_")], flush=True)
                for attr in ("all_services", "services", "peer_info"):
                    v = getattr(rsd, attr, None)
                    if v is None:
                        continue
                    try:
                        if isinstance(v, dict):
                            print(f"{attr}: dict with {len(v)} keys", flush=True)
                            for k in list(v)[:40]:
                                print("   ", k, flush=True)
                        else:
                            print(f"{attr}: {len(v)} entries", flush=True)
                            for e in list(v)[:40]:
                                print("   ", e if isinstance(e, str) else json.dumps(e, default=str)[:120], flush=True)
                    except Exception as e:
                        print(f"{attr}: unreadable {e}", flush=True)

                svcs = (rsd.peer_info or {}).get("Services") or {}
                print(f"\n=== {len(svcs)} RSD services", flush=True)
                for k in sorted(svcs):
                    if any(s in k for s in ("installation", "afc", "lockdown", "instrument", "sysmontap")):
                        print("   *", k, flush=True)

                print("\n=== installation_proxy", flush=True)
                try:
                    c = await rsd.start_remote_service("com.apple.mobile.installation_proxy.shim.remote")
                    resp = await c.send_recv_plist({"Command": "Lookup", "ClientOptions": {"ApplicationType": "User"}})
                    apps = resp.get("LookupResult", {})
                    print(f"  {len(apps)} user apps", flush=True)
                    for b, meta in list(apps.items())[:10]:
                        print(f"   - {b}  v{meta.get('CFBundleShortVersionString')}", flush=True)
                    await c.close()
                except Exception as e:
                    print("  failed:", type(e).__name__, e, flush=True)
                    traceback.print_exc()
                finally:
                    try:
                        await rsd.close()
                    except Exception:
                        pass


asyncio.run(main())
