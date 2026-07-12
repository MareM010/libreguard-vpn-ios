import Foundation

struct OpenVPNConnectionMetadata: Codable, Equatable {
    let serverId: Int
    let serverName: String
    let serverAddress: String
}

enum OpenVPNConnectionMetadataStore {
    private static let key = "libreguard.openvpn.connection-metadata"

    static func save(_ metadata: OpenVPNConnectionMetadata) throws {
        guard let defaults = UserDefaults(suiteName: OpenVPNConstants.appGroupIdentifier) else {
            throw OpenVPNMetadataError.appGroupUnavailable
        }
        defaults.set(try JSONEncoder().encode(metadata), forKey: key)
    }

    static func load() -> OpenVPNConnectionMetadata? {
        guard let defaults = UserDefaults(suiteName: OpenVPNConstants.appGroupIdentifier),
              let data = defaults.data(forKey: key) else {
            return nil
        }
        return try? JSONDecoder().decode(OpenVPNConnectionMetadata.self, from: data)
    }

    static func clear() {
        UserDefaults(suiteName: OpenVPNConstants.appGroupIdentifier)?.removeObject(forKey: key)
    }
}

enum OpenVPNMetadataError: LocalizedError {
    case appGroupUnavailable

    var errorDescription: String? {
        "The shared OpenVPN App Group is unavailable. Check signing and entitlements."
    }
}
