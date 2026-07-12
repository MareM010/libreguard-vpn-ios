# OpenVPN Release Checklist

- [ ] Select a full Xcode installation and resolve all packages without SSH credentials.
- [ ] Build and test Debug and Release configurations for the app and packet tunnel.
- [ ] Confirm the app and extension provisioning profiles include Packet Tunnel,
      Keychain Sharing, and `group.net.libreguard.libreguard-vpn-ios`.
- [ ] Publish the exact corresponding source before distributing the binary.
- [ ] Retain the GPLv3 license, TunnelKit App Store additional permission, and
      all third-party notices in the published source.
- [ ] Complete legal review of the intended App Store distribution.
- [ ] On a physical iPhone, validate staging OpenVPN connectivity, DNS and public
      IP, upload/download traffic, sleep/wake, Wi-Fi/cellular transitions,
      reconnect, cancellation, protocol switching, and certificate failures.
- [ ] With kill switch enabled, confirm no IP or DNS leak during connect,
      reconnect, network transitions, or forced server loss.
- [ ] Archive and validate the final signed build before submission.
