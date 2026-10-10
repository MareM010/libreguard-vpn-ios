import Foundation
import NetworkExtension
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct IKEv2FirstConnectionTests {
    @Test func stalledInitialStartupStopsBeforeRestartingTheApprovedProfileOnce() async throws {
        var native: NEVPNStatus = .connecting
        var elapsed: Duration = .zero
        var events: [String] = []
        try await VPNInitialStartupRecovery.recoverIfStalled(
            status: { native },
            stopTunnel: { events.append("stop"); native = .disconnecting },
            restartTunnel: {
                #expect(native == .disconnected)
                events.append("restart approved profile")
                // A second stall must remain subject to the existing deadline.
                native = .connecting
            },
            onRecoveryStateChange: { events.append($0 ? "recovering" : "finished recovery") },
            sleep: { duration in
                elapsed += duration
                if native == .disconnecting { native = .disconnected }
            }
        )
        #expect(elapsed >= .seconds(10))
        #expect(events == ["recovering", "stop", "restart approved profile", "finished recovery"])
    }

    @Test func successfulFirstConnectionDoesNotStopOrRestart() async throws {
        var native: NEVPNStatus = .connecting
        try await VPNInitialStartupRecovery.recoverIfStalled(
            status: { native },
            stopTunnel: { Issue.record("A successful first connection must not stop") },
            restartTunnel: { Issue.record("A successful first connection must not restart") },
            onRecoveryStateChange: { _ in Issue.record("Recovery must not begin") },
            sleep: { _ in native = .connected }
        )
    }

    @Test func oldDisconnectedSnapshotDoesNotSkipInitialStartupObservation() async throws {
        var native: NEVPNStatus = .disconnected
        var observations = 0
        var restarts = 0
        try await VPNInitialStartupRecovery.recoverIfStalled(
            status: { native },
            stopTunnel: { native = .disconnected },
            restartTunnel: { restarts += 1 },
            onRecoveryStateChange: { _ in },
            sleep: { _ in observations += 1; native = .connecting }
        )
        #expect(observations > 1)
        #expect(restarts == 1)
    }

    @Test(arguments: [NEVPNStatus.disconnected, .invalid, .disconnecting])
    func terminalNativeStartupIsNotRetried(terminal: NEVPNStatus) async throws {
        var native: NEVPNStatus = .connecting
        do {
            try await VPNInitialStartupRecovery.recoverIfStalled(
                status: { native },
                stopTunnel: { Issue.record("An explicit native failure must not be retried") },
                restartTunnel: { Issue.record("An explicit native failure must not be retried") },
                onRecoveryStateChange: { _ in Issue.record("Recovery must not begin") },
                sleep: { _ in native = terminal }
            )
            #expect(terminal == .disconnecting)
        } catch {
            #expect(terminal != .disconnecting)
            #expect((error as? VPNConnectionFailure)?.kind == .connectionFailed)
        }
    }

    @Test func connectionCompletingAtRecoveryCheckpointIsNotStopped() async throws {
        var native: NEVPNStatus = .connecting
        var elapsed: Duration = .zero
        try await VPNInitialStartupRecovery.recoverIfStalled(
            status: { native },
            stopTunnel: { Issue.record("A connected tunnel must not stop") },
            restartTunnel: { Issue.record("A connected tunnel must not restart") },
            onRecoveryStateChange: { _ in Issue.record("Recovery must not begin") },
            sleep: { duration in
                elapsed += duration
                if elapsed >= .seconds(10) { native = .connected }
            }
        )
    }

    @Test(arguments: [NEVPNStatus.disconnected, .invalid])
    func nativeFailureAtRecoveryCheckpointIsReportedWithoutRestarting(terminal: NEVPNStatus) async {
        var native: NEVPNStatus = .connecting
        var elapsed: Duration = .zero
        do {
            try await VPNInitialStartupRecovery.recoverIfStalled(
                status: { native },
                stopTunnel: { Issue.record("A failed native start must not restart") },
                restartTunnel: { Issue.record("A failed native start must not restart") },
                onRecoveryStateChange: { _ in Issue.record("Recovery must not begin") },
                sleep: { duration in
                    elapsed += duration
                    if elapsed >= .seconds(10) { native = terminal }
                }
            )
            Issue.record("The native startup failure must reach the caller")
        } catch {
            #expect((error as? VPNConnectionFailure)?.kind == .connectionFailed)
        }
    }

    @Test func unconfirmedStopBlocksInitialStartupRecovery() async {
        var native: NEVPNStatus = .connecting
        var recoveryStates: [Bool] = []
        do {
            try await VPNInitialStartupRecovery.recoverIfStalled(
                status: { native },
                stopTunnel: { native = .disconnecting },
                restartTunnel: { Issue.record("A provider that has not stopped must not restart") },
                onRecoveryStateChange: { recoveryStates.append($0) },
                sleep: { _ in }
            )
            Issue.record("An unconfirmed stop must fail")
        } catch {
            #expect((error as? VPNConnectionFailure)?.kind == .stopFailed)
        }
        #expect(recoveryStates == [true, false])
    }

    @Test(arguments: [false, true])
    func cancellationPreventsInitialStartupRestart(duringStop: Bool) async {
        var native: NEVPNStatus = .connecting
        var recoveryStates: [Bool] = []
        let task = Task {
            try await VPNInitialStartupRecovery.recoverIfStalled(
                status: { native },
                stopTunnel: { native = .disconnecting },
                restartTunnel: { Issue.record("A cancelled first connection must not restart") },
                onRecoveryStateChange: { recoveryStates.append($0) },
                sleep: { _ in
                    if !duringStop || native == .disconnecting {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }
        do {
            try await task.value
            Issue.record("Cancellation must reach the caller")
        } catch { #expect(error is CancellationError) }
        #expect(recoveryStates == (duringStop ? [true, false] : []))
    }

    @Test func failedRestartRestoresStatusObservationAndPropagatesTheError() async {
        var native: NEVPNStatus = .connecting
        var recoveryStates: [Bool] = []
        var restarts = 0
        do {
            try await VPNInitialStartupRecovery.recoverIfStalled(
                status: { native },
                stopTunnel: { native = .disconnected },
                restartTunnel: { restarts += 1; throw vpnError(.configurationDisabled) },
                onRecoveryStateChange: { recoveryStates.append($0) },
                sleep: { _ in }
            )
            Issue.record("A failed restart must reach the caller")
        } catch { #expect((error as NSError).code == NEVPNError.configurationDisabled.rawValue) }
        #expect(restarts == 1)
        #expect(recoveryStates == [true, false])
    }

    @Test func approvedProfileIsReloadedBeforeStarting() async throws {
        var events: [String] = []
        try await IKEv2TunnelStarter.start(
            reload: { events.append("reload") },
            startTunnel: { events.append("start") },
            waitBeforeRetry: { _ in Issue.record("A successful start must not wait") }
        )
        #expect(events == ["reload", "start"])
    }

    @Test(arguments: [NEVPNError.configurationInvalid, .configurationStale])
    func transientFirstStartFailureReloadsAndRetries(code: NEVPNError.Code) async throws {
        var events: [String] = []
        var attempts = 0
        try await IKEv2TunnelStarter.start(
            reload: { events.append("reload") },
            startTunnel: {
                events.append("start")
                attempts += 1
                if attempts == 1 { throw vpnError(code) }
            },
            waitBeforeRetry: { retry in events.append("wait \(retry)") }
        )
        #expect(events == ["reload", "start", "wait 1", "reload", "start"])
    }

    @Test func transientProfileReloadFailureRetriesBeforeStarting() async throws {
        var reloads = 0
        var starts = 0
        try await IKEv2TunnelStarter.start(
            reload: {
                reloads += 1
                if reloads == 1 { throw vpnError(.configurationInvalid) }
            },
            startTunnel: { starts += 1 },
            waitBeforeRetry: { _ in }
        )
        #expect(reloads == 2)
        #expect(starts == 1)
    }

    @Test func persistentInvalidConfigurationStopsAfterThreeAttempts() async {
        var starts = 0
        var retries: [Int] = []
        do {
            try await IKEv2TunnelStarter.start(
                reload: {},
                startTunnel: {
                    starts += 1
                    throw vpnError(.configurationInvalid)
                },
                waitBeforeRetry: { retries.append($0) }
            )
            Issue.record("A persistently invalid profile must fail")
        } catch {
            #expect((error as NSError).domain == NEVPNErrorDomain)
            #expect((error as NSError).code == NEVPNError.configurationInvalid.rawValue)
        }
        #expect(starts == 3)
        #expect(retries == [1, 2])
    }

    @Test(arguments: [
        NEVPNError.configurationDisabled, .connectionFailed,
        .configurationReadWriteFailed, .configurationUnknown
    ])
    func unrelatedStartFailuresAreNotRetried(code: NEVPNError.Code) async {
        var starts = 0
        do {
            try await IKEv2TunnelStarter.start(
                reload: {},
                startTunnel: {
                    starts += 1
                    throw vpnError(code)
                },
                waitBeforeRetry: { _ in Issue.record("This error must not be retried") }
            )
            Issue.record("The start error must reach the caller")
        } catch {
            #expect((error as NSError).code == code.rawValue)
        }
        #expect(starts == 1)
    }

    @Test func matchingErrorCodeFromAnotherDomainIsNotRetried() async {
        do {
            try await IKEv2TunnelStarter.start(
                reload: {},
                startTunnel: { throw NSError(domain: "OtherDomain", code: 1) },
                waitBeforeRetry: { _ in Issue.record("Only NEVPN errors may be retried") }
            )
            Issue.record("The start error must reach the caller")
        } catch {
            #expect((error as NSError).domain == "OtherDomain")
        }
    }

    @Test func cancellationAfterReloadPreventsTunnelStart() async {
        let task = Task {
            try await IKEv2TunnelStarter.start(
                reload: { withUnsafeCurrentTask { $0?.cancel() } },
                startTunnel: { Issue.record("A cancelled request must not start") }
            )
        }
        do {
            try await task.value
            Issue.record("Cancellation must reach the caller")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func cancellationDuringRetryPreventsAnotherStart() async {
        var starts = 0
        let task = Task {
            try await IKEv2TunnelStarter.start(
                reload: {},
                startTunnel: {
                    starts += 1
                    throw vpnError(.configurationInvalid)
                },
                waitBeforeRetry: { _ in withUnsafeCurrentTask { $0?.cancel() } }
            )
        }
        do {
            try await task.value
            Issue.record("Cancellation must reach the caller")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(starts == 1)
    }

    @Test func foregroundRefreshWaitsForPermissionSaveAndTunnelStart() async throws {
        let access = VPNPreferencesAccess()
        let permission = PendingPermission()
        var events: [String] = []
        let connection = Task {
            try await access.withExclusiveAccess {
                events.append("save awaiting permission")
                await permission.wait()
                events.append("save approved")
                try await IKEv2TunnelStarter.start(
                    reload: { events.append("reload") },
                    startTunnel: { events.append("start") }
                )
            }
        }
        await settle()
        let refresh = Task {
            try await access.withExclusiveAccess { events.append("foreground refresh") }
        }
        await settle()
        #expect(events == ["save awaiting permission"])
        permission.approve()
        try await connection.value
        try await refresh.value
        #expect(events == [
            "save awaiting permission", "save approved", "reload", "start", "foreground refresh"
        ])
    }

    @Test func cancelledPreferenceWaiterDoesNotModifyProfileOrBlockTheNextWaiter() async throws {
        let access = VPNPreferencesAccess()
        let permission = PendingPermission()
        let connection = Task {
            try await access.withExclusiveAccess { await permission.wait() }
        }
        await settle()
        let cancelled = Task {
            try await access.withExclusiveAccess {
                _ = Issue.record("A cancelled waiter must not modify the profile")
            }
        }
        await settle()
        cancelled.cancel()
        var refreshed = false
        let refresh = Task {
            try await access.withExclusiveAccess { refreshed = true }
        }
        await settle()
        permission.approve()
        try await connection.value
        do {
            try await cancelled.value
            Issue.record("Cancellation must reach the caller")
        } catch {
            #expect(error is CancellationError)
        }
        try await refresh.value
        #expect(refreshed)
    }

    @Test func failedSaveReleasesPreferencesForTheNextOperation() async throws {
        let access = VPNPreferencesAccess()
        do {
            try await access.withExclusiveAccess {
                throw vpnError(.configurationReadWriteFailed)
            }
            Issue.record("A save failure must reach the caller")
        } catch {
            #expect((error as NSError).code == NEVPNError.configurationReadWriteFailed.rawValue)
        }
        var refreshed = false
        try await access.withExclusiveAccess { refreshed = true }
        #expect(refreshed)
    }

    private func vpnError(_ code: NEVPNError.Code) -> NSError {
        NSError(domain: NEVPNErrorDomain, code: code.rawValue)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class PendingPermission {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func approve() {
        continuation?.resume()
        continuation = nil
    }
}
