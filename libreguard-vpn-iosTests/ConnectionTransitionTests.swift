import Foundation
import UserNotifications
import Testing
@testable import libreguard_vpn_ios

@Suite(SharedVPNFixtureScope())
@MainActor
struct ConnectionTransitionTests {
    @Test func heroPresentationMatchesAndroidReferenceCopyAndActions() {
        let disconnected = ConnectionHeroPresentation.make(for: .disconnected, hasQueuedReconnect: false)
        #expect(disconnected.title == "Not Protected")
        #expect(disconnected.description == "Your connection is not secure")
        #expect(disconnected.actionTitle == "Connect")

        let preparing = ConnectionHeroPresentation.make(
            for: .disconnected,
            hasQueuedReconnect: false,
            preparationMessage: "Your OpenVPN certificate is still being prepared. Try Connect again in a moment."
        )
        #expect(preparing.title == "Certificate preparing")
        #expect(preparing.progressLabel == "Preparation continues")
        #expect(preparing.actionTitle == "Connect")

        let connecting = ConnectionHeroPresentation.make(for: .connecting, hasQueuedReconnect: false)
        #expect(connecting.title == "Connecting")
        #expect(connecting.progressLabel == "Securing tunnel")
        #expect(connecting.actionTitle == "Cancel")

        let connected = ConnectionHeroPresentation.make(for: .connected, hasQueuedReconnect: false)
        #expect(connected.title == "Protected")
        #expect(connected.description == "Secure tunnel active")
        #expect(connected.progressLabel == "Tunnel established")
        #expect(connected.actionTitle == "Disconnect")

        let disconnecting = ConnectionHeroPresentation.make(for: .disconnecting, hasQueuedReconnect: false)
        #expect(disconnecting.actionTitle == "Reconnect")
        #expect(ConnectionHeroPresentation.make(for: .disconnecting, hasQueuedReconnect: true).actionTitle == "Cancel Reconnect")
    }

    @Test func heroMotionUsesAndroidReferenceMilestones() {
        #expect(ConnectionHeroMotion.initialConnectionProgress == 0.06)
        #expect(ConnectionHeroMotion.firstConnectionMilestone == 0.16)
        #expect(ConnectionHeroMotion.maximumConnectionProgress == 0.92)
        #expect(ConnectionHeroMotion.connectionCompletionFloor == 0.82)
        #expect(ConnectionHeroMotion.connectionCompletionDuration == 0.62)
        #expect(ConnectionHeroMotion.orbitDuration == 3.2)
    }

