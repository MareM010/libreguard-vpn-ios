import Foundation
import Testing
@testable import libreguard_vpn_ios

@Suite(SharedVPNFixtureScope())
@MainActor
struct SessionRefreshRaceTests {
    @Test func lateRefreshSuccessCannotReplaceNewAccount() async throws {
        try await assertReplacementSurvivesLateRefresh(sameAccount: false, refreshStatus: 200)
    }

    @Test func lateRefreshFailureCannotInvalidateNewAccount() async throws {
        try await assertReplacementSurvivesLateRefresh(sameAccount: false, refreshStatus: 401)
    }

    @Test func lateRefreshSuccessCannotReplaceNewCredentialsForSameAccount() async throws {
        try await assertReplacementSurvivesLateRefresh(sameAccount: true, refreshStatus: 200)
    }

    @Test func lateRefreshFailureCannotInvalidateNewCredentialsForSameAccount() async throws {
        try await assertReplacementSurvivesLateRefresh(sameAccount: true, refreshStatus: 401)
    }

    @Test func lateAuthorized401CannotRefreshOrRetryNewLogin() async throws {
        let original = session(credentials: "original")
        let replacement = session(credentials: "new-login")
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 1)
        let client = makeClient(store: store, transport: transport)
        var invalidationCount = 0
        client.onSessionInvalidated = { invalidationCount += 1 }

        let fetch = Task { @MainActor in try await client.fetchServers() }
        let request = try await transport.request(at: 0)
        #expect(request.url?.path == "/api/vpn/servers")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(original.accessToken)")
        _ = try client.adoptSession(from: loginResponse(replacement))
        try transport.finish(at: 0, statusCode: 401, json: ["message": "The original access token expired"])

        do {
            _ = try await fetch.value
            Issue.record("Expected the superseded authorized request to be cancelled")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(client.storedSession == replacement)
        #expect(store.session == replacement)
        #expect(invalidationCount == 0)
        #expect(transport.requests.count == 1)
    }

    @Test func currentRefresh401StillInvalidatesItsSession() async throws {
        let original = session(credentials: "original")
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 1)
        let client = makeClient(store: store, transport: transport)
        var invalidationCount = 0
        client.onSessionInvalidated = { invalidationCount += 1 }

        let refresh = Task { @MainActor in try await client.restoreSession() }
        try assertRefreshRequest(await transport.request(at: 0), for: original)
        try transport.finish(at: 0, statusCode: 401, json: [
            "message": "Your session has expired",
            "requiresLogin": true,
            "errorCode": "SESSION_EXPIRED"
        ])

