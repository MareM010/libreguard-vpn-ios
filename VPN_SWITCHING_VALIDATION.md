# VPN switching and permission recovery validation

This note summarizes coordinator behavior, recorded validation, and remaining physical-device checks. The original device-specific timestamps, attempt IDs, account details, and local result paths have been removed.

## Implemented behavior

- The coordinator serializes connection transactions, cancels superseded preparation, drains pending native starts, and accepts only the latest request. Both protocols share a preference-operation gate, including foreground refreshes.
- With Kill Switch off, a stopped IKEv2 profile must release routing and on-demand rules before OpenVPN can start. Missing profiles need no cleanup. A stopped identity-invalid LibreGuard profile can be removed and recreated through normal setup; valid certificate identity is preserved in memory across preference reloads.
- A protocol switch that would release Kill Switch protection is rejected before stopping the existing connection. The existing explicit disable confirmation remains in place.
- Startup is bounded to 30 seconds after approval, stopping to 10 seconds, and provider replies to 2 seconds. Permission waiting does not consume the startup deadline. Cleanup that has not been verified blocks another start and offers Retry Cleanup.
- Confirmed permission denial offers Retry VPN Setup and Cancel. Retry is an explicit action scoped to the failed request and account. Configuration and certificate errors remain distinct from permission denial. iOS restrictions include Settings guidance.
- Notification denial shows a nonblocking notice and Open Notification Settings. The decision is retained in Settings and refreshed when returning. Request errors are displayed separately; rapid reconnects do not repeat a decided prompt.
- Diagnostics contain an attempt UUID, protocol, phase, failure kind, and error domain/code, without credential or certificate contents. The app-group journal is bounded to 64 KB at `Library/vpn-connection-lifecycle.log`.
- Final traffic collection is bounded and does not wait for a Live Activity update. Existing history, IPv6, and routing regression checks remain in the suite.

## Automated and device validation

- An earlier recorded switching run passed 219 tests across 11 suites. Later deterministic checks covered restored-connection cleanup retry and invalid startup-status deadline cancellation.
- A signed app and extension build succeeded.
- A physical-device Wi-Fi pass completed 50 alternating protocol connections, including foreground/background movement. Three focused cancellation/replacement cycles also passed; cancelled attempts stopped cleanly and replacement attempts connected.
- Cellular switching was not run. Native permission denial followed by Allow, and packet-level DNS/IPv6 checks, still require physical-device validation.

The results above are historical evidence, not a substitute for repeating checks against the release build. Device type, exact run times, attempt identifiers, and local diagnostic paths are omitted from this public record.

## Physical-device procedure

Use the opt-in `VPNProtocolStress` scheme on a signed-in physical iPhone with OpenVPN access. Set the test-runner environment variable `LIBREGUARD_VPN_STRESS_NETWORK` to `wifi` or `cellular`. Select `VPNProtocolStressTests/testFiftyProtocolSwitches` for the 50-switch pass, or `VPNProtocolStressTests/testRapidCancellationAndReplacement` for focused cancellation/replacement cycles.

The test verifies the active interface and internet access before switching. It alternates protocols, verifies Connected and stopped states, includes foreground/background movement, and attempts cancellation/replacement when Connecting is observable. It verifies a tap was delivered before attributing a missed moving control to a VPN failure. It does not reset the account, change network settings, or turn off Kill Switch. An active Kill Switch causes the unsafe switching test to skip.

The test skips on the simulator or without explicit opt-in. Its temporary runner environment is separate from production app settings. A successful UI pass establishes connection-state and switching behavior; it does not establish packet-level DNS/IPv6 protection or actual native permission denial/recovery.

## Release checks that still require a device

- Run the switching pass on Wi-Fi and cellular.
- Exercise first native approval, actual denial, and explicit Retry VPN Setup followed by Allow.
- Check established-tunnel DNS and IPv6 protection with network observations on both interfaces.
- Review recent attempts per protocol after the device checks and confirm no unexpected events continue after a completed stop.
