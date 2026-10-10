"""Browse mDNS from the desktop: can we see our own pairable-host advertisement, and does the
phone advertise anything? Also prints the host's IPv4 addresses so we can confirm the LAN."""
import socket, sys, time
from zeroconf import Zeroconf, ServiceBrowser, ServiceListener

TYPES = [
    "_remotepairing-pairable-host._tcp.local.",
    "_remotepairing-manual-pairing._tcp.local.",
    "_remotepairing._tcp.local.",
    "_apple-mobdev2._tcp.local.",
]


class L(ServiceListener):
    def __init__(self):
        self.found = []
    def add_service(self, zc, type_, name):
        info = zc.get_service_info(type_, name, timeout=3000)
        addrs = []
        if info:
            for a in info.addresses:
                try: addrs.append(socket.inet_ntoa(a))
                except Exception: pass
        print(f"  FOUND [{type_}] {name} port={info.port if info else '?'} addrs={addrs}", flush=True)
        self.found.append(name)
    def update_service(self, zc, type_, name): pass
    def remove_service(self, zc, type_, name): pass


def local_addrs():
    out = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            out.append(info[4][0])
    except Exception:
        pass
    return sorted(set(out))


print("host IPv4:", local_addrs(), flush=True)
zc = Zeroconf()
listener = L()
browsers = [ServiceBrowser(zc, t, listener) for t in TYPES]
time.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 8)
zc.close()
print(f"total services seen: {len(listener.found)}", flush=True)
