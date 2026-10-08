import Foundation
import NetworkExtension
import Testing
import UserNotifications
@testable import libreguard_vpn_ios

@MainActor
struct VPNRecoveryTests {
    @Test func combinedLogoutCleanupAcceptsDifferentSafeOutcomesPerProfile() {
        let removed = VPNProfileCleanupResult(tunnelStopped: true, onDemandDisabled: false,
            profileRemoved: true, diagnostic: nil)
        let disabled = VPNProfileCleanupResult(tunnelStopped: true, onDemandDisabled: true,
            profileRemoved: false, diagnostic: "Removal failed, but on-demand is disabled.")

        let combined = VPNProfileCleanupResult.combined([removed, disabled])

        #expect(combined.isSafeForUnauthenticatedLogin)
        #expect(!combined.profileRemoved)
    }

    @Test func combinedLogoutCleanupRejectsEveryUnsafeProfileCombination() {
        let outcomes = [false, true].flatMap { stopped in
            [false, true].flatMap { disabled in
                [false, true].map { removed in
                    VPNProfileCleanupResult(tunnelStopped: stopped, onDemandDisabled: disabled,
                        profileRemoved: removed, diagnostic: nil)
                }
            }
        }
        for first in outcomes {
            for second in outcomes {
                #expect(VPNProfileCleanupResult.combined([first, second]).isSafeForUnauthenticatedLogin
                    == (first.isSafeForUnauthenticatedLogin && second.isSafeForUnauthenticatedLogin))
            }
        }
    }

    @Test func logoutRemovalSkipsAbsentProfileAndIsSafeToRepeat() async throws {
        var hasProfile = true
        var loads = 0
        var removals = 0
        for _ in 0..<2 {
            try await VPNProfileRemoval.removeIfPresent(
                load: { loads += 1 }, hasProfile: { hasProfile },
                remove: { removals += 1; hasProfile = false })
        }
        #expect(loads == 3)
        #expect(removals == 1)
    }

    @Test func logoutRemovalAcceptsAnAlreadyRemovedProfileOnlyAfterReload() async throws {
        var hasProfile = true
        var loads = 0
        try await VPNProfileRemoval.removeIfPresent(
            load: { loads += 1; if loads == 2 { hasProfile = false } },
            hasProfile: { hasProfile },
            remove: { throw NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationInvalid.rawValue) })
        #expect(loads == 2)
        #expect(!hasProfile)
    }

    @Test func logoutRemovalRejectsFailedOrUnverifiedRemoval() async {
        for failed in [false, true] {
            do {
                try await VPNProfileRemoval.removeIfPresent(
                    load: {}, hasProfile: { true },
                    remove: { if failed { throw NSError(domain: NEVPNErrorDomain, code: 5) } })
                Issue.record("An installed profile must not be reported as removed.")
            } catch {
                if failed { #expect((error as NSError).code == 5) }
                else { #expect((error as? VPNConnectionFailure)?.kind == .stopFailed) }
            }
        }
    }

    @Test func logoutRemovalRequiresSuccessfulPreferenceReads() async {
        for failingLoad in [1, 2] {
            var loads = 0
            var hasProfile = true
            do {
                try await VPNProfileRemoval.removeIfPresent(
                    load: {
                        loads += 1
                        if loads == failingLoad { throw NSError(domain: NEVPNErrorDomain, code: 5) }
                    }, hasProfile: { hasProfile }, remove: { hasProfile = false })
                Issue.record("Unreadable preferences must not confirm profile removal.")
            } catch { #expect((error as NSError).code == 5) }
        }
    }

    @Test func missingProfileNeedsNoSaveOrRemoval() async {
        let harness = RecoveryHarness()
        harness.profile = nil
        #expect(await harness.recover().isSafe)
        #expect(harness.events == ["load"])
    }

    @Test func missingIdentityRemovesOnlyStoppedProfile() async {
        let harness = RecoveryHarness()
        harness.profile?.identityData = nil
        #expect(await harness.recover().isSafe)
        #expect(harness.events == ["load", "remove", "load"])
        #expect(harness.profile == nil)
    }

    @Test func validIdentityIsPreservedDuringRelease() async {
        let harness = RecoveryHarness()
        let identity = harness.profile?.identityData
        #expect(await harness.recover().isSafe)
        #expect(harness.events == ["load", "save", "load"])
        #expect(harness.profile?.identityData == identity)
        #expect(harness.profile?.includeAllNetworks == false)
    }

    @Test func nativeInvalidIdentityFallsBackToRemoval() async {
        let harness = RecoveryHarness()
        harness.saveError = NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationInvalid.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Missing identity"])
        #expect(await harness.recover().isSafe)
        #expect(harness.events == ["load", "save", "remove", "load"])
    }

    @Test func deniedSaveDoesNotDeleteValidProfile() async {
        let harness = RecoveryHarness()
        harness.saveError = NSError(domain: "NEConfigurationErrorDomain", code: 10)
        #expect(await harness.recover().isSafe == false)
        #expect(harness.profile != nil)
        #expect(!harness.events.contains("remove"))
    }

    @Test func failedOrUnverifiedRemovalBlocksRecovery() async {
        for ignored in [false, true] {
            let harness = RecoveryHarness()
            harness.profile?.identityData = nil
            harness.ignoreRemoval = ignored
            if !ignored { harness.removeError = NSError(domain: NEVPNErrorDomain, code: 5) }
            #expect(await harness.recover().isSafe == false)
        }
    }

    @Test func killSwitchAndRunningTunnelCannotBeRemoved() async {
        for protected in [false, true] {
            let harness = RecoveryHarness()
            harness.profile?.identityData = nil
            harness.stopped = protected
            #expect(await harness.recover(killSwitch: protected).isSafe == false)
            #expect(harness.events.isEmpty)
        }
    }

    @Test func tunnelResumingDuringReloadBlocksCleanup() async {
        let harness = RecoveryHarness()
        harness.resumeDuringLoad = true
        #expect(await harness.recover().isSafe == false)
        #expect(harness.events == ["load"])
    }

    @Test func missingIdentityIsNeverPermissionDenial() {
        let invalid = NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationInvalid.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Missing identity"])
        #expect(VPNConnectionFailure.classify(invalid, phase: .awaitingApproval).kind == .invalidConfiguration)
        let generic = NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationReadWriteFailed.rawValue)
        #expect(VPNConnectionFailure.classify(generic, phase: .awaitingApproval).kind == .preferencesUnavailable)
        let denied = NSError(domain: NEVPNErrorDomain, code: 5,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NEConfigurationErrorDomain", code: 10)])
        #expect(VPNConnectionFailure.classify(denied, phase: .awaitingApproval).kind == .permissionDenied)
    }

    @Test func approvedIdentityRestoresOmittedDataOnlyForTheSameProfile() throws {
        let original = NEVPNProtocolIKEv2()
        original.authenticationMethod = .certificate
        original.serverAddress = "vpn.example.test"
        original.remoteIdentifier = "vpn.example.test"
        original.localIdentifier = "client.example.test"
        original.identityData = Data([1, 2, 3])
        original.identityDataPassword = "memory-only"
        let identity = try #require(IKEv2ApprovedIdentity(profile: original))
        let reloaded = try #require(original.copy() as? NEVPNProtocolIKEv2)
        reloaded.identityData = nil
        reloaded.identityDataPassword = nil
        identity.hydrate(reloaded)
        #expect(reloaded.identityData == original.identityData)
        #expect(reloaded.identityDataPassword == original.identityDataPassword)
        reloaded.identityData = nil
        reloaded.serverAddress = "other.example.test"
        identity.hydrate(reloaded)
        #expect(reloaded.identityData == nil)
    }

    @Test func missingProviderResponseTimesOutAndLateCallbackIsIgnored() async throws {
        let clock = ManualVPNClock()
        var complete: (@Sendable (Result<Data, Error>) -> Void)?
        let task = Task {
            try await VPNCallbackDeadline.run(timeout: .seconds(2), sleep: clock.sleep) { complete = $0 }
        }
        await settle()
        clock.advance(.seconds(2))
        do { _ = try await task.value; Issue.record("Provider must time out") }
        catch { #expect((error as? VPNConnectionFailure)?.kind == .startupTimeout) }
        complete?(.success(Data([1])))
        complete?(.success(Data([2])))
        await settle()
    }

    @Test func providerWaitCanBeCancelledWithoutResponse() async {
        let clock = ManualVPNClock()
        let task = Task {
            try await VPNCallbackDeadline.run(timeout: .seconds(2), sleep: clock.sleep) { (_: @escaping @Sendable (Result<Data, Error>) -> Void) in }
        }
        await settle()
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation must finish") }
        catch { #expect(error is CancellationError) }
    }

    @Test func notificationDenialUsesSettingsWithoutRepeatedPrompts() async {
        var status = UNAuthorizationStatus.notDetermined
        var prompts = 0
        var opened = false
        let service = VPNNotificationService(readStatus: { status }, request: {
            prompts += 1; status = .denied; return false
        }, openSettings: { opened = true }, installsDelegate: false)
        #expect(await service.requestAuthorizationIfNeeded() == .denied)
        #expect(await service.requestAuthorizationIfNeeded() == .denied)
        #expect(prompts == 1)
        service.openSystemSettings()
        #expect(opened)
        status = .authorized
        await service.refreshAuthorizationStatus()
        #expect(service.authorizationStatus == .authorized)
    }

    @Test func notificationRequestFailureIsNotReportedAsDenial() async {
        let service = VPNNotificationService(readStatus: { .notDetermined }, request: {
            throw NSError(domain: "test", code: 1)
        }, installsDelegate: false)
        #expect(await service.requestAuthorizationIfNeeded() == .failed)
        #expect(service.authorizationStatus == .notDetermined)
    }

    private func settle() async { for _ in 0..<40 { await Task.yield() } }
}

@MainActor
private final class RecoveryHarness {
    var profile: NEVPNProtocolIKEv2? = NEVPNProtocolIKEv2()
    var events: [String] = []
    var stopped = true
    var enabled = true
    var onDemand = true
    var saveError: Error?
    var removeError: Error?
    var ignoreRemoval = false
    var resumeDuringLoad = false
    init() {
        profile?.identityData = Data([1, 2, 3])
        profile?.includeAllNetworks = true
    }
    func recover(killSwitch: Bool = false) async -> VPNStoppedProfileRecoveryResult {
        await IKEv2StoppedProfileRecovery.recover(killSwitchEnabled: killSwitch,
            load: { self.events.append("load"); if self.resumeDuringLoad { self.stopped = false } },
            profile: { self.profile }, isStopped: { self.stopped },
            disable: { profile in profile.includeAllNetworks = false; self.enabled = false; self.onDemand = false },
            save: { self.events.append("save"); if let error = self.saveError { throw error } },
            remove: {
                self.events.append("remove")
                if let error = self.removeError { throw error }
                if !self.ignoreRemoval { self.profile = nil }
            },
            verifyReleased: { self.profile == nil || (!self.enabled && !self.onDemand && self.profile?.includeAllNetworks == false) })
    }
}

@MainActor
final class ManualVPNClock {
    private var waiters: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = (duration, $0) }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    func advance(_ duration: Duration) {
        for (id, waiter) in waiters where waiter.0 == duration {
            waiters.removeValue(forKey: id)?.1.resume()
        }
    }
}
