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

    private func makeApp(manager: ControlledVPNManager, servers: [VPNServer]) -> AppModel {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let app = AppModel(vpnManager: manager, defaults: defaults)
        app.servers = servers
        app.selectedServerID = servers.first?.id
        return app
    }

    private func makeServer(id: Int) throws -> VPNServer {
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
                "load": 20,
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
}

@MainActor
private final class ControlledVPNManager: VPNManaging {
    struct ConnectCall: Equatable {
        let serverID: Int
        let protocolName: VPNConfigurationProtocol
    }

    var status: VPNConnectionState
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    var holdDisconnect = false
    var connectError: Error?
    private(set) var connectCalls: [ConnectCall] = []
    private(set) var disconnectCalls = 0
    private var disconnectContinuation: CheckedContinuation<Void, Never>?

    init(status: VPNConnectionState = .disconnected) {
        self.status = status
    }

    func refreshStatus() async {
        onStatusChange?(status)
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol) async throws {
        connectCalls.append(ConnectCall(serverID: server.id, protocolName: protocolName))
        status = .connecting
        onStatusChange?(status)
        if let connectError {
            status = .disconnected
            onStatusChange?(status)
            throw connectError
        }
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
