import Foundation
import CryptoKit
import Security

protocol VPNDeviceKeyProviding: AnyObject {
    func publicKeyPayload() throws -> DevicePublicKeyPayload
    func decryptPassphrase(from encryptedPassphrase: EncryptedPassphrase) throws -> String
}

final class VPNDeviceKeyStore: VPNDeviceKeyProviding {
    private let applicationTag = Data("net.libreguard.libreguard-vpn-ios.vpn-device-key".utf8)
    private let keySizeInBits = 3072

    private var cachedPrivateKey: SecKey?
    private var cachedPayload: DevicePublicKeyPayload?

    func publicKeyPayload() throws -> DevicePublicKeyPayload {
        if let cachedPayload {
            return cachedPayload
        }

        let privateKey = try loadOrCreatePrivateKey()
        let publicKey = try unwrapPublicKey(from: privateKey)
        let spki = try makeSubjectPublicKeyInfo(from: publicKey)

        let payload = DevicePublicKeyPayload(
            devicePublicKey: spki.base64EncodedString(),
            devicePublicKeyId: Self.sha256Hex(of: spki),
            devicePublicKeyAlgorithm: "RSA-OAEP-256"
        )
        cachedPrivateKey = privateKey
        cachedPayload = payload
        return payload
    }

    func decryptPassphrase(from encryptedPassphrase: EncryptedPassphrase) throws -> String {
        let payload = try publicKeyPayload()
        guard encryptedPassphrase.algorithm.uppercased() == "RSA-OAEP-256" else {
            throw VPNDeviceKeyError.unsupportedAlgorithm(encryptedPassphrase.algorithm)
        }
        guard encryptedPassphrase.keyId.lowercased() == payload.devicePublicKeyId.lowercased() else {
            throw VPNDeviceKeyError.keyIdentifierMismatch(expected: payload.devicePublicKeyId, actual: encryptedPassphrase.keyId)
        }
        guard let ciphertext = Data(base64Encoded: encryptedPassphrase.ciphertext, options: [.ignoreUnknownCharacters]) else {
            throw VPNDeviceKeyError.invalidCiphertext
        }

        let privateKey = try loadOrCreatePrivateKey()
        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA256,
            ciphertext as CFData,
            &error
        ) as Data? else {
            if let cfError = error?.takeRetainedValue() {
                throw cfError as Error
            }
            throw VPNDeviceKeyError.decryptionFailed
        }

        guard let passphrase = String(data: plaintext, encoding: .utf8) else {
            throw VPNDeviceKeyError.invalidDecryptedPayload
        }
        return passphrase
    }

    private func loadOrCreatePrivateKey() throws -> SecKey {
        if let cachedPrivateKey {
            return cachedPrivateKey
        }

        if let existing = try loadPrivateKeyFromKeychain() {
            cachedPrivateKey = existing
            return existing
        }

        let privateKey = try createPrivateKey()
        cachedPrivateKey = privateKey
        return privateKey
    }

    private func loadPrivateKeyFromKeychain() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as! SecKey
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    private func createPrivateKey() throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySizeInBits,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: applicationTag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let cfError = error?.takeRetainedValue() {
                throw cfError as Error
            }
            throw VPNDeviceKeyError.keyGenerationFailed
        }
        return privateKey
    }

    private func unwrapPublicKey(from privateKey: SecKey) throws -> SecKey {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw VPNDeviceKeyError.publicKeyUnavailable
        }
        return publicKey
    }

    private func makeSubjectPublicKeyInfo(from publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            if let cfError = error?.takeRetainedValue() {
                throw cfError as Error
            }
            throw VPNDeviceKeyError.publicKeyExportFailed
        }

        let algorithmIdentifier = Data([
            0x30, 0x0D,
            0x06, 0x09,
            0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
            0x05, 0x00
        ])
        let publicKeyBitString = Self.derEncoded(tag: 0x03, contents: Data([0x00]) + pkcs1)
        return Self.derEncoded(tag: 0x30, contents: algorithmIdentifier + publicKeyBitString)
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func derEncoded(tag: UInt8, contents: Data) -> Data {
        var data = Data([tag])
        data.append(derLength(contents.count))
        data.append(contents)
        return data
    }

    private static func derLength(_ length: Int) -> Data {
        precondition(length >= 0)
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var remaining = length
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }

        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

enum VPNDeviceKeyError: LocalizedError {
    case keyGenerationFailed
    case publicKeyUnavailable
    case publicKeyExportFailed
    case unsupportedAlgorithm(String)
    case keyIdentifierMismatch(expected: String, actual: String)
    case invalidCiphertext
    case decryptionFailed
    case invalidDecryptedPayload

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Unable to create the device encryption key."
        case .publicKeyUnavailable:
            return "The VPN device public key is unavailable."
        case .publicKeyExportFailed:
            return "The VPN device public key could not be exported."
        case let .unsupportedAlgorithm(algorithm):
            return "Unsupported passphrase algorithm: \(algorithm)"
        case let .keyIdentifierMismatch(expected, actual):
            return "Device key mismatch. Expected \(expected), received \(actual)."
        case .invalidCiphertext:
            return "The encrypted passphrase payload is invalid."
        case .decryptionFailed:
            return "Unable to decrypt the VPN passphrase."
        case .invalidDecryptedPayload:
            return "The decrypted passphrase is not valid UTF-8."
        }
    }
}
