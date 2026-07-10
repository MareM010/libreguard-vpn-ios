import Foundation
import NetworkExtension

#if OPENVPN_PACKET_TUNNEL && !DEBUG && !canImport(OpenVPNCore)
#error("OpenVPNPacketTunnel Release builds require Vendor/OpenVPNCore/OpenVPNCore.xcframework to provide the OpenVPNCore module.")
#endif

protocol OpenVPNRuntime: AnyObject {
    var diagnostics: OpenVPNRuntimeDiagnostics { get }

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
    private(set) var diagnostics = OpenVPNRuntimeDiagnostics(
        state: .unavailable,
        engine: .missing,
        canStartConnections: false
    )

    func start(
        envelope: OpenVPNProfileEnvelope,
        provider: NEPacketTunnelProvider,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        diagnostics = OpenVPNRuntimeDiagnostics(
            state: .failed,
            serverId: envelope.serverId,
            serverName: envelope.serverName,
            serverAddress: envelope.serverAddress,
            lastError: OpenVPNRuntimeError.missingEngine.localizedDescription,
            engine: .missing,
            canStartConnections: false
        )
        completion(.failure(OpenVPNRuntimeError.missingEngine))
    }

    func stop() {
        diagnostics = OpenVPNRuntimeDiagnostics(
            state: .stopped,
            engine: .missing,
            canStartConnections: false
        )
    }
}

enum OpenVPNRuntimeError: LocalizedError, Equatable {
    case missingEngine
    case engineAdapterNotImplemented

    var errorDescription: String? {
        switch self {
        case .missingEngine:
            return "The OpenVPN 3 runtime is not yet vendored into this build."
        case .engineAdapterNotImplemented:
            return "OpenVPNCore is linked, but its engine adapter has not been bound to the vendored API."
        }
    }
}
