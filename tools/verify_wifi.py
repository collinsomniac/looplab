"""Verify Wi-Fi sync took effect, and test lockdownd over TCP (LAN + Tailscale) while the phone is
still plugged in, so we can compare a USB session against a network one."""
import asyncio, sys
from pymobiledevice3.lockdown import create_using_usbmux

UDID = "00008150-001139383A52401C"
DOMAIN = "com.apple.mobile.wireless_lockdown"


async def main():
    print("=== wireless lockdown domain over USB")
    client = await create_using_usbmux(serial=UDID, autopair=False)
    try:
        try:
            vals = await client.get_value(domain=DOMAIN)
            print("  domain values:", vals)
        except Exception as e:
            print("  domain read failed:", type(e).__name__, e)
        try:
            all_vals = await client.get_value()
            interesting = {k: v for k, v in all_vals.items()
                           if any(s in k.lower() for s in ("wifi", "wireless", "rp", "remotepairing"))}
            print("  keys mentioning wifi/wireless/rp:", interesting)
        except Exception as e:
            print("  full read failed:", type(e).__name__, e)
    finally:
        await client.close()

    print("\n=== lockdownd over TCP")
    from pymobiledevice3.lockdown import create_using_tcp
    for label, host in (("lan", "192.168.4.22"), ("tailscale", "100.65.154.94")):
        for port in (62078,):
            try:
                c = await asyncio.wait_for(create_using_tcp(host, identifier=UDID, autopair=False), timeout=15)
                vals = await c.get_value()
                print(f"  {label}:{port} OK — ProductVersion={vals.get('ProductVersion')} "
                      f"EnableWifiConnections={vals.get('EnableWifiConnections')}")
                await c.close()
            except Exception as e:
                print(f"  {label}:{port} failed: {type(e).__name__}: {e}")


asyncio.run(main())
