import Foundation
import NetworkExtension
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct IKEv2FirstConnectionTests {
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
