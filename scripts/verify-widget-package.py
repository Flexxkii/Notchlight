#!/usr/bin/env python3
"""Reject signed packages that cannot share Notchlight widget snapshots."""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys


class PackageError(Exception):
    pass


def codesign(*arguments):
    result = subprocess.run(
        ["/usr/bin/codesign", *map(str, arguments)], capture_output=True, check=False
    )
    if result.returncode:
        raise PackageError(result.stderr.decode(errors="replace").strip())
    return result


def inspect_bundle(bundle):
    codesign("--verify", "--deep", "--strict", bundle)
    signature = codesign("-d", "--verbose=4", bundle).stderr.decode()
    team = next((line.removeprefix("TeamIdentifier=") for line in signature.splitlines()
                 if line.startswith("TeamIdentifier=")), "")
    if not team or team == "not set" or "Signature=adhoc" in signature:
        raise PackageError(f"{bundle.name}: a team-backed signing identity is required")
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    entitlements = plistlib.loads(codesign("-d", "--entitlements", "-", "--xml", bundle).stdout)
    return info, entitlements, team


def validate_configuration(host, extension):
    host_info, host_entitlements, host_team = host
    extension_info, extension_entitlements, extension_team = extension
    if host_team != extension_team:
        raise PackageError("Host and widget extension must be signed by the same team")
    group = f"{host_team}.com.teodor.Notchlight.shared"
    for label, info, entitlements, identifier in [
        ("Host", host_info, host_entitlements, "com.teodor.Notchlight"),
        ("Widget", extension_info, extension_entitlements, "com.teodor.Notchlight.Widgets"),
    ]:
        if info.get("CFBundleIdentifier") != identifier:
            raise PackageError(f"{label}: unexpected bundle identifier")
        if info.get("NotchlightAppGroup") != group:
            raise PackageError(f"{label}: missing or incorrect NotchlightAppGroup")
        if entitlements.get("com.apple.security.application-groups") != [group]:
            raise PackageError(f"{label}: missing or incorrect signed app-group entitlement")
    if extension_entitlements.get("com.apple.security.app-sandbox") is not True:
        raise PackageError("Widget extension must have its sandbox entitlement")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if not host_info.get(key) or host_info[key] != extension_info.get(key):
            raise PackageError(f"Host and widget extension must have matching {key}")


def verify(app):
    extension = app / "Contents/PlugIns/NotchlightWidgets.appex"
    validate_configuration(inspect_bundle(app), inspect_bundle(extension))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        verify(args.app)
    except (PackageError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"Widget packaging check failed: {error}", file=sys.stderr)
        return 1
    print("Widget packaging check passed: valid signatures, matching team/app group, sandbox, and versions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
