import Foundation
import Testing
@testable import libreguard_vpn_ios

/// AppModel's traffic monitor shares the app-group VPN store. Suites that create
/// models use one scope so a suspended test cannot read another test's traffic.
struct SharedVPNFixtureScope: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await VPNFixtureIsolation.shared.withExclusiveAccess {
            let owner = await VPNFixtureOwner()
            try await VPNTestFixtures.$owner.withValue(owner) {
                await owner.prepare()
                do {
                    try await function()
                    await owner.tearDown()
                } catch {
                    await owner.tearDown()
                    throw error
                }
            }
        }
    }
}

enum VPNTestFixtures {
    @TaskLocal static var owner: VPNFixtureOwner?

    @MainActor
    static func track(
        _ model: AppModel,
        beforeDisconnect: @escaping @MainActor () -> Void = {}
    ) -> AppModel {
        owner?.models.append((model, beforeDisconnect))
        return model
    }
}

@MainActor
final class VPNFixtureOwner {
    var models: [(AppModel, @MainActor () -> Void)] = []

    func prepare() {
        VPNSharedSessionStore.clear()
    }

    func tearDown() async {
        // Clearing storage alone leaves connected monitoring tasks alive.
        // Stop each owned model first so it cannot republish a stale sample.
        for (model, beforeDisconnect) in models.reversed() {
            beforeDisconnect()
            if model.vpnStatus.isConnected || model.vpnStatus.isBusy || model.sessionMetrics != nil {
                await model.disconnectVPN()
            }
        }
        models.removeAll()
        VPNSharedSessionStore.clear()
    }
}

private actor VPNFixtureIsolation {
    static let shared = VPNFixtureIsolation()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveAccess(
        _ function: @concurrent @Sendable () async throws -> Void
    ) async rethrows {
        await acquire()
        defer { release() }
        try await function()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
