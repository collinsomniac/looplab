"""Full RSD over Tailscale on Windows: pair-verify -> tunnel -> userspace dial plane -> RSD services.

The tunnel's RSD address lives inside a userspace PyTCP stack, so services must be dialled *through*
the tunnel (UserspaceDialPlane.dial) rather than to a routable address.
"""
import asyncio, sys, traceback
from typing import cast

from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.common import TunnelProtocol
from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane, UserspaceTun
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD

REMOTE_ID = "00008150-001139383A52401C"
HOSTS = [("tailscale", "100.65.154.94"), ("lan", "192.168.4.22")]
PORT = 49152


async def probe(label, host):
    print(f"\n===== {label} {host}:{PORT}", flush=True)
    T.USE_USERSPACE_TUNNEL = True
    svc = T.RemotePairingTunnelService(REMOTE_ID, host, PORT)
    async with svc:
        await svc.connect(autopair=False)
        print("  pair-verify OK", flush=True)
        async with T.start_tunnel_over_remotepairing(svc, max_idle_timeout=120,
                                                     protocol=TunnelProtocol.TCP) as tun:
            print(f"  tunnel up: rsd={tun.address} port={tun.port}", flush=True)
            tun_obj = cast(UserspaceTun, tun.client.tun)
            tun_obj.set_peer(tun.address)
            async with UserspaceDialPlane(tun_obj, tun.address) as plane:
                rsd = RSD((tun.address, tun.port), open_connection=plane.dial,
                          auxiliary_metadata=tun.auxiliary_metadata)
                try:
                    await rsd.connect()
                    names = []
                    try:
                        names = [s.get("ServiceName") for s in rsd.all_services]
                    except Exception:
                        d = getattr(rsd, "services", {})
                        names = list(d.keys()) if hasattr(d, "keys") else []
                    print(f"  RSD CONNECTED — {len(names)} services", flush=True)
                    for n in sorted(x for x in names if x and ("installation" in x or "afc" in x or "lockdown" in x)):
                        print("     *", n, flush=True)
                    if "com.apple.mobile.installation_proxy" in names:
                        c = await rsd.connect_service("com.apple.mobile.installation_proxy")
                        resp = await c.send_recv_plist({"Command": "Lookup",
                                                        "ClientOptions": {"ApplicationType": "User"}})
                        apps = resp.get("LookupResult", {})
                        print(f"  installation_proxy Lookup -> {len(apps)} user apps", flush=True)
                        for b in list(apps)[:8]:
                            print("      -", b, flush=True)
                        await c.close()
                    return True
                finally:
                    try:
                        await rsd.close()
                    except Exception:
                        pass


async def main():
    for label, host in HOSTS:
        try:
            if await probe(label, host):
                print(f"\nSUCCESS over {label}", flush=True)
                return
        except Exception as e:
            print(f"  {label} failed: {type(e).__name__}: {e}", flush=True)
            traceback.print_exc()


asyncio.run(main())