    @Test func primaryActionCancelsAnInFlightConnection() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])

        app.requestConnectionToSelectedServer()
        await settle()

        #expect(app.vpnStatus == .connecting)
        #expect(manager.connectCalls.map(\.serverID) == [1])

        app.performVPNPrimaryAction()
        await settle()

        #expect(manager.disconnectCalls == 1)
        #expect(app.vpnStatus == .disconnected)
        #expect(app.hasQueuedVPNReconnect == false)
    }

    @Test func quickConnectRanksServersThenSelectsAndConnectsTheWinner() async throws {
        let manager = ControlledVPNManager()
        let first = try makeServer(id: 1, load: 90)
        let second = try makeServer(id: 2, load: 20)
        let app = makeApp(manager: manager, servers: [first, second])
        app.serverLatencies = [1: 30, 2: 65]

        app.requestQuickConnect()
        await settle()

        #expect(app.selectedServerID == second.id)
        #expect(manager.connectCalls.map(\.serverID) == [second.id])
    }

    @Test func newerConnectRequestReplacesAnInFlightConnection() async throws {
        let manager = ControlledVPNManager()
        let first = try makeServer(id: 1)
        let second = try makeServer(id: 2)
        let app = makeApp(manager: manager, servers: [first, second])

        app.selectServer(first)
        app.requestConnectionToSelectedServer()
        await settle()

        app.selectServer(second)
        app.requestConnectionToSelectedServer()
        await settle()

        #expect(manager.connectCalls.map(\.serverID) == [1, 2])
        #expect(manager.disconnectCalls == 1)
        #expect(app.vpnStatus == .connecting)
    }

    @Test func delayedQuotaApprovalCannotStartACancelledRequest() async throws {
        let manager = ControlledVPNManager()
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        var completion: CheckedContinuation<CanConnectResponse, Error>?
        backend.connectionEligibilityHandler = {
            try await withCheckedThrowingContinuation { completion = $0 }
        }
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)], backend: backend)
        app.session = makeSession(userId: "quota-user")
        app.requestConnectionToSelectedServer()
        await settle()
        #expect(completion != nil)
        app.requestVPNDisconnect()
        completion?.resume(throwing: StubConnectionError.failed)
        await settle()
        #expect(manager.connectCalls.isEmpty)
        #expect(!app.isCheckingConnectionQuota)
    }

    @Test func latestRequestWinsWhenOldQuotaApprovalArrivesLate() async throws {
        let manager = ControlledVPNManager()
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        var completions: [CheckedContinuation<CanConnectResponse, Error>] = []
        backend.connectionEligibilityHandler = {
            try await withCheckedThrowingContinuation { completions.append($0) }
        }
        let first = try makeServer(id: 1)
        let second = try makeServer(id: 2)
        let app = makeApp(manager: manager, servers: [first, second], backend: backend)
        app.session = makeSession(userId: "quota-user")
        app.requestConnectionToSelectedServer()
        await settle()
        app.selectServer(second)
        app.requestConnectionToSelectedServer()
        await settle()
        #expect(completions.count == 2)
        completions[1].resume(throwing: StubConnectionError.failed)
        await settle()
        completions[0].resume(throwing: StubConnectionError.failed)
        await settle()
        #expect(manager.connectCalls.map(\.serverID) == [2])
        #expect(!app.isCheckingConnectionQuota)
    }

    @Test func latestConnectRequestWinsWhileDisconnecting() async throws {
        let manager = ControlledVPNManager(status: .connected)
        manager.holdDisconnect = true
        let first = try makeServer(id: 1)
        let second = try makeServer(id: 2)
        let app = makeApp(manager: manager, servers: [first, second])

        app.selectServer(first)
        app.requestConnectionToSelectedServer()
        await settle()
        #expect(app.vpnStatus == .disconnecting)
        #expect(app.hasQueuedVPNReconnect)

        app.selectServer(second)
        app.requestConnectionToSelectedServer()
        #expect(app.hasQueuedVPNReconnect)

        manager.completeDisconnect()
        await settle()

        #expect(manager.connectCalls.map(\.serverID) == [2])
        #expect(app.hasQueuedVPNReconnect == false)
        #expect(app.vpnStatus == .connecting)
    }

    @Test func failedConnectionSettlesBackToDisconnectedAfterTransientCallback() async throws {
        let manager = ControlledVPNManager()
        manager.connectError = StubConnectionError.failed
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])

        app.requestConnectionToSelectedServer()
        await settle()

        #expect(app.vpnStatus == .disconnected)
        #expect(app.presentedError?.message == "Connection failed")
    }

    @Test func statisticsStartWhenTunnelStartReturnsBeforeConnectedStatus() async throws {
        let manager = ControlledVPNManager()
        manager.returnDisconnectedAfterStart = true
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.session = makeSession(userId: "traffic-user")

        app.requestConnectionToSelectedServer()
        await settle()

        #expect(app.vpnStatus == .connecting)
        #expect(app.sessionMetrics == nil)

        manager.emit(.connected)
        await settle()

        #expect(app.vpnStatus == .connected)
        #expect(app.sessionMetrics != nil)
    }

    @Test func statisticsUseTheNetworkExtensionConnectedDate() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 20)])
        app.session = makeSession(userId: "connected-date-user")
        let connectedDate = Date(timeIntervalSince1970: 1_234_567)
        manager.connectedDate = connectedDate

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await settle()

        #expect(app.sessionMetrics?.descriptor.connectedAt == connectedDate)
        VPNSharedSessionStore.clear()
    }

    @Test func restoringIKEv2SessionRecoversTrafficSinceTheLastCheckpoint() async throws {
        let manager = ControlledVPNManager(status: .connected)
        manager.connectedDate = Date(timeIntervalSince1970: 2_000)
        let sessionID = UUID()
        let descriptor = VPNSessionDescriptor(
            sessionID: sessionID,
            serverID: 21,
            serverName: "DE-21",
            country: "Germany",
            countryFlag: "🇩🇪",
            protocolName: "IKEv2/IPSec",
            connectedAt: Date(timeIntervalSince1970: 2_000),
            origin: .manual,
            killSwitchEnabled: false,
            onDemandEnabled: false
        )
        VPNSharedSessionStore.clear()
        VPNSharedSessionStore.save(descriptor: descriptor)
        VPNSharedSessionStore.save(
            traffic: VPNSessionTraffic(
                state: .connected,
                downloadedBytes: 100,
                uploadedBytes: 40,
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: Date(timeIntervalSince1970: 2_010)
            ),
            sessionID: sessionID
        )
        VPNSharedSessionStore.save(
            checkpoint: VPNTrafficCheckpoint(
                sessionID: sessionID,
                snapshot: TunnelTrafficSnapshot(downloadedBytes: 1_000, uploadedBytes: 400),
                sampledAt: Date(timeIntervalSince1970: 2_010)
            )
        )

        let app = makeApp(
            manager: manager,
            servers: [],
            sampler: ScriptedTrafficSampler([
                TunnelTrafficSnapshot(downloadedBytes: 1_600, uploadedBytes: 650)
            ])
        )
        manager.trafficSnapshot = TunnelTrafficSnapshot(downloadedBytes: 1_600, uploadedBytes: 650)
        app.session = makeSession(userId: "restore-user")

        await app.refreshVPNStatus()
        await settle()

        #expect(app.sessionMetrics?.traffic.downloadedBytes == 700)
        #expect(app.sessionMetrics?.traffic.uploadedBytes == 290)
        #expect(app.selectedServerID == 21)
        VPNSharedSessionStore.clear()
    }

    @Test func orphanedSessionIsFinalizedOnceAfterAProcessRestart() async throws {
        let manager = ControlledVPNManager(status: .disconnected)
        let recorder = RecordingStatisticsRecorder()
        let sessionID = UUID()
        let descriptor = VPNSessionDescriptor(
            sessionID: sessionID,
            serverID: 22,
            serverName: "DE-22",
            country: "Germany",
            countryFlag: "🇩🇪",
            protocolName: "IKEv2/IPSec",
            connectedAt: Date(timeIntervalSince1970: 3_000),
            origin: .manual,
            killSwitchEnabled: false,
            onDemandEnabled: false
        )
        VPNSharedSessionStore.clear()
        VPNSharedSessionStore.save(descriptor: descriptor)
        VPNSharedSessionStore.save(
            traffic: VPNSessionTraffic(
                state: .connected,
                downloadedBytes: 500,
                uploadedBytes: 125,
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: Date(timeIntervalSince1970: 3_100)
            ),
            sessionID: sessionID
        )

        let app = makeApp(manager: manager, servers: [], recorder: recorder)
        app.session = makeSession(userId: "orphan-user")

        await app.refreshVPNStatus()
        await app.refreshVPNStatus()

        #expect(recorder.records.count == 1)
        #expect(recorder.records.first?.downloadedBytes == 500)
        #expect(recorder.records.first?.uploadedBytes == 125)
        VPNSharedSessionStore.clear()
    }

    @Test func sharedTrafficStoreKeepsTheLargestOpenVPNTotalsAcrossWriters() throws {
        let sessionID = UUID()
        let descriptor = VPNSessionDescriptor(
            sessionID: sessionID,
            serverID: 23,
            serverName: "DE-23",
            country: "Germany",
            countryFlag: "🇩🇪",
            protocolName: "OpenVPN",
            connectedAt: Date(timeIntervalSince1970: 4_000),
            origin: .manual,
            killSwitchEnabled: false,
            onDemandEnabled: false
        )
        VPNSharedSessionStore.clear()
        VPNSharedSessionStore.save(descriptor: descriptor)

        VPNSharedSessionStore.save(
            traffic: VPNSessionTraffic(
                state: .connected,
                downloadedBytes: 1_000,
                uploadedBytes: 400,
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: Date(timeIntervalSince1970: 4_010)
            ),
            sessionID: sessionID
        )
        VPNSharedSessionStore.save(
            traffic: VPNSessionTraffic(
                state: .connected,
                downloadedBytes: 700,
                uploadedBytes: 300,
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: Date(timeIntervalSince1970: 4_011)
            ),
            sessionID: sessionID
        )

        #expect(VPNSharedSessionStore.loadTraffic()?.downloadedBytes == 1_000)
        #expect(VPNSharedSessionStore.loadTraffic()?.uploadedBytes == 400)
        VPNSharedSessionStore.clear()
    }

    @Test func reconnectCanBeCancelledWhileDisconnecting() async throws {
        let manager = ControlledVPNManager(status: .connected)
        manager.holdDisconnect = true
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])

        app.requestConnectionToSelectedServer()
        await settle()
        #expect(app.hasQueuedVPNReconnect)

        app.performVPNPrimaryAction()
        #expect(app.hasQueuedVPNReconnect == false)

        manager.completeDisconnect()
        await settle()

        #expect(manager.connectCalls.isEmpty)
        #expect(app.vpnStatus == .disconnected)
    }

    @Test func coordinatorDisconnectsOnlyManagersThatAreActive() async {
        let ikev2 = ControlledVPNManager(status: .connected)
        let openVPN = ControlledVPNManager(status: .disconnected)
        let coordinator = VPNManagerCoordinator(ikev2Manager: ikev2, openVPNManager: openVPN)

        await coordinator.disconnect()

        #expect(ikev2.disconnectCalls == 1)
        #expect(openVPN.disconnectCalls == 0)
        #expect(coordinator.status == .disconnected)
    }

    @Test func coordinatorDisablesEveryOnDemandProfileBeforeForgettingEitherTunnel() async {
        let events = CleanupEventLog()
        let ikev2 = CleanupTrackingVPNManager(label: "ikev2", events: events)
        let openVPN = CleanupTrackingVPNManager(label: "openvpn", events: events)
        let coordinator = VPNManagerCoordinator(ikev2Manager: ikev2, openVPNManager: openVPN)

        let result = await coordinator.disconnectAndForget()

        #expect(events.entries == [
            "ikev2:disable",
            "openvpn:disable",
            "ikev2:forget",
            "openvpn:forget"
        ])
        #expect(result.isSafeForUnauthenticatedLogin)
    }

    @Test func coordinatorRejectsAStaleStatusFromTheInactiveProtocol() async {
        let ikev2 = ControlledVPNManager(status: .connected)
        let openVPN = ControlledVPNManager(status: .disconnected)
        let coordinator = VPNManagerCoordinator(ikev2Manager: ikev2, openVPNManager: openVPN)

        openVPN.emit(.connected)
        await settle()

        #expect(openVPN.disconnectCalls == 1)
        #expect(coordinator.status == .connected)
    }

    @Test func coordinatorAppliesDisabledPolicyToBothProtocols() async throws {
        let ikev2 = ControlledVPNManager(status: .connected)
        let openVPN = ControlledVPNManager(status: .disconnected)
        let coordinator = VPNManagerCoordinator(ikev2Manager: ikev2, openVPNManager: openVPN)

        _ = try await coordinator.apply(policy: .disabled)

        #expect(ikev2.policyUpdates == [.disabled])
        #expect(openVPN.policyUpdates == [.disabled])
        #expect(ikev2.disconnectCalls == 0)
    }

    @Test func coordinatorRecoversOnlyTheStoppedIKEv2Profile() async {
        let ikev2 = ControlledVPNManager()
        let openVPN = ControlledVPNManager()
        let coordinator = VPNManagerCoordinator(ikev2Manager: ikev2, openVPNManager: openVPN)

        let recovered = await coordinator.recoverStoppedProfile(for: .ikev2)
        let ignored = await coordinator.recoverStoppedProfile(for: .openVPN)

        #expect(recovered.isSafe)
        #expect(ikev2.stoppedProfileRecoveryProtocols == [.ikev2])
        #expect(openVPN.stoppedProfileRecoveryProtocols.isEmpty)
        #expect(ignored == .notApplicable)
    }

    @Test func killSwitchPolicyAlwaysEnablesOnDemand() {
        #expect(VPNConnectionPolicy.appPolicy(autoConnectEnabled: false, killSwitchEnabled: false) == .disabled)
        #expect(VPNConnectionPolicy.appPolicy(autoConnectEnabled: true, killSwitchEnabled: false).onDemandEnabled)
        #expect(VPNConnectionPolicy.appPolicy(autoConnectEnabled: false, killSwitchEnabled: true).onDemandEnabled)
        #expect(VPNConnectionPolicy.appPolicy(autoConnectEnabled: true, killSwitchEnabled: true).onDemandEnabled)
    }

    @Test func proUserCanArmKillSwitchWhileDisconnected() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)], defaults: defaults)
        app.subscription = try makeSubscription(isPro: true)

        await app.setKillSwitchEnabled(true)

        #expect(app.isKillSwitchEnabled)
        #expect(app.killSwitchActivationState == .armed)
        #expect(manager.policyUpdates.isEmpty)
        #expect(defaults.bool(forKey: "vpn.killSwitch.enabled"))
    }

    @Test func freeUserCannotEnableKillSwitch() async {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [])

        await app.setKillSwitchEnabled(true)

        #expect(app.isKillSwitchEnabled == false)
        #expect(app.presentedError?.message == "Kill Switch requires a Pro plan.")
    }

    @Test func planDowngradeKeepsExistingKillSwitchButPreventsReenable() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [])
        app.subscription = try makeSubscription(isPro: true)
        await app.setKillSwitchEnabled(true)

        app.subscription = try makeSubscription(isPro: false)
        #expect(app.isKillSwitchEnabled)

        await app.setKillSwitchEnabled(false)
        await app.setKillSwitchEnabled(true)

        #expect(app.isKillSwitchEnabled == false)
        #expect(app.presentedError?.message == "Kill Switch requires a Pro plan.")
    }

    @Test func nextConnectionActivatesArmedKillSwitch() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.subscription = try makeSubscription(isPro: true)
        await app.setKillSwitchEnabled(true)

        app.requestConnectionToSelectedServer()
        await settle()

        #expect(manager.connectCalls.first?.policy.killSwitchEnabled == true)
        #expect(manager.connectCalls.first?.policy.onDemandEnabled == true)
        #expect(app.killSwitchActivationState == .active)
    }

    @Test func activeKillSwitchRequiresConfirmationBeforeDisconnect() async throws {
        let manager = ControlledVPNManager(status: .connected)
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.subscription = try makeSubscription(isPro: true)
        await app.setKillSwitchEnabled(true)

        app.requestVPNDisconnect()

        #expect(app.isKillSwitchDisconnectConfirmationPresented)
        #expect(manager.disconnectCalls == 0)

        await app.confirmKillSwitchDisableAndDisconnect()

        #expect(app.isKillSwitchEnabled == false)
        #expect(manager.policyUpdates.last == .disabled)
        #expect(manager.disconnectCalls == 1)
    }

    @Test func manualDisconnectReleasesStoppedIKEv2ProfileWhenKillSwitchIsOff() async throws {
        let manager = ControlledVPNManager(status: .connected)
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])

        await app.disconnectVPN()
        await settle()

        #expect(manager.stoppedProfileRecoveryProtocols == [.ikev2])
    }

    @Test func unexpectedIKEv2DisconnectRecoversStoppedProfile() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.session = makeSession(userId: "recovery-user")

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await settle()
        manager.emit(.disconnected)
        await settle()

        #expect(manager.stoppedProfileRecoveryProtocols == [.ikev2])
    }

    @Test func stoppedProfileRecoveryFailureIsShownToTheUser() async throws {
        let manager = ControlledVPNManager()
        manager.stoppedProfileRecoveryResult = VPNStoppedProfileRecoveryResult(
            isApplicable: true,
            routingReleased: false,
            onDemandDisabled: true,
            profileDisabled: true,
            diagnostic: "save failed"
        )
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.session = makeSession(userId: "recovery-failure-user")

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await settle()
        manager.emit(.disconnected)
        await settle()

        #expect(app.presentedError?.code == "VPN_STOPPED_PROFILE_RECOVERY_FAILED")
    }

    @Test func unexpectedDisconnectKeepsKillSwitchProfileProtected() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.session = makeSession(userId: "kill-switch-user")
        app.subscription = try makeSubscription(isPro: true)
        await app.setKillSwitchEnabled(true)

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await settle()
        manager.emit(.disconnected)
        await settle()

        #expect(manager.stoppedProfileRecoveryProtocols.isEmpty)
    }

    @Test func reassertingIKEv2TunnelDoesNotRecoverStoppedProfile() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.session = makeSession(userId: "reasserting-user")

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await settle()
        manager.emit(.reasserting)
        await settle()

        #expect(manager.stoppedProfileRecoveryProtocols.isEmpty)
    }

    @Test func disconnectPersistsStatisticsForTheActiveUser() async throws {
        let manager = ControlledVPNManager()
        let recorder = RecordingStatisticsRecorder()
        let sampler = ScriptedTrafficSampler([
            TunnelTrafficSnapshot(downloadedBytes: 100, uploadedBytes: 40),
            TunnelTrafficSnapshot(downloadedBytes: 460, uploadedBytes: 160)
        ])
        let server = try makeServer(id: 7)
        let app = makeApp(manager: manager, servers: [server], recorder: recorder, sampler: sampler)
        app.session = makeSession(userId: "user-1")

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await sampler.waitForFirstSnapshot()

        await app.disconnectVPN()

        #expect(recorder.records.count == 1)
        #expect(recorder.records.first?.userId == "user-1")
        #expect(recorder.records.first?.server.id == 7)
        #expect(recorder.records.first?.protocolName == .ikev2)
        #expect(recorder.records.first?.downloadedBytes == 360)
        #expect(recorder.records.first?.uploadedBytes == 120)
    }

    @Test func signOutFinalizesStatisticsBeforeClearingTheSession() async throws {
        let manager = ControlledVPNManager()
        let recorder = RecordingStatisticsRecorder()
        let sampler = ScriptedTrafficSampler([
            TunnelTrafficSnapshot(downloadedBytes: 50, uploadedBytes: 20),
            TunnelTrafficSnapshot(downloadedBytes: 150, uploadedBytes: 55)
        ])
        let server = try makeServer(id: 9)
        let app = makeApp(manager: manager, servers: [server], recorder: recorder, sampler: sampler)
        app.session = makeSession(userId: "user-2")

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await sampler.waitForFirstSnapshot()

        await app.signOut()

        #expect(recorder.records.count == 1)
        #expect(recorder.records.first?.userId == "user-2")
        #expect(app.session == nil)
        if case .login = app.route {
        } else {
            Issue.record("Expected the app to return to the login route")
        }
    }

    @Test func connectionLifecycleEmitsConnectedAndDisconnectedEvents() async throws {
        let manager = ControlledVPNManager()
        let notifier = RecordingVPNEventNotifier()
        let sampler = ScriptedTrafficSampler([
            TunnelTrafficSnapshot(downloadedBytes: 100, uploadedBytes: 40),
            TunnelTrafficSnapshot(downloadedBytes: 460, uploadedBytes: 160)
        ])
        let app = makeApp(
            manager: manager,
            servers: [try makeServer(id: 12)],
            sampler: sampler,
            eventNotifier: notifier
        )
        app.session = makeSession(userId: "events-user")

        app.requestConnectionToSelectedServer()
        await settle()
        manager.emit(.connected)
        await sampler.waitForFirstSnapshot()
        await app.disconnectVPN()
        await settle()

        #expect(notifier.events == [.connected, .disconnected])
        #expect(notifier.payloads.last?.traffic?.downloadedBytes == 360)
        #expect(notifier.payloads.last?.traffic?.uploadedBytes == 120)
    }

    @Test func autoConnectAndKillSwitchIncidentsEmitDedicatedEvents() async throws {
        let manager = ControlledVPNManager()
        let notifier = RecordingVPNEventNotifier()
        let app = makeApp(
            manager: manager,
            servers: [try makeServer(id: 13)],
            sampler: ScriptedTrafficSampler([
                TunnelTrafficSnapshot(downloadedBytes: 0, uploadedBytes: 0)
            ]),
            eventNotifier: notifier
        )
        app.session = makeSession(userId: "safety-user")
        app.subscription = try makeSubscription(isPro: true)
        await app.setKillSwitchEnabled(true)

        app.requestQuickConnect(origin: .autoConnect)
        await settle()
        manager.emit(.connected)
        await settle()
        manager.emit(.reasserting)
        await settle()

        #expect(notifier.events.contains(.autoConnect))
        #expect(notifier.events.contains(.connected))
        #expect(notifier.events.contains(.killSwitch))
    }

    @Test func handoffReleasesIKEv2BeforeStartingOpenVPN() async throws {
        let ike = ControlledVPNManager(status: .connected)
        let open = ControlledVPNManager()
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: open)
        try await coordinator.connect(to: makeServer(id: 1), protocol: .openVPN, policy: .disabled)
        #expect(ike.disconnectCalls == 1)
        #expect(ike.stoppedProfileRecoveryProtocols.contains(.ikev2))
        #expect(open.connectCalls.count == 1)
        _ = await coordinator.stopAndWait(releaseProtection: true)
    }

    @Test func unsafeStoppedProfileBlocksOpenVPNStart() async throws {
        let ike = ControlledVPNManager()
        ike.stoppedProfileRecoveryResult = VPNStoppedProfileRecoveryResult(isApplicable: true,
            routingReleased: false, onDemandDisabled: false, profileDisabled: false, diagnostic: "save failed")
        let open = ControlledVPNManager()
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: open)
        do {
            try await coordinator.connect(to: makeServer(id: 1), protocol: .openVPN, policy: .disabled)
            Issue.record("An unsafe profile must block startup")
        } catch { #expect((error as? VPNConnectionFailure)?.kind == .stopFailed) }
        #expect(open.connectCalls.isEmpty)
    }

    @Test func pendingStartIsStoppedEvenWhenNativeStatusIsDisconnected() async throws {
        let ike = ControlledVPNManager()
        let open = ControlledVPNManager()
        open.returnDisconnectedAfterStart = true
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: open)
        try await coordinator.connect(to: makeServer(id: 1), protocol: .openVPN, policy: .disabled)
        let stopped = await coordinator.stopAndWait(releaseProtection: true)
        #expect(stopped.isSafe)
        #expect(open.disconnectCalls == 1)
    }

    @Test func latestCoordinatorRequestCancelsAndDrainsPreparation() async throws {
        let ike = ControlledVPNManager()
        let open = ControlledVPNManager()
        open.holdConnect = true
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: open)
        let firstServer = try makeServer(id: 1)
        let lastServer = try makeServer(id: 2)
        let first = Task { try await coordinator.connect(to: firstServer, protocol: .openVPN, policy: .disabled) }
        await settle()
        let last = Task { try await coordinator.connect(to: lastServer, protocol: .ikev2, policy: .disabled) }
        await settle()
        #expect(ike.connectCalls.isEmpty)
        open.completeConnect()
        do { try await first.value; Issue.record("Superseded preparation must cancel") }
        catch { #expect(error is CancellationError) }
        try await last.value
        #expect(open.disconnectCalls == 1)
        #expect(ike.connectCalls.map(\.serverID) == [2])
        _ = await coordinator.stopAndWait(releaseProtection: true)
    }

    @Test func killSwitchRejectsCrossProtocolRequestBeforeDisconnect() async throws {
        let manager = ControlledVPNManager(status: .connected)
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.subscription = try makeSubscription(isPro: true)
        await app.setKillSwitchEnabled(true)
        app.selectVPNProtocol(.openVPN)
        app.requestConnectionToSelectedServer()
        await settle()
        #expect(manager.disconnectCalls == 0)
        #expect(manager.connectCalls.isEmpty)
        #expect(app.vpnStatus == .connected)
        #expect(app.presentedError?.message == VPNConnectionFailure(kind: .protectedSwitch).localizedDescription)
    }

    @Test func deniedVPNSetupOffersExplicitRetry() async throws {
        let manager = ControlledVPNManager()
        manager.connectError = VPNConnectionFailure(kind: .permissionDenied)
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.requestConnectionToSelectedServer()
        await settle()
        let errorID = try #require(app.presentedError?.id)
        #expect(app.vpnRecoveryActionTitle == "Retry VPN Setup")
        #expect(manager.connectCalls.count == 1)
        manager.connectError = nil
        app.retryVPNSetup(errorID: errorID)
        await settle()
        #expect(manager.connectCalls.count == 2)
        #expect(app.vpnStatus == .connecting)
    }

    @Test func changingProtocolInvalidatesPermissionRetry() async throws {
        let manager = ControlledVPNManager()
        manager.connectError = VPNConnectionFailure(kind: .permissionDenied)
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.subscription = try makeSubscription(isPro: true)
        app.requestConnectionToSelectedServer()
        await settle()
        let errorID = try #require(app.presentedError?.id)
        app.selectVPNProtocol(.openVPN)
        app.retryVPNSetup(errorID: errorID)
        await settle()
        #expect(manager.connectCalls.count == 1)
    }

    @Test func staleAttemptErrorDoesNotReplaceNewConnection() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1), try makeServer(id: 2)])
        app.requestConnectionToSelectedServer()
        await settle()
        let oldID = manager.attemptID
        app.selectedServerID = 2
        app.requestConnectionToSelectedServer()
        await settle()
        manager.onAttemptEvent?(VPNAttemptEvent(attemptID: oldID, protocolName: .ikev2,
            phase: .starting, failure: VPNConnectionFailure(kind: .connectionFailed)))
        #expect(app.presentedError == nil)
        #expect(app.vpnStatus == .connecting)
        #expect(manager.connectCalls.last?.serverID == 2)
    }

    @Test func terminalStartupCallbackFinishesConnecting() async throws {
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.requestConnectionToSelectedServer()
        await settle()
        manager.onAttemptEvent?(VPNAttemptEvent(attemptID: manager.attemptID, protocolName: .ikev2,
            phase: .starting, nativeStartupObserved: true))
        manager.emit(.disconnected)
        await settle()
        #expect(app.vpnStatus == .disconnected)
        #expect(app.presentedError != nil)
    }

    @Test func invalidStartupStatusCancelsTheStartupDeadline() async throws {
        let clock = ManualVPNClock()
        let ike = ControlledVPNManager()
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: ControlledVPNManager(),
            timing: VPNConnectionTiming(sleep: clock.sleep))
        var failures: [VPNConnectionFailure.Kind] = []
        coordinator.onAttemptEvent = { event in
            if let failure = event.failure { failures.append(failure.kind) }
        }
        try await coordinator.connect(to: makeServer(id: 1), protocol: .ikev2, policy: .disabled)
        ike.onAttemptEvent?(VPNAttemptEvent(attemptID: ike.attemptID, protocolName: .ikev2,
            phase: .starting, nativeStartupObserved: true))
        ike.emit(.invalid)
        clock.advance(.seconds(30))
        await settle()
        #expect(failures == [.connectionFailed])
        _ = await coordinator.stopAndWait(releaseProtection: true)
    }

    @Test func startupTimeoutFinishesTheSpinnerAndCancelsPendingStart() async throws {
        let clock = ManualVPNClock()
        let ike = ControlledVPNManager()
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: ControlledVPNManager(),
            timing: VPNConnectionTiming(sleep: clock.sleep))
        let app = makeApp(manager: coordinator, servers: [try makeServer(id: 1)])
        app.requestConnectionToSelectedServer()
        await settle()
        clock.advance(.seconds(30))
        await settle()
        #expect(app.vpnStatus == .disconnected)
        #expect(app.presentedError?.message == VPNConnectionFailure(kind: .startupTimeout).localizedDescription)
        #expect(ike.disconnectCalls == 1)
        #expect(app.vpnRecoveryActionTitle == "Retry Connection")
    }

    @Test func initialStartObservationKeepsTheCompletedConnectionPhase() async throws {
        let ike = ControlledVPNManager()
        ike.holdConnect = true
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: ControlledVPNManager())
        var phases: [VPNAttemptPhase] = []
        coordinator.onAttemptEvent = { phases.append($0.phase) }
        let connection = Task { try await coordinator.connect(to: makeServer(id: 1), protocol: .ikev2, policy: .disabled) }
        await settle()
        ike.emit(.connected)
        ike.onAttemptEvent?(VPNAttemptEvent(attemptID: ike.attemptID, protocolName: .ikev2, phase: .connected))
        ike.completeConnect()
        try await connection.value
        #expect(coordinator.status == .connected)
        #expect(phases.last == .connected)
        _ = await coordinator.stopAndWait(releaseProtection: true)
    }

    @Test func initialStartupRecoveryDoesNotExtendTheOverallDeadline() async throws {
        let clock = ManualVPNClock()
        let ike = ControlledVPNManager()
        var scheduledDeadlines: [Duration] = []
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: ControlledVPNManager(),
            timing: VPNConnectionTiming(sleep: { duration in
                scheduledDeadlines.append(duration)
                try await clock.sleep(duration)
            }))
        var failures: [VPNConnectionFailure.Kind] = []
        coordinator.onAttemptEvent = { event in
            if let failure = event.failure { failures.append(failure.kind) }
        }
        try await coordinator.connect(to: makeServer(id: 1), protocol: .ikev2, policy: .disabled)
        await settle()
        #expect(scheduledDeadlines == [.seconds(30)])
        ike.onAttemptEvent?(VPNAttemptEvent(attemptID: ike.attemptID, protocolName: .ikev2, phase: .recoveringStartup))
        ike.onAttemptEvent?(VPNAttemptEvent(attemptID: ike.attemptID, protocolName: .ikev2, phase: .starting))
        await settle()
        #expect(scheduledDeadlines == [.seconds(30)])
        // This harness releases a requested-duration wait, rather than advancing
        // cumulative wall time. Release the original deadline after recovery.
        clock.advance(.seconds(30))
        await settle()
        #expect(failures == [.startupTimeout])
        #expect(ike.disconnectCalls == 1)
        #expect(coordinator.status == .disconnected)
    }

    @Test func approvalWaitingDoesNotConsumeStartupDeadline() async throws {
        let clock = ManualVPNClock()
        let ike = ControlledVPNManager()
        ike.holdConnect = true
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: ControlledVPNManager(),
            timing: VPNConnectionTiming(sleep: clock.sleep))
        let app = makeApp(manager: coordinator, servers: [try makeServer(id: 1)])
        app.requestConnectionToSelectedServer()
        await settle()
        clock.advance(.seconds(30))
        await settle()
        #expect(app.presentedError == nil)
        #expect(ike.disconnectCalls == 0)
        ike.completeConnect()
        await settle()
        clock.advance(.seconds(30))
        await settle()
        #expect(app.presentedError?.message == VPNConnectionFailure(kind: .startupTimeout).localizedDescription)
    }

    @Test func stopDeadlineRetainsCleanupLockAndBlocksNewStartUntilNativeCompletion() async throws {
        let clock = ManualVPNClock()
        let ike = ControlledVPNManager(status: .connected)
        ike.holdDisconnect = true
        let open = ControlledVPNManager()
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: open,
            timing: VPNConnectionTiming(sleep: clock.sleep))
        let stop = Task { await coordinator.stopAndWait(releaseProtection: true) }
        await settle()
        clock.advance(.seconds(10))
        #expect(await stop.value.isSafe == false)
        do {
            try await coordinator.connect(to: makeServer(id: 1), protocol: .openVPN, policy: .disabled)
            Issue.record("An unfinished cleanup must block another start")
        } catch { #expect((error as? VPNConnectionFailure)?.kind == .stopFailed) }
        #expect(open.connectCalls.isEmpty)
        ike.completeDisconnect()
        await settle()
        try await coordinator.connect(to: makeServer(id: 1), protocol: .openVPN, policy: .disabled)
        #expect(open.connectCalls.count == 1)
        _ = await coordinator.stopAndWait(releaseProtection: true)
    }

    @Test func failedStopBlocksQueuedStartAndRetryKeepsLatestServer() async throws {
        let ike = ControlledVPNManager()
        let coordinator = VPNManagerCoordinator(ikev2Manager: ike, openVPNManager: ControlledVPNManager())
        let app = makeApp(manager: coordinator, servers: [try makeServer(id: 1), try makeServer(id: 2)])
        app.requestConnectionToSelectedServer()
        await settle()
        ike.stopResultOverride = VPNStopResult(tunnelStopped: false, profileReleased: false)
        app.selectedServerID = 2
        app.requestConnectionToSelectedServer()
        await settle()
        #expect(ike.connectCalls.map(\.serverID) == [1])
        #expect(app.connectionRecoveryRequired)
        #expect(app.vpnRecoveryActionTitle == "Retry Cleanup")
        ike.stopResultOverride = nil
        app.retryVPNRecovery()
        await settle()
        #expect(ike.connectCalls.map(\.serverID) == [1, 2])
    }

    @Test func restoredConnectionCanRetryCleanupWithoutAConnectRequest() async throws {
        let manager = ControlledVPNManager(status: .connected)
        manager.stopResultOverride = VPNStopResult(tunnelStopped: false, profileReleased: false)
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)])
        app.requestVPNDisconnect()
        await settle()
        #expect(app.connectionRecoveryRequired)
        #expect(app.vpnRecoveryActionTitle == "Retry Cleanup")
        manager.stopResultOverride = nil
        app.retryVPNRecovery()
        await settle()
        #expect(manager.disconnectCalls == 1)
        #expect(manager.connectCalls.isEmpty)
        #expect(app.vpnStatus == .disconnected)
        #expect(!app.connectionRecoveryRequired)
    }

    @Test func notificationDenialDoesNotPreventVPNAndSettingsRefreshClearsNotice() async throws {
        let notifications = DeniedNotificationAuthorizer()
        let manager = ControlledVPNManager()
        let app = makeApp(manager: manager, servers: [try makeServer(id: 1)], notifications: notifications)
        app.requestConnectionToSelectedServer()
        await settle()
        #expect(manager.connectCalls.count == 1)
        #expect(app.notificationPermissionNotice?.contains("Notifications are off") == true)
        notifications.authorizationStatus = .authorized
        await app.refreshNotificationAuthorizationStatus()
        #expect(app.notificationPermissionNotice == nil)
    }

    private func makeApp(
        manager: VPNManaging,
        servers: [VPNServer],
        recorder: LocalStatisticsRecording? = nil,
        sampler: TunnelTrafficSampling = ScriptedTrafficSampler([]),
        eventNotifier: VPNEventNotifying? = nil,
        defaults: UserDefaults? = nil,
        notifications: VPNNotificationAuthorizing? = nil,
        backend: StartupBackendStub? = nil
    ) -> AppModel {
        let defaults = defaults ?? UserDefaults(suiteName: UUID().uuidString)!
        // Keep connection tests independent of the live quota endpoint.
        // The stub's immediate error exercises the documented fail-open path.
        let app = VPNTestFixtures.track(AppModel(
            api: backend ?? StartupBackendStub(storedSession: nil, restoreResults: []),
            vpnManager: manager,
            statisticsRecorder: recorder,
            trafficSampler: sampler,
            notificationService: notifications,
            eventNotifier: eventNotifier,
            defaults: defaults
        ), beforeDisconnect: { (manager as? ControlledVPNManager)?.completeDisconnect() })
        app.servers = servers
        app.selectedServerID = servers.first?.id
        return app
    }

    private func makeSubscription(isPro: Bool) throws -> SubscriptionStatus {
        try JSONDecoder().decode(
            SubscriptionStatus.self,
            from: JSONSerialization.data(withJSONObject: [
                "plan": isPro ? "Pro" : "Free",
                "isPro": isPro,
                "status": "active",
                "paymentType": NSNull(),
                "currentPeriodEnd": NSNull(),
                "cancelAtPeriodEnd": false,
                "billingCycle": "monthly",
                "activeDevices": 1,
                "maxDevices": isPro ? 3 : 1,
                "canAddDevice": true
            ])
        )
    }

    private func makeServer(id: Int, load: Int = 20) throws -> VPNServer {
        try JSONDecoder().decode(
            VPNServer.self,
            from: JSONSerialization.data(withJSONObject: [
                "id": id,
                "serverName": "DE-\(id)",
                "serverIp": "203.0.113.\(id)",
                "country": "Germany",
                "city": "Frankfurt",
                "linkSpeed": 1000,
                "pricingTier": "Free",
                "load": load,
                "activeConnections": NSNull(),
                "latencyPingPort": 5001,
                "loadDataFresh": true
            ])
        )
    }

    private func settle() async {
        for _ in 0..<40 {
            await Task.yield()
        }
    }

    private func makeSession(userId: String) -> AuthSession {
        AuthSession(
            accessToken: "access",
            refreshToken: "refresh",
            email: "\(userId)@example.com",
            userId: userId,
            deviceId: "device-1"
        )
    }
}

