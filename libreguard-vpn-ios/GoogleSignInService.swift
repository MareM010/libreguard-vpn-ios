import Foundation
import UIKit
import AppAuth
import AppAuthCore

struct GoogleAuthorizationResult: Equatable {
    let code: String
    let state: String
}

struct GoogleNativeConfiguration {
    let clientID: String
    let redirectURI: String

    init?(clientID: String, callbackScheme: String) {
        guard clientID.range(of: #"^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#,
                             options: .regularExpression) != nil else { return nil }
        let reversedID = clientID.split(separator: ".").reversed().joined(separator: ".")
        guard callbackScheme == reversedID else { return nil }
        self.clientID = clientID
        redirectURI = "\(reversedID):/oauth2callback"
    }

    static func load(bundle: Bundle = .main) -> GoogleNativeConfiguration? {
        guard let clientID = bundle.object(forInfoDictionaryKey: "LibreGuardGoogleClientID") as? String,
              let scheme = bundle.object(forInfoDictionaryKey: "LibreGuardGoogleCallbackScheme") as? String,
              let urlTypes = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              urlTypes.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) else { return nil }
        return GoogleNativeConfiguration(clientID: clientID, callbackScheme: scheme)
    }

    func validate(_ attempt: GoogleNativeBeginResponse, now: Date = Date()) throws {
        guard attempt.clientId == clientID, attempt.redirectUri == redirectURI,
              attempt.expiresAt > now, attempt.expiresAt.timeIntervalSince(now) <= 660,
              !attempt.redemptionToken.isEmpty,
              Self.isOpaque(attempt.state), Self.isOpaque(attempt.nonce),
              attempt.codeChallenge.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
            throw APIError(message: "Google sign-in configuration is invalid. Please try again.", code: "GOOGLE_CONFIGURATION_INVALID")
        }
    }

    func acceptsCallback(_ url: URL) -> Bool {
        guard let expected = URLComponents(string: redirectURI),
              let returned = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return returned.scheme == expected.scheme && returned.host == nil
            && returned.user == nil && returned.password == nil && returned.port == nil
            && returned.percentEncodedPath == expected.percentEncodedPath && returned.fragment == nil
    }

    private static func isOpaque(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{32,128}$"#, options: .regularExpression) != nil
    }
}

@MainActor
protocol GoogleSigning: AnyObject {
    var isConfigured: Bool { get }
    func signIn(attempt: GoogleNativeBeginResponse) async throws -> GoogleAuthorizationResult
    func signOut()
    func handle(url: URL) -> Bool
}

/// Authorization only. The backend owns PKCE and the token exchange; no Google
/// identity/access/refresh tokens or OIDAuthState are created or persisted here.
@MainActor
final class GoogleSignInService: GoogleSigning {
    private let configuration: GoogleNativeConfiguration?
    private let presenter: () -> UIViewController?
    private var activeID: UUID?
    private var session: OIDExternalUserAgentSession?
    private var continuation: CheckedContinuation<GoogleAuthorizationResult, Error>?
    private var expiryTask: Task<Void, Never>?

    var isConfigured: Bool { configuration != nil }

    init(configuration: GoogleNativeConfiguration? = GoogleNativeConfiguration.load(),
         presenter: @escaping () -> UIViewController? = { UIApplication.shared.activeViewController }) {
        self.configuration = configuration
        self.presenter = presenter
    }

    func signIn(attempt: GoogleNativeBeginResponse) async throws -> GoogleAuthorizationResult {
        guard activeID == nil else {
            throw APIError(message: "Google sign-in is already open.")
        }
        guard let configuration else {
            throw APIError(message: "Google sign-in is not configured for this build.")
        }
        try configuration.validate(attempt)
        guard let presenter = presenter(), presenter.viewIfLoaded?.window != nil else {
            throw APIError(message: "Google sign-in could not open its account chooser.")
        }
        try Task.checkCancellation()
        let id = UUID()
        activeID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                expiryTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0, attempt.expiresAt.timeIntervalSinceNow) * 1_000_000_000))
                    } catch { return }
                    self?.finish(id: id, result: .failure(APIError(message: "Google sign-in expired. Start again.", code: "GOOGLE_LOGIN_EXPIRED")), cancelBrowser: true)
                }
                session = OIDAuthorizationService.present(
                    Self.authorizationRequest(attempt: attempt),
                    presenting: presenter,
                    prefersEphemeralSession: true
                ) { [weak self] response, error in
                    Task { @MainActor in
                        guard let self, self.activeID == id else { return }
                        if let error {
                            let failure = error as NSError
                            let cancelled = failure.domain == OIDGeneralErrorDomain
                                && (failure.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
                                    || failure.code == OIDErrorCode.programCanceledAuthorizationFlow.rawValue)
                            if cancelled {
                                self.finish(id: id, result: .failure(CancellationError()))
                            } else {
                                self.finish(id: id, result: .failure(APIError(message: "Google sign-in failed. Please try again.")))
                            }
                        } else if let response, let code = response.authorizationCode, !code.isEmpty,
                                  response.state == attempt.state, attempt.expiresAt > Date() {
                            self.finish(id: id, result: .success(GoogleAuthorizationResult(code: code, state: attempt.state)))
                        } else {
                            self.finish(id: id, result: .failure(APIError(message: "Google returned an invalid sign-in response.")))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.activeID == id else { return }
                self.signOut()
            }
        }
    }

    static func authorizationRequest(attempt: GoogleNativeBeginResponse) -> OIDAuthorizationRequest {
        let provider = OIDServiceConfiguration(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
        )
        return OIDAuthorizationRequest(
            configuration: provider, clientId: attempt.clientId, clientSecret: nil,
            scope: "openid email", redirectURL: URL(string: attempt.redirectUri)!,
            responseType: OIDResponseTypeCode, state: attempt.state, nonce: attempt.nonce,
            codeVerifier: nil, codeChallenge: attempt.codeChallenge,
            codeChallengeMethod: "S256", additionalParameters: ["prompt": "select_account"]
        )
    }

    func signOut() {
        guard let id = activeID else { return }
        finish(id: id, result: .failure(CancellationError()), cancelBrowser: true)
    }

    func handle(url: URL) -> Bool {
        guard activeID != nil, configuration?.acceptsCallback(url) == true else { return false }
        return session?.resumeExternalUserAgentFlow(with: url) ?? false
    }

    private func finish(id: UUID, result: Result<GoogleAuthorizationResult, Error>, cancelBrowser: Bool = false) {
        guard activeID == id else { return }
        let pending = continuation
        let browser = session
        activeID = nil
        continuation = nil
        session = nil
        expiryTask?.cancel()
        expiryTask = nil
        if cancelBrowser { browser?.cancel() }
        pending?.resume(with: result)
    }
}

private extension UIApplication {
    var activeViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let root = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        return root?.topmostViewController
    }
}

private extension UIViewController {
    var topmostViewController: UIViewController {
        if let presentedViewController { return presentedViewController.topmostViewController }
        if let navigation = self as? UINavigationController { return navigation.visibleViewController?.topmostViewController ?? navigation }
        if let tabs = self as? UITabBarController { return tabs.selectedViewController?.topmostViewController ?? tabs }
        return self
    }
}
