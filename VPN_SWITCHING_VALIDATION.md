# VPN switching and permission recovery validation

Date: 6 October 2026. This change has no backend API or data migration.

## Implemented behavior

- The coordinator serializes connection transactions, cancels superseded preparation, drains pending native starts, and accepts only the latest request. Both protocols share a preference-operation gate, including foreground refreshes.
- With Kill Switch off, a stopped IKEv2 profile must release routing and on-demand rules before OpenVPN can start. Missing profiles need no cleanup. A stopped identity-invalid LibreGuard profile can be removed and recreated through normal setup; valid certificate identity is preserved in memory across preference reloads.
- A protocol switch that would release Kill Switch protection is rejected before stopping the existing connection. The existing explicit disable confirmation remains in place.
- Startup is bounded to 30 seconds after approval, stopping to 10 seconds, and provider replies to 2 seconds. Permission waiting does not consume the startup deadline. Cleanup that has not been verified blocks another start and offers Retry Cleanup.
- Confirmed permission denial offers Retry VPN Setup and Cancel. Retry is an explicit action scoped to the failed request and account. Configuration and certificate errors remain distinct from permission denial. iOS restrictions include Settings guidance.
- Notification denial shows a nonblocking notice and Open Notification Settings. The decision is retained in Settings and refreshed when returning. Request errors are displayed separately; rapid reconnects do not repeat a decided prompt.
- Diagnostics contain attempt UUID, protocol, phase, failure kind, and error domain/code, without credential or certificate contents. The app-group journal is bounded to 64 KB at `Library/vpn-connection-lifecycle.log`.
- Final traffic collection is bounded and does not wait for a Live Activity update. Existing history, IPv6, and routing regression tests remain in the suite.

## Automated verification

The main scheme runs the existing unit suite plus deterministic recovery tests. Coverage includes replacement during preparation, delayed callbacks, cancellation while approval is outstanding, stop failures and deadlines, startup deadlines, stale errors, unavailable provider replies, absent and identity-invalid profiles, removal verification, explicit permission retry, Kill Switch preflight, notification denial and Settings refresh, and traffic/history regression tests.

Additional review cases cover delayed account-check responses, cleanup retry for a connection restored without a new connect request, and an invalid native startup status cancelling its deadline.

Final results and physical-device results are recorded below after the test runs finish.

## Physical-device procedure

Use the opt-in `VPNProtocolStress` scheme on a signed-in physical iPhone with OpenVPN access. Enable its test-runner environment variable `LIBREGUARD_VPN_STRESS_NETWORK` as `wifi` or `cellular`. Select `VPNProtocolStressTests/testFiftyProtocolSwitches` for the 50-switch pass, or `VPNProtocolStressTests/testRapidCancellationAndReplacement` for three focused cancellation/replacement cycles.

The test verifies the active interface and internet access before switching. It alternates protocols 50 times, verifies Connected and stopped states, includes foreground/background movement, and attempts cancellation/replacement when Connecting is observable. It verifies a tap was delivered before attributing a missed moving control to a VPN failure. It does not reset the account, change network settings, or turn off Kill Switch. An active Kill Switch causes the unsafe switching test to skip.

The test skips on the simulator or without explicit opt-in. Its temporary runner environment is separate from production app settings. A successful UI pass establishes connection-state and switching behavior; it does not constitute packet-level DNS/IPv6 leakage verification or an actual denial/Allow permission exercise.

## Release checks still requiring a device

- A 50-switch cellular pass requires working mobile data. The current iPhone has no working cellular data, as confirmed by the user.
- Exercise first native approval, actual denial, and explicit Retry VPN Setup followed by Allow on a device where approval can be requested. Deterministic tests cover these state transitions, but do not replace native permission validation.
- Check established-tunnel DNS and IPv6 protection with network observations on both interfaces. Existing routing/IPv6 tests and provider safeguards pass, but packet-level device validation is separate.
- Recheck the latest five attempts per protocol after the remaining device checks before release.

## Results

