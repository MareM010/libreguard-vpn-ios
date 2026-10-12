<div align="center">
  <img src="libreguard-vpn-ios/Assets.xcassets/LibreGuardLogo.imageset/LibreGuard_logo_cropped_V3.png" alt="LibreGuard VPN logo" width="220" />

  <h1>LibreGuard VPN</h1>

  <p>
    <a href="LICENSE">
      <img src="https://img.shields.io/badge/License-GPL%20v3-blue.svg" alt="License: GPL v3" />
    </a>
  </p>

  <p>LibreGuard VPN is an iOS client for the LibreGuard VPN service, with native IKEv2 and OpenVPN support.</p>
</div>

## Repository layout

- `libreguard-vpn-ios/` — iOS app source and assets
- `OpenVPNPacketTunnel/` — OpenVPN Network Extension
- `SharedVPN/` and `SharedStatus/` — code shared with the app extensions
- `VPNStatusWidget/` — connection-status widget
- `libreguard-vpn-iosTests/` and `libreguard-vpn-iosUITests/` — automated tests
- `Vendor/TunnelKit/` — vendored TunnelKit source, including its separate demo and test fixtures
- `*_VALIDATION.md` and `OPENVPN_RELEASE_CHECKLIST.md` — behavior notes and release checks

## Open-source release notes

- The root `LICENSE` contains the GNU GPL version 3 text.
- `THIRD_PARTY_NOTICES.md` identifies vendored code and the exact versions of the resolved Swift packages.
- `.gitignore` includes rules for local Xcode state, build output, diagnostics, credentials, and common signing artifacts.
- TunnelKit's sample key and certificate material belongs to its demo and test fixtures. Those files are not included in the LibreGuard app or tunnel-extension targets; do not use the sample credentials for a real VPN service.
- The app connects to LibreGuard's separately operated management service and VPN infrastructure. This repository does not contain that backend.

## Building locally

### Prerequisites

- macOS with Xcode and an iOS SDK that supports the project's iOS 26.5 deployment target
- A simulator runtime or a registered iOS device
- An Apple Developer team and the required App Groups, Keychain Sharing, and Network Extension capabilities for signed device builds

### Open and build

1. Clone this repository.
2. Build the pinned crypto dependency with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 Vendor/OpenSSL/build.py`.
3. Open `libreguard-vpn-ios.xcodeproj` in Xcode and let the Swift packages resolve. Select the shared `libreguard-vpn-ios` scheme and an iOS simulator, then build or run.
4. For a signed device build, create an ignored `Signing.local.xcconfig` containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. All targets inherit it. Configure app identifiers and capabilities for your Apple account.

Set release version and build numbers once in `AppVersion.xcconfig`; the app,
packet tunnel and widget inherit the same values in both build configurations.

Google sign-in builds also need an iOS OAuth client ID and its exact reversed callback scheme in the Debug and Release build settings. See [Google sign-in setup](GOOGLE_SIGN_IN_SETUP.md). The OAuth client ID is public app configuration; do not add a Google client secret to the app.

The opt-in `VPNProtocolStress` scheme is for physical-device validation and requires explicit network selection as described in [VPN switching validation](VPN_SWITCHING_VALIDATION.md).

## Source code and compliance

- Source repository: <https://github.com/MareM010/libreguard-vpn-ios>
- License and third-party acknowledgements: [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- Google sign-in configuration: [GOOGLE_SIGN_IN_SETUP.md](GOOGLE_SIGN_IN_SETUP.md)
- OpenVPN release checks: [OPENVPN_RELEASE_CHECKLIST.md](OPENVPN_RELEASE_CHECKLIST.md)
- Never commit production credentials, account tokens, signing private keys or profiles, or real user VPN profiles. TunnelKit's documented demo/test fixtures are not production credentials; public OAuth client identifiers are configuration values.

## License

This project is distributed under the GNU General Public License version 3. See [LICENSE](LICENSE) and the additional App Store distribution permission in [LICENSE-APP-STORE.md](LICENSE-APP-STORE.md). TunnelKit retains its own App Store permission; see its license and the dependency notices in `Vendor/TunnelKit` and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
