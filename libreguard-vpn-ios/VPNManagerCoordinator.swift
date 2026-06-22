import Foundation

@MainActor
final class VPNManagerCoordinator: VPNManaging {
    private let ikev2Manager: PersonalVPNManager
    private let openVPNManager: OpenVPNManager
    private var activeProtocol: VPNConfigurationProtocol?

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
        self.ikev2Manager.onStatusChange = { [weak self] _ in self?.reconcileStatus() }
        self.openVPNManager.onStatusChange = { [weak self] _ in self?.reconcileStatus() }
        self.ikev2Manager.onDisconnectError = { [weak self] error in self?.onDisconnectError?(error) }
        self.openVPNManager.onDisconnectError = { [weak self] error in self?.onDisconnectError?(error) }
        reconcileStatus()
    }

    func refreshStatus() async {
        await ikev2Manager.refreshStatus()
        await openVPNManager.refreshStatus()
        reconcileStatus()
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol) async throws {
        do {
            switch protocolName {
            case .openVPN:
                try await openVPNManager.connect(to: server, protocol: protocolName)
            case .ikev2, .ikev2IPSec:
                try await ikev2Manager.connect(to: server, protocol: protocolName)
            }
            activeProtocol = protocolName
            reconcileStatus()
        } catch {
            if activeProtocol == protocolName {
                activeProtocol = nil
            }
            reconcileStatus()
            throw error
        }
    }

    func disconnect() async {
        await ikev2Manager.disconnect()
        await openVPNManager.disconnect()
        activeProtocol = nil
        reconcileStatus()
    }

    func disconnectAndForget() async {
        await ikev2Manager.disconnectAndForget()
        await openVPNManager.disconnectAndForget()
        activeProtocol = nil
        reconcileStatus()
    }

    private func reconcileStatus() {
        let ikev2Status = ikev2Manager.status
        let openVPNStatus = openVPNManager.status

        if let activeProtocol {
            let preferredStatus: VPNConnectionState = activeProtocol == .openVPN ? openVPNStatus : ikev2Status
            if preferredStatus != .disconnected {
                status = preferredStatus
                return
            }
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
}
