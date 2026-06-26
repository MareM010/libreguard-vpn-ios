import Foundation

@MainActor
final class VPNManagerCoordinator: VPNManaging {
    private let ikev2Manager: VPNManaging
    private let openVPNManager: VPNManaging
    private var activeProtocol: VPNConfigurationProtocol?
    private var requestGeneration: UInt = 0
    private var protocolsBeingStopped: Set<VPNConfigurationProtocol> = []

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
        deviceKeyStore: VPNDeviceKeyProviding = VPNDeviceKeyStore(),
        profileStore: OpenVPNProfileEnvelopeStoring = OpenVPNProfileEnvelopeStore()
    ) {
        self.ikev2Manager = PersonalVPNManager(api: api, translator: translator)
        self.openVPNManager = OpenVPNManager(api: api, deviceKeyStore: deviceKeyStore, profileStore: profileStore)
        configureCallbacks()
        reconcileStatus()
    }

    init(ikev2Manager: VPNManaging, openVPNManager: VPNManaging) {
        self.ikev2Manager = ikev2Manager
        self.openVPNManager = openVPNManager
        configureCallbacks()
        reconcileStatus()
    }

    private func configureCallbacks() {
        ikev2Manager.onStatusChange = { [weak self] _ in
            self?.handleStatusChange(from: .ikev2)
        }
        openVPNManager.onStatusChange = { [weak self] _ in
            self?.handleStatusChange(from: .openVPN)
        }
        self.ikev2Manager.onDisconnectError = { [weak self] error in self?.onDisconnectError?(error) }
        self.openVPNManager.onDisconnectError = { [weak self] error in self?.onDisconnectError?(error) }
    }

    func refreshStatus() async {
        await ikev2Manager.refreshStatus()
        await openVPNManager.refreshStatus()
        reconcileStatus()
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol) async throws {
        requestGeneration &+= 1
        let generation = requestGeneration
        activeProtocol = protocolName
        let manager = manager(for: protocolName)

        do {
            try await manager.connect(to: server, protocol: protocolName)
            try Task.checkCancellation()
            guard generation == requestGeneration else {
                await stopIfActive(manager)
                throw CancellationError()
            }
            reconcileStatus()
        } catch is CancellationError {
            await stopIfActive(manager)
            if generation == requestGeneration {
                activeProtocol = nil
                reconcileStatus()
            }
            throw CancellationError()
        } catch {
            if generation == requestGeneration {
                activeProtocol = nil
                reconcileStatus()
            }
            throw error
        }
    }

    func disconnect() async {
        requestGeneration &+= 1
        activeProtocol = nil

        if shouldStop(openVPNManager.status) {
            await openVPNManager.disconnect()
        }
        if shouldStop(ikev2Manager.status) {
            await ikev2Manager.disconnect()
        }
        reconcileStatus()
    }

    func disconnectAndForget() async {
        requestGeneration &+= 1
        activeProtocol = nil
        await ikev2Manager.disconnectAndForget()
        await openVPNManager.disconnectAndForget()
        reconcileStatus()
    }

    private func handleStatusChange(from protocolName: VPNConfigurationProtocol) {
        if let activeProtocol,
           manager(for: activeProtocol) !== manager(for: protocolName),
           shouldStop(manager(for: protocolName).status),
           !protocolsBeingStopped.contains(protocolName) {
            let staleManager = manager(for: protocolName)
            protocolsBeingStopped.insert(protocolName)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await stopIfActive(staleManager)
                protocolsBeingStopped.remove(protocolName)
            }
        }
        reconcileStatus()
    }

    private func reconcileStatus() {
        let ikev2Status = ikev2Manager.status
        let openVPNStatus = openVPNManager.status

        if let activeProtocol {
            let preferredStatus: VPNConnectionState = activeProtocol == .openVPN ? openVPNStatus : ikev2Status
            status = preferredStatus
            return
        }

        if openVPNStatus.isConnected || openVPNStatus.isBusy {
            activeProtocol = .openVPN
            status = openVPNStatus
            return
        }

        if ikev2Status.isConnected || ikev2Status.isBusy {
            activeProtocol = .ikev2
            status = ikev2Status
            return
        }

        activeProtocol = nil
        status = .disconnected
    }

    private func manager(for protocolName: VPNConfigurationProtocol) -> VPNManaging {
        protocolName == .openVPN ? openVPNManager : ikev2Manager
    }

    private func shouldStop(_ status: VPNConnectionState) -> Bool {
        status != .disconnected && status != .invalid
    }

    private func stopIfActive(_ manager: VPNManaging) async {
        guard shouldStop(manager.status) else { return }
        await manager.disconnect()
    }
}
