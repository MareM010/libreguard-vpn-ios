import AuthenticationServices
import Foundation
import Testing
@testable import libreguard_vpn_ios

@Suite(SharedVPNFixtureScope())
@MainActor
struct NewsletterConsentTests {
    @Test func pendingPromptResumesOnlyFromServerState() async throws {
        let backend = makeBackend()
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        backend.newsletterResponse = preference(pending: false)
        await model.refresh(showPrompt: true)
        #expect(model.prompt == nil)
        backend.newsletterResponse = preference(pending: true)
        await model.refresh(showPrompt: true)
        #expect(model.prompt?.preference.promptPending == true)
        model.prompt = nil
        await model.refresh()
        #expect(model.prompt == nil)
        await model.refresh(showPrompt: true)
        #expect(model.prompt != nil)
    }

    @Test func normalRefreshUpdatesAlreadyOpenPromptToCurrentServerChoice() async throws {
        let backend = makeBackend()
        let original = preference(pending: true)
        backend.newsletterResponse = original
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        let current = preference(pending: true, version: "updated-wording")
        backend.newsletterResponse = current
        await model.refresh()
        let prompt = try #require(model.prompt)
        #expect(prompt.preference == current)
        #expect(prompt.preference.revision != original.revision)
        #expect(prompt.origin == model.snapshot?.origin)
        backend.newsletterResponse = preference(subscribed: true)
        model.decide(.subscribe, prompt: prompt)
        await finishSave(model)
        #expect(backend.newsletterDecisions.count == 1)
        #expect(backend.newsletterDecisions.first?.expectedRevision == current.revision)
        #expect(backend.newsletterDecisions.first?.consentTextVersion == current.consentTextVersion)
        #expect(model.prompt == nil)
    }

    @Test func normalRefreshPreservesDismissalAndClosesCompletedPrompt() async throws {
        let backend = makeBackend()
        backend.newsletterResponse = preference(pending: true)
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        model.prompt = nil
        backend.newsletterResponse = preference(pending: true, version: "updated-wording")
        await model.refresh()
        #expect(model.prompt == nil)
        #expect(model.preference?.consentTextVersion == "updated-wording")
        await model.refresh(showPrompt: true)
        #expect(model.prompt != nil)
        backend.newsletterResponse = preference(pending: false)
        await model.refresh()
        #expect(model.prompt == nil)
    }

