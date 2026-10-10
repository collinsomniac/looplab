"""Build a pymobiledevice3 RemotePairing record from iloader's stored pairing, then tunnel to the
phone over Tailscale and prove we can reach the install service.

Inputs (on the desktop):
  D:\\loopscope\\cred_LegacyGeneric_target_rppairing1_1_file_00008150_001139383A52.bin
      iloader's RP pairing plist: private_key (Ed25519), identifier (host identifier), public_key, alt_irk
"""
import asyncio, plistlib, sys, traceback
from pathlib import Path

SRC = Path(r"D:\loopscope\cred_LegacyGeneric_target_rppairing1_1_file_00008150_001139383A52.bin")
DEVICE_ID = sys.argv[1] if len(sys.argv) > 1 else "006A7A56-A979-4D4B-88B0-F3D4F4DE6163"
HOST = sys.argv[2] if len(sys.argv) > 2 else "100.65.154.94"
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 49152

from pymobiledevice3.pair_records import get_remote_pairing_record_filename, create_pairing_records_cache_folder
from pymobiledevice3.remote import tunnel_service as T
from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService as RSD

raw = plistlib.loads(SRC.read_bytes())
print("iloader record keys:", sorted(raw.keys()))
print("  host identifier:", raw.get("identifier"))
print("  private key bytes:", len(raw.get("private_key", b"")))
print("  public  key bytes:", len(raw.get("public_key", b"")))

record = {
    "host_identifier": raw["identifier"],
    "private_key": raw["private_key"],
    "public_key": raw.get("public_key", b""),
}
if raw.get("alt_irk"):
    record["alt_irk"] = raw["alt_irk"]

folder = create_pairing_records_cache_folder()
path = get_remote_pairing_record_filename(DEVICE_ID)
Path(path).parent.mkdir(parents=True, exist_ok=True)
Path(path).write_bytes(plistlib.dumps(record))
print("wrote pymobiledevice3 record:", path, Path(path).stat().st_size, "bytes")
print("cache folder:", folder)


async def main():
    print(f"\n=== tunnel: {DEVICE_ID} @ {HOST}:{PORT} (Tailscale)")
    svc = T.RemotePairingTunnelService(DEVICE_ID, HOST, PORT)
    try:
        async with svc:
            await svc.connect(autopair=False)
            print("  pair-verify OK (the phone accepted iloader's host key)")
            async with T.start_tunnel_over_remotepairing(svc, max_idle_timeout=60) as tun:
                print(f"  TUNNEL UP: rsd address = {tun.address}")
                rsd = RSD(tun.address)
                try:
                    await rsd.connect()
                    services = []
                    try:
                        services = [s.get("ServiceName") for s in rsd.all_services]
                    except Exception:
                        d = getattr(rsd, "services", {})
                        services = list(d.keys()) if hasattr(d, "keys") else []
                    print(f"  RSD connected: {len(services)} services")
                    for n in sorted(x for x in services if x and ("installation" in x or "afc" in x)):
                        print("    *", n)
                    if "com.apple.mobile.installation_proxy" in services:
                        c = await rsd.connect_service("com.apple.mobile.installation_proxy")
                        resp = await c.send_recv_plist({"Command": "Lookup", "ClientOptions": {"ApplicationType": "User"}})
                        apps = resp.get("LookupResult", {})
                        print(f"  installation_proxy Lookup -> {len(apps)} user apps")
                        for bid in list(apps)[:5]:
                            print("     -", bid)
                        await c.close()
                    else:
                        print("  installation_proxy NOT in service list")
                except Exception as e:
                    print("  RSD error:", type(e).__name__, e)
                    traceback.print_exc()
                finally:
                    try: await rsd.close()
                    except Exception: pass
    except Exception as e:
        print("TUNNEL FAILED:", type(e).__name__, e)
        traceback.print_exc()


asyncio.run(main())