@MainActor
private final class ControlledVPNManager: VPNManaging {
    struct ConnectCall: Equatable {
        let serverID: Int
        let protocolName: VPNConfigurationProtocol
        let policy: VPNConnectionPolicy
    }

    var status: VPNConnectionState
    var connectedDate: Date?
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    var holdDisconnect = false
    var connectError: Error?
    var returnDisconnectedAfterStart = false
    var holdConnect = false
    var stopResultOverride: VPNStopResult?
    func stopAndWait(releaseProtection: Bool) async -> VPNStopResult {
        if let stopResultOverride { return stopResultOverride }
        await disconnect()
        return .stopped
    }
    var attemptID = UUID()
    var onAttemptEvent: ((VPNAttemptEvent) -> Void)?
    var connectedProtocol: VPNConfigurationProtocol? { status.isConnected || status.isBusy ? (connectCalls.last?.protocolName ?? .ikev2) : nil }
    private var connectContinuation: CheckedContinuation<Void, Never>?

    func setAttemptContext(_ id: UUID, protocol protocolName: VPNConfigurationProtocol) { attemptID = id }
    func completeConnect() {
        holdConnect = false
        connectContinuation?.resume()
        connectContinuation = nil
    }

    var trafficSnapshot: TunnelTrafficSnapshot?
    private(set) var connectCalls: [ConnectCall] = []
    private(set) var disconnectCalls = 0
    private(set) var policyUpdates: [VPNConnectionPolicy] = []
    private(set) var stoppedProfileRecoveryProtocols: [VPNConfigurationProtocol] = []
    var stoppedProfileRecoveryResult = VPNStoppedProfileRecoveryResult(
        isApplicable: true,
        routingReleased: true,
        onDemandDisabled: true,
        profileDisabled: true,
        diagnostic: nil
    )
    private var disconnectContinuation: CheckedContinuation<Void, Never>?