    @Test func settingsEnrollmentUsesRenderedWordingAndServerResult() async throws {
        let backend = makeBackend()
        let original = preference(pending: true)
        backend.newsletterResponse = original
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh()
        backend.newsletterResponse = preference(subscribed: true)
        model.setSubscribed(true, snapshot: try #require(model.snapshot))
        await finishSave(model)
        #expect(backend.newsletterUpdates.count == 1)
        #expect(backend.newsletterUpdates.first?.expectedRevision == original.revision)
        #expect(backend.newsletterUpdates.first?.consentTextVersion == original.consentTextVersion)
        #expect(model.preference?.subscribed == true)
        #expect(model.preference?.promptPending == false)
    }

    @Test func conflictRefetchesWordingWithoutRepeatingEnrollment() async throws {
        let backend = makeBackend()
        let original = preference(pending: true)
        backend.newsletterResponse = original
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        backend.newsletterResponse = preference(pending: true, version: "wording-v2")
        backend.newsletterWriteError = APIError(statusCode: 409, message: "Changed", code: "NEWSLETTER_CONSENT_TEXT_CHANGED")
        model.decide(.subscribe, prompt: try #require(model.prompt))
        await finishSave(model)
        #expect(backend.newsletterDecisions.count == 1)
        #expect(model.preference?.consentTextVersion == "wording-v2")
        #expect(model.preference?.subscribed == false)
        #expect(model.prompt?.preference.consentTextVersion == "wording-v2")
        #expect(model.errorMessage != nil)
    }

    @Test func failedSkipNeverBlocksAndResumesOnLaterAuthenticatedStart() async throws {
        let backend = makeBackend()
        backend.newsletterResponse = preference(pending: true)
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        backend.newsletterWriteError = APIError(statusCode: 503, message: "Try again later")
        model.decide(.skip, prompt: try #require(model.prompt))
        #expect(model.prompt == nil)
        await finishSave(model)
        #expect(backend.newsletterDecisions.count == 1)
        #expect(backend.newsletterDecisions.first?.consentTextVersion == nil)
        #expect(model.errorMessage != nil)
        #expect(model.preference?.promptPending == true)
        await model.refresh()
        #expect(model.prompt == nil)
        await model.refresh(showPrompt: true)
        #expect(model.prompt != nil)
    }

    @Test func unconfirmedEmailStillAllowsSkipAndWithdrawal() async throws {
        let backend = makeBackend()
        let unavailable = preference(pending: true, canSubscribe: false)
        backend.newsletterResponse = unavailable
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        model.setSubscribed(true, snapshot: try #require(model.snapshot))
        model.decide(.subscribe, prompt: try #require(model.prompt))
        #expect(backend.newsletterUpdates.isEmpty)
        #expect(backend.newsletterDecisions.isEmpty)
        backend.newsletterResponse = preference(canSubscribe: false)
        model.decide(.skip, prompt: try #require(model.prompt))
        await finishSave(model)
        #expect(backend.newsletterDecisions.first?.decision == .skip)
        let enrolled = preference(subscribed: true, canSubscribe: false)
        backend.newsletterResponse = enrolled
        await model.refresh()
        backend.newsletterResponse = preference(canSubscribe: false)
        model.setSubscribed(false, snapshot: try #require(model.snapshot))
        await finishSave(model)
        #expect(backend.newsletterUpdates.last?.subscribed == false)
        #expect(backend.newsletterUpdates.last?.consentTextVersion == nil)
    }

    @Test func queuedEnrollmentCannotUseReplacementAccount() async throws {
        let backend = makeBackend()
        let original = preference()
        backend.newsletterResponse = original
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh()
        model.setSubscribed(true, snapshot: try #require(model.snapshot))
        backend.storedSession = session(user: "account-b")
        model.updateAccount("account-b")
        await Task.yield()
        #expect(backend.newsletterUpdates.isEmpty)
        #expect(model.preference == nil)
        #expect(!model.isSaving)
    }

    @Test func displayedConsentCannotAdoptSameAccountReplacementSession() async throws {
        let backend = makeBackend()
        let unchanged = preference(pending: true)
        backend.newsletterResponse = unchanged
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        let displayed = try #require(model.snapshot)
        let displayedPrompt = try #require(model.prompt)
        var replacement = session(user: "account-a")
        replacement = AuthSession(accessToken: "new-login", refreshToken: "new-refresh",
                                  email: replacement.email, userId: replacement.userId, deviceId: replacement.deviceId)
        backend.storedSession = replacement
        // Even before the app has redrawn, the transport epoch rejects old UI.
        model.setSubscribed(true, snapshot: displayed)
        model.decide(.subscribe, prompt: displayedPrompt)
        #expect(backend.newsletterUpdates.isEmpty)
        #expect(backend.newsletterDecisions.isEmpty)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        #expect(model.preference == unchanged)
        model.setSubscribed(true, snapshot: displayed)
        model.decide(.subscribe, prompt: displayedPrompt)
        #expect(backend.newsletterUpdates.isEmpty)
        #expect(backend.newsletterDecisions.isEmpty)
    }

    @Test func queuedEnrollmentCannotUseSameAccountRelogin() async throws {
        let backend = makeBackend()
        backend.newsletterResponse = preference()
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh()
        model.setSubscribed(true, snapshot: try #require(model.snapshot))
        backend.storedSession = AuthSession(accessToken: "new-login", refreshToken: "new-refresh",
            email: "account-a@example.com", userId: "account-a", deviceId: "test-device")
        model.updateAccount("account-a")
        await Task.yield()
        #expect(backend.newsletterUpdates.isEmpty)
        #expect(!model.isSaving)
    }

    @Test func latePendingReadCannotShowPromptForReplacementAccount() async throws {
        let backend = makeBackend()
        var waiter: CheckedContinuation<NewsletterPreference, Error>?
        backend.newsletterGetHandler = { _ in
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        let pending = Task { await model.refresh(showPrompt: true) }
        for _ in 0..<1_000 { if waiter != nil { break }; await Task.yield() }
        let completion = try #require(waiter)
        backend.storedSession = session(user: "account-b")
        model.updateAccount("account-b")
        completion.resume(returning: preference(pending: true))
        await pending.value
        #expect(model.prompt == nil)
        #expect(model.preference == nil)
        #expect(!model.isLoading)
    }

    @Test func lateWriteCannotOverwriteReplacementAccount() async throws {
        let backend = makeBackend()
        let original = preference()
        backend.newsletterResponse = original
        var waiter: CheckedContinuation<NewsletterPreference, Error>?
        backend.newsletterUpdateHandler = { _ in
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh()
        model.setSubscribed(true, snapshot: try #require(model.snapshot))
        for _ in 0..<1_000 { if waiter != nil { break }; await Task.yield() }
        let completion = try #require(waiter)
        backend.storedSession = session(user: "account-b")
        model.updateAccount("account-b")
        let replacement = preference(user: "account-b")
        backend.newsletterResponse = replacement
        await model.refresh()
        completion.resume(returning: preference(subscribed: true))
        await Task.yield()
        #expect(model.preference == replacement)
        #expect(!model.isSaving)
    }

    @Test func newsletterWireContractsExcludeIdentityAndOmitWithdrawalWording() async throws {
        var requests: [URLRequest] = []
        let client = makeClient { request in
            requests.append(request)
            return self.response(request, status: 200, json: self.preferenceJSON())
        }
        let revision = UUID()
        _ = try await client.fetchNewsletterPreference(expectedAccountId: "account-a", expectedSessionEpoch: client.newsletterSessionEpoch)
        _ = try await client.updateNewsletterPreference(subscribed: true, expectedRevision: revision, consentTextVersion: "shown-v1", expectedAccountId: "account-a", expectedSessionEpoch: client.newsletterSessionEpoch)
        _ = try await client.updateNewsletterPreference(subscribed: false, expectedRevision: revision, consentTextVersion: "ignored", expectedAccountId: "account-a", expectedSessionEpoch: client.newsletterSessionEpoch)
        _ = try await client.completeNewsletterOnboarding(decision: .skip, expectedRevision: revision, consentTextVersion: "ignored", expectedAccountId: "account-a", expectedSessionEpoch: client.newsletterSessionEpoch)
        #expect(requests.map { $0.httpMethod } == ["GET", "PUT", "PUT", "POST"])
        #expect(requests.last?.url?.path == "/api/account/newsletter/onboarding")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-account-a" })
        let enroll = try body(requests[1])
        #expect(Set(enroll.keys) == Set(["subscribed", "expectedRevision", "consentTextVersion"]))
        #expect(enroll["consentTextVersion"] as? String == "shown-v1")
        #expect(try body(requests[2])["consentTextVersion"] == nil)
        #expect(try body(requests[3])["consentTextVersion"] == nil)
        #expect(try body(requests[3])["decision"] as? String == "skip")
    }

    @Test func oldOriginFailsBeforeFirstNetworkRequest() async throws {
        var calls = 0
        let client = makeClient { request in
            calls += 1
            return self.response(request, status: 200, json: self.preferenceJSON())
        }
        do {
            _ = try await client.updateNewsletterPreference(subscribed: true, expectedRevision: UUID(), consentTextVersion: "v1", expectedAccountId: "account-b", expectedSessionEpoch: client.newsletterSessionEpoch)
            Issue.record("Expected an obsolete account action to cancel")
        } catch { #expect(error is CancellationError) }
        #expect(calls == 0)
    }

    @Test func sameAccountStableEpochPreservesDisplayedStateOnTokenRefresh() async throws {
        let backend = makeBackend()
        backend.newsletterResponse = preference(pending: true)
        let model = NewsletterConsentModel(api: backend)
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        let displayed = try #require(model.snapshot)
        let prompt = try #require(model.prompt)
        let stableEpoch = backend.newsletterSessionEpoch
        backend.storedSession = AuthSession(accessToken: "refreshed", refreshToken: "refreshed-refresh",
            email: "account-a@example.com", userId: "account-a", deviceId: "test-device")
        // Mirror APIClient's internal refresh: credentials change, login epoch does not.
        backend.newsletterSessionEpoch = stableEpoch
        model.updateAccount("account-a")
        #expect(model.snapshot == displayed)
        #expect(model.prompt?.id == prompt.id)
        #expect(model.prompt?.origin == prompt.origin)
        backend.newsletterResponse = preference(subscribed: true)
        model.decide(.subscribe, prompt: prompt)
        await finishSave(model)
        #expect(backend.newsletterDecisions.count == 1)
        #expect(model.preference?.subscribed == true)
    }

    @Test func displayedEnrollmentAcceptsItsOwnRefreshedSession() async throws {
        var consentModel: NewsletterConsentModel?
        var requests: [URLRequest] = []
        let client = makeClient { request in
            requests.append(request)
            if request.url?.path == "/api/login/refresh" {
                return self.response(request, status: 200, json: [
                    "token": "refreshed", "refreshToken": "refreshed-refresh", "email": "account-a@example.com",
                    "userId": "account-a", "deviceId": "test-device"
                ])
            }
            var json = self.preferenceJSON()
            if request.httpMethod == "GET" {
                json["promptPending"] = true
                return self.response(request, status: 200, json: json)
            }
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer refreshed" {
                return self.response(request, status: 401, json: ["message": "Expired"])
            }
            // Publish the refreshed credentials during the write, as deferred restoration can.
            consentModel?.updateAccount("account-a")
            json["subscribed"] = true
            return self.response(request, status: 200, json: json)
        }
        let model = NewsletterConsentModel(api: client)
        consentModel = model
        model.updateAccount("account-a")
        await model.refresh(showPrompt: true)
        let displayed = try #require(model.snapshot)
        model.setSubscribed(true, snapshot: displayed)
        await finishSave(model)
        #expect(client.newsletterSessionEpoch == displayed.origin.sessionEpoch)
        #expect(model.snapshot?.origin == displayed.origin)
        #expect(model.preference?.subscribed == true)
        #expect(model.prompt == nil)
        #expect(requests.map { $0.httpMethod } == ["GET", "PUT", "POST", "PUT"])
        #expect(requests[1].httpBody == requests[3].httpBody)
    }

    @Test func sameAccountReloginRejectsOldTransportEpochBeforeSending() async throws {
        var calls = 0
        let client = makeClient { request in
            calls += 1
            return self.response(request, status: 200, json: self.preferenceJSON())
        }
        let displayedEpoch = client.newsletterSessionEpoch
        let replacement = try JSONDecoder().decode(LoginResponse.self, from:
            JSONSerialization.data(withJSONObject: [
                "token": "new-login", "refreshToken": "new-refresh", "email": "account-a@example.com",
                "userId": "account-a", "deviceId": "test-device"
            ]))
        _ = try client.adoptSession(from: replacement)
        do {
            _ = try await client.updateNewsletterPreference(subscribed: true, expectedRevision: UUID(),
                consentTextVersion: "v1", expectedAccountId: "account-a", expectedSessionEpoch: displayedEpoch)
            Issue.record("Expected old consent to cancel after a same-account login")
        } catch { #expect(error is CancellationError) }
        #expect(calls == 0)
    }

    @Test func consentWriteMayRefreshItsOwnSessionWithoutChangingEpoch() async throws {
        var requests: [URLRequest] = []
        let client = makeClient { request in
            requests.append(request)
            if request.url?.path == "/api/login/refresh" {
                return self.response(request, status: 200, json: [
                    "token": "refreshed", "refreshToken": "refreshed-refresh", "email": "account-a@example.com",
                    "userId": "account-a", "deviceId": "test-device"
                ])
            }
            if requests.count == 1 { return self.response(request, status: 401, json: ["message": "Expired"]) }
            return self.response(request, status: 200, json: self.preferenceJSON())
        }
        let displayedEpoch = client.newsletterSessionEpoch
        _ = try await client.updateNewsletterPreference(subscribed: true, expectedRevision: UUID(),
            consentTextVersion: "shown-v1", expectedAccountId: "account-a", expectedSessionEpoch: displayedEpoch)
        #expect(requests.map { $0.url?.path } == ["/api/account/newsletter", "/api/login/refresh", "/api/account/newsletter"])
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed")
        #expect(client.newsletterSessionEpoch == displayedEpoch)
        #expect(requests.first?.httpBody == requests.last?.httpBody)
    }

    @Test func additiveLoginMetadataRemainsOptional() throws {
        let response = try JSONDecoder().decode(LoginResponse.self, from: Data("{}".utf8))
        #expect(response.isNewAccount == nil)
        #expect(response.newsletterConsentPromptPending == nil)
    }

    private func finishSave(_ model: NewsletterConsentModel) async {
        for _ in 0..<1_000 { if !model.isSaving { break }; await Task.yield() }
        #expect(!model.isSaving)
    }

    private func makeBackend() -> StartupBackendStub {
        StartupBackendStub(storedSession: session(user: "account-a"), restoreResults: [])
    }

    private func session(user: String) -> AuthSession {
        AuthSession(accessToken: "access-\(user)", refreshToken: "refresh-\(user)",
                    email: "\(user)@example.com", userId: user, deviceId: "test-device")
    }

    private func preference(user: String = "account-a", subscribed: Bool = false, pending: Bool = false,
                            canSubscribe: Bool = true, version: String = "wording-v1") -> NewsletterPreference {
        NewsletterPreference(accountId: user, subscribed: subscribed, canSubscribe: canSubscribe,
                             promptPending: pending, consentText: "Shown consent \(version)",
                             consentTextVersion: version, privacyUrl: URL(string: "https://libreguard.net/Privacy")!,
                             revision: UUID())
    }

    private func makeClient(handler: @escaping (URLRequest) -> (Data, URLResponse)) -> APIClient {
        APIClient(transport: { request in handler(request) },
                  sessionStore: InMemorySessionStore(session: session(user: "account-a")),
                  deviceStore: StubDeviceIdentity(), deviceKeyStore: StubVPNDeviceKeyStore())
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func preferenceJSON() -> [String: Any] {
        ["accountId": "account-a", "subscribed": false, "canSubscribe": true, "promptPending": false,
         "consentText": "Shown consent", "consentTextVersion": "wording-v1",
         "privacyUrl": "https://libreguard.net/Privacy", "revision": UUID().uuidString]
    }

    private func response(_ request: URLRequest, status: Int, json: [String: Any]) -> (Data, URLResponse) {
        (try! JSONSerialization.data(withJSONObject: json),
         HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor
final class NewsletterAppleSigningStub: AppleSigning {
    private(set) var credentialCalls = 0
    func prepare(_ request: ASAuthorizationAppleIDRequest) {}
    func credential(from result: Result<ASAuthorization, Error>) throws -> AppleSignInCredential {
        credentialCalls += 1
        return AppleSignInCredential(idToken: "apple-token", nonce: "nonce", userIdentifier: "apple-user")
    }
}
