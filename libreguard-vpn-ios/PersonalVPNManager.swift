import Foundation
import NetworkExtension
import OSLog

@MainActor
protocol VPNManaging: AnyObject {
    var status: VPNConnectionState { get }
    var connectedDate: Date? { get }
    var onStatusChange: ((VPNConnectionState) -> Void)? { get set }
    var onDisconnectError: ((Error) -> Void)? { get set }
    var onAttemptEvent: ((VPNAttemptEvent) -> Void)? { get set }
    var protectionIsInstalled: Bool { get }
    var connectedProtocol: VPNConfigurationProtocol? { get }

    func setAttemptContext(_ id: UUID, protocol protocolName: VPNConfigurationProtocol)
    func connect(request: VPNConnectRequest) async throws
    func stopAndWait(releaseProtection: Bool) async -> VPNStopResult

    func setCertificatePreparationHandler(_ handler: ((String?) -> Void)?)

    func refreshStatus() async
    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws
    @discardableResult func apply(policy: VPNConnectionPolicy) async throws -> Bool
    func disconnect() async
    /// Releases routing owned by a confirmed-stopped IKEv2 profile. Usable
    /// certificate identity is preserved; an invalid stopped profile may be
    /// removed only while Kill Switch is off.
    @discardableResult func recoverStoppedProfile(
        for protocolName: VPNConfigurationProtocol
    ) async -> VPNStoppedProfileRecoveryResult
    /// Persistently disables system on-demand behavior before an account session
    /// is discarded. Coordinators call this on every managed profile before
    /// asking either tunnel to stop.
    @discardableResult func disableOnDemandAndProfile() async -> Bool
    @discardableResult func disconnectAndForget() async -> VPNProfileCleanupResult
    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot?
}

extension VPNManaging {
    var onAttemptEvent: ((VPNAttemptEvent) -> Void)? { get { nil } set {} }
    var protectionIsInstalled: Bool { status.isConnected || status.isBusy }
    var connectedProtocol: VPNConfigurationProtocol? { nil }
    func setAttemptContext(_ id: UUID, protocol protocolName: VPNConfigurationProtocol) {}
    func connect(request: VPNConnectRequest) async throws {
        setAttemptContext(request.sessionID, protocol: request.protocolName)
        try await connect(to: request.server, protocol: request.protocolName, policy: VPNConnectionPolicy(
            killSwitchEnabled: request.killSwitchEnabled, onDemandEnabled: request.onDemandEnabled
        ))
    }
    func stopAndWait(releaseProtection: Bool) async -> VPNStopResult {
        if releaseProtection, !(await disableOnDemandAndProfile()) {
            return VPNStopResult(tunnelStopped: false, profileReleased: false)
        }
        await disconnect()
        return VPNStopResult(tunnelStopped: status == .disconnected || status == .invalid, profileReleased: true)
    }
    var connectedDate: Date? { nil }
    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot? { nil }
    func setCertificatePreparationHandler(_ handler: ((String?) -> Void)?) {}
    @discardableResult
    func recoverStoppedProfile(
        for protocolName: VPNConfigurationProtocol
    ) async -> VPNStoppedProfileRecoveryResult {
        .notApplicable
    }
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
            // A removed profile cannot reconnect on demand. Each profile may
            // be safe by a different route (removed versus disabled).
            onDemandDisabled: results.allSatisfy { $0.onDemandDisabled || $0.profileRemoved },
            profileRemoved: results.allSatisfy(\.profileRemoved),
            diagnostic: diagnostics.isEmpty ? nil : diagnostics
        )
    }
}

/// The outcome of restoring ordinary network routing after Network Extension
/// confirms that IKEv2 stopped. A valid profile is retained; a stale invalid
/// profile may be removed and recreated through normal approval on next use.
struct VPNStoppedProfileRecoveryResult: Equatable, Sendable {
    let isApplicable: Bool
    let routingReleased: Bool
    let onDemandDisabled: Bool
    let profileDisabled: Bool
    let diagnostic: String?

