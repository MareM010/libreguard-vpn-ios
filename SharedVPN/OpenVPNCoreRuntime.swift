#if canImport(OpenVPNCore)
import Foundation
import NetworkExtension
import OpenVPNCore

final class OpenVPNCoreRuntime: OpenVPNRuntime {
    private(set) var diagnostics = OpenVPNRuntimeDiagnostics(
        state: .idle,
        engine: .openVPNCore,
        canStartConnections: true
    )

    private var activeProvider: NEPacketTunnelProvider?

    func start(
        envelope: OpenVPNProfileEnvelope,
        provider: NEPacketTunnelProvider,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        activeProvider = provider
        diagnostics = OpenVPNRuntimeDiagnostics(
            state: .starting,
            serverId: envelope.serverId,
            serverName: envelope.serverName,
            serverAddress: envelope.serverAddress,
            engine: .openVPNCore,
            canStartConnections: true
        )

        diagnostics = OpenVPNRuntimeDiagnostics(
            state: .failed,
            serverId: envelope.serverId,
            serverName: envelope.serverName,
            serverAddress: envelope.serverAddress,
            lastError: OpenVPNRuntimeError.engineAdapterNotImplemented.localizedDescription,
            engine: .openVPNCore,
            canStartConnections: false
        )
        completion(.failure(OpenVPNRuntimeError.engineAdapterNotImplemented))
    }

    func stop() {
        diagnostics.state = .stopping
        activeProvider = nil
        diagnostics.state = .stopped
    }
}
#endif
