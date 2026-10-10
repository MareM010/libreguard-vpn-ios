import Foundation

@MainActor
final class VPNManagerCoordinator: VPNManaging {
    private let ikev2Manager: VPNManaging
    private let openVPNManager: VPNManaging
    private let transactions = VPNPreferencesAccess()
    private let timing: VPNConnectionTiming
    private var activeProtocol: VPNConfigurationProtocol?
    private var requestGeneration: UInt = 0
    private var attemptGeneration: UInt = 0
    private var protocolsBeingStopped: Set<VPNConfigurationProtocol> = []
    private var pendingStarts: Set<VPNConfigurationProtocol> = []
    private var currentAttempt: VPNConnectRequest?
    private var startupTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Error>?
    private var drainTask: Task<VPNStopResult, Never>?
    private var startupObserved = false
    private var attemptFailed = false
    private var isDraining = false
    private var acceptsRestoredSessions = true
    private var killSwitchEnabled = false

    var status: VPNConnectionState = .disconnected {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    var onAttemptEvent: ((VPNAttemptEvent) -> Void)?
    var connectedProtocol: VPNConfigurationProtocol? { activeProtocol }
    var protectionIsInstalled: Bool {
        ikev2Manager.protectionIsInstalled || openVPNManager.protectionIsInstalled
    }

    init(
        api: BackendServicing,
        resolver: VPNConfigurationResolving? = nil,
        translator: VPNConfigurationTranslator? = nil,
        deviceKeyStore: VPNDeviceKeyProviding = VPNDeviceKeyStore(),
        timing: VPNConnectionTiming = VPNConnectionTiming()
    ) {
        let sharedResolver = resolver ?? VPNConfigurationResolver(api: api)
        let preferences = VPNPreferencesAccess()
        self.timing = timing
        ikev2Manager = PersonalVPNManager(api: api, resolver: sharedResolver, translator: translator,
            preferencesAccess: preferences, timing: timing)
        openVPNManager = OpenVPNManager(api: api, resolver: sharedResolver, deviceKeyStore: deviceKeyStore,
            preferencesAccess: preferences, timing: timing)
        configureCallbacks()
        reconcileStatus()
    }

    init(ikev2Manager: VPNManaging, openVPNManager: VPNManaging, timing: VPNConnectionTiming = VPNConnectionTiming()) {
        self.ikev2Manager = ikev2Manager
        self.openVPNManager = openVPNManager
        self.timing = timing
        configureCallbacks()
        reconcileStatus()
    }

    func setAttemptContext(_ id: UUID, protocol protocolName: VPNConfigurationProtocol) {}
    func setCertificatePreparationHandler(_ handler: ((String?) -> Void)?) {
        ikev2Manager.setCertificatePreparationHandler(handler)
        openVPNManager.setCertificatePreparationHandler(handler)
    }

    private func configureCallbacks() {
        for protocolName in [VPNConfigurationProtocol.ikev2, .openVPN] {
            let manager = manager(for: protocolName)
            manager.onStatusChange = { [weak self] _ in self?.handleStatusChange(from: protocolName) }
            manager.onAttemptEvent = { [weak self] event in self?.receive(event) }
            manager.onDisconnectError = { [weak self] error in
                guard let self, !self.isDraining, self.activeProtocol == protocolName,
                      self.currentAttempt == nil || self.attemptGeneration == self.requestGeneration else { return }
                if let attempt = self.currentAttempt {
                    self.fail(attempt, with: VPNConnectionFailure.classify(error, phase: .starting))
                } else { self.onDisconnectError?(error) }
            }
        }
    }

    func refreshStatus() async {
        await ikev2Manager.refreshStatus()
        await openVPNManager.refreshStatus()
        reconcileStatus()
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws {
        try await connect(request: VPNConnectRequest(server: server, protocolName: protocolName,
            onDemandEnabled: policy.onDemandEnabled, killSwitchEnabled: policy.killSwitchEnabled, origin: .manual))
    }

    func connect(request incoming: VPNConnectRequest) async throws {
        guard drainTask == nil else { throw VPNConnectionFailure(kind: .stopFailed) }
        let request = VPNConnectRequest(sessionID: incoming.sessionID, server: incoming.server,
            protocolName: incoming.protocolName.transportProtocol, onDemandEnabled: incoming.onDemandEnabled,
            killSwitchEnabled: incoming.killSwitchEnabled, origin: incoming.origin)
        let otherProtocol: VPNConfigurationProtocol = request.protocolName == .ikev2 ? .openVPN : .ikev2
        if (killSwitchEnabled || request.killSwitchEnabled), manager(for: otherProtocol).protectionIsInstalled {
            throw VPNConnectionFailure(kind: .protectedSwitch)
        }
        requestGeneration &+= 1
        let generation = requestGeneration
        acceptsRestoredSessions = false
        startupTask?.cancel()
        preparationTask?.cancel()
        try await transactions.withExclusiveAccess {
            guard generation == self.requestGeneration else { throw CancellationError() }
            self.currentAttempt = request
            self.attemptGeneration = generation
            self.attemptFailed = false
            self.startupObserved = false
            self.startupTask = nil
            let target = self.manager(for: request.protocolName)
            let other = self.manager(for: otherProtocol)
            var targetPrepared = false
            do {
                // A terminal native status alone does not prove a queued start
                // or an IncludeAllNetworks profile has relinquished routing.
                self.isDraining = true
                if self.shouldStop(target.status) || self.pendingStarts.contains(request.protocolName) {
                    if request.killSwitchEnabled {
                        guard try await target.apply(policy: VPNConnectionPolicy(killSwitchEnabled: true, onDemandEnabled: false)) else {
                            throw VPNConnectionFailure(kind: .stopFailed)
                        }
                    }
                    let stopped = await target.stopAndWait(releaseProtection: !request.killSwitchEnabled)
                    guard stopped.isSafe else { throw VPNConnectionFailure(kind: .stopFailed) }
                    self.pendingStarts.remove(request.protocolName)
                }
                if self.shouldStop(other.status) || self.pendingStarts.contains(otherProtocol) {
                    let stopped = await other.stopAndWait(releaseProtection: true)
                    guard stopped.isSafe else { throw VPNConnectionFailure(kind: .stopFailed) }
                    self.pendingStarts.remove(otherProtocol)
                }
                if otherProtocol == .ikev2 {
                    let recovery = await other.recoverStoppedProfile(for: .ikev2)
                    guard recovery.isSafe else { throw VPNConnectionFailure(kind: .stopFailed) }
                } else {
                    guard await other.disableOnDemandAndProfile() else { throw VPNConnectionFailure(kind: .stopFailed) }
                }
                try Task.checkCancellation()
                guard generation == self.requestGeneration else { throw CancellationError() }
                self.isDraining = false
                self.activeProtocol = request.protocolName
                self.killSwitchEnabled = request.killSwitchEnabled
                self.pendingStarts.insert(request.protocolName)
                targetPrepared = true
                self.receive(VPNAttemptEvent(attemptID: request.sessionID, protocolName: request.protocolName, phase: .preparing))
                let preparation = Task { @MainActor in try await target.connect(request: request) }
                self.preparationTask = preparation
                try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: { preparation.cancel() }
                self.preparationTask = nil
                try Task.checkCancellation()
                guard generation == self.requestGeneration else { throw CancellationError() }
                // Initial-start observation may finish after the native session
                // connects. Preserve that completed phase in the fallback event.
                self.receive(VPNAttemptEvent(attemptID: request.sessionID, protocolName: request.protocolName,
                    phase: target.status.isConnected ? .connected : .starting))
                self.reconcileStatus()
            } catch {
                VPNConnectionJournal.record(VPNAttemptEvent(attemptID: request.sessionID,
                    protocolName: request.protocolName, phase: error is CancellationError ? .cancelled : .starting,
                    failure: error is CancellationError ? nil : VPNConnectionFailure.classify(error, phase: .starting)))
                self.preparationTask = nil
                self.isDraining = false
                self.startupTask?.cancel()
                var cleanupSafe = true
                if targetPrepared {
                    self.isDraining = true
                    // Cancellation must not cancel cleanup or release its lock
                    // before a permission-producing save has returned.
                    let result = await Task { @MainActor in
                        await target.stopAndWait(releaseProtection: !request.killSwitchEnabled)
                    }.value
                    self.isDraining = false
                    cleanupSafe = result.isSafe
                    if result.isSafe { self.pendingStarts.remove(request.protocolName) }
                    else if generation == self.requestGeneration {
                        self.fail(request, with: VPNConnectionFailure(kind: .stopFailed))
                    }
                }
                if generation == self.requestGeneration {
                    if cleanupSafe {
                        self.currentAttempt = nil
                        if targetPrepared { self.activeProtocol = nil }
                    }
                    self.reconcileStatus()
                }
                if !cleanupSafe { throw VPNConnectionFailure(kind: .stopFailed) }
                throw error
            }
        }
    }

    @discardableResult
    func apply(policy: VPNConnectionPolicy) async throws -> Bool {
        try await transactions.withExclusiveAccess {
            self.killSwitchEnabled = policy.killSwitchEnabled
            if let active = self.activeProtocol {
                let result = try await self.manager(for: active).apply(policy: policy)
                let other: VPNConfigurationProtocol = active == .ikev2 ? .openVPN : .ikev2
                // An inactive profile must not acquire Kill Switch routing.
                _ = try await self.manager(for: other).apply(policy: .disabled)
                return result
            }
            let ike = try await self.ikev2Manager.apply(policy: policy)
            let open = try await self.openVPNManager.apply(policy: .disabled)
            return ike || open
        }
    }

    func disconnect() async {
        let result = await stopAndWait(releaseProtection: !killSwitchEnabled)
        if !result.isSafe { onDisconnectError?(VPNConnectionFailure(kind: .stopFailed)) }
    }

    func stopAndWait(releaseProtection: Bool) async -> VPNStopResult {
        let operation: Task<VPNStopResult, Never>
        if let pending = drainTask {
            operation = pending
        } else {
            if let attempt = currentAttempt {
                VPNConnectionJournal.record(VPNAttemptEvent(attemptID: attempt.sessionID,
                    protocolName: attempt.protocolName, phase: .stopping))
            }
            requestGeneration &+= 1
            let generation = requestGeneration
            startupTask?.cancel()
            preparationTask?.cancel()
            acceptsRestoredSessions = false
            operation = Task { @MainActor in
                let attempt = self.currentAttempt
                let result = await self.drain(releaseProtection: releaseProtection, generation: generation)
                self.drainTask = nil
                if let attempt {
                    VPNConnectionJournal.record(VPNAttemptEvent(attemptID: attempt.sessionID,
                        protocolName: attempt.protocolName, phase: .stopped,
                        failure: result.isSafe ? nil : VPNConnectionFailure(kind: .stopFailed)))
                }
                if result.isSafe { self.reconcileStatus() }
                return result
            }
            drainTask = operation
        }
        do {
            // Bound the whole wait, including preference callbacks. The actual
            // cleanup retains the transaction lock until iOS finishes, so a
            // late callback cannot overlap a new configuration transaction.
            return try await VPNCallbackDeadline.run(timeout: timing.stop, sleep: timing.sleep) { complete in
                Task { @MainActor in complete(.success(await operation.value)) }
            }
        } catch { return VPNStopResult(tunnelStopped: false, profileReleased: false) }
    }

    private func drain(releaseProtection: Bool, generation: UInt) async -> VPNStopResult {
        do {
            return try await transactions.withExclusiveAccess {
                guard generation == self.requestGeneration else {
                    return VPNStopResult(tunnelStopped: false, profileReleased: false)
                }
                self.isDraining = true
                var safe = true
                if !releaseProtection, self.killSwitchEnabled, let active = self.activeProtocol {
                    do {
                        safe = try await self.manager(for: active).apply(
                            policy: VPNConnectionPolicy(killSwitchEnabled: true, onDemandEnabled: false))
                    } catch { safe = false }
                }
                for protocolName in [VPNConfigurationProtocol.openVPN, .ikev2] {
                    let manager = self.manager(for: protocolName)
                    if self.shouldStop(manager.status) || self.pendingStarts.contains(protocolName) {
                        let result = await manager.stopAndWait(releaseProtection: releaseProtection)
                        safe = safe && result.isSafe
                        if result.isSafe { self.pendingStarts.remove(protocolName) }
                    }
                }
                if releaseProtection {
                    let recovery = await self.ikev2Manager.recoverStoppedProfile(for: .ikev2)
                    let openReleased = await self.openVPNManager.disableOnDemandAndProfile()
                    safe = safe && recovery.isSafe && openReleased
                }
                self.isDraining = false
                if safe {
                    self.activeProtocol = nil
                    self.currentAttempt = nil
                    return .stopped
                }
                // Retain ownership and pending-start markers until cleanup succeeds.
                return VPNStopResult(tunnelStopped: false, profileReleased: false)
            }
        } catch { return VPNStopResult(tunnelStopped: false, profileReleased: false) }
    }

    func recoverStoppedProfile(for protocolName: VPNConfigurationProtocol) async -> VPNStoppedProfileRecoveryResult {
        guard protocolName == .ikev2, !killSwitchEnabled else { return .notApplicable }
        do {
            return try await transactions.withExclusiveAccess {
                await self.ikev2Manager.recoverStoppedProfile(for: protocolName)
            }
        } catch {
            return VPNStoppedProfileRecoveryResult(isApplicable: true, routingReleased: false,
                onDemandDisabled: false, profileDisabled: false, diagnostic: "Profile recovery was cancelled.")
        }
    }

    @discardableResult
    func disableOnDemandAndProfile() async -> Bool {
        do {
            return try await transactions.withExclusiveAccess { await self.disableProfiles() }
        } catch { return false }
    }

    private func disableProfiles() async -> Bool {
        let ike = await ikev2Manager.disableOnDemandAndProfile()
        let open = await openVPNManager.disableOnDemandAndProfile()
        return ike && open
    }

    func disconnectAndForget() async -> VPNProfileCleanupResult {
        requestGeneration &+= 1
        startupTask?.cancel()
        preparationTask?.cancel()
        acceptsRestoredSessions = false
        do {
            return try await transactions.withExclusiveAccess {
                self.isDraining = true
                _ = await self.disableProfiles()
                let ike = await self.ikev2Manager.disconnectAndForget()
                let open = await self.openVPNManager.disconnectAndForget()
                self.isDraining = false
                let result = VPNProfileCleanupResult.combined([ike, open])
                if result.isSafeForUnauthenticatedLogin {
                    self.activeProtocol = nil
                    self.currentAttempt = nil
                    self.pendingStarts.removeAll()
                }
                self.reconcileStatus()
                return result
            }
        } catch {
            return VPNProfileCleanupResult(tunnelStopped: false, onDemandDisabled: false,
                profileRemoved: false, diagnostic: "VPN cleanup was cancelled.")
        }
    }

    func currentTrafficSnapshot() async -> TunnelTrafficSnapshot? {
        guard let activeProtocol else { return nil }
        return await manager(for: activeProtocol).currentTrafficSnapshot()
    }
    var connectedDate: Date? {
        activeProtocol.flatMap { manager(for: $0).connectedDate }
    }

    private func receive(_ event: VPNAttemptEvent) {
        guard let attempt = currentAttempt, event.attemptID == attempt.sessionID,
              event.protocolName == attempt.protocolName, !attemptFailed,
              attemptGeneration == requestGeneration else { return }
        if event.phase == .starting {
            startupObserved = startupObserved || event.nativeStartupObserved
            if startupTask == nil {
                let sleep = timing.sleep
                let duration = timing.startup
                startupTask = Task { @MainActor [weak self] in
                    do { try await sleep(duration); try Task.checkCancellation() } catch { return }
                    guard let self, self.currentAttempt?.sessionID == attempt.sessionID,
                          !self.status.isConnected, !self.attemptFailed else { return }
                    let generation = self.requestGeneration
                    self.fail(attempt, with: VPNConnectionFailure(kind: .startupTimeout))
                    let stopped = await Task { @MainActor in
                        guard generation == self.requestGeneration else { return VPNStopResult.stopped }
                        return await self.stopAndWait(releaseProtection: !attempt.killSwitchEnabled)
                    }.value
                    if !stopped.isSafe { self.emitFailure(attempt, VPNConnectionFailure(kind: .stopFailed)) }
                }
            }
        } else if event.phase == .connected {
            startupTask?.cancel()
            pendingStarts.remove(event.protocolName)
        }
        VPNConnectionJournal.record(event)
        onAttemptEvent?(event)
    }

    private func fail(_ attempt: VPNConnectRequest, with failure: VPNConnectionFailure) {
        guard !attemptFailed else {
            // The native error lookup may finish after the terminal status.
            // Retain its domain/code without presenting the same failure twice.
            if failure.underlyingError != nil {
                VPNConnectionJournal.record(VPNAttemptEvent(attemptID: attempt.sessionID,
                    protocolName: attempt.protocolName, phase: .starting, failure: failure))
            }
            return
        }
        attemptFailed = true
        startupTask?.cancel()
        emitFailure(attempt, failure)
    }

    private func emitFailure(_ attempt: VPNConnectRequest, _ failure: VPNConnectionFailure) {
        let event = VPNAttemptEvent(attemptID: attempt.sessionID, protocolName: attempt.protocolName,
            phase: .starting, failure: failure)
        VPNConnectionJournal.record(event)
        onAttemptEvent?(event)
    }

    private func handleStatusChange(from protocolName: VPNConfigurationProtocol) {
        guard !isDraining else { return }
        if currentAttempt != nil, attemptGeneration != requestGeneration { return }
        if activeProtocol != protocolName,
           (activeProtocol != nil || !acceptsRestoredSessions),
           shouldStop(manager(for: protocolName).status), !protocolsBeingStopped.contains(protocolName) {
            protocolsBeingStopped.insert(protocolName)
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.protocolsBeingStopped.remove(protocolName) }
                try? await self.transactions.withExclusiveAccess {
                    guard self.activeProtocol != protocolName else { return }
                    _ = await self.manager(for: protocolName).stopAndWait(releaseProtection: !self.killSwitchEnabled)
                }
            }
            return
        }
        if protocolName == activeProtocol, startupObserved, pendingStarts.contains(protocolName),
           (manager(for: protocolName).status == .disconnected || manager(for: protocolName).status == .invalid),
           let attempt = currentAttempt {
            fail(attempt, with: VPNConnectionFailure(kind: .connectionFailed))
        }
        reconcileStatus()
    }

    private func reconcileStatus() {
        guard !isDraining else { return }
        if let activeProtocol {
            status = manager(for: activeProtocol).status
        } else if acceptsRestoredSessions {
            if openVPNManager.status.isConnected || openVPNManager.status.isBusy {
                activeProtocol = .openVPN; status = openVPNManager.status
            } else if ikev2Manager.status.isConnected || ikev2Manager.status.isBusy {
                activeProtocol = .ikev2; status = ikev2Manager.status
            } else { status = .disconnected }
        } else { status = .disconnected }
    }
    private func manager(for protocolName: VPNConfigurationProtocol) -> VPNManaging {
        protocolName == .openVPN ? openVPNManager : ikev2Manager
    }
    private func shouldStop(_ status: VPNConnectionState) -> Bool {
        status != .disconnected && status != .invalid
    }
}
