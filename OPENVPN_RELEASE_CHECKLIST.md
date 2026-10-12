# OpenVPN Release Checklist

- [ ] Select a full Xcode installation and resolve all packages without SSH credentials.
- [ ] Build and test Debug and Release configurations for the app and packet tunnel.
- [ ] Confirm the app and extension provisioning profiles include the required
      Network Extension, Keychain Sharing, and App Group capabilities.
- [ ] Publish the exact corresponding source before distributing the binary.
- [ ] Retain the GPLv3 license, TunnelKit App Store additional permission, and
      all third-party notices in the published source.
- [ ] Complete legal review of the intended App Store distribution.
- [ ] On a physical iPhone, validate staging OpenVPN connectivity, DNS and public
      IP, upload/download traffic, sleep/wake, Wi-Fi/cellular transitions,
      reconnect, cancellation, protocol switching, and certificate failures.
- [ ] Confirm DNS handling and filtering meet the documented product behavior
      across supported VPN protocols and subscription states.
- [ ] During staged validation, check DNS and traffic protections while connecting,
      reconnecting, switching networks, and recovering from connection failures.
- [ ] With kill switch enabled, confirm traffic remains protected during
      connection changes and unexpected server loss.
- [ ] Archive and validate the final signed build before submission.

## Build checks

On a clean checkout, build the pinned OpenSSL archive with
`Vendor/OpenSSL/build.py` before package resolution. Run
`scripts/check_release_artifact.py` against the built Release app or archive
to verify versions, bundled privacy manifests, licenses and crypto packaging.
Physical-device, service and App Store distribution checks remain separate.
