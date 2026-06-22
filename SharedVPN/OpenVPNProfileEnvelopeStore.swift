import Foundation

protocol OpenVPNProfileEnvelopeStoring: AnyObject {
    func save(_ envelope: OpenVPNProfileEnvelope) throws -> Data
    func load() throws -> OpenVPNProfileEnvelope?
    func load(persistentReference: Data) throws -> OpenVPNProfileEnvelope?
    func persistentReference() throws -> Data?
    func clear()
}

final class OpenVPNProfileEnvelopeStore: OpenVPNProfileEnvelopeStoring {
    private let keychain: SharedKeychainDataStoring
    private let account: String

    init(
        keychain: SharedKeychainDataStoring = SharedKeychainStore(
            service: OpenVPNConstants.profileKeychainService,
            accessGroup: KeychainAccessGroupResolver.resolve(suffix: OpenVPNConstants.accessGroupSuffix)
        ),
        account: String = OpenVPNConstants.profileKeychainAccount
    ) {
        self.keychain = keychain
        self.account = account
    }

    func save(_ envelope: OpenVPNProfileEnvelope) throws -> Data {
        let data = try JSONEncoder.openVPNProfileEnvelopeEncoder.encode(envelope)
        try keychain.set(data, for: account)
        guard let persistentReference = try keychain.persistentReference(for: account) else {
            throw OpenVPNProfileStoreError.persistentReferenceUnavailable
        }
        return persistentReference
    }

    func load() throws -> OpenVPNProfileEnvelope? {
        guard let data = keychain.data(for: account) else { return nil }
        return try decodeEnvelope(from: data)
    }

    func load(persistentReference: Data) throws -> OpenVPNProfileEnvelope? {
        guard let data = try keychain.data(forPersistentReference: persistentReference) else { return nil }
        return try decodeEnvelope(from: data)
    }

    func persistentReference() throws -> Data? {
        try keychain.persistentReference(for: account)
    }

    func clear() {
        keychain.remove(account)
    }

    private func decodeEnvelope(from data: Data) throws -> OpenVPNProfileEnvelope {
        do {
            return try JSONDecoder.openVPNProfileEnvelopeDecoder.decode(OpenVPNProfileEnvelope.self, from: data)
        } catch {
            throw OpenVPNProfileStoreError.decodeFailed(error)
        }
    }
}

enum OpenVPNProfileStoreError: LocalizedError {
    case persistentReferenceUnavailable
    case decodeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .persistentReferenceUnavailable:
            return "The OpenVPN profile keychain item could not be referenced."
        case let .decodeFailed(error):
            return "The OpenVPN profile envelope could not be decoded: \(error.localizedDescription)"
        }
    }
}

private extension JSONEncoder {
    static var openVPNProfileEnvelopeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(OpenVPNProfileEnvelopeStore.iso8601Formatter.string(from: date))
        }
        return encoder
    }
}

private extension JSONDecoder {
    static var openVPNProfileEnvelopeDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = OpenVPNProfileEnvelopeStore.iso8601Formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date string: \(string)"
                )
            }
            return date
        }
        return decoder
    }
}

private extension OpenVPNProfileEnvelopeStore {
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
