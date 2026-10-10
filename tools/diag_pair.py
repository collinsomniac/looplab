"""Diagnose the RemotePairing handshake: debug logging, and try both Tailscale and LAN addresses."""
import asyncio, logging, plistlib, sys, traceback
from pathlib import Path

logging.basicConfig(level=logging.DEBUG, format="%(levelname)s %(name)s: %(message)s")
for noisy in ("asyncio", "quic", "aioquic"):
    logging.getLogger(noisy).setLevel(logging.WARNING)

DEVICE_ID = "006A7A56-A979-4D4B-88B0-F3D4F4DE6163"
ADDRS = [("tailscale", "100.65.154.94", 49152), ("lan", "192.168.4.22", 49152)]
PORT_ALT = [49152, 32498]

from pymobiledevice3.remote import tunnel_service as T


async def try_addr(label, host, port):
    print(f"\n===== {label}: {host}:{port}", flush=True)
    svc = T.RemotePairingTunnelService(DEVICE_ID, host, port)
    try:
        async with svc:
            await svc.connect(autopair=False)
            print("  CONNECTED (pair-verify ok)", flush=True)
    except Exception as e:
        print(f"  failed: {type(e).__name__}: {e}", flush=True)
        return False
    return True


async def main():
    for label, host, port in ADDRS:
        for p in PORT_ALT:
            ok = await try_addr(f"{label}", host, p)
            if ok:
                return


asyncio.run(main())
