# Third-Party Notices

LibreGuard is distributed under the GNU General Public License version 3. The
complete corresponding source is available at
<https://github.com/MareM010/libreguard-vpn-ios>.

## TunnelKit OpenVPN

- Upstream: <https://github.com/pia-foss/mobile-ios-openvpn>
- Vendored revision: `f2c8825f61a57ba664971e72c37efd92ebc366c9`
- License: GPLv3 with the upstream Apple App Store additional permission
- Local modifications: the `ios-openssl` Swift package URL uses HTTPS instead
  of SSH, and `swift-log` is pinned to the upstream resolved `1.8.0` version.

The separately licensed `TunnelKitLZO` product is not linked into LibreGuard.
The complete upstream license and notices remain in `Vendor/TunnelKit`.

## ios-openssl

- Upstream: <https://github.com/pia-foss/ios-openssl>
- Version: `1.0.0`
- License and notices are included by the resolved Swift package.

## swift-log

- Upstream: <https://github.com/apple/swift-log>
- Version: `1.8.0`
- License: Apache License 2.0

See the resolved package metadata in `Vendor/TunnelKit/Package.resolved` for
the exact dependency revisions used by the build.
