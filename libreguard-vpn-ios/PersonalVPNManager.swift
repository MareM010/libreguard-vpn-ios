import Foundation
import NetworkExtension

@MainActor
protocol VPNManaging: AnyObject {
    var status: VPNConnectionState { get }
    var onStatusChange: ((VPNConnectionState) -> Void)? { get set }
    var onDisconnectError: ((Error) -> Void)? { get set }

    func refreshStatus() async
    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol) async throws
    func disconnect() async
    func disconnectAndForget() async
}

@MainActor
final class PersonalVPNManager: VPNManaging {
    private let api: BackendServicing
    private let translator: VPNConfigurationTranslator
    private let manager: NEVPNManager
    private var statusObserver: NSObjectProtocol?

    var status: VPNConnectionState = .disconnected {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }

    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?

    init(
        api: BackendServicing,
        translator: VPNConfigurationTranslator? = nil,
        manager: NEVPNManager = .shared()
    ) {
        self.api = api
        self.translator = translator ?? VPNConfigurationTranslator()
        self.manager = manager
        observeStatusChanges()
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refreshStatus() async {
        do {
            try await loadPreferences()
            updateStatus(from: manager.connection.status)
        } catch {
            status = .disconnected
        }
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol = .ikev2) async throws {
        status = .connecting

        do {
            let response = try await api.fetchVPNConfig(serverId: server.id, protocol: protocolName)
            let vpnProtocol = try translator.makeProtocol(server: server, response: response)
            try await loadPreferences()
            manager.localizedDescription = "LibreGuard"
            manager.protocolConfiguration = vpnProtocol
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil
            try await savePreferences()
            try await loadPreferences()
            try manager.connection.startVPNTunnel()
            updateStatus(from: manager.connection.status)
        } catch {
            status = .disconnected
            throw error
        }
    }

    func disconnect() async {
        status = .disconnecting
        manager.connection.stopVPNTunnel()
        await refreshStatus()
    }

    func disconnectAndForget() async {
        manager.connection.stopVPNTunnel()
        do {
            try await removePreferences()
        } catch {
            // Clearing the session should not be blocked by preference cleanup.
        }
        status = .disconnected
    }

    private func observeStatusChanges() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let previous = self.status
            self.updateStatus(from: self.manager.connection.status)
            if previous != .disconnected, self.status == .disconnected {
                self.manager.connection.fetchLastDisconnectError(completionHandler: { error in
                    if let error {
                        self.onDisconnectError?(error)
                    }
                })
            }
        }
    }

    private func updateStatus(from neStatus: NEVPNStatus) {
        status = VPNConnectionState(networkExtensionStatus: neStatus)
    }

    private func loadPreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences(completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func savePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences(completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func removePreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences(completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

private extension VPNConnectionState {
    init(networkExtensionStatus: NEVPNStatus) {
        switch networkExtensionStatus {
        case .invalid:
            self = .invalid
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reasserting:
            self = .reasserting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            self = .invalid
        }
    }
}