    init(status: VPNConnectionState = .disconnected) {
        self.status = status
        self.connectedDate = nil
        self.trafficSnapshot = nil
    }

    func refreshStatus() async {
        onStatusChange?(status)
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws {
        connectCalls.append(ConnectCall(serverID: server.id, protocolName: protocolName, policy: policy))
        status = .connecting
        onStatusChange?(status)
        if holdConnect {
            await withCheckedContinuation { connectContinuation = $0 }
            try Task.checkCancellation()
        }
        if let connectError {
            status = .disconnected
            onStatusChange?(status)
            throw connectError
        }
        if returnDisconnectedAfterStart {
            // Network Extension can still expose its old status immediately
            // after startVPNTunnel() returns. The later callback is authoritative.
            status = .disconnected
        }
    }

    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        policyUpdates.append(policy)
        return true
    }

    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot? {
        trafficSnapshot
    }

    func disconnect() async {
        disconnectCalls += 1
        status = .disconnecting
        onStatusChange?(status)

        if holdDisconnect {
            await withCheckedContinuation { continuation in
                disconnectContinuation = continuation
            }
        }

        status = .disconnected
        onStatusChange?(status)
    }

    func recoverStoppedProfile(
        for protocolName: VPNConfigurationProtocol
    ) async -> VPNStoppedProfileRecoveryResult {
        stoppedProfileRecoveryProtocols.append(protocolName)
        return stoppedProfileRecoveryResult
    }

