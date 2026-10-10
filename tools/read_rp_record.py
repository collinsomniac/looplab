"""Read iloader's stored RemotePairing record out of Windows Credential Manager."""
import sys, base64, binascii

UDID = sys.argv[1] if len(sys.argv) > 1 else "00008150-001139383A52401C"
KEYS = [f"rppairing1.1_file_{UDID}", f"host_label_{UDID}"]

import keyring

for k in KEYS:
    for svc in ("iloader",):
        try:
            v = keyring.get_password(svc, k)
        except Exception as e:
            print(f"  {svc}/{k}: error {type(e).__name__}: {e}")
            continue
        if v is None:
            print(f"  {svc}/{k}: (not found)")
            continue
        print(f"  {svc}/{k}: {len(v)} chars")
        raw = None
        # iloader stores Vec<u8>; keyring gives back a string. Try the usual encodings.
        for name, dec in (
            ("latin1", lambda s: s.encode("latin1")),
            ("b64", lambda s: base64.b64decode(s + "=" * (-len(s) % 4))),
            ("hex", lambda s: binascii.unhexlify(s)),
        ):
            try:
                cand = dec(v)
            except Exception:
                continue
            if cand[:8].startswith(b"<?xml") or cand[:6].startswith(b"bplist"):
                raw = cand
                print(f"    -> decoded as {name}, {len(cand)} bytes, plist header {cand[:16]!r}")
                break
        if raw is None:
            print(f"    -> raw head: {v[:120]!r}")
            raw = v.encode("latin1", "ignore")
        out = f"D:\\loopscope\\iloader_rp_{k.split('_')[-1][:8]}.plist"
        try:
            open(out, "wb").write(raw)
            print(f"    wrote {out}")
        except Exception as e:
            print("    write failed:", e)
        if "rppairing" in k:
            try:
                txt = raw.decode("utf-8", "replace")
                print("    ---- contents ----")
                print("\n".join("      " + l for l in txt.splitlines()[:40]))
            except Exception as e:
                print("    decode failed:", e)
