#!/usr/bin/env python3
"""Bundle source licenses and package acknowledgements for offline access."""
import argparse
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkouts", type=Path, required=True)
    args = parser.parse_args()
    destination = ROOT / "libreguard-vpn-ios" / "Legal"
    destination.mkdir(exist_ok=True)
    for source, name in [("LICENSE", "LICENSE"), ("LICENSE-APP-STORE.md", "APP_STORE_PERMISSION"),
                         ("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES"), ("Vendor/OpenSSL/LICENSE.txt", "OpenSSL-LICENSE")]:
        shutil.copyfile(ROOT / source, destination / f"{name}.txt")
    for package, name in [("AppAuth-iOS", "AppAuth"), ("swift-asn1", "swift-asn1"),
                          ("swift-certificates", "swift-certificates"), ("swift-crypto", "swift-crypto"), ("swift-log", "swift-log")]:
        root = args.checkouts / package
        files = [root / file for file in ["LICENSE", "LICENSE.txt", "NOTICE", "NOTICE.txt"] if (root / file).is_file()]
        if package == "swift-crypto":
            files += [file for file in [root / "Sources/CCryptoBoringSSL/LICENSE", root / "Sources/CCryptoBoringSSL/NOTICE"] if file.is_file()]
        if not files:
            raise SystemExit(f"Missing license for {package}; refusing incomplete acknowledgements")
        (destination / f"{name}-LICENSE.txt").write_text("\n\n".join(file.read_text() for file in files))
    tunnel_license = (ROOT / "Vendor/TunnelKit/LICENSE").read_text()
    permission = (ROOT / "Vendor/TunnelKit/README.md").read_text().split("### Part II", 1)[1].split("### Contributing", 1)[0]
    (destination / "TunnelKit-LICENSE.txt").write_text(tunnel_license + "\n\nAdditional App Store permission:\n" + permission)
    if not (destination / "MPL-2.0.txt").is_file():
        raise SystemExit("MPL-2.0.txt must be present in Legal before a release build")


if __name__ == "__main__":
    main()
