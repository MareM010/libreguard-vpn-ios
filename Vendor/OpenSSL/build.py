#!/usr/bin/env python3
"""Build pinned OpenSSL source into static Apple archives; no signing keys needed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = "3.5.9"
SHA256 = "603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"
URL = f"https://github.com/openssl/openssl/releases/download/openssl-{VERSION}/openssl-{VERSION}.tar.gz"
ROOT = Path(__file__).resolve().parent


def run(args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def sdk_path(sdk):
    return subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=min(os.cpu_count() or 2, 8))
    parser.add_argument("--work-dir", type=Path)
    args = parser.parse_args()
    work = args.work_dir or Path(tempfile.mkdtemp(prefix="libreguard-openssl-"))
    work.mkdir(parents=True, exist_ok=True)
    archive = work / f"openssl-{VERSION}.tar.gz"
    if not archive.exists():
        print(f"Downloading OpenSSL {VERSION}", flush=True)
        with urllib.request.urlopen(URL, timeout=120) as response, archive.open("wb") as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit("OpenSSL source checksum mismatch; refusing to build")
    source = work / f"openssl-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as package:
            # Support macOS's bundled Python, including versions before 3.12.
            for member in package.getmembers():
                destination = (work / member.name).resolve()
                if not str(destination).startswith(str(work.resolve()) + os.sep):
                    raise SystemExit("Unsafe path in OpenSSL source archive")
                if not (member.isfile() or member.isdir()):
                    raise SystemExit("Unexpected link or special file in OpenSSL source archive")
            package.extractall(work)

    slices = [
        ("iphoneos", "arm64", "ios64-xcrun", "arm64-apple-ios15.0"),
        ("iphonesimulator", "arm64", "iossimulator-xcrun", "arm64-apple-ios15.0-simulator"),
        ("iphonesimulator", "x86_64", "iossimulator-xcrun", "x86_64-apple-ios15.0-simulator"),
        ("macosx", "arm64", "darwin64-arm64-cc", "arm64-apple-macos10.15"),
        ("macosx", "x86_64", "darwin64-x86_64-cc", "x86_64-apple-macos10.15"),
    ]
    built = {}
    for sdk, arch, config, triple in slices:
        build = work / f"{sdk}-{arch}"
        install = build / "install"
        library = build / "libopenssl.a"
        build.mkdir(exist_ok=True)
        env = dict(os.environ)
        env["CC"] = subprocess.check_output(["xcrun", "--sdk", sdk, "--find", "clang"], text=True).strip()
        env["CFLAGS"] = f"-target {triple} -isysroot {sdk_path(sdk)} -fPIC"
        env["LDFLAGS"] = env["CFLAGS"]
        print(f"Building {sdk} {arch}", flush=True)
        if not library.exists():
            run(["perl", str(source / "Configure"), config, "no-shared", "no-tests", "no-module", "no-apps", "no-docs", f"--prefix={install}"], cwd=build, env=env)
            run(["make", f"-j{max(args.jobs, 1)}", "build_libs"], cwd=build, env=env)
            run(["make", "install_dev"], cwd=build, env=env)
            run(["xcrun", "libtool", "-static", "-o", str(library), str(build / "libssl.a"), str(build / "libcrypto.a")])
        built[(sdk, arch)] = (library, install)

    # Use archive slices rather than static .framework wrappers: Xcode may
    # otherwise copy a static framework into an app's Frameworks directory.
    libraries = []
    for sdk, architectures in [("iphoneos", ["arm64"]), ("iphonesimulator", ["arm64", "x86_64"]), ("macosx", ["arm64", "x86_64"])]:
        slice_dir = work / f"{sdk}-library"
        slice_dir.mkdir(parents=True, exist_ok=True)
        library = slice_dir / "libopenssl.a"
        run(["xcrun", "lipo", "-create", *[str(built[(sdk, arch)][0]) for arch in architectures], "-output", str(library)])
        headers = slice_dir / "Headers"
        if headers.exists():
            shutil.rmtree(headers)
        shutil.copytree(built[(sdk, architectures[0])][1] / "include", headers)
        (headers / "module.modulemap").write_text('module openssl [system] {\n  umbrella "openssl"\n  export *\n  module * { export * }\n}\n')
        libraries.append((library, headers))

    pending = work / "openssl.xcframework"
    if pending.exists():
        shutil.rmtree(pending)
    run(["xcodebuild", "-create-xcframework", *sum((["-library", str(library), "-headers", str(headers)] for library, headers in libraries), []), "-output", str(pending)])
    destination = ROOT / "openssl.xcframework"
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(pending, destination)
    shutil.copyfile(source / "LICENSE.txt", ROOT / "LICENSE.txt")
    (ROOT / "build-provenance.json").write_text(json.dumps({"version": VERSION, "sourceURL": URL, "sourceSHA256": SHA256, "linkage": "static", "packaging": "xcframework-static-archives", "configureOptions": ["no-shared", "no-tests", "no-module", "no-apps", "no-docs"], "minimumiOS": "15.0", "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines(), "slices": [f"{sdk}-{arch}" for sdk, arch, _, _ in slices]}, indent=2) + "\n")
    print(f"Built OpenSSL {VERSION}: {destination}", flush=True)


if __name__ == "__main__":
    main()