    func disconnectAndForget() async -> VPNProfileCleanupResult {
        status = .disconnected
        onStatusChange?(status)
        return .noProfile
    }

    func completeDisconnect() {
        holdDisconnect = false
        disconnectContinuation?.resume()
        disconnectContinuation = nil
    }

    func emit(_ newStatus: VPNConnectionState) {
        status = newStatus
        onStatusChange?(status)
    }
}

@MainActor
private final class CleanupEventLog {
    var entries: [String] = []
}

@MainActor
private final class CleanupTrackingVPNManager: VPNManaging {
    let label: String
    let events: CleanupEventLog
    var status: VPNConnectionState = .disconnected
    var connectedDate: Date?
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?

    init(label: String, events: CleanupEventLog) {
        self.label = label
        self.events = events
    }

    func refreshStatus() async {}

    func connect(
        to server: VPNServer,
        protocol protocolName: VPNConfigurationProtocol,
        policy: VPNConnectionPolicy
    ) async throws {}

    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        true
    }

    func disconnect() async {
        status = .disconnected
        onStatusChange?(status)
    }

    func disableOnDemandAndProfile() async -> Bool {
        events.entries.append("\(label):disable")
        return true
    }

    func disconnectAndForget() async -> VPNProfileCleanupResult {
        events.entries.append("\(label):forget")
        status = .disconnected
        onStatusChange?(status)
        return .noProfile
    }
}

