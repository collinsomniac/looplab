"""Package a signed .app directory into an IPA, preserving unix modes and symlinks.

Python's zipfile defaults files to mode 0600 and resolves symlinks, which produces an IPA that
installs but whose main binary is not executable. iOS needs the real modes.
"""
import os, sys, zipfile


def pack(app_dir: str, out: str) -> None:
    app_dir = app_dir.rstrip("/\\")
    app_name = os.path.basename(app_dir)
    if not os.path.isdir(app_dir):
        raise SystemExit(f"not a directory: {app_dir}")
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(app_dir):          # followlinks=False by default
            for name in sorted(dirs) + sorted(files):
                full = os.path.join(root, name)
                # IPAs are rooted at Payload/<App>.app — the prefix is required
                arc = f"Payload/{app_name}/" + os.path.relpath(full, app_dir).replace(os.sep, "/")
                zi = zipfile.ZipInfo(arc + ("/" if os.path.isdir(full) and not os.path.islink(full) else ""),
                                     date_time=(1980, 1, 1, 0, 0, 0))
                st = os.lstat(full)
                mode = st.st_mode & 0xFFFF
                if os.path.islink(full):
                    # symlink: S_IFLNK in the high bits, target as the content
                    zi.external_attr = ((0xA000 | 0o777) << 16)
                    z.writestr(zi, os.readlink(full))
                elif os.path.isdir(full):
                    zi.external_attr = ((0o040000 | 0o755) << 16)
                    z.writestr(zi, b"")
                else:
                    zi.external_attr = (mode << 16)
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    with open(full, "rb") as f:
                        z.writestr(zi, f.read())
                count += 1
    print(f"packed {count} entries -> {out} ({os.path.getsize(out)} bytes)")


if __name__ == "__main__":
    pack(sys.argv[1], sys.argv[2])
