import Foundation
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@MainActor
protocol GoogleSigning: AnyObject {
    func signIn() async throws -> String
    func signOut()
    func handle(url: URL) -> Bool
}

@MainActor
final class GoogleSignInService: GoogleSigning {
    func signIn() async throws -> String {
        #if canImport(GoogleSignIn)
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              !clientID.isEmpty,
              !clientID.contains("GOOGLE_IOS_CLIENT_ID") else {
            throw APIError(message: "Google Sign-In is not configured. Add the iOS OAuth client ID to the app configuration.")
        }

        let serverClientID = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID?.isEmpty == false ? serverClientID : nil
        )

        guard let presenter = UIApplication.shared.activeViewController else {
            throw APIError(message: "Google Sign-In could not open its account chooser.")
        }

        let result: GIDSignInResult = try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                if let error { continuation.resume(throwing: error) }
                else if let result { continuation.resume(returning: result) }
                else { continuation.resume(throwing: APIError(message: "Google Sign-In was cancelled.")) }
            }
        }

        let user: GIDGoogleUser = try await withCheckedThrowingContinuation { continuation in
            result.user.refreshTokensIfNeeded { user, error in
                if let error { continuation.resume(throwing: error) }
                else if let user { continuation.resume(returning: user) }
                else { continuation.resume(throwing: APIError(message: "Google did not return an account token.")) }
            }
        }

        guard let idToken = user.idToken?.tokenString, !idToken.isEmpty else {
            throw APIError(message: "Google did not return an ID token for LibreGuard.")
        }
        return idToken
        #else
        throw APIError(message: "Google Sign-In is unavailable in this build.")
        #endif
    }

    func signOut() {
        #if canImport(GoogleSignIn)
        GIDSignIn.sharedInstance.signOut()
        #endif
    }

    func handle(url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        return GIDSignIn.sharedInstance.handle(url)
        #else
        return false
        #endif
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
