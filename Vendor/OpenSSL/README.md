# LibreGuard OpenSSL

This local Swift package replaces the historical `pia-foss/ios-openssl` binary
(OpenSSL 3.0.2) with OpenSSL **3.5.9 LTS**. It retains the `openssl-apple`
product, `openssl` module, and `<openssl/...>` headers used by TunnelKit.

Before resolving packages on a clean checkout:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 Vendor/OpenSSL/build.py
```

The script downloads the official release archive and verifies the pinned
SHA-256 before extraction. It builds static device arm64, simulator arm64 and
x86_64, and macOS arm64 and x86_64 slices. No signing keys, remote binary
artifacts, dynamic modules, applications, or private crypto APIs are used.
Build arguments, architectures, and the source checksum are recorded in
`build-provenance.json`. Temporary work is retained for inspection; use
`--work-dir` to select its location. Generated XCFrameworks are ignored by Git.

The XCFramework contains static archive slices, not embedded framework bundles.
It must not be copied into an app's Frameworks folder as an embedded dynamic
framework. Mac Catalyst is not built;
the LibreGuard iOS project does not enable Mac Catalyst.

To update the library, update `VERSION`, the official source checksum, notices,
and provenance, build in a fresh work directory, and run app and TunnelKit
tests. Never reuse a work directory for a changed version or build recipe.

OpenSSL is licensed under Apache 2.0; see `LICENSE.txt`. LibreGuard's package
wrapper and build tooling follow the repository's GPLv3 license and applicable
App Store additional permission. Corresponding sources and build instructions
are linked from the app's bundled acknowledgements.
