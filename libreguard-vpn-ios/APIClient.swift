import Foundation

@MainActor
protocol BackendServicing: AnyObject {
    var storedSession: AuthSession? { get }
    var deviceId: String { get }
    var appVersion: String { get }
    func restoreSession() async throws -> AuthSession?
    func login(email: String, password: String) async throws -> LoginResponse
    func loginWithGoogle(idToken: String) async throws -> LoginResponse
    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse
    func verifyRecoveryCode(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse
    func register(email: String, password: String) async throws -> RegistrationResponse
    func confirmationStatus(userId: String) async throws -> ConfirmationStatusResponse
    func resendConfirmation(email: String) async throws
    func removePasswordDevice(email: String, password: String, deviceId: Int) async throws
    func removeGoogleDevice(idToken: String, deviceId: Int) async throws
    func adoptSession(from response: LoginResponse) throws -> AuthSession
    func clearLocalSession()
    func logout() async
    func fetchServers() async throws -> [VPNServer]
    func fetchVPNConfig(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> VPNConfigResponse
    func fetchUsage() async throws -> UsageQuota
    func fetchSubscription() async throws -> SubscriptionStatus
    func fetchTwoFactorStatus() async throws -> TwoFactorStatus
    func setupTwoFactor() async throws -> AuthenticatorSetup
    func enableTwoFactor(code: String) async throws -> [String]
    func disableTwoFactor() async throws
    func generateRecoveryCodes() async throws -> [String]
}

@MainActor
final class APIClient: BackendServicing {
    private let baseURL: URL
    private let urlSession: URLSession
    private let sessionStore: SessionStoring
    private let deviceStore: DeviceIdentifying
    private let deviceKeyStore: VPNDeviceKeyProviding
    private var refreshTask: Task<AuthSession, Error>?
    var onSessionInvalidated: (() -> Void)?

    init(
        baseURL: URL = URL(string: "https://management.libreguard.net")!,
        urlSession: URLSession = .shared,
        sessionStore: SessionStoring? = nil,
        deviceStore: DeviceIdentifying? = nil,
        deviceKeyStore: VPNDeviceKeyProviding? = nil
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.sessionStore = sessionStore ?? SessionStore()
        self.deviceStore = deviceStore ?? DeviceIdentityStore()
        self.deviceKeyStore = deviceKeyStore ?? VPNDeviceKeyStore()
    }

    var storedSession: AuthSession? { sessionStore.session }
    var deviceId: String { deviceStore.deviceId }
    var appVersion: String { deviceStore.appVersion }

    func restoreSession() async throws -> AuthSession? {
        guard sessionStore.session != nil else { return nil }
        do {
            return try await refreshSession()
        } catch {
            sessionStore.clear()
            throw error
        }
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        let keyPayload = try deviceKeyStore.publicKeyPayload()
        let response: LoginResponse = try await send(
            .post,
            path: "/api/login",
            body: LoginRequest(
                email: email,
                password: password,
                deviceId: deviceId,
                appVersion: appVersion,
                devicePublicKey: keyPayload.devicePublicKey,
                devicePublicKeyId: keyPayload.devicePublicKeyId,
                devicePublicKeyAlgorithm: keyPayload.devicePublicKeyAlgorithm
            ),
            authorized: false
        )
        return response
    }

    func loginWithGoogle(idToken: String) async throws -> LoginResponse {
        let keyPayload = try deviceKeyStore.publicKeyPayload()
        let response: LoginResponse = try await send(
            .post,
            path: "/api/login/google",
            body: GoogleLoginRequest(
                idToken: idToken,
                deviceId: deviceId,
                appVersion: appVersion,
                devicePublicKey: keyPayload.devicePublicKey,
                devicePublicKeyId: keyPayload.devicePublicKeyId,
                devicePublicKeyAlgorithm: keyPayload.devicePublicKeyAlgorithm
            ),
            authorized: false
        )
        return response
    }

    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse {
        let response: LoginResponse = try await send(
            .post,
            path: "/api/login/verify-2fa",
            body: TwoFactorLoginRequest(
                email: challenge.email,
                twoFactorCode: code,
                pendingLoginToken: challenge.pendingLoginToken,
                deviceId: deviceId,
                appVersion: appVersion
            ),
            authorized: false
        )
        return response
    }

    func verifyRecoveryCode(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse {
        let response: LoginResponse = try await send(
            .post,
            path: "/api/login/verify-recovery-code",
            body: RecoveryCodeLoginRequest(
                email: challenge.email,
                recoveryCode: code,
                pendingLoginToken: challenge.pendingLoginToken,
                deviceId: deviceId,
                appVersion: appVersion
            ),
            authorized: false
        )
        return response
    }

    func register(email: String, password: String) async throws -> RegistrationResponse {
        let response: RegistrationResponse = try await send(.post, path: "/api/register", body: RegistrationRequest(email: email, password: password), authorized: false)
        return response
    }

    func confirmationStatus(userId: String) async throws -> ConfirmationStatusResponse {
        let response: ConfirmationStatusResponse = try await send(.get, path: "/api/register/check-confirmation/\(userId)", authorized: false)
        return response
    }

    func resendConfirmation(email: String) async throws {
        let _: MessageResponse = try await send(
            .post,
            path: "/api/register/resend-confirmation",
            body: ResendConfirmationRequest(email: email),
            authorized: false
        )
    }

    func removePasswordDevice(email: String, password: String, deviceId: Int) async throws {
        let _: DeviceRemovalResponse = try await send(
            .post,
            path: "/api/devices/pre-auth/remove",
            body: PasswordDeviceRemovalRequest(email: email, password: password, deviceIdToRemove: deviceId),
            authorized: false
        )
    }

    func removeGoogleDevice(idToken: String, deviceId: Int) async throws {
        let _: DeviceRemovalResponse = try await send(
            .post,
            path: "/api/devices/pre-auth/oauth/remove",
            body: OAuthDeviceRemovalRequest(idToken: idToken, provider: "Google", deviceIdToRemove: deviceId),
            authorized: false
        )
    }

    func adoptSession(from response: LoginResponse) throws -> AuthSession {
        guard let token = response.token,
              let refreshToken = response.refreshToken,
              let email = response.email,
              let userId = response.userId else {
            throw APIError(message: "The server returned an incomplete login session.")
        }
        let session = AuthSession(
            accessToken: token,
            refreshToken: refreshToken,
            email: email,
            userId: userId,
            deviceId: response.deviceId ?? deviceId
        )
        try sessionStore.save(session)
        return session
    }

    func logout() async {
        defer { sessionStore.clear() }
        guard let session = sessionStore.session else { return }
        let _: MessageResponse? = try? await send(
            .post,
            path: "/api/logout",
            body: LogoutRequest(refreshToken: session.refreshToken),
            authorized: true,
            retryAfterRefresh: false
        )
    }

    func clearLocalSession() {
        sessionStore.clear()
    }

    func fetchServers() async throws -> [VPNServer] {
        let response: VPNServerResponse = try await send(.get, path: "/api/vpn/servers")
        return response.servers
    }

    func fetchVPNConfig(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> VPNConfigResponse {
        let response: VPNConfigResponse = try await send(
            .post,
            path: "/api/vpn/config",
            body: VPNConfigRequest(serverId: serverId, protocolName: protocolName)
        )
        return response
    }

    func fetchUsage() async throws -> UsageQuota {
        let response: UsageQuota = try await send(.get, path: "/api/usage/quota")
        return response
    }

    func fetchSubscription() async throws -> SubscriptionStatus {
        let response: SubscriptionStatus = try await send(.get, path: "/api/subscription/status")
        return response
    }

    func fetchTwoFactorStatus() async throws -> TwoFactorStatus {
        let response: TwoFactorStatus = try await send(.get, path: "/api/2fa/status")
        return response
    }

    func setupTwoFactor() async throws -> AuthenticatorSetup {
        let response: AuthenticatorSetup = try await send(.post, path: "/api/2fa/setup", body: EmptyBody())
        return response
    }

    func enableTwoFactor(code: String) async throws -> [String] {
        let response: RecoveryCodesResponse = try await send(
            .post,
            path: "/api/2fa/enable",
            body: EnableTwoFactorRequest(code: code)
        )
        return response.recoveryCodes ?? []
    }

    func disableTwoFactor() async throws {
        let _: MessageResponse = try await send(.post, path: "/api/2fa/disable", body: EmptyBody())
    }

    func generateRecoveryCodes() async throws -> [String] {
        let response: RecoveryCodesResponse = try await send(
            .post,
            path: "/api/2fa/recovery-codes/generate",
            body: EmptyBody()
        )
        return response.recoveryCodes ?? []
    }

    private func refreshSession() async throws -> AuthSession {
        if let refreshTask { return try await refreshTask.value }
        guard let existing = sessionStore.session else {
            throw APIError(statusCode: 401, message: "Your session has expired.", code: "SESSION_EXPIRED", requiresLogin: true)
        }
        let keyPayload = try deviceKeyStore.publicKeyPayload()

        let task = Task { @MainActor [weak self] () throws -> AuthSession in
            guard let self else { throw CancellationError() }
            let response: LoginResponse = try await self.send(
                .post,
                path: "/api/login/refresh",
                body: RefreshTokenRequest(
                    refreshToken: existing.refreshToken,
                    deviceId: self.deviceId,
                    appVersion: self.appVersion,
                    devicePublicKey: keyPayload.devicePublicKey,
                    devicePublicKeyId: keyPayload.devicePublicKeyId,
                    devicePublicKeyAlgorithm: keyPayload.devicePublicKeyAlgorithm
                ),
                authorized: false,
                retryAfterRefresh: false
            )
            return try self.adoptSession(from: response)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value
        } catch {
            sessionStore.clear()
            onSessionInvalidated?()
            throw error
        }
    }

    private func send<Response: Decodable>(
        _ method: HTTPMethod,
        path: String,
        authorized: Bool = true,
        retryAfterRefresh: Bool = true
    ) async throws -> Response {
        try await send(method, path: path, body: Optional<EmptyBody>.none, authorized: authorized, retryAfterRefresh: retryAfterRefresh)
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ method: HTTPMethod,
        path: String,
        body: Body?,
        authorized: Bool = true,
        retryAfterRefresh: Bool = true
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method.rawValue
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized, let token = sessionStore.session?.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError(message: "The server returned an invalid response.")
            }
            if (200..<300).contains(http.statusCode) {
                return try Self.decoder.decode(Response.self, from: data)
            }

            if authorized, http.statusCode == 401, retryAfterRefresh {
                _ = try await refreshSession()
                return try await send(method, path: path, body: body, authorized: authorized, retryAfterRefresh: false)
            }

            throw decodeError(data: data, response: http)
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError(message: "Unable to reach LibreGuard. Check your connection and try again.")
        }
    }

    private func decodeError(data: Data, response: HTTPURLResponse) -> APIError {
        let envelope = try? Self.decoder.decode(APIErrorEnvelope.self, from: data)
        let limit = response.statusCode == 409 ? try? Self.decoder.decode(DeviceLimitResponse.self, from: data) : nil
        let headerRetry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        return APIError(
            statusCode: response.statusCode,
            message: envelope?.message ?? envelope?.error ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            code: envelope?.errorCode,
            fieldErrors: envelope?.errors ?? [],
            retryAfterSeconds: envelope?.retryAfterSeconds ?? headerRetry,
            requiresLogin: envelope?.requiresLogin ?? false,
            requiresDeviceRegistration: envelope?.requiresDeviceRegistration ?? false,
            deviceLimit: limit
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter.withFractionalSeconds.date(from: value)
                ?? ISO8601DateFormatter.standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }()
}

private struct EmptyBody: Encodable {}

private extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
