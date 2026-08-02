import Foundation
import Testing
@testable import libreguard_vpn_ios

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
        #expect(manager.disconnectCalls == 1)
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
        await settle()

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
        await settle()

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
        await settle()
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

    private func makeApp(
        manager: VPNManaging,
        servers: [VPNServer],
        recorder: LocalStatisticsRecording? = nil,
        sampler: TunnelTrafficSampling = ScriptedTrafficSampler([]),
        eventNotifier: VPNEventNotifying? = nil,
        defaults: UserDefaults? = nil
    ) -> AppModel {
        let defaults = defaults ?? UserDefaults(suiteName: UUID().uuidString)!
        let app = AppModel(
            vpnManager: manager,
            statisticsRecorder: recorder,
            trafficSampler: sampler,
            eventNotifier: eventNotifier,
            defaults: defaults
        )
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
        for _ in 0..<8 {
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
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    var holdDisconnect = false
    var connectError: Error?
    private(set) var connectCalls: [ConnectCall] = []
    private(set) var disconnectCalls = 0
    private(set) var policyUpdates: [VPNConnectionPolicy] = []
    private var disconnectContinuation: CheckedContinuation<Void, Never>?

    init(status: VPNConnectionState = .disconnected) {
        self.status = status
    }

    func refreshStatus() async {
        onStatusChange?(status)
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws {
        connectCalls.append(ConnectCall(serverID: server.id, protocolName: protocolName, policy: policy))
        status = .connecting
        onStatusChange?(status)
        if let connectError {
            status = .disconnected
            onStatusChange?(status)
            throw connectError
        }
    }

    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        policyUpdates.append(policy)
        return true
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

    func disconnectAndForget() async {
        status = .disconnected
        onStatusChange?(status)
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

    init(_ snapshots: [TunnelTrafficSnapshot]) {
        self.snapshots = snapshots
    }

    func currentSnapshot() -> TunnelTrafficSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
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
