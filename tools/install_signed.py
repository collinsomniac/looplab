"""Install a signed IPA on the phone over Tailscale (RSD tunnel), then read the version back."""
import asyncio, sys
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
    ipa = sys.argv[1]
    T.USE_USERSPACE_TUNNEL = True
    svc = T.RemotePairingTunnelService(REMOTE_ID, HOST, PORT)
    async with svc:
        await svc.connect(autopair=False)
        async with T.start_tunnel_over_remotepairing(svc, max_idle_timeout=900, protocol=TunnelProtocol.TCP) as tun:
            tun_obj = cast(UserspaceTun, tun.client.tun)
            tun_obj.set_peer(tun.address)
            async with UserspaceDialPlane(tun_obj, tun.address) as plane:
                rsd = RSD((tun.address, tun.port), open_connection=plane.dial,
                          auxiliary_metadata=tun.auxiliary_metadata)
                await rsd.connect()
                print("RSD over Tailscale connected", flush=True)
                ip = InstallationProxyService(rsd)
                print(f"installing {ipa} ...", flush=True)
                await ip.install_from_local(ipa)
                apps = await ip.get_apps(application_type="User")
                hits = {k: v for k, v in apps.items() if "looplab" in k.lower()}
                for k, v in hits.items():
                    print(f"installed: {k} v{v.get('CFBundleShortVersionString')} ({v.get('CFBundleVersion')})", flush=True)
                if not hits:
                    print("no LoopLab bundle found (check the bundle id)", flush=True)
                await rsd.close()


asyncio.run(main())
