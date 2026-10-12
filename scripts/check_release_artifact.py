#!/usr/bin/env python3
"""Check a built .app or .xcarchive for the client release invariants."""
import argparse
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    app = args.artifact
    if app.suffix == ".xcarchive":
        apps = list((app / "Products/Applications").glob("*.app"))
        if len(apps) != 1:
            raise SystemExit("Expected one app in archive")
        app = apps[0]
    info = plistlib.loads((app / "Info.plist").read_bytes())
    versions = (info["CFBundleShortVersionString"], info["CFBundleVersion"])
    bundles = [app, *sorted((app / "PlugIns").glob("*.appex"))]
    if len(bundles) != 3:
        raise SystemExit("Expected app, packet tunnel and widget")
    for bundle in bundles:
        data = plistlib.loads((bundle / "Info.plist").read_bytes())
        if (data["CFBundleShortVersionString"], data["CFBundleVersion"]) != versions:
            raise SystemExit(f"Version mismatch: {bundle.name}")
        manifest = plistlib.loads((bundle / "PrivacyInfo.xcprivacy").read_bytes())
        if manifest.get("NSPrivacyTracking") is not False:
            raise SystemExit(f"Unexpected tracking declaration: {bundle.name}")
        categories = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons'] for item in manifest['NSPrivacyAccessedAPITypes']}
        if 'NSPrivacyAccessedAPICategoryUserDefaults' not in categories:
            raise SystemExit(f"Missing defaults reasons: {bundle.name}")
        executable = bundle / data["CFBundleExecutable"]
        imports = subprocess.check_output(["nm", "-u", str(executable)], text=True)
        if "_SecTask" in imports:
            raise SystemExit(f"Private SecTask API in {bundle.name}")
        if any(symbol in imports for symbol in ["_stat\n", "_fstat\n", "_lstat\n"]):
            if "C617.1" not in categories.get("NSPrivacyAccessedAPICategoryFileTimestamp", []):
                raise SystemExit(f"Missing container-file timestamp reason: {bundle.name}")
        if bundle.name == "OpenVPNPacketTunnel.appex":
            binary = executable.read_bytes()
            if b"OpenSSL 3.5.9" not in binary or b"OpenSSL 3.0.2" in binary:
                raise SystemExit("Wrong OpenSSL runtime version")
            if b"Tunnel connectivity probe (" in binary or b"TunnelKit diagnostic log storage is empty" in binary:
                raise SystemExit("Debug diagnostic code retained in Release")
        if list(bundle.rglob("openssl.framework")):
            raise SystemExit("Static OpenSSL framework must not be embedded")
    names = ['LICENSE', 'APP_STORE_PERMISSION', 'THIRD_PARTY_NOTICES', 'TunnelKit-LICENSE', 'OpenSSL-LICENSE', 'AppAuth-LICENSE', 'swift-asn1-LICENSE', 'swift-certificates-LICENSE', 'swift-crypto-LICENSE', 'swift-log-LICENSE', 'MPL-2.0']
    for name in names:
        files = list(app.rglob(name + '.txt'))
        if len(files) != 1 or not files[0].stat().st_size:
            raise SystemExit(f"Missing or ambiguous offline license: {name}")
    print("Passed: three manifests, versions, required reasons, offline licenses, no SecTask imports, OpenSSL 3.5.9, static linkage and Release diagnostics.")
    print("Signed provisioning, App Store privacy report and device/service validation remain separate release gates.")


if __name__ == '__main__':
    main()
