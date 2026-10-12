# Third-Party Notices

LibreGuard source is distributed under the GNU General Public License version 3,
with the additional App Store executable distribution permission in
`LICENSE-APP-STORE.md`. TunnelKit retains its own additional permission.
App Store executables use MPL 2.0 under those permissions; corresponding source
and all third-party notices remain available. The
complete corresponding source is available at
<https://github.com/MareM010/libreguard-vpn-ios>.

## TunnelKit OpenVPN

- Upstream: <https://github.com/pia-foss/mobile-ios-openvpn>
- Vendored revision: `f2c8825f61a57ba664971e72c37efd92ebc366c9`
- License: GPLv3 with the upstream Apple App Store additional permission
- Local modifications: the `ios-openssl` Swift package URL uses HTTPS instead
  of SSH originally; it now uses the local checksum-pinned OpenSSL package,
  `swift-log` is pinned to `1.8.0`, a Keychain configuration-resolution hook
  and SDK privacy manifests are added, and fixture-key logging is removed
  from two encryption tests.

The upstream demo and OpenVPN test suite contain sample client-key fixtures for
the standalone demo apps and parser/decryption tests. They are not included in
the LibreGuard app or tunnel-extension targets and must not be used as real VPN
credentials.

The separately licensed `TunnelKitLZO` product is not linked into LibreGuard.
The complete upstream license and notices remain in `Vendor/TunnelKit`.

## Resolved Swift packages

The app's exact package versions and revisions are pinned in
`libreguard-vpn-ios.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
TunnelKit's package pins are in `Vendor/TunnelKit/Package.resolved`.

| Package | Version and resolved revision | License | Upstream |
| --- | --- | --- | --- |
| AppAuth for iOS | 3.0.0 — `a972daac82d449d58ab119e91c68153e29ddac33` | Apache License 2.0 | <https://github.com/openid/AppAuth-iOS> |
| OpenSSL library | 3.5.9 — source SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a` | Apache License 2.0 | <https://github.com/openssl/openssl/releases/tag/openssl-3.5.9> |
| swift-asn1 | 1.7.1 — `a9a5efd40eaf558a2bcd48d64b1d1646be686008` | Apache License 2.0 | <https://github.com/apple/swift-asn1> |
| swift-certificates | 1.19.4 — `449dbbecd0f31e82b510ada227ca152caa8b5e98` | Apache License 2.0 | <https://github.com/apple/swift-certificates> |
| swift-crypto | 4.5.1 — `47d3869a7291f085c1fb9fb1e6d3b97a793f45c6` | Apache License 2.0 | <https://github.com/apple/swift-crypto> |
| swift-log | 1.8.0 — `bc386b95f2a16ccd0150a8235e7c69eab2b866ca` | Apache License 2.0 | <https://github.com/apple/swift-log> |

OpenSSL is built using `Vendor/OpenSSL/build.py`; its source checksum, build
recipe, and provenance are included in the source distribution. Generated
frameworks are statically linked and are not embedded as dynamic frameworks.
The LibreGuard wrapper and build tooling follow this repository's GPLv3 license
and applicable additional permission, separately from OpenSSL's Apache license.

The lockfiles above remain the source of truth for remote package versions. These
packages are resolved separately from this repository; their upstream source
distributions contain the corresponding license and notice files, including
attributions for derived code or test data.

## Google sign-in button

- Official asset: <https://developers.google.com/static/identity/gsi/web/images/standard-button-white.png>
- Guidelines: <https://developers.google.com/identity/branding-guidelines>
- Unmodified pre-approved light button, used with its original aspect ratio.
  Google brand use remains subject to those guidelines.
