"""Fail closed when a development artifact does not authorize this Mac."""
import plistlib
import subprocess
import sys

hardware = plistlib.loads(subprocess.check_output(
    ["system_profiler", "SPHardwareDataType", "-xml"]))[0]["_items"][0]
udid = hardware.get("provisioning_UDID")
if not udid:
    raise SystemExit("Cannot determine this Mac's provisioning UDID")
for path in sys.argv[1:]:
    profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", path]))
    if not profile.get("ProvisionsAllDevices") and udid not in profile.get("ProvisionedDevices", []):
        raise SystemExit(f"FAIL: {path}: profile does not authorize this Mac")
    print(f"PASS: {profile['Name']} ({profile['UUID']}) authorizes this Mac")
