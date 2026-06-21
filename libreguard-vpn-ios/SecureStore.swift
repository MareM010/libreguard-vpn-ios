import Foundation
import Security

protocol SessionStoring: AnyObject {
    var session: AuthSession? { get }
    func save(_ session: AuthSession) throws
    func clear()
}

final class KeychainStore {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "net.libreguard.libreguard-vpn-ios") {
        self.service = service
    }

    func data(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func set(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func remove(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

final class SessionStore: SessionStoring {
    private let keychain: KeychainStore
    private let sessionKey = "auth.session"
    private(set) var session: AuthSession?

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        if let data = keychain.data(for: sessionKey) {
            session = try? JSONDecoder().decode(AuthSession.self, from: data)
        }
    }

    func save(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        try keychain.set(data, for: sessionKey)
        self.session = session
    }

    func clear() {
        keychain.remove(sessionKey)
        session = nil
    }
}

protocol DeviceIdentifying: AnyObject {
    var deviceId: String { get }
    var appVersion: String { get }
}

final class DeviceIdentityStore: DeviceIdentifying {
    private let keychain: KeychainStore
    private let key = "device.identifier"

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    var deviceId: String {
        if let data = keychain.data(for: key), let existing = String(data: data, encoding: .utf8) {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        try? keychain.set(Data(generated.utf8), for: key)
        return generated
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
