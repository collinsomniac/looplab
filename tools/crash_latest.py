"""List Nabla crash reports on the phone over the Tailscale RSD tunnel and symbolicate-print the newest.

Uses CrashReportsManager.parse() (mgr.pull() silently writes nothing on Windows paths).
Prints: exception, termination reason, crashed thread frames (symbol + image), and the
last-exception backtrace if present.
"""
import asyncio, re, sys
from typing import cast
from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.common import TunnelProtocol
from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane, UserspaceTun
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD
from pymobiledevice3.services.crash_reports import CrashReportsManager

PAT = re.compile(r"(nabla)", re.I)
N = int(sys.argv[1]) if len(sys.argv) > 1 else 2


def show(rep, name):
    print("=" * 100)
    print(name)
    for attr in ("timestamp", "incident_id", "exception_type", "exception_subtype", "faulting_thread",
                 "termination_reason", "bug_type"):
        v = getattr(rep, attr, None)
        if v not in (None, ""):
            print(f"  {attr}: {v}")
    frames = getattr(rep, "frames", None) or []
    print(f"  crashed-thread frames: {len(frames)}")
    for i, f in enumerate(frames[:40]):
        sym = getattr(f, "symbol", None) or "?"
        img = getattr(f, "image_name", None) or getattr(f, "image", None) or "?"
        off = getattr(f, "offset", None) or getattr(f, "symbol_offset", None) or ""
        print(f"   {i:2d} {img:28s} {sym} {off}")
    raw = getattr(rep, "_data", None) or getattr(rep, "raw", None)
    if isinstance(raw, dict):
        for k in ("exception", "termination", "asi", "lastExceptionBacktrace", "crashReporterKey"):
            if k in raw:
                print(f"  {k}: {str(raw[k])[:1200]}")


async def main():
    T.USE_USERSPACE_TUNNEL = True
    svc = T.RemotePairingTunnelService("00008150-001139383A52401C", "100.65.154.94", 49152)
    async with svc:
        await svc.connect(autopair=False)
        async with T.start_tunnel_over_remotepairing(svc, max_idle_timeout=600, protocol=TunnelProtocol.TCP) as tun:
            t = cast(UserspaceTun, tun.client.tun); t.set_peer(tun.address)
            async with UserspaceDialPlane(t, tun.address) as plane:
                rsd = RSD((tun.address, tun.port), open_connection=plane.dial, auxiliary_metadata=tun.auxiliary_metadata)
                await rsd.connect()
                mgr = CrashReportsManager(rsd)
                names = await mgr.ls("/", depth=2)
                hits = sorted(n for n in names if PAT.search(n))
                print(f"{len(names)} entries; nabla-matching: {len(hits)}")
                for h in hits[-12:]:
                    print("   ", h)
                for h in hits[-N:]:
                    try:
                        rep = await mgr.parse(h)
                        show(rep, h)
                    except Exception as e:
                        print(f"  parse {h}: {type(e).__name__}: {e}")
                await rsd.close()

asyncio.run(main())
