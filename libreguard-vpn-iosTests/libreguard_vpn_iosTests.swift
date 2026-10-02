import Foundation
import AuthenticationServices
import SwiftData
import SwiftUI
import StoreKit
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct libreguard_vpn_iosTests {
    @Test func themeModeDefaultsToSystemForMissingOrInvalidStorage() {
        #expect(ThemeMode.fromStoredValue(nil) == .system)
        #expect(ThemeMode.fromStoredValue("unsupported") == .system)
        #expect(ThemeMode.fromStoredValue(ThemeMode.dark.rawValue) == .dark)
    }

    @Test func themeModeMapsToTheExpectedColorSchemeOverride() {
        #expect(ThemeMode.system.colorSchemeOverride == nil)
        #expect(ThemeMode.light.colorSchemeOverride == .light)
        #expect(ThemeMode.dark.colorSchemeOverride == .dark)
    }

    @Test func favoriteServerStorePersistsNewestFirstPerAccount() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserDefaultsFavoriteServerStore(defaults: defaults)

        store.saveFavoriteServerIDs([42, 17], for: "user-a")
        store.saveFavoriteServerIDs([99], for: "user-b")

        let restoredStore = UserDefaultsFavoriteServerStore(defaults: defaults)
        #expect(restoredStore.favoriteServerIDs(for: "user-a") == [42, 17])
        #expect(restoredStore.favoriteServerIDs(for: "user-b") == [99])

        restoredStore.saveFavoriteServerIDs([], for: "user-a")
        #expect(restoredStore.favoriteServerIDs(for: "user-a").isEmpty)
        #expect(restoredStore.favoriteServerIDs(for: "user-b") == [99])
    }

    @Test func appModelLoadsAndPersistsFavoritesForTheActiveAccount() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserDefaultsFavoriteServerStore(defaults: defaults)
        let app = AppModel(favoriteServerStore: store, defaults: defaults)
        let firstAccount = AuthSession(
            accessToken: "access-a",
            refreshToken: "refresh-a",
            email: "a@example.com",
            userId: "user-a",
            deviceId: "device"
        )
        let secondAccount = AuthSession(
            accessToken: "access-b",
            refreshToken: "refresh-b",
            email: "b@example.com",
            userId: "user-b",
            deviceId: "device"
        )

        app.session = firstAccount
        app.toggleFavoriteServer(17)
        app.toggleFavoriteServer(42)
        #expect(app.favoriteServerIDs == [42, 17])
        #expect(app.selectedServerID == nil)

        app.session = secondAccount
        #expect(app.favoriteServerIDs.isEmpty)
        app.toggleFavoriteServer(99)

        app.session = firstAccount
        #expect(app.favoriteServerIDs == [42, 17])
        app.session = nil
        #expect(app.favoriteServerIDs.isEmpty)
        #expect(store.favoriteServerIDs(for: "user-a") == [42, 17])
        #expect(store.favoriteServerIDs(for: "user-b") == [99])
    }

    @Test func unscopedPlanCacheIsIgnoredForAStoredAccount() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("Pro", forKey: "cached.plan.name")
        defaults.set(true, forKey: "cached.plan.isPro")
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let app = makeStartupApp(
            backend: backend,
            vpn: StartupVPNManager(status: .disconnected),
            defaults: defaults
        )

        #expect(app.currentPlanDisplayName == "Free")
        #expect(app.isProUser == false)
        #expect(defaults.string(forKey: "cached.plan.name") == nil)
    }

    @Test func validRestoredSessionKeepsConnectedVPNOnTheDashboard() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "vpn.autoConnect.enabled")
        let session = startupSession()
        let backend = StartupBackendStub(storedSession: session, restoreResults: [.success(session)])
        let vpn = StartupVPNManager(status: .connected)
        let app = makeStartupApp(backend: backend, vpn: vpn, defaults: defaults)
        VPNSharedSessionStore.clear()
        defer { VPNSharedSessionStore.clear() }

        await app.start()

        if case .authenticated = app.route {
        } else {
            Issue.record("Expected a restored session to show the dashboard")
        }
        #expect(app.session?.userId == session.userId)
        #expect(app.isAutoConnectEnabled)
        #expect(vpn.cleanupCalls == 0)
    }

    @Test func missingSessionDisablesStoppedPersistedProfileBeforeLogin() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "vpn.autoConnect.enabled")
        defaults.set(true, forKey: "vpn.killSwitch.enabled")
        let disabledProfileLeftInstalled = VPNProfileCleanupResult(
            tunnelStopped: true,
            onDemandDisabled: true,
            profileRemoved: false,
            diagnostic: "preference removal failed after the tunnel stopped"
        )
        let vpn = StartupVPNManager(status: .connected, cleanupResults: [disabledProfileLeftInstalled])
        let app = makeStartupApp(
            backend: StartupBackendStub(storedSession: nil, restoreResults: []),
            vpn: vpn,
            defaults: defaults
        )
        VPNSharedSessionStore.clear()
        defer { VPNSharedSessionStore.clear() }

        await app.start()

        if case .login = app.route {
        } else {
            Issue.record("Expected login after the stopped profile was persistently disabled")
        }
        #expect(vpn.cleanupCalls == 1)
        #expect(vpn.disableCalls == 1)
        #expect(app.isAutoConnectEnabled == false)
        #expect(app.isKillSwitchEnabled == false)
        #expect(app.presentedError?.code == "SESSION_ENDED")
    }

    @Test func invalidStartupSessionCleansUpVPNBeforeShowingLogin() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(true, forKey: "vpn.autoConnect.enabled")
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [
            .failure(APIError(statusCode: 401, message: "Expired", code: "SESSION_EXPIRED", requiresLogin: true))
        ])
        let vpn = StartupVPNManager(status: .connected)
        let app = makeStartupApp(backend: backend, vpn: vpn, defaults: defaults)
        VPNSharedSessionStore.clear()
        defer { VPNSharedSessionStore.clear() }

        await app.start()

        if case .login = app.route {
        } else {
            Issue.record("Expected login only after VPN cleanup")
        }
        #expect(vpn.cleanupCalls == 1)
        #expect(vpn.disableCalls == 1)
        #expect(app.isAutoConnectEnabled == false)
        #expect(app.session == nil)
        #expect(app.presentedError?.code == "SESSION_ENDED")
        #expect(backend.sessionInvalidationCallbackCount == 1)
    }

    @Test func incompleteVPNCleanupBlocksLoginUntilRetrySucceeds() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let unsafeCleanup = VPNProfileCleanupResult(
            tunnelStopped: false,
            onDemandDisabled: true,
            profileRemoved: false,
            diagnostic: "still stopping"
        )
        let vpn = StartupVPNManager(status: .connected, cleanupResults: [unsafeCleanup, .noProfile])
        let app = makeStartupApp(backend: StartupBackendStub(storedSession: nil, restoreResults: []), vpn: vpn, defaults: defaults)
        VPNSharedSessionStore.clear()
        defer { VPNSharedSessionStore.clear() }

        await app.start()

        if case .sessionCleanup = app.route {
        } else {
            Issue.record("Expected cleanup screen while tunnel status is uncertain")
        }
        #expect(app.sessionCleanupState == .requiresRetry)
        #expect(vpn.cleanupCalls == 1)

        await app.retrySessionCleanup()

        if case .login = app.route {
        } else {
            Issue.record("Expected login after confirmed cleanup")
        }
        #expect(app.sessionCleanupState == nil)
        #expect(vpn.cleanupCalls == 2)
    }

    @Test func transientRestoreFailureKeepsCachedDashboardAndCanValidateLater() async {
        let session = startupSession()
        let transientError = APIError(message: "Service temporarily unavailable")
        let backend = StartupBackendStub(storedSession: session, restoreResults: [.failure(transientError), .success(session)])
        let vpn = StartupVPNManager(status: .connected)
        let app = makeStartupApp(
            backend: backend,
            vpn: vpn,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        VPNSharedSessionStore.clear()
        defer { VPNSharedSessionStore.clear() }

        await app.start()

        if case .authenticated = app.route {
        } else {
            Issue.record("Expected cached dashboard after a transient restore failure")
        }
        #expect(app.session?.userId == session.userId)
        #expect(vpn.cleanupCalls == 0)

        await app.retrySessionValidationIfNeeded()

        if case .authenticated = app.route {
        } else {
            Issue.record("Expected the later session validation to remain authenticated")
        }
        #expect(vpn.cleanupCalls == 0)
    }

    @Test func themeModeUsesAndroidCopyForSubtitlesAndButtonTitles() {
        #expect(
            ThemeMode.system.subtitle(effectiveDarkMode: true) ==
                "Following system theme • Currently Dark"
        )
        #expect(
            ThemeMode.system.subtitle(effectiveDarkMode: false) ==
                "Following system theme • Currently Light"
        )
        #expect(ThemeMode.light.subtitle(effectiveDarkMode: true) == "Manual theme override • Always Light")
        #expect(ThemeMode.dark.subtitle(effectiveDarkMode: false) == "Manual theme override • Always Dark")

        #expect(ThemeMode.system.buttonTitle(effectiveDarkMode: true, isSelected: true) == "System • Dark")
        #expect(ThemeMode.system.buttonTitle(effectiveDarkMode: false, isSelected: true) == "System • Light")
        #expect(ThemeMode.system.buttonTitle(effectiveDarkMode: true, isSelected: false) == "System")
        #expect(ThemeMode.light.buttonTitle(effectiveDarkMode: true, isSelected: false) == "Light")
        #expect(ThemeMode.dark.buttonTitle(effectiveDarkMode: false, isSelected: false) == "Dark")
    }

    @Test func registrationRequestSendsNewsletterConsentValue() async throws {
        try await withSerializedRequests {
            var receivedValues: [Bool] = []
            let client = makeClient { request in
                #expect(request.url?.path == "/api/register")
                let json = try #require(JSONSerialization.jsonObject(with: requestBody(from: request)) as? [String: Any])
                receivedValues.append(try #require(json["newsletterConsent"] as? Bool))
                return try makeResponse(request, status: 200, json: [
                    "message": "Check your inbox.",
                    "userId": "pending-user",
                    "email": "person@example.com",
                    "requiresEmailConfirmation": true
                ])
            }

            _ = try await client.register(email: "person@example.com", password: "Password1!", newsletterConsent: true)
            _ = try await client.register(email: "person@example.com", password: "Password1!", newsletterConsent: false)

            #expect(receivedValues == [true, false])
        }
    }

    @Test func nativeGoogleBeginBindsPlatformDeviceAndOptionalConsent() async throws {
        try await withSerializedRequests {
            var received: [[String: Any]] = []
            let client = makeClient { request in
                #expect(request.url?.path == "/api/login/google/native/begin")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                received.append(try #require(JSONSerialization.jsonObject(with: requestBody(from: request)) as? [String: Any]))
                return try makeResponse(request, status: 200, json: googleBeginJSON)
            }
            _ = try await client.beginGoogleLogin()
            _ = try await client.beginGoogleLogin(newsletterConsent: true)
            #expect(received.count == 2)
            #expect(received[0]["platform"] as? String == "ios")
            #expect(received[0]["deviceId"] as? String == "test-device")
            #expect(received[0]["appVersion"] as? String == "1.0-test")
            #expect(received[0]["devicePublicKey"] as? String == "base64-spki")
            #expect(received[0]["devicePublicKeyId"] as? String == "device-key-id")
            #expect(received[0]["devicePublicKeyAlgorithm"] as? String == "RSA-OAEP-256")
            #expect(received[0]["newsletterConsent"] == nil)
            #expect(received[1]["newsletterConsent"] as? Bool == true)
            #expect(received.allSatisfy { $0["idToken"] == nil && $0["codeVerifier"] == nil && $0["clientSecret"] == nil })
        }
    }

    @Test func nativeGoogleCompleteAndContinueSendOnlyBackendCapabilities() async throws {
        try await withSerializedRequests {
            var paths: [String] = []
            var bodies: [[String: Any]] = []
            let client = makeClient { request in
                paths.append(try #require(request.url?.path))
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                bodies.append(try #require(JSONSerialization.jsonObject(with: requestBody(from: request)) as? [String: Any]))
                return try makeResponse(request, status: 200, json: [:])
            }
            let begin = try googleBegin()
            _ = try await client.completeGoogleLogin(attempt: begin, authorization: GoogleAuthorizationResult(code: "one-use-code", state: begin.state))
            _ = try await client.continueGoogleLogin(token: "single-use-continuation", deviceIdsToRemove: [42])
            #expect(paths == ["/api/login/google/native/complete", "/api/login/google/native/continue"])
            #expect(Set(bodies[0].keys) == Set(["attemptId", "redemptionToken", "code", "state"]))
            #expect(bodies[0]["redemptionToken"] as? String == begin.redemptionToken)
            #expect(bodies[0]["code"] as? String == "one-use-code")
            #expect(Set(bodies[1].keys) == Set(["loginContinuationToken", "deviceIdsToRemove"]))
            #expect(bodies[1]["deviceIdsToRemove"] as? [Int] == [42])
        }
    }

    @Test func nativeGoogleRedemptionDoesNotRetryFailedRequests() async throws {
        try await withSerializedRequests {
            var calls = 0
            let client = makeClient { request in
                calls += 1
                return try makeResponse(request, status: 503, json: ["message": "Restart sign-in", "errorCode": "GOOGLE_AUTHORIZATION_FAILED"])
            }
            do {
                _ = try await client.completeGoogleLogin(attempt: googleBegin(), authorization: GoogleAuthorizationResult(code: "one-use-code", state: String(repeating: "s", count: 43)))
                Issue.record("Expected failure")
            } catch let error as APIError {
                #expect(error.code == "GOOGLE_AUTHORIZATION_FAILED")
            }
            #expect(calls == 1)
        }
    }

    @Test func appleLoginSendsNonceDeviceKeyAndOptionalConsent() async throws {
        try await withSerializedRequests {
            var receivedBodies: [[String: Any]] = []
            let client = makeClient { request in
                #expect(request.url?.path == "/api/login/apple")
                receivedBodies.append(try #require(
                    JSONSerialization.jsonObject(with: requestBody(from: request)) as? [String: Any]
                ))
                return try makeResponse(request, status: 200, json: [:])
            }

            _ = try await client.loginWithApple(idToken: "login-token", nonce: "login-nonce")
            _ = try await client.loginWithApple(
                idToken: "registration-token",
                nonce: "registration-nonce",
                newsletterConsent: true
            )

            #expect(receivedBodies.count == 2)
            #expect(receivedBodies[0]["idToken"] as? String == "login-token")
            #expect(receivedBodies[0]["nonce"] as? String == "login-nonce")
            #expect(receivedBodies[0]["newsletterConsent"] == nil)
            #expect(receivedBodies[0]["deviceId"] as? String == "test-device")
            #expect(receivedBodies[0]["appVersion"] as? String == "1.0-test")
            #expect(receivedBodies[0]["devicePublicKey"] as? String == "base64-spki")
            #expect(receivedBodies[0]["devicePublicKeyId"] as? String == "device-key-id")
            #expect(receivedBodies[0]["devicePublicKeyAlgorithm"] as? String == "RSA-OAEP-256")
            #expect(receivedBodies[1]["idToken"] as? String == "registration-token")
            #expect(receivedBodies[1]["nonce"] as? String == "registration-nonce")
            #expect(receivedBodies[1]["newsletterConsent"] as? Bool == true)
        }
    }

    @Test func appleDeviceRemovalSendsProviderNonceAndDevice() async throws {
        try await withSerializedRequests {
            var receivedBodies: [[String: Any]] = []
            let client = makeClient { request in
                #expect(request.url?.path == "/api/devices/pre-auth/oauth/remove")
                receivedBodies.append(try #require(
                    JSONSerialization.jsonObject(with: requestBody(from: request)) as? [String: Any]
                ))
                return try makeResponse(request, status: 200, json: [
                    "success": true,
                    "message": "Removed",
                    "deviceId": 42,
                    "removedDeviceCount": 1
                ])
            }

            try await client.removeAppleDevice(idToken: "apple-token", nonce: "apple-nonce", deviceId: 42)

            #expect(receivedBodies.count == 1)
            #expect(receivedBodies[0]["provider"] as? String == "Apple")
            #expect(receivedBodies[0]["idToken"] as? String == "apple-token")
            #expect(receivedBodies[0]["nonce"] as? String == "apple-nonce")
            #expect(receivedBodies[0]["deviceIdToRemove"] as? Int == 42)
        }
    }

    @Test func appleNonceIsRandomBase64URLAndHashesDeterministically() throws {
        let first = try AppleSignInService.generateNonce()
        let second = try AppleSignInService.generateNonce()

        #expect(first.count == 43)
        #expect(second.count == 43)
        #expect(first != second)
        #expect(first.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        #expect(AppleSignInService.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func appleRequestHashesNonceAndClearsItAfterCancellation() {
        let service = AppleSignInService(nonceGenerator: { "fixed-raw-nonce" })
        let request = ASAuthorizationAppleIDProvider().createRequest()
        service.prepare(request)

        #expect(request.requestedScopes == [.email])
        #expect(request.nonce == AppleSignInService.sha256("fixed-raw-nonce"))
        #expect(service.hasPendingRequest)

        let cancellation = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.canceled.rawValue
        )
        #expect(throws: Error.self) {
            _ = try service.credential(from: .failure(cancellation))
        }
        #expect(!service.hasPendingRequest)
    }

    @Test func appleCancellationIsSilentAndOtherAuthorizationErrorsArePresented() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        let vpn = StartupVPNManager(status: .disconnected)
        let service = AppleSignInService(nonceGenerator: { "fixed-raw-nonce" })
        let app = makeStartupApp(
            backend: backend,
            vpn: vpn,
            defaults: defaults,
            appleSignIn: service
        )

        app.prepareAppleSignIn(ASAuthorizationAppleIDProvider().createRequest())
        #expect(app.isAuthenticating)
        let cancellation = NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.canceled.rawValue
        )
        await app.completeAppleSignIn(.failure(cancellation))
        #expect(app.presentedError == nil)
        #expect(!app.isAuthenticating)
        #expect(!service.hasPendingRequest)

        app.prepareAppleSignIn(ASAuthorizationAppleIDProvider().createRequest())
        await app.completeAppleSignIn(.failure(NSError(
            domain: ASAuthorizationError.errorDomain,
            code: ASAuthorizationError.failed.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Authorization failed"]
        )))
        #expect(app.presentedError?.message == "Authorization failed")
        #expect(!service.hasPendingRequest)
    }

    @Test func appleDeviceRemovalRetryPreservesTokenNonceAndConsent() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.appleLoginResponse = try JSONDecoder().decode(
            LoginResponse.self,
            from: Data("""
                {
                  "requiresTwoFactor": true,
                  "pendingLoginToken": "pending-token",
                  "email": "person@example.com",
                  "userId": "user-1",
                  "deviceId": "test-device"
                }
                """.utf8)
        )
        let limit = try JSONDecoder().decode(
            DeviceLimitResponse.self,
            from: Data("""
                {
                  "message": "Device limit reached",
                  "errorCode": "DEVICE_LIMIT_EXCEEDED",
                  "currentDevices": 1,
                  "maxDevices": 1,
                  "planType": "Free",
                  "devices": [{ "id": 42, "deviceIdHash": "device-hash" }]
                }
                """.utf8)
        )
        let context = DeviceLimitContext(
            response: limit,
            attempt: .apple(
                idToken: "apple-token",
                nonce: "raw-nonce",
                newsletterConsent: true,
                userIdentifier: "apple-user"
            ),
            afterTwoFactor: false
        )
        let app = makeStartupApp(
            backend: backend,
            vpn: StartupVPNManager(status: .disconnected),
            defaults: defaults
        )

        await app.removeDeviceAndRetry(try #require(limit.devices.first), context: context)

        #expect(backend.removedAppleDeviceId == 42)
        #expect(backend.removedAppleToken == "apple-token")
        #expect(backend.removedAppleNonce == "raw-nonce")
        #expect(backend.appleLoginIdToken == "apple-token")
        #expect(backend.appleLoginNonce == "raw-nonce")
        #expect(backend.appleLoginConsent == true)
        if case let .twoFactor(challenge) = app.route {
            if case let .apple(idToken, nonce, consent, userIdentifier) = challenge.attempt {
                #expect(idToken == "apple-token")
                #expect(nonce == "raw-nonce")
                #expect(consent == true)
                #expect(userIdentifier == "apple-user")
            } else {
                Issue.record("Expected the Apple login attempt to survive the 2FA transition")
            }
        } else {
            Issue.record("Expected a two-factor route after retry")
        }
    }

    @Test func successfulAppleRetryBindsCredentialToBackendSession() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.appleLoginResponse = try loginResponse(userId: "user-apple")
        let bindingStore = InMemoryAppleCredentialBindingStore()
        let limit = try JSONDecoder().decode(
            DeviceLimitResponse.self,
            from: Data("""
                {
                  "message": "Device limit reached",
                  "errorCode": "DEVICE_LIMIT_EXCEEDED",
                  "currentDevices": 1,
                  "maxDevices": 1,
                  "planType": "Free",
                  "devices": [{ "id": 42, "deviceIdHash": "device-hash" }]
                }
                """.utf8)
        )
        let app = makeStartupApp(
            backend: backend,
            vpn: StartupVPNManager(status: .disconnected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            appleCredentialBindingStore: bindingStore
        )
        let context = DeviceLimitContext(
            response: limit,
            attempt: .apple(
                idToken: "apple-token",
                nonce: "raw-nonce",
                newsletterConsent: nil,
                userIdentifier: "apple-user-identifier"
            ),
            afterTwoFactor: false
        )

        await app.removeDeviceAndRetry(try #require(limit.devices.first), context: context)

        #expect(bindingStore.binding == AppleCredentialBinding(
            userIdentifier: "apple-user-identifier",
            backendUserId: "user-apple"
        ))
        #expect(app.session?.userId == "user-apple")
    }

    @Test func successfulPasswordLoginClearsPreviousAppleCredentialBinding() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.passwordLoginResponse = try loginResponse(userId: "password-user")
        let bindingStore = InMemoryAppleCredentialBindingStore(binding: AppleCredentialBinding(
            userIdentifier: "old-apple-user",
            backendUserId: "old-backend-user"
        ))
        let app = makeStartupApp(
            backend: backend,
            vpn: StartupVPNManager(status: .disconnected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            appleCredentialBindingStore: bindingStore
        )

        await app.login(email: "person@example.com", password: "Password1!")

        #expect(bindingStore.binding == nil)
        #expect(app.session?.userId == "password-user")
    }

    @Test func staleAccountRefreshCannotRestorePreviousPlanAfterSignOutAndLogin() async throws {
        let oldSession = AuthSession(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            email: "pro@example.com",
            userId: "pro-user",
            deviceId: "test-device"
        )
        let backend = StartupBackendStub(storedSession: oldSession, restoreResults: [])
        backend.holdFirstSubscriptionRequest = true
        backend.subscriptionResults = [
            .success(try subscriptionStatus(plan: "Pro", isPro: true)),
            .success(try subscriptionStatus(plan: "Free", isPro: false))
        ]
        backend.passwordLoginResponse = try loginResponse(userId: "free-user")
        let app = makeStartupApp(
            backend: backend,
            vpn: StartupVPNManager(status: .disconnected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        app.session = oldSession

        let oldRefresh = Task { @MainActor in
            await app.refreshAccountData(showErrors: false)
        }
        await backend.waitForFirstSubscriptionRequest()

        await app.signOut()
        await app.login(email: "free@example.com", password: "Password1!")

        backend.releaseFirstSubscriptionRequest()
        await oldRefresh.value

        #expect(app.session?.userId == "free-user")
        #expect(app.subscription?.isPro == false)
        #expect(app.currentPlanDisplayName == "Free")
        #expect(app.isProUser == false)
    }

    @Test func freeAccountCannotEnableAutoConnectWithoutUpgradePrompt() async {
        let app = makeStartupApp(
            backend: StartupBackendStub(storedSession: nil, restoreResults: []),
            vpn: StartupVPNManager(status: .disconnected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        await app.setAutoConnectEnabled(true)

        #expect(app.isAutoConnectEnabled == false)
        #expect(app.upgradePromptRequested)
    }

    @Test(arguments: [
        AppleCredentialState.revoked,
        AppleCredentialState.notFound,
        AppleCredentialState.transferred
    ])
    func terminalAppleCredentialStateDisconnectsAndClearsSessionAtStartup(
        state: AppleCredentialState
    ) async {
        let session = startupSession()
        let backend = StartupBackendStub(storedSession: session, restoreResults: [.success(session)])
        let vpn = StartupVPNManager(status: .connected)
        let bindingStore = InMemoryAppleCredentialBindingStore(binding: AppleCredentialBinding(
            userIdentifier: "apple-user",
            backendUserId: session.userId
        ))
        let checker = StubAppleCredentialStateChecker(result: .success(state))
        let app = makeStartupApp(
            backend: backend,
            vpn: vpn,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            appleCredentialStateChecker: checker,
            appleCredentialBindingStore: bindingStore
        )

        await app.start()

        #expect(app.session == nil)
        #expect(bindingStore.binding == nil)
        #expect(vpn.cleanupCalls == 1)
        #expect(app.presentedError?.code == "SESSION_ENDED")
    }

    @Test func transientAppleCredentialStateFailurePreservesSession() async {
        let session = startupSession()
        let backend = StartupBackendStub(storedSession: session, restoreResults: [.success(session)])
        let binding = AppleCredentialBinding(userIdentifier: "apple-user", backendUserId: session.userId)
        let bindingStore = InMemoryAppleCredentialBindingStore(binding: binding)
        let checker = StubAppleCredentialStateChecker(result: .failure(APIError(message: "Offline")))
        let app = makeStartupApp(
            backend: backend,
            vpn: StartupVPNManager(status: .connected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            appleCredentialStateChecker: checker,
            appleCredentialBindingStore: bindingStore
        )

        await app.start()

        #expect(app.session == session)
        #expect(bindingStore.binding == binding)
        if case .authenticated = app.route {
        } else {
            Issue.record("A transient Apple credential-state failure must preserve the session")
        }
    }

    @Test func nativeAppleRevocationNotificationTriggersCredentialCheckAndCleanup() async {
        let session = startupSession()
        let backend = StartupBackendStub(storedSession: session, restoreResults: [.success(session)])
        let vpn = StartupVPNManager(status: .connected)
        let bindingStore = InMemoryAppleCredentialBindingStore(binding: AppleCredentialBinding(
            userIdentifier: "apple-user",
            backendUserId: session.userId
        ))
        let checker = StubAppleCredentialStateChecker(result: .success(.authorized))
        let notificationCenter = NotificationCenter()
        let app = makeStartupApp(
            backend: backend,
            vpn: vpn,
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            appleCredentialStateChecker: checker,
            appleCredentialBindingStore: bindingStore,
            notificationCenter: notificationCenter
        )
        await app.start()
        checker.result = .success(.notFound)

        notificationCenter.post(name: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(app.session == nil)
        #expect(bindingStore.binding == nil)
        #expect(vpn.cleanupCalls == 1)
    }

    @Test func connectionEligibilityUsesReadOnlyBackendPreflight() async throws {
        try await withSerializedRequests {
            let session = AuthSession(
                accessToken: "usage-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                #expect(request.url?.path == "/api/usage/can-connect")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer usage-access")
                return try makeResponse(request, status: 200, json: [
                    "allowed": false,
                    "reason": "Data limit exceeded for this billing period",
                    "bytesUsed": 5_368_709_120,
                    "bytesLimit": 5_368_709_120,
                    "resetDate": "2026-07-01T00:00:00Z",
                    "isUnlimited": false,
                    "message": "Upgrade to Pro for unlimited data."
                ])
            }

            let response = try await client.fetchConnectionEligibility()
            #expect(response.allowed == false)
            #expect(response.bytesLimit == 5_368_709_120)
            #expect(response.reason?.contains("exceeded") == true)
        }
    }

    @Test func proQuotaDecodesNullableUnlimitedFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let quota = try decoder.decode(UsageQuota.self, from: JSONSerialization.data(withJSONObject: [
            "bytesUsed": 2_048,
            "bytesLimit": NSNull(),
            "bytesRemaining": NSNull(),
            "usagePercentage": NSNull(),
            "isUnlimited": true,
            "isOverLimit": false,
            "formattedUsed": "2 KB",
            "formattedLimit": NSNull(),
            "formattedRemaining": NSNull(),
            "cycleStart": "2026-06-01T00:00:00Z",
            "cycleEnd": "2026-07-01T00:00:00Z",
            "resetDate": "2026-07-01T00:00:00Z"
        ]))

        #expect(quota.isUnlimited)
        #expect(quota.bytesLimit == nil)
        #expect(quota.usagePercentage == nil)
    }

    @Test func dnsPreferenceEndpointsUseAuthenticatedAccountContract() async throws {
        try await withSerializedRequests {
            let session = AuthSession(
                accessToken: "dns-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            var requestCount = 0
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                requestCount += 1
                #expect(request.url?.path == "/api/dns/settings")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dns-access")

                if request.httpMethod == "GET" {
                    return try makeResponse(request, status: 200, json: [
                        "requestedEnabled": false,
                        "canUseAdBlocking": true,
                        "effectiveEnabled": false,
                        "effectiveMode": "regular",
                        "propagationSeconds": 15
                    ])
                }

                #expect(request.httpMethod == "PUT")
                let body = try requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["adBlockingEnabled"] as? Bool == true)
                return try makeResponse(request, status: 200, json: [
                    "requestedEnabled": true,
                    "canUseAdBlocking": true,
                    "effectiveEnabled": true,
                    "effectiveMode": "filtered",
                    "propagationSeconds": 15
                ])
            }

            let initial = try await client.fetchDNSPreference()
            #expect(initial.requestedEnabled == false)
            #expect(initial.normalizedEffectiveMode == "regular")

            let updated = try await client.updateDNSPreference(adBlockingEnabled: true)
            #expect(updated.requestedEnabled)
            #expect(updated.canUseAdBlocking)
            #expect(updated.effectiveEnabled)
            #expect(updated.normalizedEffectiveMode == "filtered")
            #expect(updated.propagationSeconds == 15)
            #expect(requestCount == 2)
        }
    }

    @Test func freeUserCanDisableSavedAdBlockingButCannotEnableIt() async throws {
        try await withSerializedRequests {
            let session = AuthSession(
                accessToken: "dns-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            var putValues: [Bool] = []
            var requestedEnabled = true
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                if request.httpMethod == "PUT" {
                    let body = try requestBody(from: request)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    let enabled = try #require(json["adBlockingEnabled"] as? Bool)
                    putValues.append(enabled)
                    requestedEnabled = enabled
                }
                return try makeResponse(request, status: 200, json: [
                    "requestedEnabled": requestedEnabled,
                    "canUseAdBlocking": false,
                    "effectiveEnabled": false,
                    "effectiveMode": "regular",
                    "propagationSeconds": 15
                ])
            }
            let app = AppModel(
                api: client,
                vpnManager: DNSSettingsTestVPNManager(),
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )

            await app.refreshDNSPreference()
            #expect(app.dnsPreference?.requestedEnabled == true)
            #expect(app.dnsPreference?.effectiveEnabled == false)

            await app.setAdBlockingEnabled(false)
            #expect(app.dnsPreference?.requestedEnabled == false)
            #expect(putValues == [false])

            app.presentedError = nil
            await app.setAdBlockingEnabled(true)
            #expect(app.dnsPreference?.requestedEnabled == false)
            #expect(putValues == [false])
            #expect(app.presentedError?.code == "PRO_REQUIRED")
        }
    }

    @Test func failedAdBlockingUpdateRestoresTheConfirmedPreference() async throws {
        try await withSerializedRequests {
            let session = AuthSession(
                accessToken: "dns-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                if request.httpMethod == "PUT" {
                    return try makeResponse(request, status: 503, json: ["message": "DNS update unavailable"])
                }
                return try makeResponse(request, status: 200, json: [
                    "requestedEnabled": false,
                    "canUseAdBlocking": true,
                    "effectiveEnabled": false,
                    "effectiveMode": "regular",
                    "propagationSeconds": 15
                ])
            }
            let app = AppModel(
                api: client,
                vpnManager: DNSSettingsTestVPNManager(),
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )

            await app.refreshDNSPreference()
            await app.setAdBlockingEnabled(true)

            #expect(app.dnsPreference?.requestedEnabled == false)
            #expect(app.dnsPreference?.effectiveEnabled == false)
            #expect(app.isUpdatingAdBlocking == false)
            #expect(app.presentedError?.message == "DNS update unavailable")
        }
    }

    @Test func dnsPreferenceFailureDoesNotDiscardOtherAccountData() async throws {
        try await withSerializedRequests {
            let session = AuthSession(
                accessToken: "dns-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                switch request.url?.path {
                case "/api/usage/quota":
                    return try makeResponse(request, status: 200, json: quotaJSON)
                case "/api/subscription/status":
                    return try makeResponse(request, status: 200, json: [
                        "plan": "Pro",
                        "isPro": true,
                        "status": "active",
                        "paymentType": NSNull(),
                        "currentPeriodEnd": NSNull(),
                        "cancelAtPeriodEnd": false,
                        "billingCycle": "monthly",
                        "activeDevices": 1,
                        "maxDevices": 3,
                        "canAddDevice": true
                    ])
                case "/api/2fa/status":
                    return try makeResponse(request, status: 200, json: [
                        "is2faEnabled": false,
                        "hasAuthenticator": false,
                        "recoveryCodesLeft": 0
                    ])
                case "/api/dns/settings":
                    return try makeResponse(request, status: 503, json: ["message": "DNS settings unavailable"])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }
            let app = AppModel(
                api: client,
                vpnManager: DNSSettingsTestVPNManager(),
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )

            await app.refreshAccountData(showErrors: false)

            #expect(app.subscription?.isPro == true)
            #expect(app.usageQuota?.bytesUsed == 1_024)
            #expect(app.twoFactorStatus?.is2faEnabled == false)
            #expect(app.dnsPreference == nil)
        }
    }

    @Test func accountRefreshCommitsSubscriptionWhenOtherAccountRequestsFail() async throws {
        try await withSerializedRequests {
            let session = AuthSession(
                accessToken: "account-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                switch request.url?.path {
                case "/api/usage/quota":
                    return try self.makeResponse(request, status: 503, json: ["message": "Usage unavailable"])
                case "/api/subscription/status":
                    return try self.makeResponse(request, status: 200, json: self.subscriptionJSON(plan: "Pro", isPro: true))
                case "/api/2fa/status":
                    return try self.makeResponse(request, status: 503, json: ["message": "2FA unavailable"])
                case "/api/dns/settings":
                    return try self.makeResponse(request, status: 200, json: self.dnsPreferenceJSON)
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }
            let app = AppModel(
                api: client,
                vpnManager: DNSSettingsTestVPNManager(),
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )

            await app.refreshAccountData(showErrors: false)

            #expect(app.subscription?.isPro == true)
            #expect(app.isProUser)
            #expect(app.currentPlanDisplayName == "Pro")
            #expect(app.dnsPreference?.requestedEnabled == false)
        }
    }

    @Test func failedSubscriptionRefreshKeepsCachedProPlanDespiteFreeUsageQuota() async throws {
        try await withSerializedRequests {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            defaults.set("Pro", forKey: "cached.plan.name")
            defaults.set(true, forKey: "cached.plan.isPro")
            defaults.set("user-1", forKey: "cached.plan.userID")
            let session = AuthSession(
                accessToken: "account-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                switch request.url?.path {
                case "/api/usage/quota":
                    return try self.makeResponse(request, status: 200, json: self.quotaJSON)
                case "/api/subscription/status":
                    return try self.makeResponse(request, status: 503, json: ["message": "Subscription unavailable"])
                case "/api/2fa/status":
                    return try self.makeResponse(request, status: 200, json: [
                        "is2faEnabled": false,
                        "hasAuthenticator": false,
                        "recoveryCodesLeft": 0
                    ])
                case "/api/dns/settings":
                    return try self.makeResponse(request, status: 200, json: self.dnsPreferenceJSON)
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }
            let app = AppModel(
                api: client,
                vpnManager: DNSSettingsTestVPNManager(),
                defaults: defaults
            )

            await app.refreshAccountData(showErrors: false)

            #expect(app.subscription == nil)
            #expect(app.isProUser)
            #expect(app.currentPlanDisplayName == "Pro")
        }
    }

    @Test func successfulFreeSubscriptionReplacesCachedProPlan() async throws {
        try await withSerializedRequests {
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            defaults.set("Pro", forKey: "cached.plan.name")
            defaults.set(true, forKey: "cached.plan.isPro")
            defaults.set("user-1", forKey: "cached.plan.userID")
            let session = AuthSession(
                accessToken: "account-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            )
            let client = makeClient(sessionStore: InMemorySessionStore(session: session)) { request in
                switch request.url?.path {
                case "/api/usage/quota":
                    return try self.makeResponse(request, status: 200, json: self.quotaJSON)
                case "/api/subscription/status":
                    return try self.makeResponse(request, status: 200, json: self.subscriptionJSON(plan: "Free", isPro: false))
                case "/api/2fa/status":
                    return try self.makeResponse(request, status: 200, json: [
                        "is2faEnabled": false,
                        "hasAuthenticator": false,
                        "recoveryCodesLeft": 0
                    ])
                case "/api/dns/settings":
                    return try self.makeResponse(request, status: 200, json: self.dnsPreferenceJSON)
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }
            let app = AppModel(
                api: client,
                vpnManager: DNSSettingsTestVPNManager(),
                defaults: defaults
            )

            await app.refreshAccountData(showErrors: false)

            #expect(app.subscription?.isPro == false)
            #expect(app.isProUser == false)
            #expect(app.currentPlanDisplayName == "Free")
            #expect(defaults.bool(forKey: "cached.plan.isPro") == false)
        }
    }

    @Test func appleSubscriptionEndpointsUseAuthenticatedAccountContract() async throws {
        try await withSerializedRequests {
            let token = UUID(uuidString: "4CB6C240-6A45-42B4-AD28-C54C49B43F11")!
            var requestCount = 0
            let client = makeClient(sessionStore: InMemorySessionStore(session: AuthSession(
                accessToken: "apple-access",
                refreshToken: "refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            ))) { request in
                requestCount += 1
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer apple-access")
                #expect(request.url?.host == "management.libreguard.net")
                switch request.url?.path {
                case "/api/subscription/apple/account-token":
                    #expect(request.httpMethod == "GET")
                    return try makeResponse(request, status: 200, json: ["appAccountToken": token.uuidString])
                case "/api/subscription/apple/verify":
                    #expect(request.httpMethod == "POST")
                    let json = try #require(JSONSerialization.jsonObject(with: requestBody(from: request)) as? [String: Any])
                    #expect(json["signedTransactionInfo"] as? String == "signed-jws")
                    #expect(json["allowTransfer"] as? Bool == true)
                    return try makeResponse(request, status: 200, json: [
                        "transferred": true,
                        "subscription": [
                            "plan": "Pro",
                            "isPro": true,
                            "status": "active",
                            "paymentType": "Apple",
                            "currentPeriodEnd": NSNull(),
                            "cancelAtPeriodEnd": false,
                            "billingCycle": "annual",
                            "activeDevices": 1,
                            "maxDevices": 3,
                            "canAddDevice": true
                        ]
                    ])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            #expect(try await client.fetchAppleAccountToken(environment: .production) == token)
            let response = try await client.verifyAppleTransaction("signed-jws", allowTransfer: true, environment: .production)
            #expect(response.transferred)
            #expect(response.subscription.isAppleBilled)
            #expect(response.subscription.billingCycle == "annual")
            #expect(requestCount == 2)
        }
    }

    @Test func appleSubscriptionEndpointsRouteSandboxAndRejectLocalXcodeTransactions() async throws {
        try await withSerializedRequests {
            var requestHosts: [String] = []
            let client = makeClient(sessionStore: InMemorySessionStore(session: startupSession())) { request in
                requestHosts.append(request.url?.host ?? "")
                switch request.url?.path {
                case "/api/subscription/apple/account-token":
                    return try makeResponse(request, status: 200, json: ["appAccountToken": UUID().uuidString])
                case "/api/subscription/apple/verify":
                    return try makeResponse(request, status: 200, json: [
                        "subscription": self.subscriptionJSON(plan: "Pro", isPro: true),
                        "transferred": false
                    ])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }
            _ = try await client.fetchAppleAccountToken(environment: .sandbox)
            _ = try await client.verifyAppleTransaction("signed-jws", allowTransfer: false, environment: .sandbox)
            #expect(requestHosts == ["sandbox.management.libreguard.net", "sandbox.management.libreguard.net"])
            do {
                _ = try await client.fetchAppleAccountToken(environment: .xcode)
                Issue.record("Xcode account-token request must be rejected")
            } catch is AppleStoreError {}
            do {
                _ = try await client.verifyAppleTransaction("signed-jws", allowTransfer: false, environment: .xcode)
                Issue.record("Xcode verification request must be rejected")
            } catch is AppleStoreError {}
            #expect(requestHosts.count == 2)
        }
    }

    @Test func appleStoreEnvironmentsRemainDistinct() {
        #expect(AppleAPIEnvironment(.production) == .production)
        #expect(AppleAPIEnvironment(.sandbox) == .sandbox)
        #expect(AppleAPIEnvironment(.xcode) == .xcode)
    }

    @Test func applePurchaseRejectsExistingProAndLocalXcodeEnvironment() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        let app = await makeApplePurchaseApp(backend: backend, store: store)
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Pro", isPro: true))]
        await app.purchaseSelectedAppleSubscription()
        #expect(store.purchaseCalls.isEmpty)
        #expect(backend.requestedAppleEnvironments.isEmpty)
        #expect(app.applePurchaseMessage?.contains("already active") == true)

        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        store.environment = .xcode
        await app.purchaseSelectedAppleSubscription()
        #expect(store.purchaseCalls.isEmpty)
        #expect(backend.requestedAppleEnvironments.isEmpty)
        #expect(app.applePurchaseMessage?.contains("Local Xcode StoreKit") == true)
    }

    @Test func localStoreKitPurchaseCannotBeSentToTheLiveVerifier() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        let store = ControllableAppleSubscriptionStore()
        store.purchaseResult = .success(.success(AppleStoreTransaction(
            id: 100,
            productID: AppleSubscriptionCatalog.monthlyProductID,
            signedTransactionInfo: "locally-signed-transaction",
            environment: .xcode
        )))
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        await app.purchaseSelectedAppleSubscription()

        #expect(store.purchaseCalls.count == 1)
        #expect(backend.appleVerificationAllowTransfer.isEmpty)
        #expect(store.finishedIDs.isEmpty)
        #expect(!app.isProUser)
        #expect(app.applePurchaseMessage?.contains("StoreKit Configuration to None") == true)
    }

    @Test func applePurchaseRestoresExistingEntitlementInsteadOfChargingAgain() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        let transaction = appleTransaction(id: 101)
        store.currentResults = [.verified(transaction)]
        let pro = AppleTransactionVerificationResponse(subscription: try subscriptionStatus(plan: "Pro", isPro: true), transferred: false)
        backend.appleVerificationResults = [.success(pro), .success(pro)]
        backend.subscriptionResults = [.success(pro.subscription)]
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        await app.purchaseSelectedAppleSubscription()

        #expect(store.purchaseCalls.isEmpty)
        #expect(store.finishedIDs == [101])
        #expect(app.isProUser)
        #expect(app.applePurchaseMessage?.contains("already active") == true)
    }

    @Test func applePurchaseHandlesPendingCancellationAndUnverifiedResultWithoutBackendVerification() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        let free = try subscriptionStatus(plan: "Free", isPro: false)
        backend.subscriptionResults = [.success(free), .success(free), .success(free)]
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        store.purchaseResult = .success(.pending)
        await app.purchaseSelectedAppleSubscription()
        #expect(app.applePurchaseMessage?.contains("pending approval") == true)

        store.purchaseResult = .success(.userCancelled)
        await app.purchaseSelectedAppleSubscription()
        #expect(app.applePurchaseMessage == "Purchase cancelled.")

        store.purchaseResult = .failure(AppleStoreError.unverifiedTransaction)
        await app.purchaseSelectedAppleSubscription()
        #expect(app.applePurchaseMessage?.contains("could not verify") == true)
        #expect(backend.appleVerificationAllowTransfer.isEmpty)
        #expect(store.finishedIDs.isEmpty)
    }

    @Test func applePurchaseRetriesTransientVerificationAndFinishesAfterBackendConfirmation() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        store.purchaseResult = .success(.success(appleTransaction(id: 202)))
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        backend.appleVerificationResults = [
            .failure(APIError(statusCode: 503, message: "Unavailable")),
            .success(AppleTransactionVerificationResponse(subscription: try subscriptionStatus(plan: "Pro", isPro: true), transferred: false))
        ]
        let app = await makeApplePurchaseApp(backend: backend, store: store, retryDelays: [0, 0])

        await app.purchaseSelectedAppleSubscription()

        #expect(backend.appleVerificationAllowTransfer == [false, false])
        #expect(store.finishedIDs == [202])
        #expect(app.isProUser)
    }

    @Test func applePurchaseDoesNotRetryTerminalBackendConflict() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        store.purchaseResult = .success(.success(appleTransaction(id: 203)))
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        backend.appleVerificationResults = [
            .failure(APIError(statusCode: 409, message: "Subscription conflict", code: "APPLE_SUBSCRIPTION_FAMILY_CONFLICT"))
        ]
        let app = await makeApplePurchaseApp(backend: backend, store: store, retryDelays: [0, 0])

        await app.purchaseSelectedAppleSubscription()

        #expect(backend.appleVerificationAllowTransfer == [false])
        #expect(store.finishedIDs.isEmpty)
        #expect(app.applePurchaseMessage?.contains("already linked") == true)
    }

    @Test func appleRestoreRecoversCurrentEntitlementAndTemporaryFailureKeepsTransaction() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        store.currentResults = [.verified(appleTransaction(id: 250))]
        backend.appleVerificationResults = [
            .success(AppleTransactionVerificationResponse(subscription: try subscriptionStatus(plan: "Pro", isPro: true), transferred: false))
        ]
        let app = await makeApplePurchaseApp(backend: backend, store: store)
        await app.restoreApplePurchases()
        #expect(store.syncCount == 1)
        #expect(store.finishedIDs == [250])
        #expect(app.isProUser)

        let failedBackend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let failedStore = ControllableAppleSubscriptionStore()
        failedStore.purchaseResult = .success(.success(appleTransaction(id: 251)))
        failedBackend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        failedBackend.appleVerificationResults = [
            .failure(APIError(statusCode: 503, message: "Unavailable"))
        ]
        let failedApp = await makeApplePurchaseApp(backend: failedBackend, store: failedStore)
        await failedApp.purchaseSelectedAppleSubscription()
        #expect(failedStore.finishedIDs.isEmpty)
        #expect(failedApp.applePurchaseMessage?.contains("Retry Restore Purchases") == true)
        await failedApp.purchaseSelectedAppleSubscription()
        #expect(failedStore.purchaseCalls.count == 1)
        #expect(failedApp.applePurchaseMessage?.contains("previous Apple purchase") == true)

        failedStore.unfinishedResults = [.verified(appleTransaction(id: 251))]
        failedBackend.appleVerificationResults = [
            .success(AppleTransactionVerificationResponse(subscription: try subscriptionStatus(plan: "Pro", isPro: true), transferred: false))
        ]
        await failedApp.restoreApplePurchases()
        #expect(failedStore.finishedIDs == [251])
        #expect(failedApp.isProUser)
    }

    @Test func appleVerificationWinsOverAnEarlierAccountRefresh() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        backend.holdFirstSubscriptionRequest = true
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        backend.appleVerificationResults = [
            .success(AppleTransactionVerificationResponse(
                subscription: try subscriptionStatus(plan: "Pro", isPro: true),
                transferred: false
            ))
        ]
        let store = ControllableAppleSubscriptionStore()
        store.currentResults = [.verified(appleTransaction(id: 252))]
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        let refresh = Task { await app.refreshAccountData(showErrors: false) }
        await backend.waitForFirstSubscriptionRequest()
        await app.restoreApplePurchases()
        backend.releaseFirstSubscriptionRequest()
        await refresh.value

        #expect(store.finishedIDs == [252])
        #expect(app.isProUser)
        #expect(app.subscription?.isPro == true)
    }

    @Test func restoreWithoutIOSPurchaseKeepsExistingLibreGuardProStatus() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Pro", isPro: true))]
        let store = ControllableAppleSubscriptionStore()
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        await app.restoreApplePurchases()

        #expect(app.isProUser)
        #expect(app.applePurchaseMessage?.contains("Pro is active") == true)
        #expect(store.finishedIDs.isEmpty)
    }

    @Test func applePurchaseTransferRequiresConfirmationBeforeFinishing() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        store.purchaseResult = .success(.success(appleTransaction(id: 303)))
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        backend.appleVerificationResults = [
            .failure(APIError(statusCode: 409, message: "Transfer required", code: "APPLE_SUBSCRIPTION_TRANSFER_REQUIRED")),
            .success(AppleTransactionVerificationResponse(subscription: try subscriptionStatus(plan: "Pro", isPro: true), transferred: true))
        ]
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        await app.purchaseSelectedAppleSubscription()
        #expect(app.pendingAppleSubscriptionTransfer?.id == 303)
        #expect(store.finishedIDs.isEmpty)
        await app.confirmAppleSubscriptionTransfer(appleTransaction(id: 303))
        #expect(backend.appleVerificationAllowTransfer == [false, true])
        #expect(store.finishedIDs == [303])
    }

    @Test func expiredRejectedTransactionFinishesOnlyWhenNoCurrentEntitlementExists() async throws {
        let expired = appleTransaction(id: 404, expirationDate: Date().addingTimeInterval(-3600))
        let rejection = APIError(statusCode: 409, message: "Not entitled", code: "APPLE_TRANSACTION_NOT_ENTITLED")
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let store = ControllableAppleSubscriptionStore()
        store.unfinishedResults = [.verified(expired)]
        backend.appleVerificationResults = [.failure(rejection)]
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        await app.purchaseSelectedAppleSubscription()
        #expect(store.finishedIDs == [404])
        #expect(store.purchaseCalls.isEmpty)
        #expect(app.applePurchaseMessage?.contains("expired") == true)

        let backendWithEntitlement = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let storeWithEntitlement = ControllableAppleSubscriptionStore()
        storeWithEntitlement.unfinishedResults = [.verified(expired)]
        storeWithEntitlement.currentResults = [.unverified(productID: AppleSubscriptionCatalog.monthlyProductID, message: "Unverified")]
        backendWithEntitlement.appleVerificationResults = [.failure(rejection)]
        backendWithEntitlement.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        let appWithEntitlement = await makeApplePurchaseApp(backend: backendWithEntitlement, store: storeWithEntitlement)

        await appWithEntitlement.purchaseSelectedAppleSubscription()
        #expect(storeWithEntitlement.finishedIDs.isEmpty)
        #expect(storeWithEntitlement.purchaseCalls.isEmpty)

        let unexpiredBackend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        let unexpiredStore = ControllableAppleSubscriptionStore()
        unexpiredStore.unfinishedResults = [.verified(appleTransaction(id: 405, expirationDate: Date().addingTimeInterval(3600)))]
        unexpiredBackend.appleVerificationResults = [.failure(rejection)]
        unexpiredBackend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        let unexpiredApp = await makeApplePurchaseApp(backend: unexpiredBackend, store: unexpiredStore)
        await unexpiredApp.purchaseSelectedAppleSubscription()
        #expect(unexpiredStore.finishedIDs.isEmpty)
        #expect(unexpiredStore.purchaseCalls.isEmpty)
    }

    @Test func appleVerificationFromPreviousAccountCannotGrantProOrFinishTransaction() async throws {
        let backend = StartupBackendStub(storedSession: startupSession(), restoreResults: [])
        backend.holdFirstAppleVerification = true
        backend.subscriptionResults = [.success(try subscriptionStatus(plan: "Free", isPro: false))]
        backend.appleVerificationResults = [
            .success(AppleTransactionVerificationResponse(subscription: try subscriptionStatus(plan: "Pro", isPro: true), transferred: false))
        ]
        let store = ControllableAppleSubscriptionStore()
        store.purchaseResult = .success(.success(appleTransaction(id: 505)))
        let app = await makeApplePurchaseApp(backend: backend, store: store)

        let purchase = Task { await app.purchaseSelectedAppleSubscription() }
        await backend.waitForFirstAppleVerification()
        app.session = AuthSession(accessToken: "other", refreshToken: "other", email: "other@example.com", userId: "other-user", deviceId: "other-device")
        backend.releaseFirstAppleVerification()
        await purchase.value

        #expect(app.subscription == nil)
        #expect(store.finishedIDs.isEmpty)
    }

    @Test func passwordResetRequestsUseUnauthenticatedAccountEndpoints() async throws {
        try await withSerializedRequests {
            var requestCount = 0
            let client = makeClient { request in
                requestCount += 1
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                let body = try requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                switch request.url?.path {
                case "/api/account/forgot-password":
                    #expect(json["email"] as? String == "person@example.com")
                    return try makeResponse(request, status: 200, json: ["message": "Check your inbox."])
                case "/api/account/reset-password":
                    #expect(json["email"] as? String == "person@example.com")
                    #expect(json["token"] as? String == "reset-code")
                    #expect(json["newPassword"] as? String == "new-secret")
                    return try makeResponse(request, status: 200, json: ["message": "Password has been reset successfully."])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            _ = try await client.requestPasswordReset(email: "person@example.com")
            _ = try await client.resetPassword(email: "person@example.com", token: "reset-code", newPassword: "new-secret")
            #expect(requestCount == 2)
        }
    }

    @Test func loginDecodesTwoFactorChallenge() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                #expect(request.url?.path == "/api/login")
                let body = try requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["deviceId"] as? String == "test-device")
                #expect(json["appVersion"] as? String == "1.0-test")
                #expect(json["devicePublicKey"] as? String == "base64-spki")
                #expect(json["devicePublicKeyId"] as? String == "device-key-id")
                #expect(json["devicePublicKeyAlgorithm"] as? String == "RSA-OAEP-256")
                return try makeResponse(request, status: 200, json: [
                    "requiresTwoFactor": true,
                    "pendingLoginToken": "pending-token",
                    "email": "person@example.com",
                    "userId": "user-1",
                    "deviceId": "test-device",
                    "message": "Two-factor authentication required."
                ])
            }

            let result = try await client.login(email: "person@example.com", password: "secret")
            #expect(result.requiresTwoFactor == true)
            #expect(result.pendingLoginToken == "pending-token")
        }
    }

    @Test func deviceLimitErrorIncludesSelectableDevices() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                try makeResponse(request, status: 409, json: [
                    "message": "Device limit reached.",
                    "errorCode": "DEVICE_LIMIT_EXCEEDED",
                    "currentDevices": 1,
                    "maxDevices": 1,
                    "planType": "Free",
                    "devices": [[
                        "id": 42,
                        "deviceIdHash": "abcdef123456",
                        "appVersion": "1.0",
                        "deviceNickname": "Old iPhone",
                        "lastSeenAt": "2026-06-21T16:00:00.1234567Z",
                        "daysSinceLastSeen": 0
                    ]]
                ])
            }

            do {
                _ = try await client.login(email: "person@example.com", password: "secret")
                Issue.record("Expected a device-limit error")
            } catch let error as APIError {
                #expect(error.code == "DEVICE_LIMIT_EXCEEDED")
                #expect(error.deviceLimit?.devices.first?.id == 42)
                #expect(error.deviceLimit?.devices.first?.displayName == "Old iPhone")
            }
        }
    }

    @Test func protectedRequestRotatesRefreshTokenAndRetriesOnce() async throws {
        try await withSerializedRequests {
            let store = InMemorySessionStore(session: AuthSession(
                accessToken: "expired-access",
                refreshToken: "old-refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            ))
            var quotaAttempts = 0
            let client = makeClient(sessionStore: store) { request in
                switch request.url?.path {
                case "/api/login/refresh":
                    let body = try requestBody(from: request)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["devicePublicKey"] as? String == "base64-spki")
                    #expect(json["devicePublicKeyId"] as? String == "device-key-id")
                    #expect(json["devicePublicKeyAlgorithm"] as? String == "RSA-OAEP-256")
                    return try makeResponse(request, status: 200, json: [
                        "token": "new-access",
                        "refreshToken": "new-refresh",
                        "email": "person@example.com",
                        "userId": "user-1",
                        "deviceId": "test-device"
                    ])
                case "/api/usage/quota":
                    quotaAttempts += 1
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-access" {
                        return try makeResponse(request, status: 401, json: ["message": "Expired"])
                    }
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
                    return try makeResponse(request, status: 200, json: quotaJSON)
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let quota = try await client.fetchUsage()
            #expect(quota.isUnlimited == false)
            #expect(quotaAttempts == 2)
            #expect(store.session?.refreshToken == "new-refresh")
        }
    }

    @Test func vpnConfigRequestEncodesProtocolAndServer() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                #expect(request.url?.path == "/api/vpn/config")
                let body = try requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["serverId"] as? Int == 12)
                #expect(json["protocol"] as? String == "IKEV2")

                return try makeResponse(request, status: 200, json: [
                    "success": true,
                    "protocol": "IKEV2",
                    "serverName": "DE-1",
                    "serverIp": "203.0.113.10",
                    "certificateName": "IKEV2_client1",
                    "configContent": "{\"local\":{\"p12\":\"UEs=\",\"password\":\"[ENCRYPTED_PASSPHRASE]\"},\"remote\":{\"addr\":\"vpn.libreguard.net\"}}",
                    "encryptedPassphrase": [
                        "algorithm": "RSA-OAEP-256",
                        "keyId": "device-key-id",
                        "ciphertext": "YQ=="
                    ],
                    "issueDate": "2026-06-21T16:00:00Z",
                    "expirationDate": "2028-06-21T16:00:00Z",
                    "clientIp": "198.51.100.45",
                    "deviceId": "test-device"
                ])
            }

            let fetchVPNConfig: (Int, VPNConfigurationProtocol) async throws -> VPNConfigResponse = client.fetchVPNConfig(serverId:protocol:)
            let response = try await fetchVPNConfig(12, VPNConfigurationProtocol.ikev2)
            #expect(response.serverName == "DE-1")
            #expect(response.protocolName == "IKEV2")
            #expect(response.encryptedPassphrase.algorithm == "RSA-OAEP-256")
        }
    }

    @Test func localStatisticsAggregateAndClearWithoutNetworking() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LocalConnectionRecord.self, configurations: configuration)
        let context = ModelContext(container)
        let recorder = SwiftDataStatisticsRecorder(context: context)
        let server = try JSONDecoder().decode(VPNServer.self, from: JSONSerialization.data(withJSONObject: [
            "id": 1,
            "serverName": "DE-MULTI-1",
            "serverIp": "203.0.113.1",
            "country": "Germany",
            "city": "Frankfurt",
            "linkSpeed": 1000,
            "pricingTier": "Free",
            "load": 35,
            "activeConnections": NSNull(),
            "latencyPingPort": 5001,
            "loadDataFresh": true
        ]))

        let start = Date().addingTimeInterval(-600)
        let sessionID = UUID()
        try recorder.record(
            sessionID: sessionID,
            userId: "user-1",
            connectedAt: start,
            disconnectedAt: Date(),
            server: server,
            protocolName: .ikev2,
            downloadedBytes: 1_000,
            uploadedBytes: 250
        )
        try recorder.record(
            sessionID: sessionID,
            userId: "user-1",
            connectedAt: start,
            disconnectedAt: Date(),
            server: server,
            protocolName: .ikev2,
            downloadedBytes: 1_200,
            uploadedBytes: 300
        )
        try recorder.record(
            sessionID: UUID(),
            userId: "user-2",
            connectedAt: start,
            disconnectedAt: Date(),
            server: server,
            protocolName: .openVPN,
            downloadedBytes: 5_000,
            uploadedBytes: 900
        )
        let records = try context.fetch(FetchDescriptor<LocalConnectionRecord>())
        let summary = LocalStatisticsSummary(
            records: records.filter { $0.userId == "user-1" },
            interval: DateInterval(start: start.addingTimeInterval(-1), end: Date().addingTimeInterval(1))
        )
        #expect(summary.totalBytes == 1_500)
        #expect(summary.connectedDuration >= 599)

        try recorder.clear(userId: "user-1")
        let remainingRecords = try context.fetch(FetchDescriptor<LocalConnectionRecord>())
        #expect(remainingRecords.count == 1)
        #expect(remainingRecords.first?.userId == "user-2")
    }

    @Test func countryFlagsResolveFromNamesAndAliases() {
        #expect(CountryFlagResolver.flagEmoji(for: "Germany") == "🇩🇪")
        #expect(CountryFlagResolver.flagEmoji(for: "United States") == "🇺🇸")
        #expect(CountryFlagResolver.flagEmoji(for: "UK") == "🇬🇧")
        #expect(CountryFlagResolver.flagEmoji(for: "Unknown Region") == "🌐")
    }

    @Test func premiumPricingTierDisplaysAsPro() throws {
        let server = try JSONDecoder().decode(VPNServer.self, from: JSONSerialization.data(withJSONObject: [
            "id": 99,
            "serverName": "DE-PRO-1",
            "serverIp": "203.0.113.99",
            "country": "Germany",
            "city": "Frankfurt",
            "linkSpeed": 1000,
            "pricingTier": "Premium",
            "load": 20,
            "activeConnections": NSNull(),
            "latencyPingPort": 5001,
            "loadDataFresh": true
        ]))

        #expect(server.pricingTierLabel == "Pro")
        #expect(server.requiresProSubscription == true)
        #expect(server.flagEmoji == "🇩🇪")
    }

    @Test func subscriptionDisplayNameNormalizesPremiumTier() throws {
        let subscription = try JSONDecoder().decode(libreguard_vpn_ios.SubscriptionStatus.self, from: JSONSerialization.data(withJSONObject: [
            "plan": "Premium",
            "isPro": true,
            "status": "Active",
            "paymentType": NSNull(),
            "currentPeriodEnd": NSNull(),
            "cancelAtPeriodEnd": false,
            "billingCycle": "Monthly",
            "activeDevices": 2,
            "maxDevices": 3,
            "canAddDevice": true
        ]))

        #expect(subscription.planTier == .pro)
        #expect(subscription.displayName == "Pro")
    }

    @Test func appleAppStorePaymentTypeShowsSubscriptionManagement() throws {
        var payload = subscriptionJSON(plan: "Pro", isPro: true)
        payload["paymentType"] = "AppleAppStore"
        let subscription = try JSONDecoder().decode(
            libreguard_vpn_ios.SubscriptionStatus.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )

        #expect(subscription.isAppleBilled)
    }

    @Test func subscriptionDisplayNameUsesExplicitEntitlementWhenPlanNameIsStale() throws {
        let subscription = try JSONDecoder().decode(libreguard_vpn_ios.SubscriptionStatus.self, from: JSONSerialization.data(withJSONObject: [
            "plan": "Pro",
            "isPro": false,
            "status": "inactive",
            "paymentType": NSNull(),
            "currentPeriodEnd": NSNull(),
            "cancelAtPeriodEnd": false,
            "billingCycle": "monthly",
            "activeDevices": 1,
            "maxDevices": 1,
            "canAddDevice": true
        ]))

        #expect(subscription.planTier == .free)
        #expect(subscription.displayName == "Free")
    }

    @Test func latencyProbeUsesHTTPSPingEndpoint() async throws {
        try await withSerializedRequests {
            let server = makeLatencyServer(id: 1, hostname: "fra-1.example.com")
            URLProtocolStub.handler = { request in
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                #expect(request.url?.scheme == "https")
                #expect(request.url?.host == "fra-1.example.com")
                #expect(request.url?.port == 5001)
                #expect(request.url?.path == "/ping")
                return try self.makeResponse(request, status: 200, json: [
                    "pong": true,
                    "timestamp": 1_703_868_000_000
                ])
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [URLProtocolStub.self]
            let probe = NetworkLatencyProbe(urlSession: URLSession(configuration: configuration))
            let latencies = await probe.measure([server])

            #expect(latencies[server.id] != nil)
        }
    }

    @Test func latencyProbeIgnoresInvalidPingResponsesAndFailures() async throws {
        try await withSerializedRequests {
            let valid = makeLatencyServer(id: 1, hostname: "valid.example.com")
            let invalid = makeLatencyServer(id: 2, hostname: "invalid.example.com")
            let failed = makeLatencyServer(id: 3, hostname: "failed.example.com")
            URLProtocolStub.handler = { request in
                switch request.url?.host {
                case valid.latencyHost:
                    return try self.makeResponse(request, status: 200, json: ["pong": true])
                case invalid.latencyHost:
                    return try self.makeResponse(request, status: 200, json: ["pong": false])
                case failed.latencyHost:
                    throw APIError(message: "Ping failed")
                default:
                    throw APIError(message: "Unexpected ping host")
                }
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [URLProtocolStub.self]
            let probe = NetworkLatencyProbe(urlSession: URLSession(configuration: configuration))
            let latencies = await probe.measure([valid, invalid, failed])

            #expect(latencies[valid.id] != nil)
            #expect(latencies[invalid.id] == nil)
            #expect(latencies[failed.id] == nil)
        }
    }

    @Test func latencyProbeWarmsEachServerBeforeRecordingLatency() async throws {
        try await withSerializedRequests {
            let server = makeLatencyServer(id: 1, hostname: "warm.example.com")
            let requestCount = ThreadSafeProbeStats()
            URLProtocolStub.handler = { request in
                requestCount.recordRequest()
                #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                return try self.makeResponse(request, status: 200, json: ["pong": true])
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [URLProtocolStub.self]
            let probe = NetworkLatencyProbe(urlSession: URLSession(configuration: configuration))
            let latencies = await probe.measure([server])

            #expect(requestCount.requestCount == 2)
            #expect(latencies[server.id] != nil)
        }
    }

    @Test func latencyProbeLimitsConcurrentServerWorkersToEight() async throws {
        try await withSerializedRequests {
            let servers = (1...16).map { makeLatencyServer(id: $0, hostname: "probe-\($0).example.com") }
            let probeStats = ThreadSafeProbeStats()
            ConcurrentURLProtocolStub.handler = { request in
                let active = probeStats.beginRequest()
                probeStats.recordMaximumActiveRequests(active)
                Thread.sleep(forTimeInterval: 0.02)
                probeStats.endRequest()
                return try self.makeResponse(request, status: 200, json: ["pong": true])
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ConcurrentURLProtocolStub.self]
            let probe = NetworkLatencyProbe(urlSession: URLSession(configuration: configuration))
            let latencies = await probe.measure(servers)

            #expect(latencies.count == servers.count)
            #expect(probeStats.maximumActiveRequests <= 8)
            #expect(probeStats.maximumActiveRequests > 1)
        }
    }

    @Test func connectedServerRefreshUpdatesCatalogWithoutMeasuringLatency() async throws {
        let server = makeLatencyServer(id: 1, hostname: "connected.example.com")
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.serverResponse = [server]
        let probe = RecordingLatencyProbe(result: [server.id: 12])
        let vpn = StartupVPNManager(status: .connected)
        let app = AppModel(
            api: backend,
            latencyProbe: probe,
            vpnManager: vpn,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        app.session = startupSession()
        app.serverLatencies = [server.id: 88]

        app.refreshServers(trigger: .sceneActivation)
        await waitForServerRefresh(app)

        #expect(backend.fetchServersCallCount == 1)
        #expect(app.servers == [server])
        #expect(app.serverLatencies == [server.id: 88])
        #expect(probe.measurementCalls.isEmpty)
    }

    @Test func busyVPNStatesSkipServerLatencyMeasurement() async throws {
        for status in [
            VPNConnectionState.connecting,
            .connected,
            .reasserting,
            .disconnecting
        ] {
            let server = makeLatencyServer(id: 1, hostname: "busy-\(String(describing: status)).example.com")
            let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
            backend.serverResponse = [server]
            let probe = RecordingLatencyProbe(result: [server.id: 12])
            let app = AppModel(
                api: backend,
                latencyProbe: probe,
                vpnManager: StartupVPNManager(status: status),
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            )
            app.session = startupSession()

            app.refreshServers(trigger: .automatic)
            await waitForServerRefresh(app)

            #expect(probe.measurementCalls.isEmpty)
        }
    }

    @Test func disconnectedRefreshMeasuresLatencyAndDuplicateRequestsCoalesce() async throws {
        let first = makeLatencyServer(id: 1, hostname: "first.example.com")
        let second = makeLatencyServer(id: 2, hostname: "second.example.com")
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.serverResponse = [first, second]
        let probe = RecordingLatencyProbe(result: [first.id: 24, second.id: 36])
        let app = AppModel(
            api: backend,
            latencyProbe: probe,
            vpnManager: StartupVPNManager(status: .disconnected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        app.session = startupSession()

        app.refreshServers(trigger: .sceneActivation)
        app.refreshServers(trigger: .dashboardAppearance)
        await waitForServerRefresh(app)

        #expect(backend.fetchServersCallCount == 1)
        #expect(probe.measurementCalls.count == 1)
        #expect(app.serverLatencies == [first.id: 24, second.id: 36])
    }

    @Test func disconnectedRefreshPreservesFailureSemantics() async throws {
        let server = makeLatencyServer(id: 1, hostname: "failed-refresh.example.com")
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.serverError = APIError(message: "Server catalog unavailable")
        let probe = RecordingLatencyProbe(result: [server.id: 12])
        let app = AppModel(
            api: backend,
            latencyProbe: probe,
            vpnManager: StartupVPNManager(status: .disconnected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        app.session = startupSession()
        app.servers = [server]
        app.serverLatencies = [server.id: 88]

        app.refreshServers(trigger: .manual)
        await waitForServerRefresh(app)

        #expect(backend.fetchServersCallCount == 1)
        #expect(app.servers == [server])
        #expect(app.serverLatencies == [server.id: 88])
        #expect(app.presentedError?.message == "Server catalog unavailable")
        #expect(probe.measurementCalls.isEmpty)
    }

    @Test func quickConnectDoesNotStartAnotherServerRefresh() async throws {
        let server = makeLatencyServer(id: 1, hostname: "quick-connect.example.com")
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        let vpn = StartupVPNManager(status: .disconnected)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let app = AppModel(
            api: backend,
            latencyProbe: RecordingLatencyProbe(result: [server.id: 12]),
            vpnManager: vpn,
            defaults: defaults
        )
        app.session = startupSession()
        app.subscription = try subscriptionStatus(plan: "Pro", isPro: true)
        app.servers = [server]

        app.requestQuickConnect()
        for _ in 0..<20 { await Task.yield() }

        #expect(backend.fetchServersCallCount == 0)
        #expect(vpn.status == .connected)
    }

    @Test func connectingDuringLatencyMeasurementDiscardsTheResult() async throws {
        let server = makeLatencyServer(id: 1, hostname: "transition.example.com")
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.serverResponse = [server]
        let probe = RecordingLatencyProbe(result: [server.id: 999], holdMeasurement: true)
        let vpn = StartupVPNManager(status: .disconnected)
        let app = AppModel(
            api: backend,
            latencyProbe: probe,
            vpnManager: vpn,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        app.session = startupSession()
        app.serverLatencies = [server.id: 45]

        app.refreshServers(trigger: .automatic)
        for _ in 0..<100 where probe.measurementCalls.isEmpty {
            await Task.yield()
        }
        #expect(!probe.measurementCalls.isEmpty)
        vpn.emit(.connected)
        await waitForServerRefresh(app)

        #expect(app.serverLatencies == [server.id: 45])
    }

    @Test func nativeGoogleCancellationIsDismissalAndDuplicateLoginIsIgnored() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.googleBeginResponse = try googleBegin()
        let google = ControlledGoogleSigner()
        google.holdAuthorization = true
        let app = makeStartupApp(backend: backend, vpn: StartupVPNManager(status: .disconnected), defaults: UserDefaults(suiteName: UUID().uuidString)!, google: google)
        let first = Task { await app.loginWithGoogle() }
        for _ in 0..<100 where google.calls == 0 { await Task.yield() }
        await app.loginWithGoogle()
        #expect(backend.googleBeginCalls == 1)
        #expect(google.calls == 1)
        app.showLogin()
        await first.value
        #expect(backend.googleCompleteCalls == 0)
        #expect(app.presentedError == nil)
        #expect(!app.isAuthenticating)
    }

    @Test func nativeGoogleLateAuthorizationCannotCreateASession() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.googleBeginResponse = try googleBegin()
        backend.googleCompleteResult = .success(try loginResponse(userId: "unexpected"))
        let google = ControlledGoogleSigner()
        google.holdAuthorization = true
        google.ignoreCancellation = true
        let app = makeStartupApp(backend: backend, vpn: StartupVPNManager(status: .disconnected), defaults: UserDefaults(suiteName: UUID().uuidString)!, google: google)
        let task = Task { await app.loginWithGoogle() }
        for _ in 0..<100 where google.calls == 0 { await Task.yield() }
        app.showRegister()
        google.complete()
        await task.value
        #expect(backend.googleCompleteCalls == 0)
        #expect(app.session == nil)
        #expect(!app.isAuthenticating)
    }

    @Test func nativeGoogleLinkRequiredOpensOnlyManagementLinking() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.googleBeginResponse = try googleBegin()
        backend.googleCompleteResult = .failure(APIError(statusCode: 409, message: "Link required", code: "GOOGLE_LINK_REQUIRED"))
        var opened = 0
        let app = makeStartupApp(backend: backend, vpn: StartupVPNManager(status: .disconnected), defaults: UserDefaults(suiteName: UUID().uuidString)!, google: ControlledGoogleSigner(), openGoogleLinkingPage: { opened += 1 })
        await app.loginWithGoogle()
        #expect(opened == 1)
        #expect(app.presentedError?.code == "GOOGLE_LINK_REQUIRED")
        #expect(app.session == nil)
        #expect(app.deviceLimitContext == nil)
    }

    @Test func nativeGoogleMFADeviceLimitUsesContinuationAndRotatesTicket() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.googleBeginResponse = try googleBegin()
        backend.googleCompleteResult = .success(try JSONDecoder().decode(LoginResponse.self, from: Data("""
            {"requiresTwoFactor":true,"pendingLoginToken":"pending-factor","email":"person@example.com"}
            """.utf8)))
        backend.factorResult = .failure(try googleLimitError(token: "first-ticket"))
        backend.googleContinueResult = .failure(try googleLimitError(token: "rotated-ticket"))
        let google = ControlledGoogleSigner()
        let app = makeStartupApp(backend: backend, vpn: StartupVPNManager(status: .disconnected), defaults: UserDefaults(suiteName: UUID().uuidString)!, google: google)
        await app.loginWithGoogle()
        guard case let .twoFactor(challenge) = app.route else { Issue.record("Expected factor"); return }
        await app.verifyTwoFactor(challenge, code: "123456", recovery: false)
        let context = try #require(app.deviceLimitContext)
        #expect(context.afterTwoFactor)
        #expect(context.canRemoveInApp)
        await app.removeDeviceAndRetry(try #require(context.response.devices.first), context: context)
        #expect(backend.googleContinueTokens == ["first-ticket"])
        #expect(backend.googleRemovedDevices == [[42]])
        #expect(backend.googleCompleteCalls == 1)
        #expect(google.calls == 1)
        #expect(app.deviceLimitContext?.response.loginContinuationToken == "rotated-ticket")
        #expect(app.deviceLimitContext?.afterTwoFactor == true)
        app.cancelGoogleLogin()
    }

    @Test func nativeGoogleBadFactorPreservesChallengeAndAmbiguousContinuationRestarts() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.googleBeginResponse = try googleBegin()
        backend.googleCompleteResult = .success(try JSONDecoder().decode(LoginResponse.self, from: Data("""
            {"requiresTwoFactor":true,"pendingLoginToken":"pending-factor","email":"person@example.com"}
            """.utf8)))
        let app = makeStartupApp(backend: backend, vpn: StartupVPNManager(status: .disconnected), defaults: UserDefaults(suiteName: UUID().uuidString)!, google: ControlledGoogleSigner())
        await app.loginWithGoogle()
        guard case let .twoFactor(challenge) = app.route else { Issue.record("Expected factor"); return }
        backend.factorResult = .failure(APIError(statusCode: 401, message: "Invalid code", code: "INVALID_TWO_FACTOR_CODE"))
        await app.verifyTwoFactor(challenge, code: "000000", recovery: false)
        guard case let .twoFactor(retained) = app.route else { Issue.record("Lost challenge"); return }
        #expect(retained.id == challenge.id)
        backend.factorResult = .failure(try googleLimitError(token: "ticket"))
        await app.verifyTwoFactor(challenge, code: "recovery", recovery: true)
        let context = try #require(app.deviceLimitContext)
        backend.googleContinueResult = .failure(APIError(message: "Connection lost", code: "TRANSPORT_FAILURE"))
        await app.removeDeviceAndRetry(try #require(context.response.devices.first), context: context)
        #expect(app.deviceLimitContext == nil)
        #expect(app.session == nil)
        await app.removeDeviceAndRetry(try #require(context.response.devices.first), context: context)
        #expect(backend.googleContinueTokens == ["ticket"])
    }

    @Test func cancelledGoogleFactorCannotStoreSessionOrClearANewerLogin() async throws {
        let backend = StartupBackendStub(storedSession: nil, restoreResults: [])
        backend.googleBeginResponse = try googleBegin()
        backend.googleCompleteResult = .success(try JSONDecoder().decode(LoginResponse.self, from: Data("""
            {"requiresTwoFactor":true,"pendingLoginToken":"pending-factor","email":"person@example.com"}
            """.utf8)))
        backend.holdFactorResponse = true
        let google = ControlledGoogleSigner()
        let app = makeStartupApp(backend: backend, vpn: StartupVPNManager(status: .disconnected), defaults: UserDefaults(suiteName: UUID().uuidString)!, google: google)
        await app.loginWithGoogle()
        guard case let .twoFactor(challenge) = app.route else { Issue.record("Expected factor"); return }
        let oldFactor = Task { await app.verifyTwoFactor(challenge, code: "123456", recovery: false) }
        for _ in 0..<100 where !backend.hasPendingFactorResponse { await Task.yield() }
        #expect(backend.hasPendingFactorResponse)
        app.showLogin()
        google.holdAuthorization = true
        let newerLogin = Task { await app.loginWithGoogle() }
        for _ in 0..<100 where google.calls < 2 { await Task.yield() }
        #expect(google.calls == 2)
        backend.completeFactorResponse(with: .success(try loginResponse(userId: "must-not-store")))
        await oldFactor.value
        #expect(app.session == nil)
        #expect(backend.storedSession == nil)
        #expect(app.isAuthenticating)
        app.showLogin()
        await newerLogin.value
        #expect(!app.isAuthenticating)
    }

    private var googleBeginJSON: [String: Any] {
        [
            "attemptId": "214e1228-4266-4b82-9cb7-41d1da0b7d41",
            "redemptionToken": String(repeating: "r", count: 43),
            "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)),
            "clientId": "123-test.apps.googleusercontent.com",
            "redirectUri": "com.googleusercontent.apps.123-test:/oauth2callback",
            "state": String(repeating: "s", count: 43), "nonce": String(repeating: "n", count: 43),
            "codeChallenge": String(repeating: "c", count: 43)
        ]
    }

    private func googleBegin() throws -> GoogleNativeBeginResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GoogleNativeBeginResponse.self, from: JSONSerialization.data(withJSONObject: googleBeginJSON))
    }

    private func googleLimitError(token: String) throws -> APIError {
        let json: [String: Any] = [
            "message": "Device limit reached", "errorCode": "DEVICE_LIMIT_EXCEEDED",
            "currentDevices": 1, "maxDevices": 1, "planType": "Free",
            "devices": [["id":42,"deviceIdHash":"device-hash"]],
            "loginContinuationToken": token,
            "loginContinuationExpiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let limit = try decoder.decode(DeviceLimitResponse.self, from: JSONSerialization.data(withJSONObject: json))
        return APIError(statusCode:409, message:limit.message, code:limit.errorCode, deviceLimit:limit)
    }

    private func waitForServerRefresh(_ app: AppModel) async {
        for _ in 0..<200 {
            if !app.isRefreshingServers { return }
            await Task.yield()
        }
        Issue.record("Server refresh did not finish during the test")
    }

    private func startupSession() -> AuthSession {
        AuthSession(
            accessToken: "startup-access",
            refreshToken: "startup-refresh",
            email: "startup@example.com",
            userId: "startup-user",
            deviceId: "startup-device"
        )
    }

    private func loginResponse(userId: String) throws -> LoginResponse {
        try JSONDecoder().decode(
            LoginResponse.self,
            from: Data("""
                {
                  "token": "access-token",
                  "refreshToken": "refresh-token",
                  "email": "person@example.com",
                  "userId": "\(userId)",
                  "deviceId": "test-device",
                  "planType": "Free"
                }
                """.utf8)
        )
    }

    private func subscriptionStatus(plan: String, isPro: Bool) throws -> libreguard_vpn_ios.SubscriptionStatus {
        try JSONDecoder().decode(
            libreguard_vpn_ios.SubscriptionStatus.self,
            from: JSONSerialization.data(withJSONObject: subscriptionJSON(plan: plan, isPro: isPro))
        )
    }

    private func appleTransaction(id: UInt64, expirationDate: Date? = nil) -> AppleStoreTransaction {
        AppleStoreTransaction(
            id: id,
            productID: AppleSubscriptionCatalog.monthlyProductID,
            signedTransactionInfo: "signed-transaction-\(id)",
            environment: .sandbox,
            purchaseDate: Date().addingTimeInterval(-7200),
            expirationDate: expirationDate
        )
    }

    private func makeApplePurchaseApp(
        backend: StartupBackendStub,
        store: ControllableAppleSubscriptionStore,
        retryDelays: [UInt64] = [0]
    ) async -> AppModel {
        let app = makeStartupApp(
            backend: backend,
            vpn: StartupVPNManager(status: .disconnected),
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            appleStore: store,
            appleVerificationRetryDelays: retryDelays
        )
        app.session = startupSession()
        await app.loadAppleSubscriptions()
        return app
    }

    private func makeStartupApp(
        backend: StartupBackendStub,
        vpn: StartupVPNManager,
        defaults: UserDefaults,
        appleStore: AppleSubscriptionStoreServing? = nil,
        google: GoogleSigning? = nil,
        openGoogleLinkingPage: (() -> Void)? = nil,
        appleVerificationRetryDelays: [UInt64] = [0, 1, 3],
        appleSignIn: AppleSigning? = nil,
        appleCredentialStateChecker: AppleCredentialStateChecking? = nil,
        appleCredentialBindingStore: AppleCredentialBindingStoring? = nil,
        notificationCenter: NotificationCenter = .default
    ) -> AppModel {
        AppModel(
            api: backend,
            appleStore: appleStore ?? NoOpAppleSubscriptionStore(),
            google: google,
            openGoogleLinkingPage: openGoogleLinkingPage,
            appleSignIn: appleSignIn,
            appleCredentialStateChecker: appleCredentialStateChecker,
            appleCredentialBindingStore: appleCredentialBindingStore,
            notificationCenter: notificationCenter,
            latencyProbe: NoOpLatencyProbe(),
            vpnManager: vpn,
            defaults: defaults,
            appleVerificationRetryDelays: appleVerificationRetryDelays
        )
    }

    func makeClient(
        sessionStore: SessionStoring? = nil,
        deviceKeyStore: VPNDeviceKeyProviding? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return APIClient(
            baseURL: URL(string: "https://management.libreguard.net")!,
            urlSession: URLSession(configuration: configuration),
            sessionStore: sessionStore ?? InMemorySessionStore(),
            deviceStore: StubDeviceIdentity(),
            deviceKeyStore: deviceKeyStore ?? StubVPNDeviceKeyStore()
        )
    }

    func withSerializedRequests<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await TestIsolation.shared.withExclusiveAccess(operation)
    }

    func requestBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw APIError(message: "Missing request body")
        }
        stream.open()
        defer { stream.close() }

        let bufferSize = 4_096
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError ?? APIError(message: "Unable to read request body")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    func makeResponse(_ request: URLRequest, status: Int, json: Any) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else {
            throw APIError(message: "Missing request URL")
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: status == 429 ? ["Retry-After": "30"] : nil
        ) else {
            throw APIError(message: "Failed to build test response")
        }
        return (response, try JSONSerialization.data(withJSONObject: json))
    }

    private var quotaJSON: [String: Any] {
        [
            "bytesUsed": 1_024,
            "bytesLimit": 5_120,
            "bytesRemaining": 4_096,
            "usagePercentage": 20.0,
            "isUnlimited": false,
            "isOverLimit": false,
            "formattedUsed": "1 KB",
            "formattedLimit": "5 KB",
            "formattedRemaining": "4 KB",
            "cycleStart": "2026-06-01T00:00:00Z",
            "cycleEnd": "2026-07-01T00:00:00Z",
            "resetDate": "2026-07-01T00:00:00Z"
        ]
    }

    private var dnsPreferenceJSON: [String: Any] {
        [
            "requestedEnabled": false,
            "canUseAdBlocking": true,
            "effectiveEnabled": false,
            "effectiveMode": "regular",
            "propagationSeconds": 15
        ]
    }

    private func subscriptionJSON(plan: String, isPro: Bool) -> [String: Any] {
        [
            "plan": plan,
            "isPro": isPro,
            "status": isPro ? "active" : "inactive",
            "paymentType": NSNull(),
            "currentPeriodEnd": NSNull(),
            "cancelAtPeriodEnd": false,
            "billingCycle": isPro ? "monthly" : "none",
            "activeDevices": 1,
            "maxDevices": isPro ? 3 : 1,
            "canAddDevice": isPro
        ]
    }

    private func makeLatencyServer(id: Int, hostname: String) -> VPNServer {
        VPNServer(
            id: id,
            serverName: "Server-\(id)",
            serverIp: "203.0.113.\(id)",
            serverHostname: hostname,
            country: "Germany",
            city: "Frankfurt",
            linkSpeed: 1_000,
            pricingTier: "Free",
            load: 20,
            activeConnections: nil,
            latencyPingPort: 5_001,
            loadDataFresh: true
        )
    }
}

actor TestIsolation {
    static let shared = TestIsolation()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveAccess<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        isLocked = true
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

@MainActor
final class InMemorySessionStore: SessionStoring {
    private(set) var session: AuthSession?

    init(session: AuthSession? = nil) { self.session = session }
    func save(_ session: AuthSession) throws { self.session = session }
    func clear() { session = nil }
}

@MainActor
final class StubDeviceIdentity: DeviceIdentifying {
    let deviceId = "test-device"
    let appVersion = "1.0-test"
}

@MainActor
final class StubVPNDeviceKeyStore: VPNDeviceKeyProviding {
    func publicKeyPayload() throws -> DevicePublicKeyPayload {
        DevicePublicKeyPayload(
            devicePublicKey: "base64-spki",
            devicePublicKeyId: "device-key-id",
            devicePublicKeyAlgorithm: "RSA-OAEP-256"
        )
    }

    func decryptPassphrase(from encryptedPassphrase: EncryptedPassphrase) throws -> String {
        "test-passphrase"
    }
}

@MainActor
private final class DNSSettingsTestVPNManager: VPNManaging {
    var status: VPNConnectionState = .disconnected
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?

    func refreshStatus() async {}
    func connect(
        to server: VPNServer,
        protocol protocolName: VPNConfigurationProtocol,
        policy: VPNConnectionPolicy
    ) async throws {}
    func apply(policy: VPNConnectionPolicy) async throws -> Bool { true }
    func disconnect() async {}
    func disconnectAndForget() async -> VPNProfileCleanupResult { .noProfile }
}

@MainActor
final class StartupBackendStub: BackendServicing, SessionInvalidationObserving {
    var storedSession: AuthSession?
    let deviceId = "startup-device"
    let appVersion = "1.0-test"
    var onSessionInvalidated: (() -> Void)?
    private(set) var sessionInvalidationCallbackCount = 0
    private var restoreResults: [Result<AuthSession?, Error>]
    var googleBeginResponse: GoogleNativeBeginResponse?
    var googleCompleteResult: Result<LoginResponse, Error>?
    var googleContinueResult: Result<LoginResponse, Error>?
    var googleBeginCalls = 0
    var googleCompleteCalls = 0
    var googleContinueTokens: [String] = []
    var googleRemovedDevices: [[Int]] = []
    var factorResult: Result<LoginResponse, Error>?
    var holdFactorResponse = false
    private var pendingFactorResponse: CheckedContinuation<LoginResponse, Error>?
    var hasPendingFactorResponse: Bool { pendingFactorResponse != nil }
    func completeFactorResponse(with result: Result<LoginResponse, Error>) {
        let response = pendingFactorResponse
        pendingFactorResponse = nil
        response?.resume(with: result)
    }
    var passwordLoginResponse: LoginResponse?
    var appleLoginResponse: LoginResponse?
    var subscriptionResults: [Result<libreguard_vpn_ios.SubscriptionStatus, Error>] = []
    var appleVerificationResults: [Result<AppleTransactionVerificationResponse, Error>] = []
    var appleAccountToken = UUID()
    private(set) var requestedAppleEnvironments: [AppleAPIEnvironment] = []
    private(set) var appleVerificationAllowTransfer: [Bool] = []
    var holdFirstAppleVerification = false
    private var firstAppleVerificationStarted = false
    private var firstAppleVerificationWaiter: CheckedContinuation<Void, Never>?
    private var firstAppleVerificationRelease: CheckedContinuation<Void, Never>?
    var holdFirstSubscriptionRequest = false
    private(set) var appleLoginIdToken: String?
    private(set) var appleLoginNonce: String?
    private(set) var appleLoginConsent: Bool?
    private(set) var removedAppleToken: String?
    private(set) var removedAppleNonce: String?
    private(set) var removedAppleDeviceId: Int?
    private var subscriptionRequestCount = 0
    private var firstSubscriptionRequestStarted = false
    private var firstSubscriptionRequestWaiter: CheckedContinuation<Void, Never>?
    private var firstSubscriptionRequestRelease: CheckedContinuation<Void, Never>?
    var serverResponse: [VPNServer] = []
    var serverError: Error?
    private(set) var fetchServersCallCount = 0

    init(storedSession: AuthSession?, restoreResults: [Result<AuthSession?, Error>]) {
        self.storedSession = storedSession
        self.restoreResults = restoreResults
    }

    func restoreSession() async throws -> AuthSession? {
        guard !restoreResults.isEmpty else { return storedSession }
        let result = restoreResults.removeFirst()
        do {
            let restoredSession = try result.get()
            if let restoredSession { storedSession = restoredSession }
            return restoredSession
        } catch {
            if let apiError = error as? APIError,
               apiError.statusCode == 401 || apiError.requiresLogin || apiError.requiresDeviceRegistration || apiError.code == "SESSION_EXPIRED" {
                sessionInvalidationCallbackCount += 1
                onSessionInvalidated?()
            }
            throw error
        }
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        guard let passwordLoginResponse else { return try unsupported() }
        return passwordLoginResponse
    }
    func beginGoogleLogin(newsletterConsent: Bool?) async throws -> GoogleNativeBeginResponse {
        googleBeginCalls += 1
        guard let googleBeginResponse else { return try unsupported() }
        return googleBeginResponse
    }
    func completeGoogleLogin(attempt: GoogleNativeBeginResponse, authorization: GoogleAuthorizationResult) async throws -> LoginResponse {
        googleCompleteCalls += 1
        guard let googleCompleteResult else { return try unsupported() }
        return try googleCompleteResult.get()
    }
    func continueGoogleLogin(token: String, deviceIdsToRemove: [Int]) async throws -> LoginResponse {
        googleContinueTokens.append(token)
        googleRemovedDevices.append(deviceIdsToRemove)
        guard let googleContinueResult else { return try unsupported() }
        return try googleContinueResult.get()
    }
    func loginWithApple(idToken: String, nonce: String, newsletterConsent: Bool?) async throws -> LoginResponse {
        appleLoginIdToken = idToken
        appleLoginNonce = nonce
        appleLoginConsent = newsletterConsent
        guard let appleLoginResponse else { return try unsupported() }
        return appleLoginResponse
    }
    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse {
        if holdFactorResponse {
            return try await withCheckedThrowingContinuation { pendingFactorResponse = $0 }
        }
        guard let factorResult else { return try unsupported() }
        return try factorResult.get()
    }
    func verifyRecoveryCode(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse { try await verifyTwoFactor(challenge, code: code) }
    func register(email: String, password: String, newsletterConsent: Bool) async throws -> RegistrationResponse { try unsupported() }
    func requestPasswordReset(email: String) async throws -> MessageResponse { try unsupported() }
    func resetPassword(email: String, token: String, newPassword: String) async throws -> MessageResponse { try unsupported() }
    func confirmationStatus(userId: String) async throws -> ConfirmationStatusResponse { try unsupported() }
    func resendConfirmation(email: String) async throws { throw APIError(message: "Not configured") }
    func removePasswordDevice(email: String, password: String, deviceId: Int) async throws { throw APIError(message: "Not configured") }
    func removeAppleDevice(idToken: String, nonce: String, deviceId: Int) async throws {
        removedAppleToken = idToken
        removedAppleNonce = nonce
        removedAppleDeviceId = deviceId
    }
    func adoptSession(from response: LoginResponse) throws -> AuthSession {
        guard let accessToken = response.token,
              let refreshToken = response.refreshToken,
              let email = response.email,
              let userId = response.userId,
              let deviceId = response.deviceId else {
            return try unsupported()
        }
        let session = AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            userId: userId,
            deviceId: deviceId
        )
        storedSession = session
        return session
    }
    func clearLocalSession() { storedSession = nil }
    func logout() async { storedSession = nil }
    func fetchServers() async throws -> [VPNServer] {
        fetchServersCallCount += 1
        if let serverError { throw serverError }
        return serverResponse
    }
    func fetchVPNConfig(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> VPNConfigResponse { try unsupported() }
    func requestCertificate(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateJobCreatedResponse { try unsupported() }
    func fetchCertificateGenerationStatus(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateGenerationStatusResponse { try unsupported() }
    func fetchCertificateJob(jobId: Int) async throws -> CertificateJobStatusResponse { try unsupported() }
    func fetchUsage() async throws -> UsageQuota { try unsupported() }
    func fetchConnectionEligibility() async throws -> CanConnectResponse { try unsupported() }
    func fetchSubscription() async throws -> libreguard_vpn_ios.SubscriptionStatus {
        subscriptionRequestCount += 1
        guard !subscriptionResults.isEmpty else { return try unsupported() }
        let result = subscriptionResults.removeFirst()
        if subscriptionRequestCount == 1, holdFirstSubscriptionRequest {
            firstSubscriptionRequestStarted = true
            firstSubscriptionRequestWaiter?.resume()
            firstSubscriptionRequestWaiter = nil
            await withCheckedContinuation { continuation in
                firstSubscriptionRequestRelease = continuation
            }
        }
        return try result.get()
    }
    func waitForFirstSubscriptionRequest() async {
        guard !firstSubscriptionRequestStarted else { return }
        await withCheckedContinuation { continuation in
            firstSubscriptionRequestWaiter = continuation
        }
    }
    func releaseFirstSubscriptionRequest() {
        firstSubscriptionRequestRelease?.resume()
        firstSubscriptionRequestRelease = nil
    }
    func fetchDNSPreference() async throws -> DNSPreference { try unsupported() }
    func updateDNSPreference(adBlockingEnabled: Bool) async throws -> DNSPreference { try unsupported() }
    func fetchAppleAccountToken(environment: AppleAPIEnvironment) async throws -> UUID {
        requestedAppleEnvironments.append(environment)
        return appleAccountToken
    }
    func verifyAppleTransaction(_ signedTransactionInfo: String, allowTransfer: Bool, environment: AppleAPIEnvironment) async throws -> AppleTransactionVerificationResponse {
        appleVerificationAllowTransfer.append(allowTransfer)
        if holdFirstAppleVerification, appleVerificationAllowTransfer.count == 1 {
            firstAppleVerificationStarted = true
            firstAppleVerificationWaiter?.resume()
            firstAppleVerificationWaiter = nil
            await withCheckedContinuation { continuation in firstAppleVerificationRelease = continuation }
        }
        guard !appleVerificationResults.isEmpty else { return try unsupported() }
        return try appleVerificationResults.removeFirst().get()
    }
    func waitForFirstAppleVerification() async {
        guard !firstAppleVerificationStarted else { return }
        await withCheckedContinuation { continuation in firstAppleVerificationWaiter = continuation }
    }
    func releaseFirstAppleVerification() {
        firstAppleVerificationRelease?.resume()
        firstAppleVerificationRelease = nil
    }
    func fetchTwoFactorStatus() async throws -> TwoFactorStatus { try unsupported() }
    func setupTwoFactor() async throws -> AuthenticatorSetup { try unsupported() }
    func enableTwoFactor(code: String) async throws -> [String] { try unsupported() }
    func disableTwoFactor() async throws { throw APIError(message: "Not configured") }
    func generateRecoveryCodes() async throws -> [String] { try unsupported() }

    private func unsupported<T>() throws -> T {
        throw APIError(message: "Not configured")
    }
}

@MainActor
private final class StartupVPNManager: VPNManaging {
    var status: VPNConnectionState
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    private(set) var disableCalls = 0
    private(set) var cleanupCalls = 0
    private var cleanupResults: [VPNProfileCleanupResult]

    init(
        status: VPNConnectionState,
        cleanupResults: [VPNProfileCleanupResult]? = nil
    ) {
        self.status = status
        self.cleanupResults = cleanupResults ?? [.noProfile]
    }

    func refreshStatus() async {
        onStatusChange?(status)
    }

    func emit(_ status: VPNConnectionState) {
        self.status = status
        onStatusChange?(status)
    }

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws {
        status = .connected
        onStatusChange?(status)
    }

    func apply(policy: VPNConnectionPolicy) async throws -> Bool { true }

    func disconnect() async {
        status = .disconnected
        onStatusChange?(status)
    }

    func disableOnDemandAndProfile() async -> Bool {
        disableCalls += 1
        return true
    }

    func disconnectAndForget() async -> VPNProfileCleanupResult {
        cleanupCalls += 1
        _ = await disableOnDemandAndProfile()
        let result = cleanupResults.isEmpty ? .noProfile : cleanupResults.removeFirst()
        if result.tunnelStopped {
            status = .disconnected
            onStatusChange?(status)
        }
        return result
    }
}

@MainActor
private final class ControllableAppleSubscriptionStore: AppleSubscriptionStoreServing {
    var canMakePayments = true
    var environment: AppleAPIEnvironment = .sandbox
    var purchaseResult: Result<ApplePurchaseResult, Error> = .success(.userCancelled)
    var currentResults: [AppleStoreUpdate] = []
    var unfinishedResults: [AppleStoreUpdate] = []
    private(set) var purchaseCalls: [String] = []
    private(set) var finishedIDs: [UInt64] = []
    private(set) var syncCount = 0

    func purchaseEnvironment() async throws -> AppleAPIEnvironment { environment }
    func loadProducts() async throws -> [AppleSubscriptionProduct] {
        [
            AppleSubscriptionProduct(id: AppleSubscriptionCatalog.annualProductID,
                                     displayName: "Pro Annual", description: "Pro", displayPrice: "$29.99",
                                     price: Decimal(29.99), period: .annual),
            AppleSubscriptionProduct(id: AppleSubscriptionCatalog.monthlyProductID,
                                     displayName: "Pro Monthly", description: "Pro", displayPrice: "$5.99",
                                     price: Decimal(5.99), period: .monthly)
        ]
    }
    func purchase(productID: String, appAccountToken: UUID) async throws -> ApplePurchaseResult {
        purchaseCalls.append(productID)
        return try purchaseResult.get()
    }
    func sync() async throws { syncCount += 1 }
    func currentEntitlements() async -> [AppleStoreUpdate] { currentResults }
    func unfinishedTransactions() async -> [AppleStoreUpdate] { unfinishedResults }
    func transactionUpdates() -> AsyncStream<AppleStoreUpdate> {
        AsyncStream { continuation in continuation.finish() }
    }
    func finish(transactionID: UInt64) async {
        if !finishedIDs.contains(transactionID) { finishedIDs.append(transactionID) }
    }
}

@MainActor
private final class NoOpAppleSubscriptionStore: AppleSubscriptionStoreServing {
    var canMakePayments: Bool { true }
    func purchaseEnvironment() async throws -> AppleAPIEnvironment { .production }
    func loadProducts() async throws -> [AppleSubscriptionProduct] { [] }
    func purchase(productID: String, appAccountToken: UUID) async throws -> ApplePurchaseResult { throw APIError(message: "Not configured") }
    func sync() async throws {}
    func currentEntitlements() async -> [AppleStoreUpdate] { [] }
    func unfinishedTransactions() async -> [AppleStoreUpdate] { [] }
    func transactionUpdates() -> AsyncStream<AppleStoreUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
    func finish(transactionID: UInt64) async {}
}

@MainActor
private final class NoOpLatencyProbe: LatencyProbing {
    func measure(_ servers: [VPNServer]) async -> [Int: Int] { [:] }
}

@MainActor
private final class RecordingLatencyProbe: LatencyProbing {
    let result: [Int: Int]
    let holdMeasurement: Bool
    private(set) var measurementCalls: [[VPNServer]] = []

    init(result: [Int: Int], holdMeasurement: Bool = false) {
        self.result = result
        self.holdMeasurement = holdMeasurement
    }

    func measure(_ servers: [VPNServer]) async -> [Int: Int] {
        measurementCalls.append(servers)
        while holdMeasurement, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return result
    }
}

final class ThreadSafeProbeStats: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequests = 0
    private(set) var requestCount = 0
    private(set) var maximumActiveRequests = 0

    func recordRequest() {
        lock.lock()
        requestCount += 1
        lock.unlock()
    }

    func beginRequest() -> Int {
        lock.lock()
        activeRequests += 1
        let active = activeRequests
        lock.unlock()
        return active
    }

    func recordMaximumActiveRequests(_ active: Int) {
        lock.lock()
        maximumActiveRequests = max(maximumActiveRequests, active)
        lock.unlock()
    }

    func endRequest() {
        lock.lock()
        activeRequests -= 1
        lock.unlock()
    }
}

@MainActor
private final class InMemoryAppleCredentialBindingStore: AppleCredentialBindingStoring {
    var binding: AppleCredentialBinding?

    init(binding: AppleCredentialBinding? = nil) {
        self.binding = binding
    }

    func load() -> AppleCredentialBinding? { binding }
    func save(_ binding: AppleCredentialBinding) throws { self.binding = binding }
    func clear() { binding = nil }
}

@MainActor
private final class StubAppleCredentialStateChecker: AppleCredentialStateChecking {
    var result: Result<AppleCredentialState, Error>
    private(set) var checkedUserIdentifiers: [String] = []

    init(result: Result<AppleCredentialState, Error>) {
        self.result = result
    }

    func credentialState(for userIdentifier: String) async throws -> AppleCredentialState {
        checkedUserIdentifiers.append(userIdentifier)
        return try result.get()
    }
}

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError(message: "Missing test handler"))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ConcurrentURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let client = self.client
        let request = self.request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError(message: "Missing test handler"))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}


@MainActor
private final class ControlledGoogleSigner: GoogleSigning {
    var isConfigured = true
    var calls = 0
    var holdAuthorization = false
    var ignoreCancellation = false
    private var pending: CheckedContinuation<GoogleAuthorizationResult, Error>?
    private var state = ""
    func signIn(attempt: GoogleNativeBeginResponse) async throws -> GoogleAuthorizationResult {
        calls += 1
        state = attempt.state
        if holdAuthorization {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return GoogleAuthorizationResult(code: "authorization-code", state: attempt.state)
    }
    func complete() {
        let callback = pending
        pending = nil
        callback?.resume(returning: GoogleAuthorizationResult(code: "late-code", state: state))
    }
    func signOut() {
        guard !ignoreCancellation else { return }
        let callback = pending
        pending = nil
        callback?.resume(throwing: CancellationError())
    }
    func handle(url: URL) -> Bool { false }
}
