# First-connection startup recovery

This note records the startup stall observed with a newly created VPN profile and the recovery added to the connection coordinator. Device identifiers, attempt IDs, account state, and local log paths are intentionally omitted.

## Observed behavior

On a physical iOS device, the first IKEv2 startup remained in Connecting because the native provider's scoped interface was not ready. The provider did not begin DNS resolution or an IKE handshake before the existing startup deadline. A second attempt with the same approved profile connected successfully. The trace did not establish why iOS left the interface unsatisfied.

## Implemented recovery

For a newly created IncludeAllNetworks profile, observe initial native startup for ten seconds. If it is still Connecting, stop that session, wait for a confirmed native stop, reload the already approved profile, and start it once more within the same user request. A completed connection or terminal native startup state does not trigger a restart. A terminal failure after observed native startup reaches the caller immediately. Cancellation and an unconfirmed stop prevent the restart.

The recovery retains certificates, native approval, routing protection, and the attempt UUID. It does not save the profile again, generate another certificate, or extend the coordinator's existing 30-second startup deadline. The internal stop is hidden from normal connection-state notifications, and `recoveringStartup` is recorded in the lifecycle journal. If observation finishes after the native session has connected, the coordinator retains the Connected phase.

IKEv2 always uses IncludeAllNetworks while connecting. OpenVPN uses it when Kill Switch is enabled, so the shared recovery also applies to a newly created OpenVPN profile under that policy. The observed stall was in Apple's IKEv2 provider; an equivalent OpenVPN stall was not reproduced during the recorded device checks.

## Recorded verification

- The unit suite passed 264 tests across 12 suites. Coverage included initial success, a stalled first start, a stale Disconnected snapshot, terminal startup states, completion or failure at the recovery checkpoint, cancellation during observation and stopping, an unconfirmed stop, and restart errors.
- A signed app and extension build succeeded. The installed build restored an existing session successfully.
- A fresh-account/new-profile first start has not been repeated on physical hardware with the recovery enabled. OpenVPN device validation also remains outstanding where an account with OpenVPN access is available.

These results are historical validation evidence; repeat the relevant checks against the release build before distribution.
