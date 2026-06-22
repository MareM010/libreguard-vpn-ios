import Foundation
import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? OpenVPNConstants.tunnelBundleIdentifier,
        category: "PacketTunnel"
    )
    private let profileStore: OpenVPNProfileEnvelopeStoring = OpenVPNProfileEnvelopeStore()
    private let runtime: OpenVPNRuntime = OpenVPNRuntimeFactory.make()

    override func startTunnel(options: [String : NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        logger.info("OpenVPN packet tunnel start requested")

        guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(OpenVPNProviderError.missingProtocolConfiguration)
            return
        }
        guard let profileReference = tunnelProtocol.passwordReference else {
            completionHandler(OpenVPNProviderError.missingProfileReference)
            return
        }

        do {
            guard let envelope = try profileStore.load(persistentReference: profileReference) else {
                throw OpenVPNProviderError.profileNotFound
            }
            guard !envelope.isExpired else {
                throw OpenVPNProfileError.expiredCertificate
            }

            let configuration = try OpenVPNProfileConfiguration.parse(envelope.configContent)
            try configuration.validateMobileCompatibility()

            runtime.start(envelope: envelope, provider: self) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.logger.info("OpenVPN runtime reported a successful start")
                    completionHandler(nil)
                case .failure(let error):
                    self.logger.error("OpenVPN runtime failed to start: \(Self.describe(error))")
                    completionHandler(error)
                }
            }
        } catch {
            logger.error("OpenVPN packet tunnel start failed: \(Self.describe(error))")
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("OpenVPN packet tunnel stop requested with reason \(reason.rawValue, privacy: .public)")
        runtime.stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        completionHandler?(nil)
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }
}

enum OpenVPNProviderError: LocalizedError {
    case missingProtocolConfiguration
    case missingProfileReference
    case profileNotFound

    var errorDescription: String? {
        switch self {
        case .missingProtocolConfiguration:
            return "The OpenVPN tunnel configuration is missing."
        case .missingProfileReference:
            return "The OpenVPN profile reference is missing."
        case .profileNotFound:
            return "The OpenVPN profile could not be loaded from keychain."
        }
    }
}

