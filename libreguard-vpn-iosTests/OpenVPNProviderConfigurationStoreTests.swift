import Foundation
import Testing
@testable import libreguard_vpn_ios

nonisolated final class MemoryVPNKeychain: SharedKeychainDataStoring {
    var items: [String: Data] = [:]
    var rejectsWrites = false
    func data(for account: String) -> Data? { items[account] }
    func set(_ data: Data, for account: String) throws {
        if rejectsWrites { throw OpenVPNCredentialError.credentialsUnavailable }
        items[account] = data
    }
    func remove(_ account: String) { items.removeValue(forKey: account) }
    func persistentReference(for account: String) throws -> Data? { nil }
    func data(forPersistentReference persistentReference: Data) throws -> Data? { nil }
}

@Suite @MainActor
struct OpenVPNProviderConfigurationStoreTests {
    private var legacy: [String: Any] {
        ["appGroup": OpenVPNConstants.appGroupIdentifier,
         OpenVPNConstants.ipv6BlockingConfigurationKey: true,
         "sessionConfiguration": ["clientKey": "private-key-fixture", "tlsWrap": ["key": "tls-crypt-fixture"], "mtu": 1280],
         "masksPrivateData": true, "shouldDebug": false]
    }

    @Test func persistedConfigurationContainsNoKeysOrSessionSecrets() throws {
        let keychain = MemoryVPNKeychain()
        let store = OpenVPNProviderConfigurationStore(keychain: keychain)
        let protected = try store.protect(legacy)
        let serialized = try PropertyListSerialization.data(fromPropertyList: protected, format: .xml, options: 0)
        #expect(serialized.range(of: Data("private-key-fixture".utf8)) == nil)
        #expect(serialized.range(of: Data("tls-crypt-fixture".utf8)) == nil)
        #expect(protected["sessionConfiguration"] == nil)
        #expect(keychain.items.count == 1)
        let resolved = try store.resolve(protected)
        let session = try #require(resolved["sessionConfiguration"] as? [String: Any])
        #expect(session["clientKey"] as? String == "private-key-fixture")
        #expect(session["mtu"] as? Int == 1280)
        #expect(resolved[OpenVPNConstants.ipv6BlockingConfigurationKey] as? Bool == true)
    }

    @Test func unavailableOrDeletedCredentialsFailClosed() throws {
        let store = OpenVPNProviderConfigurationStore(keychain: MemoryVPNKeychain())
        let protected = try store.protect(legacy)
        store.remove(protected)
        #expect(throws: (any Error).self) { try store.resolve(protected) }
        #expect(throws: (any Error).self) { try store.resolve(legacy) }
    }

    @Test func connectionMetadataUpdatesCannotReplaceKeychainSecrets() throws {
        let store = OpenVPNProviderConfigurationStore(keychain: MemoryVPNKeychain())
        var protected = try store.protect(legacy)
        protected["resolvedAddresses"] = ["203.0.113.20"]
        protected["sessionConfiguration"] = ["clientKey": "replacement"]
        protected["masksPrivateData"] = false
        let resolved = try store.resolve(protected)
        #expect((resolved["sessionConfiguration"] as? [String: Any])?["clientKey"] as? String == "private-key-fixture")
        #expect(resolved["resolvedAddresses"] as? [String] == ["203.0.113.20"])
        #expect(resolved["masksPrivateData"] as? Bool == true)
    }

    @Test func keychainFailureCannotReturnAnInsecureFallback() {
        let keychain = MemoryVPNKeychain()
        keychain.rejectsWrites = true
        let store = OpenVPNProviderConfigurationStore(keychain: keychain)
        #expect(throws: (any Error).self) { try store.protect(legacy) }
        #expect(keychain.items.isEmpty)
    }

    @Test func unsupportedReferenceVersionFailsClosed() throws {
        let store = OpenVPNProviderConfigurationStore(keychain: MemoryVPNKeychain())
        var protected = try store.protect(legacy)
        protected[OpenVPNProviderConfigurationStore.versionKey] = 2
        #expect(throws: (any Error).self) { try store.resolve(protected) }
    }
}
