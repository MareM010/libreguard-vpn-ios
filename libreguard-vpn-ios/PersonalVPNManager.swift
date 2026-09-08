import Foundation
import NetworkExtension
import OSLog

@MainActor
protocol VPNManaging: AnyObject {
    var status: VPNConnectionState { get }
    var connectedDate: Date? { get }
    var onStatusChange: ((VPNConnectionState) -> Void)? { get set }
    var onDisconnectError: ((Error) -> Void)? { get set }

    func setCertificatePreparationHandler(_ handler: ((String?) -> Void)?)

    func refreshStatus() async
    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws
    @discardableResult func apply(policy: VPNConnectionPolicy) async throws -> Bool
    func disconnect() async
    /// Persistently disables system on-demand behavior before an account session
    /// is discarded. Coordinators call this on every managed profile before
    /// asking either tunnel to stop.
    @discardableResult func disableOnDemandAndProfile() async -> Bool
    @discardableResult func disconnectAndForget() async -> VPNProfileCleanupResult
    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot?
}

extension VPNManaging {
    var connectedDate: Date? { nil }
    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot? { nil }
    func setCertificatePreparationHandler(_ handler: ((String?) -> Void)?) {}
    @discardableResult func disableOnDemandAndProfile() async -> Bool { true }
}

/// The result of removing a persisted Network Extension profile. A profile that
/// could not be removed is still safe to leave behind only when its on-demand
/// behavior was disabled and its tunnel has actually stopped.
struct VPNProfileCleanupResult: Equatable, Sendable {
    let tunnelStopped: Bool
    let onDemandDisabled: Bool
    let profileRemoved: Bool
    let diagnostic: String?

    static let noProfile = VPNProfileCleanupResult(
        tunnelStopped: true,
        onDemandDisabled: true,
        profileRemoved: true,
        diagnostic: nil
    )

    var isSafeForUnauthenticatedLogin: Bool {
        tunnelStopped && (onDemandDisabled || profileRemoved)
    }

    static func combined(_ results: [VPNProfileCleanupResult]) -> VPNProfileCleanupResult {
        let diagnostics = results.compactMap(\.diagnostic).joined(separator: " | ")
        return VPNProfileCleanupResult(
            tunnelStopped: results.allSatisfy(\.tunnelStopped),
            onDemandDisabled: results.allSatisfy(\.onDemandDisabled),
            profileRemoved: results.allSatisfy(\.profileRemoved),
            diagnostic: diagnostics.isEmpty ? nil : diagnostics
        )
    }
}

struct VPNConnectionPolicy: Equatable {
    let killSwitchEnabled: Bool
    let onDemandEnabled: Bool

    static let disabled = VPNConnectionPolicy(killSwitchEnabled: false, onDemandEnabled: false)

    static func appPolicy(autoConnectEnabled: Bool, killSwitchEnabled: Bool) -> VPNConnectionPolicy {
        VPNConnectionPolicy(
            killSwitchEnabled: killSwitchEnabled,
            onDemandEnabled: autoConnectEnabled || killSwitchEnabled
        )
    }

    func apply(to protocolConfiguration: NEVPNProtocol) {
        protocolConfiguration.includeAllNetworks = killSwitchEnabled
        protocolConfiguration.excludeLocalNetworks = false
        protocolConfiguration.excludeAPNs = false
        protocolConfiguration.excludeCellularServices = false
        protocolConfiguration.excludeDeviceCommunication = false
        // Packet tunnels already install their included routes through
        // NEPacketTunnelNetworkSettings. On iOS 26, enforcing a default route
        // can cause the system to drop ordinary app traffic before it reaches
        // packetFlow. A kill switch is enforced by includeAllNetworks instead.
        protocolConfiguration.enforceRoutes = false
        protocolConfiguration.disconnectOnSleep = false
    }

