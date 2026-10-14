import Foundation
import AuthenticationServices
import CryptoKit
import Security
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct AppleRecoveryStart: Decodable, Equatable, Sendable {
    let recoveryId: UUID
    let authorizationUrl: URL
    let expiresAtUtc: Date
}
struct AppleRecoveryStatus: Decodable, Equatable, Sendable {
    let recoveryId: UUID
    let status: String
    let expiresAtUtc: Date
}
struct AppleRecoveryRequestBody: Encodable {
    let signedTransactionInfo: String
    let state: String
    let codeChallenge: String
    let codeChallengeMethod = "S256"
}
struct AppleRecoveryRedeemBody: Encodable { let codeVerifier: String }

enum AppleRecoveryError: LocalizedError {
    case invalidResponse, unavailable, accountChanged
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The purchase recovery response could not be verified. Start recovery again."
        case .unavailable: "Purchase recovery is unavailable. Recover the previous account or contact support."
        case .accountChanged: "Your signed-in account changed. Start recovery again on the intended account."
        }
    }
}
struct AppleRecoveryProof: Sendable {
    let state: String
    let verifier: String
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    init() throws {
        state = try Self.random()
        verifier = try Self.random()
    }
    init(state: String, verifier: String) { self.state = state; self.verifier = verifier }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppleRecoveryError.unavailable }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func validate(start: AppleRecoveryStart, host: String = "management.libreguard.net") throws {
        guard start.expiresAtUtc > Date(), start.authorizationUrl.scheme == "https",
            start.authorizationUrl.host == host, start.authorizationUrl.port == nil,
            start.authorizationUrl.user == nil, start.authorizationUrl.password == nil,
            start.authorizationUrl.query == nil,
            start.authorizationUrl.path.lowercased() == "/account/applepurchaserecovery/" + start.recoveryId.uuidString.lowercased(),
            let fragment = start.authorizationUrl.fragment,
            fragment.hasPrefix("launch="),
            String(fragment.dropFirst(7)).range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
        else { throw AppleRecoveryError.invalidResponse }
    }
    func validate(callback: URL, id: UUID, scheme: String) throws {
        guard callback.scheme == scheme, callback.host == "complete", callback.path.isEmpty,
              callback.port == nil, callback.user == nil, callback.password == nil, callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 2,
              items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "recoveryId" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              items.first(where: { $0.name == "recoveryId" })?.value.flatMap(UUID.init(uuidString:)) == id
        else { throw AppleRecoveryError.invalidResponse }
    }
}
@MainActor protocol AppleRecoveryBrowserServing: AnyObject {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}
@MainActor final class AppleRecoveryBrowser: NSObject, AppleRecoveryBrowserServing, ASWebAuthenticationPresentationContextProviding {
    private var browser: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var operationID: UUID?
    private var timeout: Task<Void, Never>?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        cancel()
        let id = UUID()
        operationID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, self.operationID == id else { return }
                        let continuation = self.continuation
                        self.continuation = nil; self.operationID = nil; self.browser = nil
                        self.timeout?.cancel(); self.timeout = nil
                        if let result { continuation?.resume(returning: result) }
                        else { continuation?.resume(throwing: error ?? AppleRecoveryError.unavailable) }
                    }
                }
                session.prefersEphemeralWebBrowserSession = true
                session.presentationContextProvider = self
                browser = session
                if !session.start() { cancel() }
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    guard self?.operationID == id else { return }
                    self?.cancel()
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    func cancel() {
        let pending = continuation
        continuation = nil; operationID = nil
        timeout?.cancel(); timeout = nil
        browser?.cancel(); browser = nil
        pending?.resume(throwing: CancellationError())
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
        #endif
    }
}
