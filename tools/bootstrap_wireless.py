"""One-time bootstrap while the phone is connected by USB.

Enables everything that makes future installs cable-free, and reports what worked:
  1. confirm the phone is visible over USB
  2. read + enable Wi-Fi sync (EnableWifiConnections) -> classic lockdown over TCP
  3. ask the lockdown RemotePairing control channel for its handshake info
  4. list the pair records we end up with

Run with the phone plugged in, unlocked, and trusted.
"""
import asyncio, json, sys
from pymobiledevice3.lockdown import create_using_usbmux

UDID = sys.argv[1] if len(sys.argv) > 1 else None


async def main():
    print("=== devices over USB")
    try:
        from pymobiledevice3.usbmux import list_devices
        devs = await list_devices()
        for d in devs:
            print(f"  {d.serial}  {d.connection_type}")
        if not devs:
            print("  none — is the phone plugged in and unlocked?")
            return
    except Exception as e:
        print("  usbmux list failed:", type(e).__name__, e)

    print("\n=== lockdown over USB")
    client = await create_using_usbmux(serial=UDID, autopair=False)
    try:
        vals = await client.get_value()
        for k in ("ProductVersion", "ProductType", "DeviceName", "UniqueDeviceID",
                  "EnableWifiConnections", "WiFiAddress", "DeveloperModeStatus"):
            if k in vals:
                print(f"  {k} = {vals[k]}")

        print("\n=== enable Wi-Fi sync")
        try:
            await client.set_value(domain="com.apple.mobile.wireless_lockdown",
                                   key="EnableWifiConnections", value=True)
            print("  set EnableWifiConnections = true")
        except Exception as e:
            print("  set failed:", type(e).__name__, e)
        try:
            await client.set_value(domain="com.apple.mobile.wireless_lockdown",
                                   key="EnableWifi", value=True)
            print("  set EnableWifi = true")
        except Exception as e:
            print("  (EnableWifi)", type(e).__name__, e)

        vals2 = await client.get_value()
        print("  now EnableWifiConnections =", vals2.get("EnableWifiConnections"),
              " EnableWifi =", vals2.get("EnableWifi"))

        print("\n=== lockdown RemotePairing control channel")
        try:
            resp = await client.get_service_client("com.apple.dt.remotepairingdeviced.lockdown")
            print("  service opened:", type(resp).__name__)
        except Exception as e:
            print("  not available:", type(e).__name__, e)
    finally:
        await client.close()

    print("\n=== pair records on this host")
    import os, glob
    for p in glob.glob(os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"),
                                    "Apple", "Lockdown", "*.plist")):
        print("  ", os.path.basename(p), os.path.getsize(p), "bytes")
    home = os.path.join(os.environ.get("USERPROFILE", ""), ".pymobiledevice3")
    if os.path.isdir(home):
        for f in os.listdir(home):
            print("  rp:", f)


asyncio.run(main())
