import Foundation

enum OpenVPNRuntimeConnectionState: String, Codable, Equatable {
    case idle
    case starting
    case connected
    case reconnecting
    case stopping
    case stopped
    case failed
    case unavailable
}

enum OpenVPNRuntimeEngine: String, Codable, Equatable {
    case tunnelKit = "TunnelKit"
}

struct OpenVPNRuntimeDiagnostics: Codable, Equatable {
    var state: OpenVPNRuntimeConnectionState
    var serverId: Int?
    var serverName: String?
    var serverAddress: String?
    var connectedAt: Date?
    var lastError: String?
    var engine: OpenVPNRuntimeEngine
    var canStartConnections: Bool

    init(
        state: OpenVPNRuntimeConnectionState = .idle,
        serverId: Int? = nil,
        serverName: String? = nil,
        serverAddress: String? = nil,
        connectedAt: Date? = nil,
        lastError: String? = nil,
        engine: OpenVPNRuntimeEngine,
        canStartConnections: Bool
    ) {
        self.state = state
        self.serverId = serverId
        self.serverName = serverName
        self.serverAddress = serverAddress
        self.connectedAt = connectedAt
        self.lastError = lastError
        self.engine = engine
        self.canStartConnections = canStartConnections
    }
}

/// Keeps the last packet-tunnel lifecycle events in the app group. Network
/// Extension can invalidate or terminate the provider before its final OSLog
/// message reaches the containing app, so this gives us a durable breadcrumb.
enum OpenVPNExtensionLifecycleJournal {
    private static let filename = "openvpn-lifecycle.log"
    private static let maximumBytes = 32_000

    static func append(_ event: String) {
        guard !event.isEmpty,
              let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: VPNSharedConstants.appGroupIdentifier
              ) else {
            return
        }

        let url = containerURL.appendingPathComponent(filename)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(event)\n"
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(contentsOf: Data(line.utf8))
        if data.count > maximumBytes {
            data = data.suffix(maximumBytes)
        }
        try? data.write(to: url, options: .atomic)
    }

    static func tail(maximumCharacters: Int = 8_000) -> String? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: VPNSharedConstants.appGroupIdentifier
        ) else {
            return nil
        }
        let url = containerURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8),
              !contents.isEmpty else {
            return nil
        }
        return String(contents.suffix(maximumCharacters))
    }
}
