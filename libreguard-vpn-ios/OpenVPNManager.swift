import Foundation
import NetworkExtension
import OSLog

@MainActor
final class OpenVPNManager: VPNManaging {
    private let api: BackendServicing
    private let deviceKeyStore: VPNDeviceKeyProviding
    private let profileStore: OpenVPNProfileEnvelopeStoring
    private let manager: NETunnelProviderManager
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "libreguard-vpn-ios",
        category: "OpenVPN"
    )
    private let providerBundleIdentifier: String
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
        deviceKeyStore: VPNDeviceKeyProviding = VPNDeviceKeyStore(),
        profileStore: OpenVPNProfileEnvelopeStoring = OpenVPNProfileEnvelopeStore(),
        manager: NETunnelProviderManager = NETunnelProviderManager(),
        providerBundleIdentifier: String = OpenVPNConstants.tunnelBundleIdentifier
    ) {
        self.api = api
        self.deviceKeyStore = deviceKeyStore
        self.profileStore = profileStore
        self.manager = manager
        self.providerBundleIdentifier = providerBundleIdentifier
        observeStatusChanges()
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refreshStatus() async {
        guard !isRunningInSimulator else {
            logger.info("Skipping OpenVPN status refresh in the iOS Simulator")
            status = .disconnected
            return
        }

        do {
            logger.debug("Loading OpenVPN preferences for status refresh")
            try await loadPreferences()
            logger.debug("OpenVPN status refresh completed with status \(self.manager.connection.status.rawValue, privacy: .public)")
            updateStatus(from: manager.connection.status)
        } catch {
            logger.error("OpenVPN status refresh failed: \(Self.describe(error))")
            status = .disconnected
        }
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol = .openVPN) async throws {
        logger.info("OpenVPN connect requested for server \(server.id, privacy: .public) using protocol \(protocolName.rawValue, privacy: .public)")

        guard protocolName == .openVPN else {
            throw OpenVPNManagerError.unsupportedProtocol(protocolName.rawValue)
        }

        guard !isRunningInSimulator else {
            logger.error("OpenVPN connections are not supported in the iOS Simulator")
            status = .disconnected
            throw VPNManagerError.simulatorUnsupported
        }

        status = .connecting

        do {
            logger.debug("Fetching OpenVPN configuration from backend")
            let response = try await api.fetchVPNConfig(serverId: server.id, protocol: .openVPN)
            logger.debug("Backend OpenVPN configuration received for server \(server.id, privacy: .public)")
            let profile = try OpenVPNProfileConfiguration.parse(response.configContent)
            try profile.validateMobileCompatibility()

            if let expirationDate = response.expirationDate, expirationDate <= Date() {
                throw OpenVPNProfileError.expiredCertificate
            }

            let passphrase = try deviceKeyStore.decryptPassphrase(from: response.encryptedPassphrase)
            let serverAddress = Self.resolveServerAddress(from: profile, response: response, server: server)
            let envelope = OpenVPNProfileEnvelope(
                serverId: server.id,
                serverName: response.serverName,
                serverAddress: serverAddress,
                certificateName: response.certificateName,
                issueDate: response.issueDate,
                expirationDate: response.expirationDate,
                configContent: response.configContent,
                privateKeyPassphrase: passphrase
            )

            let persistentReference = try profileStore.save(envelope)

            try await loadPreferences()
            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
            tunnelProtocol.serverAddress = serverAddress
            tunnelProtocol.passwordReference = persistentReference
            tunnelProtocol.providerConfiguration = [
                "schemaVersion": NSNumber(value: envelope.schemaVersion),
                "serverId": NSNumber(value: envelope.serverId),
                "serverName": envelope.serverName as NSString,
                "serverAddress": envelope.serverAddress as NSString
            ]

            manager.localizedDescription = "LibreGuard OpenVPN"
            manager.protocolConfiguration = tunnelProtocol
            manager.isEnabled = true
            manager.isOnDemandEnabled = false
            manager.onDemandRules = nil

            logger.debug("Saving OpenVPN preferences")
            try await savePreferences()
            logger.debug("Reloading OpenVPN preferences before tunnel start")
            try await loadPreferences()
            logger.debug("Starting OpenVPN tunnel")
            try manager.connection.startVPNTunnel()
            logger.info("OpenVPN startVPNTunnel() returned without throwing")
            updateStatus(from: manager.connection.status)
        } catch {
            logger.error("OpenVPN connect failed: \(Self.describe(error))")
            status = .disconnected
            throw error
        }
    }

    func disconnect() async {
        logger.info("OpenVPN disconnect requested")
        status = .disconnecting
        manager.connection.stopVPNTunnel()
        await refreshStatus()
    }

    func disconnectAndForget() async {
        logger.info("OpenVPN disconnect-and-forget requested")
        manager.connection.stopVPNTunnel()
        do {
            try await removePreferences()
        } catch {
            logger.error("Failed to remove OpenVPN preferences during disconnect: \(Self.describe(error))")
        }
        profileStore.clear()
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
                    logger.error("OpenVPN loadFromPreferences() failed: \(Self.describe(error))")
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
                    logger.error("OpenVPN saveToPreferences() failed: \(Self.describe(error))")
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
                    logger.error("OpenVPN removeFromPreferences() failed: \(Self.describe(error))")
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

    private static func resolveServerAddress(from profile: OpenVPNProfileConfiguration, response: VPNConfigResponse, server: VPNServer) -> String {
        if let remoteHost = profile.remoteEndpoints.first?.host.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteHost.isEmpty {
            return remoteHost
        }

        if let hostname = server.serverHostname?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostname.isEmpty {
            return hostname
        }

        let responseServerIp = response.serverIp.trimmingCharacters(in: .whitespacesAndNewlines)
        if !responseServerIp.isEmpty {
            return responseServerIp
        }

        let serverIp = server.serverIp.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverIp.isEmpty {
            return serverIp
        }

        let responseServerName = response.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !responseServerName.isEmpty {
            return responseServerName
        }

        return server.serverName
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

enum OpenVPNManagerError: LocalizedError {
    case unsupportedProtocol(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProtocol(protocolName):
            return "OpenVPNManager only supports OpenVPN. Received \(protocolName)."
        }
    }
}
