# First-connection startup recovery

Validated on 10 October 2026 against the connected iPhone SE running iOS 26.6.2.

## Device evidence

The app-group journal and the local iPhone unified-log archive identify two consecutive IKEv2 attempts. Times below are Europe/Belgrade (UTC+02:00).

| Attempt | Event | Time |
| --- | --- | --- |
| `9769DA18` | Configuration preparation began | 08:55:12 |
| `9769DA18` | Approved profile started | 08:55:21 |
| `9769DA18` | Native provider skipped startup because its interface was not ready | 08:55:21.380 |
| `9769DA18` | Wi-Fi scoped interface remained unsatisfied | 08:55:21.465 |
| `9769DA18` | Existing 30-second startup deadline expired | 08:55:51 |
| `1F899756` | Second attempt started | 08:55:57 |
| `1F899756` | Wi-Fi scoped interface became satisfied | 08:55:57.111 |
| `1F899756` | IKE handshake began | 08:55:57.269 |
| `1F899756` | IKE and child security associations connected | 08:55:57.665 |
| `1F899756` | App reported connected | 08:55:58 |

The first native provider never began DNS resolution or an IKE handshake. Its failure was a native interface-readiness stall after installing the IncludeAllNetworks profile. The trace does not establish why iOS left that interface unsatisfied. It contains no certificate-authentication rejection for that attempt, and the approved configuration worked on the second attempt.

Evidence stays local:

- `/private/tmp/libreguard-first-connect-native.logarchive`
- `/private/tmp/libreguard-first-connect-native-vpn.log`
- `/private/tmp/libreguard-first-connect-provider.log`
- `/private/tmp/libreguard-first-connect-device-lifecycle.log`

## Implemented recovery

For a newly created IncludeAllNetworks profile, observe initial native startup for ten seconds. If it is still Connecting, stop that session, wait for a confirmed native stop, reload the already approved profile, and start it once more within the same user request. A completed connection or terminal native startup state does not trigger a restart. A terminal failure after observed native startup reaches the caller immediately. Cancellation and an unconfirmed stop prevent the restart.

The recovery retains certificates, native approval, routing protection, and the attempt UUID. It does not save the profile again, generate another certificate, or extend the coordinator's existing 30-second startup deadline. The internal stop is hidden from normal connection-state notifications, and `recoveringStartup` is recorded in the lifecycle journal. If observation finishes after the native session has connected, the coordinator retains the Connected phase.

IKEv2 always uses IncludeAllNetworks while connecting. OpenVPN uses it when Kill Switch is enabled, so the shared recovery is also applied to a newly created OpenVPN profile under that policy. The observed stall was in Apple's IKEv2 provider; an equivalent OpenVPN stall was not reproduced on this device.

## Verification

- All **264 unit tests in 12 suites passed**, including initial success, a stalled first start, an initially stale Disconnected snapshot, terminal startup states, completion or failure at the recovery checkpoint, cancellation during observation and stopping, an unconfirmed stop, and a restart error. Coordinator tests confirm the completed phase is retained and recovery schedules no additional startup deadline. Result: `/private/tmp/libreguard-first-connect-verified.xcresult`.
- The signed physical-device app and extensions built successfully. Log: `/private/tmp/libreguard-first-connect-device-reviewed-build.log`.
- The fixed build was installed and launched on the connected iPhone. At 09:38:15–09:38:16, the app logged `Launch VPN status=connected` and `Session restore succeeded; vpnStatus=connected`. The signed-in account and existing connection were retained. Log: `/private/tmp/libreguard-first-connect-final-device-app.log`.
- A fresh-account/new-profile first start has not yet been repeated with the fixed build on physical hardware. The current account already has its working certificate/profile. It is Free and has no OpenVPN access, so an OpenVPN device pass also remains unverified.

No backend API or data migration is required.
