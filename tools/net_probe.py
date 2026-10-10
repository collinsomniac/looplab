"""Prove a network (Tailscale) path to the phone's device services.

Step 1: lockdownd over TCP using the existing USB pair record.
Step 2: if that works, ask for a tunnel and list services.
"""
import asyncio, sys, traceback
from pymobiledevice3.lockdown import create_using_tcp

HOST = sys.argv[1] if len(sys.argv) > 1 else "100.65.154.94"
UDID = sys.argv[2] if len(sys.argv) > 2 else "00008150-001139383A52401C"


async def main():
    print(f"connecting to lockdownd at {HOST}:62078 ...")
    try:
        client = await create_using_tcp(HOST, identifier=UDID, autopair=False)
    except Exception as e:
        print("FAILED:", type(e).__name__, e)
        traceback.print_exc()
        return
    print("connected:", type(client).__name__)
    try:
        values = await client.get_value()
        keep = ["ProductVersion", "ProductType", "DeviceName", "UniqueDeviceID", "DeveloperModeStatus",
                "EnableWifiConnections", "WirelessBuddyID", "TotalDiskCapacity"]
        for k in keep:
            if k in values:
                print(f"  {k} = {values[k]}")
    except Exception as e:
        print("get_value failed:", type(e).__name__, e)
    try:
        info = await client.get_developer_mode_status()
        print("  developer mode:", info)
    except Exception as e:
        print("  developer mode query:", type(e).__name__, e)
    await client.close()


asyncio.run(main())
