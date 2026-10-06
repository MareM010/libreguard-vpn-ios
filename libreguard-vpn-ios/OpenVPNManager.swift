import Foundation
import Network
import NetworkExtension
import OSLog

@MainActor
final class OpenVPNManager: VPNManaging {
    private let api: BackendServicing
    private let configurationResolver: VPNConfigurationResolving
    private let deviceKeyStore: VPNDeviceKeyProviding
    private let protocolBuilder: OpenVPNTunnelProtocolBuilding
    private let manager: NETunnelProviderManager
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "libreguard-vpn-ios",
        category: "OpenVPN"
    )
    private let providerBundleIdentifierOverride: String?
    private var statusObserver: NSObjectProtocol?
    private let preferencesAccess: VPNPreferencesAccess
    private let timing: VPNConnectionTiming
    private var attemptID = UUID()
    private var phase: VPNAttemptPhase = .preparing
    private var lifecycleGeneration: UInt = 0
    private var expectedStop = false
    private var isPreparing = false


    var status: VPNConnectionState = .disconnected {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }

    var connectedDate: Date? {
        manager.connection.connectedDate
    }

    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    var onAttemptEvent: ((VPNAttemptEvent) -> Void)?
    var connectedProtocol: VPNConfigurationProtocol? { status.isConnected || status.isBusy ? .openVPN : nil }
    var protectionIsInstalled: Bool {
        manager.isEnabled && manager.protocolConfiguration?.includeAllNetworks == true
    }

    func setAttemptContext(_ id: UUID, protocol protocolName: VPNConfigurationProtocol) {
        attemptID = id
        lifecycleGeneration &+= 1
        expectedStop = false
    }

    private func publish(_ phase: VPNAttemptPhase) {
        self.phase = phase
        onAttemptEvent?(VPNAttemptEvent(attemptID: attemptID, protocolName: .openVPN, phase: phase))
    }


    init(
        api: BackendServicing,
        resolver: VPNConfigurationResolving? = nil,
        deviceKeyStore: VPNDeviceKeyProviding = VPNDeviceKeyStore(),
        protocolBuilder: OpenVPNTunnelProtocolBuilding = TunnelKitOpenVPNProtocolBuilder(),
        manager: NETunnelProviderManager = NETunnelProviderManager(),
        providerBundleIdentifier: String? = nil,
        preferencesAccess: VPNPreferencesAccess? = nil,
        timing: VPNConnectionTiming = VPNConnectionTiming()
    ) {
        self.api = api
        self.configurationResolver = resolver ?? VPNConfigurationResolver(api: api)
        self.deviceKeyStore = deviceKeyStore
        self.protocolBuilder = protocolBuilder
        self.manager = manager
        self.preferencesAccess = preferencesAccess ?? VPNPreferencesAccess()
        self.timing = timing
        self.providerBundleIdentifierOverride = providerBundleIdentifier
        observeStatusChanges()
    }

    func setCertificatePreparationHandler(_ handler: ((String?) -> Void)?) {
        configurationResolver.onPreparationStateChange = handler
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
            try await preferencesAccess.withExclusiveAccess { try await self.loadPreferences() }
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
        expectedStop = false
        isPreparing = true
        publish(.preparing)
        defer { isPreparing = false }

        do {
            logger.debug("Resolving OpenVPN configuration from backend")
            let response = try await configurationResolver.resolve(serverId: server.id, protocol: .openVPN)
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
            let resolvedAddresses = Self.applyResolvedAddresses(
                to: tunnelProtocol,
                response: response,
                server: server
            )
            if !resolvedAddresses.isEmpty {
                logger.debug("OpenVPN will use DNS first with backend-resolved IPv4 fallback endpoint(s): \(resolvedAddresses, privacy: .public)")
            }
            try OpenVPNConnectionMetadataStore.save(
                OpenVPNConnectionMetadata(
                    serverId: server.id,
                    serverName: response.serverName,
                    serverAddress: serverAddress
                )
            )

            let providerBundleIdentifier = try resolvedProviderBundleIdentifier()
            try await preferencesAccess.withExclusiveAccess {
                try await self.loadPreferences()
                try Task.checkCancellation()
                try await self.removeStaleProviderConfiguration(ifProviderIdentifierDiffersFrom: providerBundleIdentifier)
                tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
                policy.apply(to: tunnelProtocol)

                self.manager.localizedDescription = "LibreGuard OpenVPN"
                self.manager.protocolConfiguration = tunnelProtocol
                self.manager.isEnabled = true
                self.applyOnDemandConfiguration(enabled: policy.onDemandEnabled)

                self.logger.debug("Saving OpenVPN preferences")
                self.publish(.awaitingApproval)
                try await self.savePreferences()
                try Task.checkCancellation()
                self.publish(.starting)
                try await IKEv2TunnelStarter.start(
                    reload: {
                        try await self.loadPreferences()
                        try self.verifySavedProviderConfiguration(expectedIdentifier: providerBundleIdentifier)
                    },
                    startTunnel: {
                        try self.manager.connection.startVPNTunnel(options: ["LibreGuardAttemptID": self.attemptID.uuidString as NSString])
                    }
                )
            }
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
            if phase == .preparing { throw error }
            throw VPNConnectionFailure.classify(error, phase: phase)
        }
    }

    @discardableResult
    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        guard !isRunningInSimulator else { return false }
        return try await preferencesAccess.withExclusiveAccess {
            try await self.loadPreferences()
            guard let tunnelProtocol = self.manager.protocolConfiguration else { return false }
            policy.apply(to: tunnelProtocol)
            self.applyOnDemandConfiguration(enabled: policy.onDemandEnabled)
            try await self.savePreferences()
            try await self.loadPreferences()
            return self.manager.protocolConfiguration?.includeAllNetworks == policy.killSwitchEnabled
                && self.manager.isOnDemandEnabled == policy.onDemandEnabled
        }
    }

    func disconnect() async {
        _ = await stopAndWait(releaseProtection: false)
    }

    func stopAndWait(releaseProtection: Bool) async -> VPNStopResult {
        expectedStop = true
        lifecycleGeneration &+= 1
        publish(.stopping)
        guard !isRunningInSimulator else { status = .disconnected; return .stopped }
        status = .disconnecting
        manager.connection.stopVPNTunnel()
        let released = releaseProtection ? await disableOnDemandAndProfile() : true
        // Disable persisted pending starts before accepting a later request.
        manager.connection.stopVPNTunnel()
        let stopped = await waitForTunnelToStop()
        return VPNStopResult(tunnelStopped: stopped, profileReleased: released)
    }

    @discardableResult
    func disableOnDemandAndProfile() async -> Bool {
        guard !isRunningInSimulator else { return true }
        do {
            return try await preferencesAccess.withExclusiveAccess {
                await self.disableOnDemandAndProfileWithExclusiveAccess()
            }
        } catch { return false }
    }

    private func disableOnDemandAndProfileWithExclusiveAccess() async -> Bool {

        do {
            try await loadPreferences()
            guard manager.protocolConfiguration != nil else { return true }

            if let profile = manager.protocolConfiguration {
                VPNConnectionPolicy.disabled.apply(to: profile)
            }
            manager.onDemandRules = nil
            manager.isOnDemandEnabled = false
            manager.isEnabled = false
            try await savePreferences()
            try await loadPreferences()

            let hasNoOnDemandRules = manager.onDemandRules?.isEmpty ?? true
            let disabled = !manager.isOnDemandEnabled && !manager.isEnabled && hasNoOnDemandRules
                && manager.protocolConfiguration?.includeAllNetworks != true
                && manager.protocolConfiguration?.enforceRoutes != true
            if !disabled {
                logger.error("OpenVPN profile remained enabled after disabling on-demand")
            }
            return disabled
        } catch {
            logger.error("Failed to disable OpenVPN on-demand profile: \(Self.describe(error))")
            return false
        }
    }

    func disconnectAndForget() async -> VPNProfileCleanupResult {
        logger.info("OpenVPN disconnect-and-forget requested")
        guard !isRunningInSimulator else {
            status = .disconnected
            return .noProfile
        }

        let onDemandDisabled = await disableOnDemandAndProfile()
        manager.connection.stopVPNTunnel()

        let tunnelStopped = await waitForTunnelToStop()
        guard tunnelStopped else {
            let diagnostic = "iOS did not confirm that the OpenVPN tunnel stopped."
            logger.error("\(diagnostic, privacy: .public)")
            return VPNProfileCleanupResult(
                tunnelStopped: false,
                onDemandDisabled: onDemandDisabled,
                profileRemoved: false,
                diagnostic: diagnostic
            )
        }

        do {
            try await preferencesAccess.withExclusiveAccess {
                try await self.loadPreferences()
                try await self.removePreferences()
                try await self.loadPreferences()
            }
            OpenVPNConnectionMetadataStore.clear()
            status = VPNConnectionState(networkExtensionStatus: manager.connection.status)
            let result = VPNProfileCleanupResult(
                tunnelStopped: true,
                onDemandDisabled: onDemandDisabled,
                profileRemoved: true,
                diagnostic: nil
            )
            logger.info("OpenVPN profile cleanup stopped=\(result.tunnelStopped, privacy: .public) onDemandDisabled=\(result.onDemandDisabled, privacy: .public) removed=\(result.profileRemoved, privacy: .public)")
            return result
        } catch {
            let diagnostic = "OpenVPN profile could not be removed after stopping."
            logger.error("\(diagnostic, privacy: .public) \(Self.describe(error))")
            status = VPNConnectionState(networkExtensionStatus: manager.connection.status)
            let result = VPNProfileCleanupResult(
                tunnelStopped: true,
                onDemandDisabled: onDemandDisabled,
                profileRemoved: false,
                diagnostic: diagnostic
            )
            logger.info("OpenVPN profile cleanup stopped=\(result.tunnelStopped, privacy: .public) onDemandDisabled=\(result.onDemandDisabled, privacy: .public) removed=\(result.profileRemoved, privacy: .public)")
            return result
        }
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
                if self.status == .connected { self.publish(.connected) }
                if previous != .disconnected, self.status == .disconnected, !self.expectedStop {
                    let generation = self.lifecycleGeneration
                    let id = self.attemptID
                    let packetError = VPNSharedSessionStore.loadTunnelError()
                    VPNSharedSessionStore.clearTunnelError()
                    let tunnelKitError = Self.loadTunnelKitLastError()
                    self.manager.connection.fetchLastDisconnectError { error in
                        Task { @MainActor [weak self] in
                            guard let self, generation == self.lifecycleGeneration,
                                  id == self.attemptID, !self.expectedStop,
                                  self.status == .disconnected else { return }
                            if let description = packetError ?? tunnelKitError {
                                let providerError = NSError(domain: "OpenVPNPacketTunnel", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: description])
                                self.onDisconnectError?(VPNConnectionFailure.classify(providerError, phase: self.phase))
                            } else if let error {
                                self.onDisconnectError?(VPNConnectionFailure.classify(error, phase: self.phase))
                            } else {
                                self.logger.info("OpenVPN tunnel stopped without a NetworkExtension error")
                            }
                        }
                    }
                }
            }
        }
    }

    private func applyOnDemandConfiguration(enabled: Bool) {
        manager.onDemandRules = enabled ? [NEOnDemandRuleConnect()] : nil
        manager.isOnDemandEnabled = enabled
    }

    private func waitForTunnelToStop(maximumAttempts: Int? = nil) async -> Bool {
        let seconds = Double(timing.stop.components.seconds) + Double(timing.stop.components.attoseconds) / 1e18
        let maximumAttempts = maximumAttempts ?? max(0, Int(ceil(seconds / 0.2)))
        for attempt in 0...maximumAttempts {
            let observedStatus = VPNConnectionState(networkExtensionStatus: manager.connection.status)
            if observedStatus == .disconnected || observedStatus == .invalid {
                status = observedStatus
                return true
            }

            guard attempt < maximumAttempts else {
                status = observedStatus
                return false
            }
            try? await timing.sleep(.milliseconds(200))
        }
        return false
    }

    private func resolvedProviderBundleIdentifier() throws -> String {
        if let providerBundleIdentifierOverride {
            return providerBundleIdentifierOverride
        }

        guard let embeddedIdentifier = OpenVPNConstants.embeddedTunnelBundleIdentifier() else {
            throw OpenVPNManagerError.packetTunnelExtensionNotEmbedded
        }

        logger.debug("Using embedded OpenVPN packet-tunnel provider \(embeddedIdentifier, privacy: .public)")
        return embeddedIdentifier
    }

    private func removeStaleProviderConfiguration(ifProviderIdentifierDiffersFrom expectedIdentifier: String) async throws {
        guard let existingProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
              existingProtocol.providerBundleIdentifier != expectedIdentifier else {
            return
        }

        let existingIdentifier = existingProtocol.providerBundleIdentifier ?? "<missing>"

        logger.warning(
            "Removing stale OpenVPN provider configuration \(existingIdentifier, privacy: .public); expected \(expectedIdentifier, privacy: .public)"
        )
        try await removePreferences()
        try await loadPreferences()
    }

    private func verifySavedProviderConfiguration(expectedIdentifier: String) throws {
        guard let savedProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw OpenVPNManagerError.providerConfigurationUnavailable(expected: expectedIdentifier, actual: nil)
        }

        guard savedProtocol.providerBundleIdentifier == expectedIdentifier else {
            throw OpenVPNManagerError.providerConfigurationUnavailable(
                expected: expectedIdentifier,
                actual: savedProtocol.providerBundleIdentifier
            )
        }
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
        try await VPNCallbackDeadline.run(timeout: timing.providerMessage, sleep: timing.sleep) { complete in
            try providerSession.sendProviderMessage(requestData) { data in
                if let data { complete(.success(data)) }
                else { complete(.failure(OpenVPNProviderMessageError.invalidMessage)) }
            }
        }
    }

    private func updateStatus(from neStatus: NEVPNStatus) {
        if neStatus == .connecting || neStatus == .reasserting {
            onAttemptEvent?(VPNAttemptEvent(attemptID: attemptID, protocolName: .openVPN,
                phase: .starting, nativeStartupObserved: true))
        }
        let mappedStatus = VPNConnectionState(networkExtensionStatus: neStatus)
        if isPreparing, mappedStatus == .disconnected || mappedStatus == .invalid { return }
        if mappedStatus.isConnected, !hasIPv6BlockingConfiguration {
            logger.error("Refusing to report OpenVPN connected without IPv6 blocking configuration")
            manager.connection.stopVPNTunnel()
            status = .disconnecting
            return
        }
        status = mappedStatus
    }

    private var hasIPv6BlockingConfiguration: Bool {
        guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfiguration = tunnelProtocol.providerConfiguration else {
            return false
        }
        return OpenVPNIPv6Protection.isEnabled(in: providerConfiguration)
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

    internal static func preferredResolvedAddresses(response: VPNConfigResponse, server: VPNServer) -> [String] {
        var addresses: [String] = []
        for candidate in [response.serverIp, server.serverIp] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            // TunnelKit's resolvedAddresses path treats every entry as IPv4.
            // Never force a hostname, URL, port-qualified address, or IPv6
            // address through that path; use normal DNS resolution instead.
            guard IPv4Address(trimmed) != nil, !addresses.contains(trimmed) else { continue }
            addresses.append(trimmed)
        }
        return addresses
    }

    @discardableResult
    private static func applyResolvedAddresses(
        to tunnelProtocol: NETunnelProviderProtocol,
        response: VPNConfigResponse,
        server: VPNServer
    ) -> [String] {
        let resolvedAddresses = preferredResolvedAddresses(response: response, server: server)
        guard !resolvedAddresses.isEmpty else { return [] }

        var providerConfiguration = tunnelProtocol.providerConfiguration ?? [:]
        // Keep the hostname from the .ovpn profile as the primary endpoint.
        // The backend IPs are fallback addresses only: forcing them as the
        // sole endpoint can break servers whose certificate, NAT, or OpenVPN
        // listener is tied to the profile's hostname.
        providerConfiguration["prefersResolvedAddresses"] = false
        providerConfiguration["resolvedAddresses"] = resolvedAddresses
        tunnelProtocol.providerConfiguration = providerConfiguration
        return resolvedAddresses
    }

    nonisolated private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var details = ["\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"]
        for key in [NSLocalizedFailureReasonErrorKey, NSLocalizedRecoverySuggestionErrorKey] {
            if let value = nsError.userInfo[key] as? String, !value.isEmpty {
                details.append(value)
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("underlying \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)")
        }
        return details.joined(separator: " | ")
    }

    private static func loadTunnelKitLastError() -> String? {
        UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier)?
            .string(forKey: "TunnelKitLastError")
    }

    private static func loadTunnelKitDebugLogTail() -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: VPNSharedConstants.appGroupIdentifier
        ) else {
            return nil
        }
        let logURL = containerURL.appendingPathComponent("debug.log")
        guard let log = try? String(contentsOf: logURL), !log.isEmpty else {
            return nil
        }
        return String(log.suffix(8_000))
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
    case packetTunnelExtensionNotEmbedded
    case providerConfigurationUnavailable(expected: String, actual: String?)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProtocol(protocolName):
            return "OpenVPNManager only supports OpenVPN. Received \(protocolName)."
        case .expiredCertificate:
            return "The OpenVPN certificate has expired."
        case .packetTunnelExtensionNotEmbedded:
            return "The OpenVPN packet-tunnel extension is not embedded in this app build. Reinstall the latest LibreGuard app build."
        case let .providerConfigurationUnavailable(expected, actual):
            let actualDescription = actual ?? "missing"
            return "The OpenVPN provider configuration could not be saved (expected \(expected), got \(actualDescription))."
        }
    }
}
