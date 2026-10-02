import Foundation
import AppAuth
import AppAuthCore
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct GoogleAuthorizationRequestTests {
    private let clientID = "123-test.apps.googleusercontent.com"
    private let scheme = "com.googleusercontent.apps.123-test"

    @Test func placeholdersAndWrongCallbackSchemeDisableSignIn() {
        #expect(GoogleNativeConfiguration(clientID: "IOS_CLIENT_ID_HERE", callbackScheme: scheme) == nil)
        #expect(GoogleNativeConfiguration(clientID: clientID, callbackScheme: "libreguardvpn") == nil)
        #expect(GoogleNativeConfiguration(clientID: clientID, callbackScheme: scheme)?.redirectURI == "\(scheme):/oauth2callback")
    }

    @Test func backendRegistrationAndTransactionFieldsAreValidated() throws {
        let configuration = try #require(GoogleNativeConfiguration(clientID: clientID, callbackScheme: scheme))
        let now = Date()
        try configuration.validate(begin(expiresAt: now.addingTimeInterval(600)), now: now)
        for invalid in [
            begin(clientId: "456-other.apps.googleusercontent.com"),
            begin(redirect: "\(scheme)://oauth2callback"),
            begin(expiresAt: now.addingTimeInterval(-1)),
            begin(expiresAt: now.addingTimeInterval(3600)),
            begin(state: "short"),
            begin(nonce: ""),
            begin(challenge: "not-an-s256-challenge")
        ] {
            #expect(throws: Error.self) { try configuration.validate(invalid, now: now) }
        }
    }

    @Test func authorizationCarriesOnlyPublicParametersAndBackendPKCEChallenge() throws {
        let attempt = begin()
        let request = GoogleSignInService.authorizationRequest(attempt: attempt)
        let url = request.authorizationRequestURL()
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(parameters["response_type"] == "code")
        #expect(parameters["scope"] == "openid email")
        #expect(parameters["client_id"] == clientID)
        #expect(parameters["redirect_uri"] == "\(scheme):/oauth2callback")
        #expect(parameters["state"] == attempt.state)
        #expect(parameters["nonce"] == attempt.nonce)
        #expect(parameters["code_challenge"] == attempt.codeChallenge)
        #expect(parameters["code_challenge_method"] == "S256")
        #expect(parameters["prompt"] == "select_account")
        #expect(request.codeVerifier == nil)
        #expect(request.clientSecret == nil)
        #expect(parameters["code_verifier"] == nil)
        #expect(parameters["redemptionToken"] == nil)
        #expect(parameters["attemptId"] == nil)
        #expect(!url.absoluteString.contains(attempt.redemptionToken))
    }

    @Test func callbacksRequireExactSingleSlashSchemeAndPath() throws {
        let configuration = try #require(GoogleNativeConfiguration(clientID: clientID, callbackScheme: scheme))
        #expect(configuration.acceptsCallback(URL(string: "\(scheme):/oauth2callback?code=code&state=state")!))
        for value in [
            "\(scheme)://oauth2callback?code=x",
            "\(scheme):/wrong?code=x",
            "\(scheme):/%6fauth2callback?code=x",
            "\(scheme):/oauth2callback#code=x",
            "other:/oauth2callback?code=x",
            "libreguardvpn://account/reset-password?code=x"
        ] {
            #expect(!configuration.acceptsCallback(URL(string: value)!))
        }
        let service = GoogleSignInService(configuration: configuration, presenter: { nil })
        #expect(!service.handle(url: URL(string: "\(scheme):/oauth2callback?code=late")!))
    }

    @Test func noLivePresenterFailsRecoverablyBeforeOpeningBrowser() async throws {
        let configuration = try #require(GoogleNativeConfiguration(clientID: clientID, callbackScheme: scheme))
        let service = GoogleSignInService(configuration: configuration, presenter: { nil })
        do {
            _ = try await service.signIn(attempt: begin())
            Issue.record("Expected a presentation failure")
        } catch let error as APIError {
            #expect(error.message == "Google sign-in could not open its account chooser.")
        }
        service.signOut()
        #expect(service.isConfigured)
    }

    private func begin(
        clientId: String? = nil, redirect: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(600),
        state: String = String(repeating: "s", count: 43),
        nonce: String = String(repeating: "n", count: 43),
        challenge: String = String(repeating: "c", count: 43)
    ) -> GoogleNativeBeginResponse {
        GoogleNativeBeginResponse(
            attemptId: UUID(), redemptionToken: String(repeating: "r", count: 43),
            expiresAt: expiresAt, clientId: clientId ?? clientID,
            redirectUri: redirect ?? "\(scheme):/oauth2callback", state: state,
            nonce: nonce, codeChallenge: challenge
        )
    }
}
