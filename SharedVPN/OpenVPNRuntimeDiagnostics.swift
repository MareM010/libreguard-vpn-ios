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
    case openVPNCore = "OpenVPNCore"
    case missing = "Missing"
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
