import Foundation
import NetworkExtension

protocol OpenVPNRuntime: AnyObject {
    func start(
        envelope: OpenVPNProfileEnvelope,
        provider: NEPacketTunnelProvider,
        completion: @escaping (Result<Void, Error>) -> Void
    )

    func stop()
}

enum OpenVPNRuntimeFactory {
    static func make() -> OpenVPNRuntime {
        #if canImport(OpenVPNCore)
        return OpenVPNCoreRuntime()
        #else
        return UnavailableOpenVPNRuntime()
        #endif
    }
}

final class UnavailableOpenVPNRuntime: OpenVPNRuntime {
    func start(
        envelope: OpenVPNProfileEnvelope,
        provider: NEPacketTunnelProvider,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        completion(.failure(OpenVPNRuntimeError.missingEngine))
    }

    func stop() {}
}

enum OpenVPNRuntimeError: LocalizedError {
    case missingEngine

    var errorDescription: String? {
        switch self {
        case .missingEngine:
            return "The OpenVPN 3 runtime is not yet vendored into this build."
        }
    }
}

