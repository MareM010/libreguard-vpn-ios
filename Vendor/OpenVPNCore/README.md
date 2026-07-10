# OpenVPNCore Vendor Drop

Place the licensed OpenVPN engine here:

```text
Vendor/OpenVPNCore/OpenVPNCore.xcframework
```

The framework must expose a Swift module named `OpenVPNCore` and support iOS
device builds for use from the `OpenVPNPacketTunnel` app extension.

Release builds of `OpenVPNPacketTunnel` intentionally fail when this module is
not importable. Debug builds keep the unavailable runtime so unit tests and
non-device development can still run without a licensed vendor artifact.

After adding the XCFramework, bind its concrete client/session API inside
`SharedVPN/OpenVPNCoreRuntime.swift`.
