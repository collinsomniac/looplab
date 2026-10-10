"""Deploy a LoopLab IPA to the phone with no cable: fetch -> sign -> pack -> install -> verify.

Runs on the desktop. Needs:
  - loopdeploy.exe (the Rust signer, from the loopdeploy CI release) in the working directory
  - iloader's saved Apple ID credentials in the Windows keyring (service "iloader")
  - the RemotePairing record from the one-time USB pairing (~/.pymobiledevice3/remote_<udid>.plist)
  - Python 3.13 (the TCP tunnel)

2FA: Apple issues a fresh code for every login. The signer writes WAITING_FOR_CODE to its log and
waits for the code in `2fa.txt` (10 minutes). Write the code there and it continues. Once the session
is cached in the keyring, later deploys usually need no code.

Usage:
  python deploy.py                    # newest GitHub release
  python deploy.py <path-to.ipa>      # a local IPA
"""
import os
import re
import subprocess
import sys
import time
import json
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = r"D:\loopscope"
SIGNER = os.path.join(WORK, "loopdeploy.exe")
SIGN_LOG = os.path.join(WORK, "sign.log")
CODE_FILE = os.path.join(WORK, "2fa.txt")
UDID = "00008150-001139383A52401C"
EMAIL = "collinchattom@gmail.com"
ANISETTE = "https://ani.sidestore.io"
APP_ID = "io.github.collinsomniac.looplab"
REPO = "collinsomniac/looplab"
PY313 = os.path.join(os.environ.get("LOCALAPPDATA", ""), r"Programs\Python\Python313\python.exe")


def latest_release_ipa() -> str:
    url = f"https://api.github.com/repos/{REPO}/releases"
    tok = os.environ.get("GITHUB_TOKEN")
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json",
                                               **({"Authorization": f"Bearer {tok}"} if tok else {})})
    releases = json.loads(urllib.request.urlopen(req, timeout=60).read())
    for rel in releases:
        assets = [a for a in rel["assets"] if a["name"].endswith(".ipa")]
        if assets:
            out = os.path.join(WORK, "LoopLab-latest.ipa")
            print(f"release {rel['tag_name']} -> {assets[0]['name']}")
            subprocess.run(["curl.exe", "-sL", "--fail", "-o", out, assets[0]["browser_download_url"]], check=True)
            return out
    raise SystemExit("no IPA asset in any release")


def sign(ipa: str) -> str:
    out = os.path.join(WORK, "LoopLab-signed.ipa")
    for f in (SIGN_LOG, CODE_FILE, out):
        if os.path.exists(f):
            os.remove(f)
    env = dict(os.environ, LOOPDEPLOY_2FA_FILE=CODE_FILE)
    proc = subprocess.Popen([SIGNER, "sign", ipa, out, EMAIL, UDID, ANISETTE],
                            cwd=WORK, env=env,
                            stdout=open(SIGN_LOG, "w"), stderr=subprocess.STDOUT)
    print("signing… (watch for WAITING_FOR_CODE)")
    deadline = time.time() + 900
    waiting_announced = False
    while proc.poll() is None and time.time() < deadline:
        try:
            text = open(SIGN_LOG, encoding="utf-8", errors="replace").read()
        except OSError:
            text = ""
        if "WAITING_FOR_CODE" in text and not waiting_announced:
            waiting_announced = True
            print(f"\n*** 2FA REQUIRED: write the code to {CODE_FILE} (e.g. "
                  f"echo 123456 > \"{CODE_FILE}\") ***\n")
        time.sleep(3)
    if proc.poll() is None:
        proc.kill()
        raise SystemExit("signing timed out")
    log = open(SIGN_LOG, encoding="utf-8", errors="replace").read()
    if "App signed!" not in log:
        raise SystemExit(f"signing failed:\n{log[-2000:]}")
    print("signed ok (packaging is done by pack_ipa.py)")
    return out


def pack_and_install(signed_ipa: str) -> None:
    """The signer leaves a signed .app; re-pack it (it needs the Payload/ prefix and unix modes)."""
    import glob
    candidates = glob.glob(os.path.join(os.environ.get("TEMP", ""), "*_extracted", "Payload", "*.app"))
    candidates += glob.glob(os.path.join(os.environ.get("TEMP", ""), "Payload", "*.app"))
    if not candidates:
        raise SystemExit("could not find the signed .app to repack")
    app = max(candidates, key=os.path.getmtime)
    packed = os.path.join(WORK, "LoopLab-signed.ipa")
    subprocess.run([sys.executable, os.path.join(HERE, "pack_ipa.py"), app, packed], check=True)
    # install over the RSD tunnel
    inst = os.path.join(WORK, "install_signed.py")
    subprocess.run([PY313 if os.path.exists(PY313) else sys.executable, inst, packed], check=True)


if __name__ == "__main__":
    ipa = sys.argv[1] if len(sys.argv) > 1 else latest_release_ipa()
    signed = sign(ipa)
    pack_and_install(signed)