        do {
            _ = try await refresh.value
            Issue.record("Expected the current session's refresh to fail")
        } catch {
            let apiError = try #require(error as? APIError)
            #expect(apiError.statusCode == 401)
            #expect(apiError.requiresLogin)
        }
        #expect(client.storedSession == nil)
        #expect(store.session == nil)
        #expect(invalidationCount == 1)
        #expect(try await client.restoreSession() == nil)
        #expect(transport.requests.count == 1)
    }

    @Test func lateLogoutCompletionCannotClearNewLogin() async throws {
        let original = session(credentials: "original")
        let replacement = session(credentials: "new-login")
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 1)
        let client = makeClient(store: store, transport: transport)
        var invalidationCount = 0
        client.onSessionInvalidated = { invalidationCount += 1 }

        let logout = Task { @MainActor in await client.logout() }
        let request = try await transport.request(at: 0)
        #expect(request.url?.path == "/api/logout")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(original.accessToken)")
        #expect(try requestBody(request)["refreshToken"] as? String == original.refreshToken)

        _ = try client.adoptSession(from: loginResponse(replacement))
        try transport.finish(at: 0, statusCode: 200, json: ["message": "Logged out"])
        await logout.value

        #expect(client.storedSession == replacement)
        #expect(store.session == replacement)
        #expect(invalidationCount == 0)
        #expect(transport.requests.count == 1)
    }

    @Test func lateRefreshAfterLocalClearCannotRecreateSession() async throws {
        let original = session(credentials: "original")
        let staleRotation = session(credentials: "stale-rotation")
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 1)
        let client = makeClient(store: store, transport: transport)
        var invalidationCount = 0
        client.onSessionInvalidated = { invalidationCount += 1 }

        let refresh = Task { @MainActor in try await client.restoreSession() }
        let request = try await transport.request(at: 0)
        try assertRefreshRequest(request, for: original)
        client.clearLocalSession()
        #expect(client.storedSession == nil)

        try transport.finish(at: 0, statusCode: 200, json: loginJSON(staleRotation))
        _ = await refresh.result

        #expect(client.storedSession == nil)
        #expect(store.session == nil)
        #expect(invalidationCount == 0)
        #expect(try await client.restoreSession() == nil)
        #expect(transport.requests.count == 1)
    }

    @Test func oldRefreshCleanupDoesNotRetireReplacementRefresh() async throws {
        let original = session(credentials: "original")
        let replacement = session(credentials: "new-login")
        let staleRotation = session(credentials: "stale-rotation")
        let replacementRotation = session(credentials: "new-rotation")
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 2)
        let client = makeClient(store: store, transport: transport)
        var invalidationCount = 0
        client.onSessionInvalidated = { invalidationCount += 1 }

        let oldRefresh = Task { @MainActor in try await client.restoreSession() }
        try assertRefreshRequest(await transport.request(at: 0), for: original)

        client.clearLocalSession()
        _ = try client.adoptSession(from: loginResponse(replacement))
        let replacementRefresh = Task { @MainActor in try await client.restoreSession() }
        try assertRefreshRequest(await transport.request(at: 1), for: replacement)

        // The cancelled transport deliberately delivers its response while the
        // replacement refresh is still suspended. Its cleanup must only retire A.
        try transport.finish(at: 0, statusCode: 200, json: loginJSON(staleRotation))
        _ = await oldRefresh.result
        #expect(client.storedSession == replacement)

        let callerStarted = SessionRaceSignal()
        let coalescedCaller = Task { @MainActor in
            callerStarted.signal()
            return try await client.restoreSession()
        }
        await callerStarted.wait()
        // Let the caller enter the shared refresh wait before releasing B.
        await Task.yield()
        #expect(transport.requests.count == 2)

        try transport.finish(at: 1, statusCode: 200, json: loginJSON(replacementRotation))
        let replacementResult = try await replacementRefresh.value
        let coalescedResult = try await coalescedCaller.value

        #expect(replacementResult == replacementRotation)
        #expect(coalescedResult == replacementRotation)
        #expect(client.storedSession == replacementRotation)
        #expect(store.session == replacementRotation)
        #expect(invalidationCount == 0)
        #expect(transport.requests.count == 2)
    }

    @Test func startupLateRefreshSuccessCannotRestoreOldCredentials() async throws {
        try await assertStartupReplacementSurvivesLateRefresh(refreshStatus: 200)
    }

    @Test func startupLateRefreshFailureCannotRestoreOldCredentials() async throws {
        try await assertStartupReplacementSurvivesLateRefresh(refreshStatus: 401)
    }

    @Test func queuedInvalidationCannotCleanUpNewLogin() async throws {
        let original = session(credentials: "original")
        let replacement = session(credentials: "new-login")
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 0)
        let client = makeClient(store: store, transport: transport)
        let vpn = SessionRaceVPNManager()
        let suiteName = "SessionRefreshRaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let app = makeApp(client: client, vpn: vpn, defaults: defaults)
        app.session = original

        client.clearLocalSession()
        let invalidation = try #require(client.onSessionInvalidated)
        invalidation()
        // The callback queues its UI/VPN cleanup on the main actor. A new login
        // is adopted synchronously before that queued task gets to run.
        _ = try client.adoptSession(from: loginResponse(replacement))
        app.session = replacement
        for _ in 0..<20 { await Task.yield() }

        #expect(app.session == replacement)
        #expect(client.storedSession == replacement)
        #expect(store.session == replacement)
        #expect(app.sessionCleanupState == nil)
        #expect(vpn.cleanupCalls == 0)
        #expect(transport.requests.isEmpty)
    }

    private func assertStartupReplacementSurvivesLateRefresh(refreshStatus: Int) async throws {
        let original = session(credentials: "original")
        let replacement = session(credentials: "new-login")
        let staleRotation = session(credentials: "stale-rotation", userId: original.userId)
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 1)
        let client = makeClient(store: store, transport: transport)
        let vpn = SessionRaceVPNManager()
        let suiteName = "SessionRefreshRaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let app = makeApp(client: client, vpn: vpn, defaults: defaults)
        app.session = original

        let startup = Task { @MainActor in await app.start() }
        try assertRefreshRequest(await transport.request(at: 0), for: original)
        _ = try client.adoptSession(from: loginResponse(replacement))
        app.session = replacement

        let response: [String: Any] = refreshStatus == 200
            ? loginJSON(staleRotation)
            : ["message": "The original session expired", "requiresLogin": true, "errorCode": "SESSION_EXPIRED"]
        try transport.finish(at: 0, statusCode: refreshStatus, json: response)
        await startup.value
        for _ in 0..<20 { await Task.yield() }

        #expect(app.session == replacement)
        #expect(client.storedSession == replacement)
        #expect(store.session == replacement)
        #expect(app.sessionCleanupState == nil)
        #expect(vpn.cleanupCalls == 0)
        #expect(transport.requests.count == 1)
    }

    private func assertReplacementSurvivesLateRefresh(
        sameAccount: Bool,
        refreshStatus: Int
    ) async throws {
        let original = session(credentials: "original")
        let replacement = session(
            credentials: "new-login",
            userId: sameAccount ? original.userId : "other-user"
        )
        // Keep the late response bound to the original account. A user-ID-only
        // fence would pass the different-account cases but fail the same-account ones.
        let staleRotation = session(credentials: "stale-rotation", userId: original.userId)
        let store = InMemorySessionStore(session: original)
        let transport = SessionRaceTransport(maximumRequests: 1)
        let client = makeClient(store: store, transport: transport)
        var invalidationCount = 0
        client.onSessionInvalidated = { invalidationCount += 1 }

        let refresh = Task { @MainActor in try await client.restoreSession() }
        try assertRefreshRequest(await transport.request(at: 0), for: original)
        _ = try client.adoptSession(from: loginResponse(replacement))
        #expect(client.storedSession == replacement)

        let response: [String: Any] = refreshStatus == 200
            ? loginJSON(staleRotation)
            : ["message": "The original session expired", "requiresLogin": true, "errorCode": "SESSION_EXPIRED"]
        try transport.finish(at: 0, statusCode: refreshStatus, json: response)
        _ = await refresh.result

        #expect(client.storedSession == replacement)
        #expect(store.session == replacement)
        #expect(invalidationCount == 0)
        #expect(transport.requests.count == 1)
    }

    private func makeClient(store: InMemorySessionStore, transport: SessionRaceTransport) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://session-races.example")!,
            transport: { request in try await transport.send(request) },
            sessionStore: store,
            deviceStore: StubDeviceIdentity(),
            deviceKeyStore: StubVPNDeviceKeyStore()
        )
    }

    private func makeApp(client: APIClient, vpn: SessionRaceVPNManager, defaults: UserDefaults) -> AppModel {
        VPNTestFixtures.track(AppModel(
            api: client,
            appleStore: SessionRaceAppleStore(),
            appleCredentialBindingStore: SessionRaceAppleBindingStore(),
            notificationCenter: NotificationCenter(),
            latencyProbe: SessionRaceLatencyProbe(),
            vpnManager: vpn,
            defaults: defaults
        ))
    }

    private func session(credentials: String, userId: String = "original-user") -> AuthSession {
        AuthSession(
            accessToken: "\(credentials)-access",
            refreshToken: "\(credentials)-refresh",
            email: "\(userId)@example.com",
            userId: userId,
            deviceId: "test-device"
        )
    }

    private func loginJSON(_ session: AuthSession) -> [String: Any] {
        [
            "token": session.accessToken,
            "refreshToken": session.refreshToken,
            "email": session.email,
            "userId": session.userId,
            "deviceId": session.deviceId
        ]
    }

    private func loginResponse(_ session: AuthSession) throws -> LoginResponse {
        try JSONDecoder().decode(LoginResponse.self, from: JSONSerialization.data(withJSONObject: loginJSON(session)))
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertRefreshRequest(_ request: URLRequest, for session: AuthSession) throws {
        #expect(request.url?.path == "/api/login/refresh")
        #expect(request.httpMethod == "POST")
        let body = try requestBody(request)
        #expect(body["refreshToken"] as? String == session.refreshToken)
        #expect(body["deviceId"] as? String == session.deviceId)
    }
}

