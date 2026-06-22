import Foundation
import NetworkExtension
import OSLog

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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "libreguard-vpn-ios",
        category: "VPN"
    )
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
        guard !isRunningInSimulator else {
            logger.info("Skipping VPN status refresh in the iOS Simulator")
            status = .disconnected
            return
        }

        do {
            logger.debug("Loading VPN preferences for status refresh")
            try await loadPreferences()
            logger.debug("VPN status refresh completed with status \(self.manager.connection.status.rawValue, privacy: .public)")
            updateStatus(from: manager.connection.status)
        } catch {
            logger.error("VPN status refresh failed: \(Self.describe(error))")
            status = .disconnected
        }
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol = .ikev2) async throws {
        logger.info("VPN connect requested for server \(server.id, privacy: .public) using protocol \(protocolName.rawValue, privacy: .public)")

        guard !isRunningInSimulator else {
            logger.error("VPN connections are not supported in the iOS Simulator")
            status = .disconnected
            throw VPNManagerError.simulatorUnsupported
        }

        status = .connecting

        do {
            logger.debug("Fetching VPN configuration from backend")
            let response = try await api.fetchVPNConfig(serverId: server.id, protocol: protocolName)
            logger.debug("Backend VPN configuration received for server \(server.id, privacy: .public)")
            let vpnProtocol = try translator.makeProtocol(server: server, response: response)
            let serverAddress = String(describing: vpnProtocol.serverAddress)
            let remoteIdentifier = String(describing: vpnProtocol.remoteIdentifier)
            let localIdentifier = String(describing: vpnProtocol.localIdentifier)
            let configSummary = "serverAddress=\(serverAddress) remoteIdentifier=\(remoteIdentifier) localIdentifier=\(localIdentifier) includeAllNetworks=\(vpnProtocol.includeAllNetworks)"
            logger.debug("Translated VPN config \(configSummary, privacy: .public)")

            try await loadPreferences()
            logger.debug("Loaded existing VPN preferences")
            manager.localizedDescription = "LibreGuard"
            manager.protocolConfiguration = vpnProtocol
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil
            logger.debug("Saving VPN preferences")
            try await savePreferences()
            logger.debug("Reloading VPN preferences before tunnel start")
            try await loadPreferences()
            logger.debug("Starting VPN tunnel")
            try manager.connection.startVPNTunnel()
            logger.info("startVPNTunnel() returned without throwing")
            updateStatus(from: manager.connection.status)
        } catch {
            logger.error("VPN connect failed: \(Self.describe(error))")
            status = .disconnected
            throw error
        }
    }

    func disconnect() async {
        logger.info("VPN disconnect requested")
        status = .disconnecting
        manager.connection.stopVPNTunnel()
        await refreshStatus()
    }

    func disconnectAndForget() async {
        logger.info("VPN disconnect-and-forget requested")
        manager.connection.stopVPNTunnel()
        do {
            try await removePreferences()
        } catch {
            logger.error("Failed to remove VPN preferences during disconnect: \(Self.describe(error))")
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.status
                self.updateStatus(from: self.manager.connection.status)
                if previous != .disconnected, self.status == .disconnected {
                    self.manager.connection.fetchLastDisconnectError(completionHandler: { error in
                        guard let error else { return }
                        Task { @MainActor in
                            self.onDisconnectError?(error)
                        }
                    })
                }
            }
        }
    }

    private func updateStatus(from neStatus: NEVPNStatus) {
        status = VPNConnectionState(networkExtensionStatus: neStatus)
    }

    private func loadPreferences() async throws {
        let logger = logger
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences(completionHandler: { error in
                if let error {
                    logger.error("loadFromPreferences() failed: \(Self.describe(error))")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func savePreferences() async throws {
        let logger = logger
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences(completionHandler: { error in
                if let error {
                    logger.error("saveToPreferences() failed: \(Self.describe(error))")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func removePreferences() async throws {
        let logger = logger
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences(completionHandler: { error in
                if let error {
                    logger.error("removeFromPreferences() failed: \(Self.describe(error))")
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private var isRunningInSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
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

enum VPNManagerError: LocalizedError {
    case simulatorUnsupported

    var errorDescription: String? {
        switch self {
        case .simulatorUnsupported:
            return "VPN connections are not supported in the iOS Simulator. Run the app on a physical device to test the tunnel."
        }
    }
}
