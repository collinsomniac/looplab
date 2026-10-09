"""Generate LoopLab app icon: 1024x1024 PNG, dark navy field with a lighter "loop" ring and a core dot.
Pure stdlib (zlib + struct) so it runs anywhere."""
import struct, zlib, math, os

S = 1024
BG = (13, 17, 23)
RING = (88, 166, 255)
CORE = (126, 231, 135)
RING_R, RING_W = 300, 58
CORE_R = 96

px = bytearray()
cx = cy = S / 2

# precompute per-row for speed
def blend(base, top, a):
    return tuple(int(b + (t - b) * a) for b, t in zip(base, top))

rows = []
for y in range(S):
    row = bytearray()
    for x in range(S):
        d = math.hypot(x - cx, y - cy)
        c = BG
        # ring: antialiased band
        edge = abs(d - RING_R) - RING_W / 2
        if edge < 1.5:
            a = 1.0 if edge < -1.5 else (1.5 - edge) / 3.0
            c = blend(c, RING, a)
        # core dot
        e2 = d - CORE_R
        if e2 < 1.5:
            a = 1.0 if e2 < -1.5 else (1.5 - e2) / 3.0
            c = blend(c, CORE, a)
        # a gap in the ring at the top-right, suggesting a cycle that continues
        ang = math.degrees(math.atan2(-(y - cy), x - cx)) % 360
        if 35 <= ang <= 75 and abs(d - RING_R) - RING_W / 2 < 1.5:
            c = BG
        row += bytes(c)
    rows.append(bytes(row))

raw = b"".join(b"\x00" + r for r in rows)

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
os.makedirs(os.path.join(root, "App", "Assets.xcassets", "AppIcon.appiconset"), exist_ok=True)
open(os.path.join(root, "icon.png"), "wb").write(png)
open(os.path.join(root, "App", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"), "wb").write(png)
open(os.path.join(root, "App", "Assets.xcassets", "AppIcon.appiconset", "Contents.json"), "w").write(
    '{\n  "images" : [\n    {\n      "filename" : "icon-1024.png",\n      "idiom" : "universal",\n      "platform" : "ios",\n      "size" : "1024x1024"\n    }\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
open(os.path.join(root, "App", "Assets.xcassets", "Contents.json"), "w").write(
    '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
print("wrote icon.png and app icon set, bytes:", len(png))
