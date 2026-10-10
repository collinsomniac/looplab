"""Prove the full path: RSD over Tailscale -> installation_proxy -> list installed apps."""
import asyncio, traceback
from typing import cast

from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.common import TunnelProtocol
from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane, UserspaceTun
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD
from pymobiledevice3.services.installation_proxy import InstallationProxyService

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
                print("RSD over Tailscale connected", flush=True)
                try:
                    ip = InstallationProxyService(rsd)
                    apps = await ip.get_apps(application_type="User")
                    print(f"installation_proxy: {len(apps)} user apps", flush=True)
                    for b, m in list(apps.items())[:12]:
                        print(f"   - {b}  v{m.get('CFBundleShortVersionString')}", flush=True)
                    if "com.collinsomniac.looplab" in apps:
                        print("LoopLab installed:", apps["com.collinsomniac.looplab"].get("CFBundleShortVersionString"), flush=True)
                except Exception as e:
                    print("installation_proxy failed:", type(e).__name__, e, flush=True)
                    traceback.print_exc()
                finally:
                    try:
                        await rsd.close()
                    except Exception:
                        pass


asyncio.run(main())
