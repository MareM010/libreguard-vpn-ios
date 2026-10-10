import Foundation
import NetworkExtension

/// MainActor isolation alone does not prevent preference transactions from
/// interleaving at an await, particularly while iOS asks to install a profile.
@MainActor
final class VPNPreferencesAccess {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveAccess<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        if isOccupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isOccupied = true
        }
        defer {
            if waiters.isEmpty {
                isOccupied = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

@MainActor
enum IKEv2TunnelStarter {
    /// A newly approved profile can still be unavailable to the VPN session.
    /// Reload the successfully saved profile before each bounded start attempt;
    /// never repeat the permission-producing save or retry unrelated failures.
    static func start(
        reload: () async throws -> Void,
        startTunnel: () throws -> Void,
        waitBeforeRetry: (Int) async throws -> Void = { retry in
            try await Task.sleep(for: .milliseconds(200 * retry))
        },
        onRetry: (Error, Int) -> Void = { _, _ in }
    ) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                try await reload()
                try Task.checkCancellation()
                try startTunnel()
                return
            } catch {
                let nsError = error as NSError
                let canReload = nsError.domain == NEVPNErrorDomain
                    && (nsError.code == NEVPNError.configurationInvalid.rawValue
                        || nsError.code == NEVPNError.configurationStale.rawValue)
                guard canReload, attempt < 2 else { throw error }
                try Task.checkCancellation()
                onRetry(error, attempt + 1)
                try await waitBeforeRetry(attempt + 1)
            }
        }
    }
}

/// A newly installed IncludeAllNetworks profile can leave the native provider
/// waiting for a usable interface without ever beginning its handshake. Recover
/// once using the already approved profile, within the coordinator's existing
/// startup deadline. Explicit disconnects and completed connections are not retried.
@MainActor
enum VPNInitialStartupRecovery {
    static func recoverIfStalled(
        status: () -> NEVPNStatus,
        stopTunnel: () -> Void,
        restartTunnel: () async throws -> Void,
        onRecoveryStateChange: (Bool) -> Void,
        sleep: (Duration) async throws -> Void,
        startupGrace: Duration = .seconds(10),
        stopTimeout: Duration = .seconds(10)
    ) async throws {
        var elapsed: Duration = .zero
        var observedStarting = false
        while elapsed < startupGrace {
            try Task.checkCancellation()
            let current = status()
            if current == .connected || current == .disconnecting { return }
            if current == .invalid || (current == .disconnected && observedStarting) {
                // Preparation masks old terminal notifications. A terminal state
                // after actual startup is a failure, not a stalled provider; do
                // not let that failure disappear while observing the first start.
                if observedStarting { throw VPNConnectionFailure(kind: .connectionFailed) }
                return
            }
            observedStarting = observedStarting || current == .connecting || current == .reasserting
            let delay = min(.milliseconds(200), startupGrace - elapsed)
            try await sleep(delay)
            elapsed += delay
        }
        try Task.checkCancellation()
        let current = status()
        if observedStarting, current == .disconnected || current == .invalid {
            throw VPNConnectionFailure(kind: .connectionFailed)
        }
        guard current == .connecting else { return }

        onRecoveryStateChange(true)
        defer { onRecoveryStateChange(false) }
        stopTunnel()
        elapsed = .zero
        while status() != .disconnected && status() != .invalid {
            try Task.checkCancellation()
            guard elapsed < stopTimeout else { throw VPNConnectionFailure(kind: .stopFailed) }
            let delay = min(.milliseconds(200), stopTimeout - elapsed)
            try await sleep(delay)
            elapsed += delay
        }
        try Task.checkCancellation()
        try await restartTunnel()
    }
}
