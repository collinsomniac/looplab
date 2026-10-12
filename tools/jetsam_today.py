"""Find JetsamEvent / resource reports from today and print the Nabla entry of each."""
import asyncio, json, re, sys
from typing import cast
from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.common import TunnelProtocol
from pymobiledevice3.remote.userspace_tunnel import UserspaceDialPlane, UserspaceTun
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD
from pymobiledevice3.services.crash_reports import CrashReportsManager

DAY = sys.argv[1] if len(sys.argv) > 1 else "2026-10-11"


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
                today = sorted(n for n in names if DAY in n)
                print(f"{len(today)} reports on {DAY}:")
                for n in today:
                    print("   ", n)
                afc = mgr.afc
                for n in today:
                    if not re.search(r"(Jetsam|Nabla|ExcResource|cpu_resource|diskwrites)", n, re.I):
                        continue
                    try:
                        raw = await afc.get_file_contents(n)
                    except Exception as e:
                        print(f"  read {n}: {e}"); continue
                    text = raw.decode("utf-8", "replace")
                    print("=" * 90); print(n, len(text), "bytes")
                    # .ips = one JSON header line + JSON body
                    parts = text.split("\n", 1)
                    body = parts[1] if len(parts) > 1 else parts[0]
                    try:
                        j = json.loads(body)
                    except Exception:
                        print(text[:3000]); continue
                    if "processes" in j:  # JetsamEvent
                        print("  largestProcess:", j.get("largestProcess"), "| memoryStatus:",
                              {k: j.get("memoryStatus", {}).get(k) for k in ("memoryPages", "compressorSize")} if isinstance(j.get("memoryStatus"), dict) else "")
                        for p in j["processes"]:
                            nm = p.get("name", "")
                            if re.search(r"nabla|minis", nm, re.I) or p.get("reason"):
                                pages = p.get("rpages") or p.get("pages")
                                print(f"   proc={nm} reason={p.get('reason')} rpages={pages} "
                                      f"(~{(pages or 0)*16384/1e9:.2f} GB) lifetimeMax={p.get('lifetimeMax')} states={p.get('states')}")
                    else:
                        for k in ("exception", "termination", "event", "duration", "writes_caused", "action_taken",
                                  "resource", "limit", "procName", "parentProc"):
                            if k in j:
                                print(f"  {k}: {str(j[k])[:500]}")
                        print("  keys:", list(j.keys())[:30])
                await rsd.close()

asyncio.run(main())
