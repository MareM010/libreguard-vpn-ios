import Foundation
import AuthenticationServices
import SwiftData
import SwiftUI
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

    @Test func googleLoginOmitsConsentForLoginAndIncludesItForRegistration() async throws {
        try await withSerializedRequests {
            var receivedValues: [Bool?] = []
            let client = makeClient { request in
                #expect(request.url?.path == "/api/login/google")
                let json = try #require(JSONSerialization.jsonObject(with: requestBody(from: request)) as? [String: Any])
                receivedValues.append(json["newsletterConsent"] as? Bool)
                return try makeResponse(request, status: 200, json: [:])
            }

            _ = try await client.loginWithGoogle(idToken: "login-token")
            _ = try await client.loginWithGoogle(idToken: "registration-token", newsletterConsent: true)

            #expect(receivedValues.count == 2)
            #expect(receivedValues[0] == nil)
            #expect(receivedValues[1] == true)
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

    @Test func oauthDeviceRemovalKeepsGoogleCompatibleAndAddsAppleNonce() async throws {
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

            try await client.removeGoogleDevice(idToken: "google-token", deviceId: 41)
            try await client.removeAppleDevice(idToken: "apple-token", nonce: "apple-nonce", deviceId: 42)

            #expect(receivedBodies.count == 2)
            #expect(receivedBodies[0]["provider"] as? String == "Google")
            #expect(receivedBodies[0]["idToken"] as? String == "google-token")
            #expect(receivedBodies[0]["nonce"] == nil)
            #expect(receivedBodies[0]["deviceIdToRemove"] as? Int == 41)
            #expect(receivedBodies[1]["provider"] as? String == "Apple")
            #expect(receivedBodies[1]["idToken"] as? String == "apple-token")
            #expect(receivedBodies[1]["nonce"] as? String == "apple-nonce")
            #expect(receivedBodies[1]["deviceIdToRemove"] as? Int == 42)
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
        let quota = try JSONDecoder().decode(UsageQuota.self, from: JSONSerialization.data(withJSONObject: [
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

            #expect(try await client.fetchAppleAccountToken() == token)
            let response = try await client.verifyAppleTransaction("signed-jws", allowTransfer: true)
            #expect(response.transferred)
            #expect(response.subscription.isAppleBilled)
            #expect(response.subscription.billingCycle == "annual")
            #expect(requestCount == 2)
        }
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
        let subscription = try JSONDecoder().decode(SubscriptionStatus.self, from: JSONSerialization.data(withJSONObject: [
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

    private func makeStartupApp(
        backend: StartupBackendStub,
        vpn: StartupVPNManager,
        defaults: UserDefaults,
        appleSignIn: AppleSigning? = nil,
        appleCredentialStateChecker: AppleCredentialStateChecking? = nil,
        appleCredentialBindingStore: AppleCredentialBindingStoring? = nil,
        notificationCenter: NotificationCenter = .default
    ) -> AppModel {
        AppModel(
            api: backend,
            appleStore: NoOpAppleSubscriptionStore(),
            appleSignIn: appleSignIn,
            appleCredentialStateChecker: appleCredentialStateChecker,
            appleCredentialBindingStore: appleCredentialBindingStore,
            notificationCenter: notificationCenter,
            latencyProbe: NoOpLatencyProbe(),
            vpnManager: vpn,
            defaults: defaults
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
private final class StartupBackendStub: BackendServicing, SessionInvalidationObserving {
    var storedSession: AuthSession?
    let deviceId = "startup-device"
    let appVersion = "1.0-test"
    var onSessionInvalidated: (() -> Void)?
    private(set) var sessionInvalidationCallbackCount = 0
    private var restoreResults: [Result<AuthSession?, Error>]
    var passwordLoginResponse: LoginResponse?
    var appleLoginResponse: LoginResponse?
    private(set) var appleLoginIdToken: String?
    private(set) var appleLoginNonce: String?
    private(set) var appleLoginConsent: Bool?
    private(set) var removedAppleToken: String?
    private(set) var removedAppleNonce: String?
    private(set) var removedAppleDeviceId: Int?

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
    func loginWithGoogle(idToken: String, newsletterConsent: Bool?) async throws -> LoginResponse { try unsupported() }
    func loginWithApple(idToken: String, nonce: String, newsletterConsent: Bool?) async throws -> LoginResponse {
        appleLoginIdToken = idToken
        appleLoginNonce = nonce
        appleLoginConsent = newsletterConsent
        guard let appleLoginResponse else { return try unsupported() }
        return appleLoginResponse
    }
    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse { try unsupported() }
    func verifyRecoveryCode(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse { try unsupported() }
    func register(email: String, password: String, newsletterConsent: Bool) async throws -> RegistrationResponse { try unsupported() }
    func requestPasswordReset(email: String) async throws -> MessageResponse { try unsupported() }
    func resetPassword(email: String, token: String, newPassword: String) async throws -> MessageResponse { try unsupported() }
    func confirmationStatus(userId: String) async throws -> ConfirmationStatusResponse { try unsupported() }
    func resendConfirmation(email: String) async throws { throw APIError(message: "Not configured") }
    func removePasswordDevice(email: String, password: String, deviceId: Int) async throws { throw APIError(message: "Not configured") }
    func removeGoogleDevice(idToken: String, deviceId: Int) async throws { throw APIError(message: "Not configured") }
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
    func fetchServers() async throws -> [VPNServer] { [] }
    func fetchVPNConfig(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> VPNConfigResponse { try unsupported() }
    func requestCertificate(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateJobCreatedResponse { try unsupported() }
    func fetchCertificateGenerationStatus(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateGenerationStatusResponse { try unsupported() }
    func fetchCertificateJob(jobId: Int) async throws -> CertificateJobStatusResponse { try unsupported() }
    func fetchUsage() async throws -> UsageQuota { try unsupported() }
    func fetchConnectionEligibility() async throws -> CanConnectResponse { try unsupported() }
    func fetchSubscription() async throws -> SubscriptionStatus { try unsupported() }
    func fetchDNSPreference() async throws -> DNSPreference { try unsupported() }
    func updateDNSPreference(adBlockingEnabled: Bool) async throws -> DNSPreference { try unsupported() }
    func fetchAppleAccountToken() async throws -> UUID { try unsupported() }
    func verifyAppleTransaction(_ signedTransactionInfo: String, allowTransfer: Bool) async throws -> AppleTransactionVerificationResponse { try unsupported() }
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
private final class NoOpAppleSubscriptionStore: AppleSubscriptionStoreServing {
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
