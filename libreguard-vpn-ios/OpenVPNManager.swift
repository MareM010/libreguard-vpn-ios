import Foundation
import NetworkExtension
import OSLog

@MainActor
final class OpenVPNManager: VPNManaging {
    private let api: BackendServicing
    private let deviceKeyStore: VPNDeviceKeyProviding
    private let protocolBuilder: OpenVPNTunnelProtocolBuilding
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
        protocolBuilder: OpenVPNTunnelProtocolBuilding = TunnelKitOpenVPNProtocolBuilder(),
        manager: NETunnelProviderManager = NETunnelProviderManager(),
        providerBundleIdentifier: String = OpenVPNConstants.tunnelBundleIdentifier
    ) {
        self.api = api
        self.deviceKeyStore = deviceKeyStore
        self.protocolBuilder = protocolBuilder
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

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol = .openVPN, policy: VPNConnectionPolicy = .disabled) async throws {
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
            try Task.checkCancellation()
            logger.debug("Backend OpenVPN configuration received for server \(server.id, privacy: .public)")

            if let expirationDate = response.expirationDate, expirationDate <= Date() {
                throw OpenVPNManagerError.expiredCertificate
            }

            let passphrase = try deviceKeyStore.decryptPassphrase(from: response.encryptedPassphrase)
            try Task.checkCancellation()
            let tunnelProtocol = try protocolBuilder.makeTunnelProtocol(
                configuration: response.configContent,
                privateKeyPassphrase: passphrase
            )
            try Task.checkCancellation()

            let serverAddress = tunnelProtocol.serverAddress ?? Self.fallbackServerAddress(response: response, server: server)
            tunnelProtocol.serverAddress = serverAddress
            try OpenVPNConnectionMetadataStore.save(
                OpenVPNConnectionMetadata(
                    serverId: server.id,
                    serverName: response.serverName,
                    serverAddress: serverAddress
                )
            )

            try await loadPreferences()
            try Task.checkCancellation()
            tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
            policy.apply(to: tunnelProtocol)

            manager.localizedDescription = "LibreGuard OpenVPN"
            manager.protocolConfiguration = tunnelProtocol
            manager.isEnabled = true
            applyOnDemandConfiguration(enabled: policy.onDemandEnabled)

            logger.debug("Saving OpenVPN preferences")
            try await savePreferences()
            try Task.checkCancellation()
            logger.debug("Reloading OpenVPN preferences before tunnel start")
            try await loadPreferences()
            try Task.checkCancellation()
            logger.debug("Starting OpenVPN tunnel")
            try manager.connection.startVPNTunnel()
            try Task.checkCancellation()
            logger.info("OpenVPN startVPNTunnel() returned without throwing")
            updateStatus(from: manager.connection.status)
        } catch is CancellationError {
            logger.info("OpenVPN connect request cancelled")
            status = .disconnecting
            manager.connection.stopVPNTunnel()
            await refreshStatus()
            throw CancellationError()
        } catch {
            logger.error("OpenVPN connect failed: \(Self.describe(error))")
            OpenVPNConnectionMetadataStore.clear()
            status = .disconnected
            throw error
        }
    }

    @discardableResult
    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        guard !isRunningInSimulator else { return false }
        try await loadPreferences()
        guard let tunnelProtocol = manager.protocolConfiguration else { return false }
        policy.apply(to: tunnelProtocol)
        applyOnDemandConfiguration(enabled: policy.onDemandEnabled)
        try await savePreferences()
        try await loadPreferences()
        return manager.protocolConfiguration?.includeAllNetworks == policy.killSwitchEnabled
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
        OpenVPNConnectionMetadataStore.clear()
        status = .disconnected
    }

    func fetchProviderDiagnostics() async throws -> OpenVPNRuntimeDiagnostics {
        let response = try await sendProviderMessage(type: .diagnostics)
        return response.diagnostics
    }

    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot? {
        guard status.isConnected,
              let providerSession = manager.connection as? NETunnelProviderSession else {
            return nil
        }

        do {
            let data = try await sendProviderMessage(Data([0xfe]), through: providerSession)
            guard data.count == 16 else { return nil }
            let inbound = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) }
            let outbound = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self) }
            return TunnelTrafficSnapshot(
                downloadedBytes: Int64(clamping: inbound),
                uploadedBytes: Int64(clamping: outbound)
            )
        } catch {
            return nil
        }
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

    private func applyOnDemandConfiguration(enabled: Bool) {
        manager.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : nil
        manager.isOnDemandEnabled = enabled
    }

    private func sendProviderMessage(type: OpenVPNProviderMessageType) async throws -> OpenVPNProviderResponse {
        let requestData = try JSONEncoder().encode(OpenVPNProviderRequest(type: type))
        guard let providerSession = manager.connection as? NETunnelProviderSession else {
            throw OpenVPNProviderMessageError.invalidMessage
        }
        let responseData = try await sendProviderMessage(requestData, through: providerSession)
        return try OpenVPNProviderMessageCodec.decodeResponse(from: responseData)
    }

    private func sendProviderMessage(
        _ requestData: Data,
        through providerSession: NETunnelProviderSession
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            do {
                try providerSession.sendProviderMessage(requestData) { data in
                    guard let data else {
                        continuation.resume(throwing: OpenVPNProviderMessageError.invalidMessage)
                        return
                    }
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(throwing: error)
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

    private static func fallbackServerAddress(response: VPNConfigResponse, server: VPNServer) -> String {
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
    case expiredCertificate

    var errorDescription: String? {
        switch self {
        case let .unsupportedProtocol(protocolName):
            return "OpenVPNManager only supports OpenVPN. Received \(protocolName)."
        case .expiredCertificate:
            return "The OpenVPN certificate has expired."
        }
    }
}