/// An instance-local transport that can deliver work after Task.cancel().
/// Cancellation cannot remove the checked continuation, so each test exercises
/// the authentication fence even when the underlying network ignores cancellation.
@MainActor
private final class SessionRaceTransport {
    private let maximumRequests: Int
    private(set) var requests: [URLRequest] = []
    private var pending: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var requestWaiters: [Int: [CheckedContinuation<URLRequest, Error>]] = [:]

    init(maximumRequests: Int) {
        self.maximumRequests = maximumRequests
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        if index >= maximumRequests {
            // A broken coalescing guard should fail immediately, not leave the
            // unexpected third request suspended forever.
            throw APIError(statusCode: 500, message: "Unexpected extra request in session race test")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            let waiters = requestWaiters.removeValue(forKey: index) ?? []
            for waiter in waiters { waiter.resume(returning: request) }
        }
    }

    func request(at index: Int) async throws -> URLRequest {
        if requests.indices.contains(index) { return requests[index] }
        return try await withCheckedThrowingContinuation { continuation in
            requestWaiters[index, default: []].append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                let waiters = self?.requestWaiters.removeValue(forKey: index) ?? []
                for waiter in waiters {
                    waiter.resume(throwing: APIError(message: "Timed out waiting for session race request \(index)"))
                }
            }
        }
    }

    func finish(at index: Int, statusCode: Int, json: [String: Any]) throws {
        let request = try #require(requests.indices.contains(index) ? requests[index] : nil)
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil))
        let data = try JSONSerialization.data(withJSONObject: json)
        let pendingContinuation = pending.removeValue(forKey: index)
        let continuation = try #require(pendingContinuation)
        continuation.resume(returning: (data, response))
    }
}

