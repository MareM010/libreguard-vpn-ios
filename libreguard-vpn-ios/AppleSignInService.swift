import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct AppleSignInCredential: Equatable {
    let idToken: String
    let nonce: String
    let userIdentifier: String
}

enum AppleCredentialState: Equatable {
    case authorized
    case revoked
    case notFound
    case transferred
    case unknown
}

struct AppleCredentialBinding: Codable, Equatable {
    let userIdentifier: String
    let backendUserId: String
}

@MainActor
protocol AppleCredentialStateChecking: AnyObject {
    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState
}

@MainActor
final class AppleCredentialStateService: AppleCredentialStateChecking {
    private let provider: ASAuthorizationAppleIDProvider

    init(provider: ASAuthorizationAppleIDProvider = ASAuthorizationAppleIDProvider()) {
        self.provider = provider
    }

    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        try await withCheckedThrowingContinuation { continuation in
            provider.getCredentialState(forUserID: userIdentifier) { state, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let resolved: AppleCredentialState = switch state {
                case .authorized: .authorized
                case .revoked: .revoked
                case .notFound: .notFound
                case .transferred: .transferred
                @unknown default: .unknown
                }
                continuation.resume(returning: resolved)
            }
        }
    }
}

@MainActor
protocol AppleCredentialBindingStoring: AnyObject {
    func load() -> AppleCredentialBinding?
    func save(_ binding: AppleCredentialBinding) throws
    func clear()
}

@MainActor
final class AppleCredentialBindingStore: AppleCredentialBindingStoring {
    private let keychain: KeychainStore
    private let key = "apple.credential.binding"

    init(keychain: KeychainStore? = nil) {
        self.keychain = keychain ?? KeychainStore()
    }

    func load() -> AppleCredentialBinding? {
        guard let data = keychain.data(for: key) else { return nil }
        return try? JSONDecoder().decode(AppleCredentialBinding.self, from: data)
    }

    func save(_ binding: AppleCredentialBinding) throws {
        try keychain.set(JSONEncoder().encode(binding), for: key)
    }

    func clear() {
        keychain.remove(key)
    }
}

enum AppleSignInServiceError: LocalizedError {
    case nonceGenerationFailed(OSStatus)
    case requestNotPrepared
    case invalidCredential
    case missingIdentityToken

    var errorDescription: String? {
        switch self {
        case .nonceGenerationFailed:
            "Apple Sign-In could not create a secure request. Please try again."
        case .requestNotPrepared:
            "Apple Sign-In could not verify this request. Please try again."
        case .invalidCredential, .missingIdentityToken:
            "Apple did not return a valid identity token. Please try again."
        }
    }
}

@MainActor
protocol AppleSigning: AnyObject {
    func prepare(_ request: ASAuthorizationAppleIDRequest)
    func credential(from result: Result<ASAuthorization, Error>) throws -> AppleSignInCredential
}

@MainActor
final class AppleSignInService: AppleSigning {
    private let nonceGenerator: () throws -> String
    private var pendingNonce: String?
    private var preparationError: Error?

    init(nonceGenerator: @escaping () throws -> String = { try AppleSignInService.generateNonce() }) {
        self.nonceGenerator = nonceGenerator
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        clearPendingRequest()
        request.requestedScopes = [.email]

        do {
            let nonce = try nonceGenerator()
            pendingNonce = nonce
            request.nonce = Self.sha256(nonce)
        } catch {
            preparationError = error
        }
    }

    func credential(from result: Result<ASAuthorization, Error>) throws -> AppleSignInCredential {
        defer { clearPendingRequest() }

        if let preparationError {
            throw preparationError
        }
        guard let pendingNonce else {
            throw AppleSignInServiceError.requestNotPrepared
        }

        let authorization = try result.get()
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            throw AppleSignInServiceError.invalidCredential
        }
        guard !credential.user.isEmpty else {
            throw AppleSignInServiceError.invalidCredential
        }
        guard let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              !idToken.isEmpty else {
            throw AppleSignInServiceError.missingIdentityToken
        }

        return AppleSignInCredential(
            idToken: idToken,
            nonce: pendingNonce,
            userIdentifier: credential.user
        )
    }

    nonisolated static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func generateNonce(byteCount: Int = 32) throws -> String {
        precondition(byteCount > 0)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AppleSignInServiceError.nonceGenerationFailed(status)
        }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    var hasPendingRequest: Bool {
        pendingNonce != nil || preparationError != nil
    }

    private func clearPendingRequest() {
        pendingNonce = nil
        preparationError = nil
    }
}
