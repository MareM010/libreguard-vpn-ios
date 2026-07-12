# Vendored Source Provenance

This directory is a source snapshot of
<https://github.com/pia-foss/mobile-ios-openvpn> at commit
`f2c8825f61a57ba664971e72c37efd92ebc366c9` (2026-06-05).

LibreGuard changes the `ios-openssl` dependency URL in `Package.swift` and
`Package.resolved` from GitHub SSH to HTTPS, and pins `swift-log` exactly to
the upstream resolved version (`1.8.0`) instead of allowing an unbounded
minor update. Update this file whenever the vendored snapshot changes.