    static let notApplicable = VPNStoppedProfileRecoveryResult(
        isApplicable: false,
        routingReleased: true,
        onDemandDisabled: true,
        profileDisabled: true,
        diagnostic: nil
    )

    var isSafe: Bool {
        !isApplicable || (routingReleased && onDemandDisabled && profileDisabled)
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
        // includeAllNetworks and enforceRoutes are alternative routing
        // controls. Keep the full-tunnel setting, but do not ask iOS to
        // enforce a second default route that can outlive a stopped tunnel.
        protocolConfiguration.enforceRoutes = false
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
    private let preferencesAccess: VPNPreferencesAccess
    private let timing: VPNConnectionTiming
    private var connectionsBeingPrepared: Set<UUID> = []
    private var attemptID = UUID()
    private var phase: VPNAttemptPhase = .preparing
    private var lifecycleGeneration: UInt = 0
    private var expectedStop = false
    private var isRecoveringInitialStartup = false
    private var killSwitchEnabled = false
    private var approvedIdentity: IKEv2ApprovedIdentity?

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
    var connectedProtocol: VPNConfigurationProtocol? { status.isConnected || status.isBusy ? .ikev2 : nil }
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
        onAttemptEvent?(VPNAttemptEvent(attemptID: attemptID, protocolName: .ikev2, phase: phase))
    }

