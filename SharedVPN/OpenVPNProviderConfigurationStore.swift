import Foundation

/// Both targets declare the same first Keychain access group. The service
/// namespaces these items separately from account tokens and device identity.
nonisolated final class OpenVPNProviderConfigurationStore {
    static let referenceKey = "LibreGuardCredentialReference"
    static let versionKey = "LibreGuardCredentialFormatVersion"
    private let keychain: SharedKeychainDataStoring
    private static let metadataKeys = [
        "appGroup", "resolvedAddresses", "prefersResolvedAddresses",
        OpenVPNConstants.ipv6BlockingConfigurationKey
    ]

    init(keychain: SharedKeychainDataStoring = SharedKeychainStore(
        service: "net.libreguard.libreguard-vpn-ios.openvpn.configuration"
    )) {
        self.keychain = keychain
    }

    static func reference(in configuration: [String: Any]) -> String? {
        guard let raw = configuration[referenceKey] as? String,
              let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString
    }

    static func isLegacy(_ configuration: [String: Any]) -> Bool {
        configuration[referenceKey] == nil && configuration["sessionConfiguration"] != nil
    }

    func protect(_ configuration: [String: Any]) throws -> [String: Any] {
        guard configuration[Self.referenceKey] == nil,
              let session = configuration["sessionConfiguration"] as? [String: Any],
              session["clientKey"] != nil, session["tlsWrap"] != nil else {
            throw OpenVPNCredentialError.invalidConfiguration
        }
        let data = try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)
        guard data.count <= 4 * 1_024 * 1_024 else { throw OpenVPNCredentialError.invalidConfiguration }
        let reference = UUID().uuidString
        try keychain.set(data, for: reference)
        var protected: [String: Any] = [Self.referenceKey: reference, Self.versionKey: 1]
        for key in Self.metadataKeys { protected[key] = configuration[key] }
        return protected
    }

    func resolve(_ configuration: [String: Any]) throws -> [String: Any] {
        // Never accept the previous plaintext format in the extension. The app
        // migrates it through saveToPreferences before the next tunnel start.
        guard configuration[Self.versionKey] as? Int == 1,
              let reference = Self.reference(in: configuration),
              let data = keychain.data(for: reference), data.count <= 4 * 1_024 * 1_024,
              var full = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let session = full["sessionConfiguration"] as? [String: Any],
              session["clientKey"] != nil, session["tlsWrap"] != nil else {
            throw OpenVPNCredentialError.credentialsUnavailable
        }
        // Only connection metadata can override the authenticated Keychain
        // payload. Arbitrary preference fields cannot replace stored secrets.
        for key in Self.metadataKeys {
            if let value = configuration[key] { full[key] = value }
        }
        full["masksPrivateData"] = true
        #if !DEBUG
        full["shouldDebug"] = false
        #endif
        return full
    }

    func remove(_ configuration: [String: Any]) {
        guard let reference = Self.reference(in: configuration) else { return }
        keychain.remove(reference)
    }
}

nonisolated enum OpenVPNCredentialError: LocalizedError {
    case invalidConfiguration
    case credentialsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The OpenVPN profile is incomplete and could not be stored securely."
        case .credentialsUnavailable:
            "Secure OpenVPN credentials are unavailable. Unlock your device and reconnect from LibreGuard."
        }
    }
}
