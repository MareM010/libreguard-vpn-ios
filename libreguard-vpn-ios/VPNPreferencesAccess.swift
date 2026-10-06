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
