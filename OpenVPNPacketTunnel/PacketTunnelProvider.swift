import Foundation
import NetworkExtension
import OSLog
import TunnelKitOpenVPNAppExtension

final class PacketTunnelProvider: OpenVPNTunnelProvider {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? OpenVPNConstants.tunnelBundleIdentifier,
        category: "PacketTunnel"
    )
    private let diagnosticsLock = NSLock()
    private var storedDiagnostics = OpenVPNRuntimeDiagnostics(
        state: .idle,
        engine: .tunnelKit,
        canStartConnections: true
    )

    private var diagnostics: OpenVPNRuntimeDiagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return storedDiagnostics
    }

    override var reasserting: Bool {
        didSet {
            mutateDiagnostics { diagnostics in
                diagnostics.state = reasserting ? .reconnecting : .connected
                if !reasserting, diagnostics.connectedAt == nil {
                    diagnostics.connectedAt = Date()
                }
            }
        }
    }

    override func startTunnel(options: [String: NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        logger.info("OpenVPN packet tunnel start requested")
        let metadata = OpenVPNConnectionMetadataStore.load()
        mutateDiagnostics { diagnostics in
            diagnostics = OpenVPNRuntimeDiagnostics(
                state: .starting,
                serverId: metadata?.serverId,
                serverName: metadata?.serverName,
                serverAddress: metadata?.serverAddress,
                engine: .tunnelKit,
                canStartConnections: true
            )
        }

        super.startTunnel(options: options) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            self.mutateDiagnostics { diagnostics in
                if let error {
                    diagnostics.state = .failed
                    diagnostics.lastError = error.localizedDescription
                } else {
                    diagnostics.state = .connected
                    diagnostics.connectedAt = Date()
                    diagnostics.lastError = nil
                }
            }
            if let error {
                self.logger.error("OpenVPN tunnel failed to start: \(Self.describe(error))")
            } else {
                self.logger.info("OpenVPN tunnel connected")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        logger.info("OpenVPN packet tunnel stop requested with reason \(reason.rawValue, privacy: .public)")
        mutateDiagnostics { $0.state = .stopping }
        super.stopTunnel(with: reason) { [weak self] in
            self?.mutateDiagnostics { diagnostics in
                diagnostics.state = .stopped
                diagnostics.connectedAt = nil
            }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = try? OpenVPNProviderMessageCodec.decodeRequest(from: messageData) else {
            super.handleAppMessage(messageData, completionHandler: completionHandler)
            return
        }

        let response = try? OpenVPNProviderMessageCodec.encodeResponse(
            type: request.type,
            diagnostics: diagnostics
        )
        completionHandler?(response)
    }

    private func mutateDiagnostics(_ mutation: (inout OpenVPNRuntimeDiagnostics) -> Void) {
        diagnosticsLock.lock()
        mutation(&storedDiagnostics)
        diagnosticsLock.unlock()
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }
}