    func apply(to protocolConfiguration: NEVPNProtocolIKEv2) {
        apply(to: protocolConfiguration as NEVPNProtocol)
        // Native IKEv2 does not expose a packet-flow filter. Keep the tunnel
        // full-tunnel while connected so IPv6 follows the same route policy
        // as the rest of the connection. This is intentionally best-effort:
        // the server's negotiated traffic selectors still determine what the
        // IKEv2 tunnel can carry.
        protocolConfiguration.includeAllNetworks = true
        protocolConfiguration.enforceRoutes = true
    }
}

@MainActor
final class PersonalVPNManager: VPNManaging {
    private let api: BackendServicing
    private let configurationResolver: VPNConfigurationResolving
    private let translator: VPNConfigurationTranslator
    private let manager: NEVPNManager
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "libreguard-vpn-ios",
        category: "VPN"
    )
    private var statusObserver: NSObjectProtocol?
    private let trafficSampler = SystemTunnelTrafficSampler()

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

    init(
        api: BackendServicing,
        resolver: VPNConfigurationResolving? = nil,
        translator: VPNConfigurationTranslator? = nil,
        manager: NEVPNManager = .shared()
    ) {
        self.api = api
        self.configurationResolver = resolver ?? VPNConfigurationResolver(api: api)
        self.translator = translator ?? VPNConfigurationTranslator()
        self.manager = manager
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

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol = .ikev2, policy: VPNConnectionPolicy = .disabled) async throws {
        logger.info("VPN connect requested for server \(server.id, privacy: .public) using protocol \(protocolName.rawValue, privacy: .public)")

        guard !isRunningInSimulator else {
            logger.error("VPN connections are not supported in the iOS Simulator")
            status = .disconnected
            throw VPNManagerError.simulatorUnsupported
        }

        status = .connecting

        do {
            logger.debug("Resolving VPN configuration from backend")
            let response = try await configurationResolver.resolve(serverId: server.id, protocol: protocolName)
            try Task.checkCancellation()
            logger.debug("Backend VPN configuration received for server \(server.id, privacy: .public)")
            let vpnProtocol = try translator.makeProtocol(server: server, response: response, policy: policy)
            try Task.checkCancellation()
            let serverAddress = String(describing: vpnProtocol.serverAddress)
            let remoteIdentifier = String(describing: vpnProtocol.remoteIdentifier)
            let localIdentifier = String(describing: vpnProtocol.localIdentifier)
            logger.debug(
                "Translated VPN config serverAddress=\(serverAddress, privacy: .public) remoteIdentifier=\(remoteIdentifier, privacy: .public) localIdentifier=\(localIdentifier, privacy: .private(mask: .hash)) includeAllNetworks=\(vpnProtocol.includeAllNetworks, privacy: .public)"
            )

            try await loadPreferences()
            try Task.checkCancellation()
            logger.debug("Loaded existing VPN preferences")
            manager.localizedDescription = "LibreGuard"
            manager.protocolConfiguration = vpnProtocol
            manager.isEnabled = true
            applyOnDemandConfiguration(enabled: policy.onDemandEnabled)
            logger.debug("Saving VPN preferences")
            try await savePreferences()
            try Task.checkCancellation()
            logger.debug("Reloading VPN preferences before tunnel start")
            try await loadPreferences()
            try Task.checkCancellation()
            logger.debug("Starting VPN tunnel")
            try manager.connection.startVPNTunnel()
            try Task.checkCancellation()
            logger.info("startVPNTunnel() returned without throwing")
            updateStatus(from: manager.connection.status)
        } catch is CancellationError {
            logger.info("VPN connect request cancelled")
            status = .disconnecting
            manager.connection.stopVPNTunnel()
            await refreshStatus()
            throw CancellationError()
        } catch {
            logger.error("VPN connect failed: \(Self.describe(error))")
            status = .disconnected
            throw error
        }
    }

    @discardableResult
    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        guard !isRunningInSimulator else { return false }
        try await loadPreferences()
        guard let vpnProtocol = manager.protocolConfiguration as? NEVPNProtocolIKEv2 else { return false }
        policy.apply(to: vpnProtocol)
        applyOnDemandConfiguration(enabled: policy.onDemandEnabled)
        try await savePreferences()
        try await loadPreferences()
        guard let savedProtocol = manager.protocolConfiguration else { return false }
        return savedProtocol.includeAllNetworks && savedProtocol.enforceRoutes
    }

    func disconnect() async {
        logger.info("VPN disconnect requested")
        status = .disconnecting
        manager.connection.stopVPNTunnel()
        await refreshStatus()
    }

    @discardableResult
    func disableOnDemandAndProfile() async -> Bool {
        guard !isRunningInSimulator else { return true }

        // An invalid manager has no installed profile to disable. Treat it as
        // safe rather than turning a first launch into a permanent blocker.
        guard manager.connection.status != .invalid else { return true }

        do {
            try await loadPreferences()
            guard manager.protocolConfiguration != nil else { return true }

            manager.onDemandRules = nil
            manager.isOnDemandEnabled = false
            manager.isEnabled = false
            try await savePreferences()
            try await loadPreferences()

            let hasNoOnDemandRules = manager.onDemandRules?.isEmpty ?? true
            let disabled = !manager.isOnDemandEnabled && !manager.isEnabled && hasNoOnDemandRules
            if !disabled {
                logger.error("VPN profile remained enabled after disabling on-demand")
            }
            return disabled
        } catch {
            logger.error("Failed to disable VPN on-demand profile: \(Self.describe(error))")
            return manager.connection.status == .invalid
        }
    }

    func disconnectAndForget() async -> VPNProfileCleanupResult {
        logger.info("VPN disconnect-and-forget requested")
        guard !isRunningInSimulator else {
            status = .disconnected
            return .noProfile
        }

        let onDemandDisabled = await disableOnDemandAndProfile()
        manager.connection.stopVPNTunnel()

        let tunnelStopped = await waitForTunnelToStop()
        guard tunnelStopped else {
            let diagnostic = "iOS did not confirm that the IKEv2 tunnel stopped."
            logger.error("\(diagnostic, privacy: .public)")
            return VPNProfileCleanupResult(
                tunnelStopped: false,
                onDemandDisabled: onDemandDisabled,
                profileRemoved: false,
                diagnostic: diagnostic
            )
        }

        do {
            try await removePreferences()
            status = VPNConnectionState(networkExtensionStatus: manager.connection.status)
            let result = VPNProfileCleanupResult(
                tunnelStopped: true,
                onDemandDisabled: onDemandDisabled,
                profileRemoved: true,
                diagnostic: nil
            )
            logger.info("IKEv2 profile cleanup stopped=\(result.tunnelStopped, privacy: .public) onDemandDisabled=\(result.onDemandDisabled, privacy: .public) removed=\(result.profileRemoved, privacy: .public)")
            return result
        } catch {
            let diagnostic = "IKEv2 VPN profile could not be removed after stopping."
            logger.error("\(diagnostic, privacy: .public) \(Self.describe(error))")
            status = VPNConnectionState(networkExtensionStatus: manager.connection.status)
            let result = VPNProfileCleanupResult(
                tunnelStopped: true,
                onDemandDisabled: onDemandDisabled,
                profileRemoved: false,
                diagnostic: diagnostic
            )
            logger.info("IKEv2 profile cleanup stopped=\(result.tunnelStopped, privacy: .public) onDemandDisabled=\(result.onDemandDisabled, privacy: .public) removed=\(result.profileRemoved, privacy: .public)")
            return result
        }
    }

    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot? {
        trafficSampler.currentSnapshot()
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
                        guard let error else {
                            self.logger.error("IKEv2 tunnel disconnected without a NetworkExtension error")
                            return
                        }
                        self.logger.error("IKEv2 tunnel disconnect error: \(Self.describe(error), privacy: .public)")
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

    private func waitForTunnelToStop(maximumAttempts: Int = 25) async -> Bool {
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
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
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