    init(
        api: BackendServicing,
        resolver: VPNConfigurationResolving? = nil,
        translator: VPNConfigurationTranslator? = nil,
        manager: NEVPNManager = .shared(),
        preferencesAccess: VPNPreferencesAccess? = nil,
        timing: VPNConnectionTiming = VPNConnectionTiming()
    ) {
        self.api = api
        self.configurationResolver = resolver ?? VPNConfigurationResolver(api: api)
        self.translator = translator ?? VPNConfigurationTranslator()
        self.manager = manager
        self.preferencesAccess = preferencesAccess ?? VPNPreferencesAccess()
        self.timing = timing
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
            try await preferencesAccess.withExclusiveAccess {
                try await self.loadPreferences()
            }
            logger.debug("VPN status refresh completed with status \(self.manager.connection.status.rawValue, privacy: .public)")
            updateStatus(from: manager.connection.status)
        } catch is CancellationError {
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
        expectedStop = false
        killSwitchEnabled = policy.killSwitchEnabled
        publish(.preparing)
        let preparationID = UUID()
        connectionsBeingPrepared.insert(preparationID)
        defer { connectionsBeingPrepared.remove(preparationID) }

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

            try await preferencesAccess.withExclusiveAccess {
                try await self.loadPreferences()
                try Task.checkCancellation()
                self.logger.debug("Loaded existing VPN preferences")
                let recoverInitialStartup = self.manager.protocolConfiguration == nil && vpnProtocol.includeAllNetworks
                self.manager.localizedDescription = "LibreGuard"
                self.manager.protocolConfiguration = vpnProtocol
                self.manager.isEnabled = true
                self.applyOnDemandConfiguration(enabled: policy.onDemandEnabled)
                self.logger.debug("Saving VPN preferences")
                self.publish(.awaitingApproval)
                try await self.savePreferences()
                self.approvedIdentity = IKEv2ApprovedIdentity(profile: vpnProtocol)
                try Task.checkCancellation()
                self.publish(.starting)
                try await IKEv2TunnelStarter.start(
                    reload: {
                        self.logger.debug("Reloading VPN preferences before tunnel start")
                        try await self.loadPreferences()
                    },
                    startTunnel: {
                        self.logger.debug("Starting VPN tunnel")
                        try self.manager.connection.startVPNTunnel()
                    },
                    onRetry: { error, retry in
                        self.logger.notice("Reloading approved IKEv2 profile for start retry \(retry, privacy: .public): \(Self.describe(error), privacy: .public)")
                    }
                )
                if recoverInitialStartup {
                    try await VPNInitialStartupRecovery.recoverIfStalled(
                        status: { self.manager.connection.status },
                        stopTunnel: { self.manager.connection.stopVPNTunnel() },
                        restartTunnel: {
                            self.expectedStop = false
                            self.publish(.starting)
                            try await IKEv2TunnelStarter.start(
                                reload: { try await self.loadPreferences() },
                                startTunnel: { try self.manager.connection.startVPNTunnel() }
                            )
                        },
                        onRecoveryStateChange: { recovering in
                            self.isRecoveringInitialStartup = recovering
                            if recovering {
                                self.expectedStop = true
                                self.lifecycleGeneration &+= 1
                                self.logger.notice("Restarting stalled first IKEv2 startup with the approved profile")
                                self.publish(.recoveringStartup)
                            }
                        },
                        sleep: self.timing.sleep,
                        stopTimeout: self.timing.stop
                    )
                }
            }
            try Task.checkCancellation()
            logger.info("startVPNTunnel() returned without throwing")
            updateStatus(from: manager.connection.status)
            if status == .connected, phase != .connected { publish(.connected) }
        } catch is CancellationError {
            logger.info("VPN connect request cancelled")
            connectionsBeingPrepared.remove(preparationID)
            status = .disconnecting
            manager.connection.stopVPNTunnel()
            await refreshStatus()
            throw CancellationError()
        } catch {
            logger.error("VPN connect failed: \(Self.describe(error))")
            status = .disconnected
            if phase == .preparing { throw error }
            throw VPNConnectionFailure.classify(error, phase: phase)
        }
    }

    @discardableResult
    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        guard !isRunningInSimulator else { return false }
        return try await preferencesAccess.withExclusiveAccess {
            try await self.applyToPreferences(policy: policy)
        }
    }

    private func applyToPreferences(policy: VPNConnectionPolicy) async throws -> Bool {
        killSwitchEnabled = policy.killSwitchEnabled
        try await loadPreferences()
        guard let vpnProtocol = manager.protocolConfiguration as? NEVPNProtocolIKEv2 else { return false }
        approvedIdentity?.hydrate(vpnProtocol)

        let nativeStatus = manager.connection.status
        let shouldKeepFullTunnel = policy.killSwitchEnabled || !Self.isTerminalStatus(nativeStatus)
        if shouldKeepFullTunnel {
            policy.apply(to: vpnProtocol)
            applyOnDemandConfiguration(enabled: policy.onDemandEnabled)
        } else {
            return await recoverStoppedProfileWithExclusiveAccess().isSafe
        }
        try await savePreferences()
        try await loadPreferences()
        guard let savedProtocol = manager.protocolConfiguration else { return false }
        if shouldKeepFullTunnel {
            return savedProtocol.includeAllNetworks && !savedProtocol.enforceRoutes
                && manager.isOnDemandEnabled == policy.onDemandEnabled
        }
        return !savedProtocol.includeAllNetworks
            && !savedProtocol.enforceRoutes
            && !manager.isOnDemandEnabled
            && !manager.isEnabled
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
        // A queued start may still expose .disconnected. Always send the stop.
        manager.connection.stopVPNTunnel()
        if releaseProtection {
            // Disable a valid profile before waiting so on-demand cannot race
            // the stop. Missing identity is handled after confirmed teardown.
            _ = await disableOnDemandAndProfile()
            manager.connection.stopVPNTunnel()
        }
        let stopped = await waitForTunnelToStop()
        guard stopped else { return VPNStopResult(tunnelStopped: false, profileReleased: false) }
        guard releaseProtection else { return .stopped }
        killSwitchEnabled = false
        let recovery = await recoverStoppedProfile(for: .ikev2)
        return VPNStopResult(tunnelStopped: true, profileReleased: recovery.isSafe)
    }

    func recoverStoppedProfile(
        for protocolName: VPNConfigurationProtocol
    ) async -> VPNStoppedProfileRecoveryResult {
        guard protocolName == .ikev2, !isRunningInSimulator else {
            return .notApplicable
        }

        do {
            return try await preferencesAccess.withExclusiveAccess {
                await self.recoverStoppedProfileWithExclusiveAccess()
            }
        } catch {
            return VPNStoppedProfileRecoveryResult(isApplicable: true, routingReleased: false,
                onDemandDisabled: false, profileDisabled: false, diagnostic: "Profile recovery was cancelled.")
        }
    }

    private func recoverStoppedProfileWithExclusiveAccess() async -> VPNStoppedProfileRecoveryResult {
        guard connectionsBeingPrepared.isEmpty else {
            return VPNStoppedProfileRecoveryResult(isApplicable: true, routingReleased: false,
                onDemandDisabled: false, profileDisabled: false, diagnostic: "IKEv2 setup is still in progress.")
        }
        return await IKEv2StoppedProfileRecovery.recover(
            killSwitchEnabled: killSwitchEnabled,
            load: { try await self.loadPreferences() },
            profile: {
                guard let profile = self.manager.protocolConfiguration as? NEVPNProtocolIKEv2 else { return nil }
                self.approvedIdentity?.hydrate(profile)
                return profile
            },
            isStopped: { Self.isTerminalStatus(self.manager.connection.status) },
            disable: { profile in
                VPNConnectionPolicy.disabled.apply(to: profile as NEVPNProtocol)
                self.manager.onDemandRules = nil
                self.manager.isOnDemandEnabled = false
                self.manager.isEnabled = false
            },
            save: { try await self.savePreferences() },
            remove: {
                try await self.removePreferences()
                self.approvedIdentity = nil
            },
            verifyReleased: {
                guard let profile = self.manager.protocolConfiguration else { return true }
                return !profile.includeAllNetworks && !profile.enforceRoutes
                    && !self.manager.isOnDemandEnabled && (self.manager.onDemandRules?.isEmpty ?? true)
                    && !self.manager.isEnabled
            }
        )
    }

    @discardableResult
    func disableOnDemandAndProfile() async -> Bool {
        guard !isRunningInSimulator else { return true }

        do {
            return try await preferencesAccess.withExclusiveAccess {
                await self.disableOnDemandAndProfileWithExclusiveAccess()
            }
        } catch {
            return false
        }
    }

    private func disableOnDemandAndProfileWithExclusiveAccess() async -> Bool {
        do {
            try await loadPreferences()
            guard manager.protocolConfiguration != nil else { return true }
            if let profile = manager.protocolConfiguration as? NEVPNProtocolIKEv2 {
                approvedIdentity?.hydrate(profile)
            }

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
            return false
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
            try await preferencesAccess.withExclusiveAccess {
                try await VPNProfileRemoval.removeIfPresent(
                    load: { try await self.loadPreferences() },
                    hasProfile: { self.manager.protocolConfiguration != nil },
                    remove: { try await self.removePreferences() }
                )
                self.approvedIdentity = nil
            }
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
                if self.status == .connected { self.publish(.connected) }
                if previous != .disconnected, self.status == .disconnected, !self.expectedStop {
                    let generation = self.lifecycleGeneration
                    let id = self.attemptID
                    self.manager.connection.fetchLastDisconnectError { error in
                        Task { @MainActor [weak self] in
                            guard let self, generation == self.lifecycleGeneration,
                                  id == self.attemptID, !self.expectedStop,
                                  self.status == .disconnected else { return }
                            guard let error else {
                                self.logger.info("IKEv2 tunnel stopped without a NetworkExtension error")
                                return
                            }
                            self.onDisconnectError?(VPNConnectionFailure.classify(error, phase: self.phase))
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

    private func updateStatus(from neStatus: NEVPNStatus) {
        // The internal stop belongs to the same user request. Keep Connecting
        // visible and prevent its terminal notification from failing that request.
        guard !isRecoveringInitialStartup else { return }
        if neStatus == .connecting || neStatus == .reasserting {
            onAttemptEvent?(VPNAttemptEvent(attemptID: attemptID, protocolName: .ikev2,
                phase: .starting, nativeStartupObserved: true))
        }
        // Profile installation/reloads can report terminal states before the
        // first start. Keep the user's request pending throughout approval and
        // retry, without reporting an old disconnect error as a new failure.
        guard connectionsBeingPrepared.isEmpty || !Self.isTerminalStatus(neStatus) else { return }
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

    nonisolated private static func isTerminalStatus(_ status: NEVPNStatus) -> Bool {
        status == .disconnected || status == .invalid
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
