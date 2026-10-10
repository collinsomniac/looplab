"""Pair with the phone without a cable.

pymobiledevice3's own mDNS responder does not appear to publish on this Windows host, so we run its
pairing listener (which owns the protocol logic) and publish the advertisement ourselves with
zeroconf, which we verified is visible on this LAN.

On the phone: Settings > Developer > Paired Macs, then tap this host under "Other Devices" and enter
the printed PIN.
"""
import asyncio, socket, sys, threading, time
from pymobiledevice3.remote import tunnel_service as T
from zeroconf import Zeroconf, ServiceInfo

LAN_IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.4.28"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 45999
TIMEOUT = float(sys.argv[3]) if len(sys.argv) > 3 else 2400.0
SERVICE = "_remotepairing-pairable-host._tcp.local."

info = T.PairableHostInfo(name="loopscope-desktop", model="Mac17,7")
txt = info.mdns_txt_records()
print("identifier:", info.identifier, flush=True)
print("TXT records:", txt, flush=True)

zc = Zeroconf()
props = {}
for k, v in (txt or {}).items():
    props[k] = v if isinstance(v, bytes) else str(v).encode()
si = ServiceInfo(
    type_=SERVICE,
    name=f"{info.identifier}.{SERVICE}",
    addresses=[socket.inet_aton(LAN_IP)],
    port=PORT,
    properties=props,
    server=f"{socket.gethostname()}.local.",
)
zc.register_service(si, strict=False)
print(f"advertised {si.name} at {LAN_IP}:{PORT}", flush=True)
time.sleep(1.5)
# Show our own registration back to ourselves, as proof it is live on the network.
from zeroconf import ServiceBrowser, ServiceListener


class L(ServiceListener):
    def add_service(self, zc_, type_, name):
        i = zc_.get_service_info(type_, name, timeout=2000)
        if i:
            addrs = [socket.inet_ntoa(a) for a in i.addresses]
            print(f"  SEEN ON LAN: {name} {addrs}:{i.port} props={i.properties}", flush=True)
    def update_service(self, *a): pass
    def remove_service(self, *a): pass


try:
    ServiceBrowser(zc, SERVICE, L())
except Exception as e:
    print("  (self-check browse unavailable:", e, ")")
time.sleep(4)


def pin(p):
    print(f"\n  ==== ENTER THIS CODE ON THE PHONE: {p} ====\n", flush=True)


def waiting(sec):
    if int(sec) % 20 == 0:
        print(f"  waiting {int(sec)}s — open Settings > Developer > Paired Macs", flush=True)


async def main():
    try:
        result = await T.serve_pairable_host(info, port=PORT, pin_callback=pin,
                                             timeout=TIMEOUT, waiting_callback=waiting)
        print("PAIRED:", result, flush=True)
    except Exception as e:
        print("pairing failed:", type(e).__name__, e, flush=True)
    finally:
        try:
            zc.unregister_service(si); zc.close()
        except Exception:
            pass


asyncio.run(main())