@MainActor
private final class SessionRaceSignal {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        signaled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
private final class SessionRaceVPNManager: VPNManaging {
    var status: VPNConnectionState = .disconnected
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    private(set) var cleanupCalls = 0

    func refreshStatus() async { onStatusChange?(status) }
    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws {}
    func apply(policy: VPNConnectionPolicy) async throws -> Bool { true }
    func disconnect() async {}
    func disconnectAndForget() async -> VPNProfileCleanupResult {
        cleanupCalls += 1
        return .noProfile
    }
}

@MainActor
private final class SessionRaceAppleStore: AppleSubscriptionStoreServing {
    var canMakePayments: Bool { true }
    func purchaseEnvironment() async throws -> AppleAPIEnvironment { .production }
    func loadProducts() async throws -> [AppleSubscriptionProduct] { [] }
    func purchase(productID: String, appAccountToken: UUID) async throws -> ApplePurchaseResult { .userCancelled }
    func sync() async throws {}
    func currentEntitlements() async -> [AppleStoreUpdate] { [] }
    func unfinishedTransactions() async -> [AppleStoreUpdate] { [] }
    func transactionUpdates() -> AsyncStream<AppleStoreUpdate> {
        AsyncStream { $0.finish() }
    }
    func finish(transactionID: UInt64) async {}
}

@MainActor
private final class SessionRaceAppleBindingStore: AppleCredentialBindingStoring {
    private var binding: AppleCredentialBinding?
    func load() -> AppleCredentialBinding? { binding }
    func save(_ binding: AppleCredentialBinding) throws { self.binding = binding }
    func clear() { binding = nil }
}

@MainActor
private final class SessionRaceLatencyProbe: LatencyProbing {
    func measure(_ servers: [VPNServer]) async -> [Int: Int] { [:] }
}
