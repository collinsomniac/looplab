"""Enumerate Windows Credential Manager entries and dump any that look like iloader's pairing."""
import ctypes, ctypes.wintypes as w, sys

CRED_TYPE_GENERIC = 1
CRED_ENUMERATE_ALL_CREDENTIALS = 0x1


class CREDENTIAL(ctypes.Structure):
    _fields_ = [
        ("Flags", w.DWORD),
        ("Type", w.DWORD),
        ("TargetName", w.LPWSTR),
        ("Comment", w.LPWSTR),
        ("LastWritten", w.FILETIME),
        ("CredentialBlobSize", w.DWORD),
        ("CredentialBlob", ctypes.POINTER(ctypes.c_byte)),
        ("Persist", w.DWORD),
        ("AttributeCount", w.DWORD),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", w.LPWSTR),
        ("UserName", w.LPWSTR),
    ]


advapi = ctypes.WinDLL("advapi32", use_last_error=True)
advapi.CredEnumerateW.argtypes = [w.LPCWSTR, w.DWORD, ctypes.POINTER(w.DWORD), ctypes.POINTER(ctypes.POINTER(ctypes.POINTER(CREDENTIAL)))]
advapi.CredEnumerateW.restype = w.BOOL
advapi.CredFree.argtypes = [ctypes.c_void_p]

count = w.DWORD(0)
pp = ctypes.POINTER(ctypes.POINTER(CREDENTIAL))()
ok = advapi.CredEnumerateW(None, CRED_ENUMERATE_ALL_CREDENTIALS, ctypes.byref(count), ctypes.byref(pp))
if not ok:
    print("CredEnumerate failed:", ctypes.get_last_error())
    sys.exit(1)

print(f"{count.value} credential(s) in this logon session")
wanted = []
for i in range(count.value):
    c = pp[i].contents
    tn = c.TargetName or ""
    un = c.UserName or ""
    blob = ctypes.string_at(c.CredentialBlob, c.CredentialBlobSize) if c.CredentialBlobSize else b""
    interesting = any(k in tn.lower() or k in un.lower() for k in ("iloader", "rppairing", "pairing", "host_label", "side"))
    print(f"  [{i}] target={tn!r} user={un!r} type={c.Type} blob={len(blob)}B {'<== MATCH' if interesting else ''}")
    if interesting:
        wanted.append((tn, un, blob))

for tn, un, blob in wanted:
    safe = "".join(ch if ch.isalnum() else "_" for ch in tn)[:60]
    path = f"D:\\loopscope\\cred_{safe}.bin"
    open(path, "wb").write(blob)
    print(f"  wrote {path} ({len(blob)} bytes)")
    head = blob[:400]
    try:
        text = blob.decode("utf-8")
        print("    as text:", text[:300].replace("\n", " "))
    except Exception:
        print("    as bytes:", head[:200])
