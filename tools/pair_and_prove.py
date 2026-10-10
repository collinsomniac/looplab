"""Pair with the iPhone once (device-initiated, iOS 27) and then prove a Tailscale-only path.

Phase 1: advertise as a pairable host over Bonjour. On the phone:
         Settings > Developer > Paired Macs, tap this host under "Other Devices", enter the PIN.
Phase 2: with the record saved, build the RemotePairing tunnel directly against the Tailscale
         address (no Bonjour) and ask the device for its RSD address.
Phase 3: connect to RSD and list the services it offers (installation_proxy is the one we need).

Usage: python pair_and_prove.py <tailscale-ip> <udid> [phase]
"""
import asyncio, json, os, platform, sys, traceback
from pathlib import Path

HOST = sys.argv[1] if len(sys.argv) > 1 else "100.65.154.94"
UDID = sys.argv[2] if len(sys.argv) > 2 else "00008150-001139383A52401C"
PHASE = sys.argv[3] if len(sys.argv) > 3 else "pair"
RSPORT = 49152

from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD


async def phase_pair():
    info = T.PairableHostInfo(name="loopscope-desktop", model="Mac17,7")

    def pin(p):
        print(f"PIN={p}", flush=True)

    def waiting(sec):
        if int(sec) % 30 == 0:
            print(f"  still waiting ({int(sec)}s) — open Settings > Developer > Paired Macs", flush=True)

    print("advertising as a pairable host (Bonjour) ...", flush=True)
    result = await T.serve_pairable_host(info, pin_callback=pin, timeout=2400, waiting_callback=waiting)
    print("PAIRED:", result, flush=True)


async def phase_prove():
    print(f"connecting RemotePairing to {HOST}:{RSPORT} (Tailscale) ...", flush=True)
    svc = T.RemotePairingTunnelService(UDID, HOST, RSPORT)
    async with svc:
        print("  pairing service reachable", flush=True)
        async for tun in T.start_tunnel_over_remotepairing(svc, max_idle_timeout=60):
            addr = tun.address
            print(f"TUNNEL RSD ADDRESS = {addr}", flush=True)
            if PHASE == "prove":
                break
            rsd = RSD(addr)
            try:
                await rsd.connect()
                names = []
                try:
                    names = [s.get("ServiceName") for s in rsd.all_services]  # type: ignore
                except Exception:
                    names = list(getattr(rsd, "services", {}).keys()) if hasattr(rsd, "services") else []
                print(f"  RSD connected; {len(names)} services", flush=True)
                interesting = [n for n in names if n and any(k in n for k in ("installation", "afc", "sysmontap", "mobile_image"))]
                print("  of interest:", interesting, flush=True)
                if "com.apple.mobile.installation_proxy" in (names or []):
                    c = await rsd.connect_service("com.apple.mobile.installation_proxy")
                    await c.send_recv_plist({"Command": "Lookup", "ClientOptions": {"ApplicationType": "User"}})
                    print("  installation_proxy responded to Lookup", flush=True)
                    await c.close()
            except Exception as e:
                print("  RSD error:", type(e).__name__, e, flush=True)
            finally:
                await rsd.close()
            break


async def main():
    if PHASE in ("pair", "both"):
        try:
            await phase_pair()
        except Exception:
            traceback.print_exc()
    if PHASE in ("prove", "both"):
        try:
            await phase_prove()
        except Exception:
            traceback.print_exc()


asyncio.run(main())