@MainActor
private final class DeniedNotificationAuthorizer: VPNNotificationAuthorizing {
    var authorizationStatus: UNAuthorizationStatus = .denied
    func refreshAuthorizationStatus() async {}
    func requestAuthorizationIfNeeded() async -> VPNNotificationAuthorizationOutcome { .denied }
    func openSystemSettings() {}
}

private enum StubConnectionError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Connection failed"
    }
}

@MainActor
private final class RecordingStatisticsRecorder: LocalStatisticsRecording {
    struct Record {
        let userId: String
        let connectedAt: Date
        let disconnectedAt: Date
        let server: VPNServer
        let protocolName: VPNConfigurationProtocol
        let downloadedBytes: Int64
        let uploadedBytes: Int64
    }

    private(set) var records: [Record] = []
    private(set) var clearedUserIDs: [String] = []

    func record(
        sessionID: UUID,
        userId: String,
        connectedAt: Date,
        disconnectedAt: Date,
        server: VPNServer,
        protocolName: VPNConfigurationProtocol,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) throws {
        records.append(
            Record(
                userId: userId,
                connectedAt: connectedAt,
                disconnectedAt: disconnectedAt,
                server: server,
                protocolName: protocolName,
                downloadedBytes: downloadedBytes,
                uploadedBytes: uploadedBytes
            )
        )
    }

    func clear(userId: String) throws {
        clearedUserIDs.append(userId)
    }
}

private final class ScriptedTrafficSampler: TunnelTrafficSampling {
    private var snapshots: [TunnelTrafficSnapshot]
    private var index = 0
    private var firstSnapshotWaiter: CheckedContinuation<Void, Never>?

    init(_ snapshots: [TunnelTrafficSnapshot]) {
        self.snapshots = snapshots
    }

    func waitForFirstSnapshot() async {
        guard index == 0, !snapshots.isEmpty else { return }
        await withCheckedContinuation { firstSnapshotWaiter = $0 }
    }

    func currentSnapshot() -> TunnelTrafficSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        if index == 1 {
            let waiter = firstSnapshotWaiter
            firstSnapshotWaiter = nil
            waiter?.resume()
        }
        return snapshot
    }
}

@MainActor
private final class RecordingVPNEventNotifier: VPNEventNotifying {
    private(set) var payloads: [VPNNotificationPayload] = []
    var events: [VPNNotificationEvent] { payloads.map(\.event) }

    func emit(_ payload: VPNNotificationPayload) async {
        payloads.append(payload)
    }
}