- **219 automated tests passed in 11 suites.** Result bundle: `/private/tmp/libreguard-vpn-fix-tests-reviewed.xcresult`.
- **Signed app and extension build passed.** Build log: `/private/tmp/libreguard-vpn-device-reviewed-build.log`.
- **50 alternating Wi-Fi connections passed on the physical iPhone SE**, including foreground/background movement. Result bundle: `/private/tmp/libreguard-vpn-device-wifi-final.xcresult`. Run: 20:41:41–20:50:58 Europe/Belgrade. The journal contains exactly 50 new attempt IDs, all connected and all stopped, with zero recorded failures and no events after a completed stop for those IDs.
- The 50-switch build includes the connection/profile changes, deadlines, account-check scoping, and notification/VPN recovery UI. The subsequent two error-path refinements (restored-connection cleanup retry and invalid-status deadline cancellation) passed their additional deterministic tests and the signed device build; that reviewed build was installed after the pass and passed the additional focused physical cancellation/replacement test.
- No attempt in this pass remained Connecting indefinitely. The last five attempts per protocol at the end of the 50-switch pass all reached Connected and stopped successfully, each within approximately one second of Preparing. The latest five after the focused cancellation check are shown below; expected cancelled attempts are normal events. Timestamps have one-second resolution.
- Cancellation during Connecting was conditional in the UI test; these cached starts completed too quickly to exercise that branch in this successful pass. The subsequent focused device test passed all three cycles: six attempt IDs, three cancelled before Connected, and three replacements connected. Every attempt stopped successfully, no failure was recorded, and no cancelled ID emitted events after its verified stop. Result bundle: `/private/tmp/libreguard-vpn-device-cancellation.xcresult`.
- Cellular was not run because the user confirmed there is no working mobile data. Actual native denial/Allow recovery and packet-level DNS/IPv6 checks remain pending before release.
- Preliminary UI runs did not complete: the connection control did not accept some taps while its layout moved. After adding tap-delivery verification, the full pass completed. Xcode automatic device-diagnostic collection also failed to locate `devicectl`; direct app-group journal export succeeded and supplied the attempt review.

### Latest five attempts for each protocol

Times below are Europe/Belgrade (UTC+02:00), on 6 October 2026. UUID prefixes identify entries in the full journal.

| Protocol | Attempt | Preparing | Connected | Stopped | Outcome | Failure |
| --- | --- | --- | --- | --- | --- | --- |
| OpenVPN | 3AE4A744 | 20:50:41 | 20:50:42 | 20:50:44 | Connected, then stopped | None |
| OpenVPN | 498A6571 | 20:54:40 | — | 20:54:40 | Cancelled, then stopped | None |
| OpenVPN | 2152C456 | 20:54:42 | 20:54:43 | 20:54:46 | Connected, then stopped | None |
| OpenVPN | C7617A65 | 20:55:07 | — | 20:55:08 | Cancelled, then stopped | None |
| OpenVPN | 204B57E2 | 20:55:09 | 20:55:10 | 20:55:13 | Connected, then stopped | None |
| IKEv2/IPSec | E449AF1E | 20:50:08 | 20:50:09 | 20:50:13 | Connected, then stopped | None |
| IKEv2/IPSec | A0026A0F | 20:50:30 | 20:50:31 | 20:50:34 | Connected, then stopped | None |
| IKEv2/IPSec | 2FB175EE | 20:50:51 | 20:50:52 | 20:50:57 | Connected, then stopped | None |
| IKEv2/IPSec | 7DE6055D | 20:54:53 | — | 20:54:54 | Cancelled, then stopped | None |
| IKEv2/IPSec | 51E71DB8 | 20:54:56 | 20:54:57 | 20:55:01 | Connected, then stopped | None |

Diagnostic snapshots: `/private/tmp/libreguard-device-fix-lifecycle-final.log` (50-switch pass) and `/private/tmp/libreguard-device-cancel-lifecycle.log` (latest five after rapid cancellation). The separate redacted IKEv2 error from the original archive remains unconfirmed; future native failures now retain error domains and codes in the bounded journal.
