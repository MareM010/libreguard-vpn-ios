import Foundation
import OSLog

@MainActor
protocol BackendServicing: AnyObject {
    var storedSession: AuthSession? { get }
    var deviceId: String { get }
    var appVersion: String { get }
    func restoreSession() async throws -> AuthSession?
    func login(email: String, password: String) async throws -> LoginResponse
    func loginWithGoogle(idToken: String, newsletterConsent: Bool?) async throws -> LoginResponse
    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse
    func verifyRecoveryCode(_ challenge: TwoFactorChallenge, code: String) async throws -> LoginResponse
    func register(email: String, password: String, newsletterConsent: Bool) async throws -> RegistrationResponse
    func requestPasswordReset(email: String) async throws -> MessageResponse
    func resetPassword(email: String, token: String, newPassword: String) async throws -> MessageResponse
    func confirmationStatus(userId: String) async throws -> ConfirmationStatusResponse
    func resendConfirmation(email: String) async throws
    func removePasswordDevice(email: String, password: String, deviceId: Int) async throws
    func removeGoogleDevice(idToken: String, deviceId: Int) async throws
    func adoptSession(from response: LoginResponse) throws -> AuthSession
    func clearLocalSession()
    func logout() async
    func fetchServers() async throws -> [VPNServer]
    func fetchVPNConfig(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> VPNConfigResponse
    func requestCertificate(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateJobCreatedResponse
    func fetchCertificateGenerationStatus(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateGenerationStatusResponse
    func fetchCertificateJob(jobId: Int) async throws -> CertificateJobStatusResponse
    func fetchUsage() async throws -> UsageQuota
    func fetchConnectionEligibility() async throws -> CanConnectResponse
    func fetchSubscription() async throws -> SubscriptionStatus
    func fetchDNSPreference() async throws -> DNSPreference
    func updateDNSPreference(adBlockingEnabled: Bool) async throws -> DNSPreference
    func fetchAppleAccountToken() async throws -> UUID
    func verifyAppleTransaction(_ signedTransactionInfo: String, allowTransfer: Bool) async throws -> AppleTransactionVerificationResponse
    func fetchTwoFactorStatus() async throws -> TwoFactorStatus
    func setupTwoFactor() async throws -> AuthenticatorSetup
    func enableTwoFactor(code: String) async throws -> [String]
    func disableTwoFactor() async throws
    func generateRecoveryCodes() async throws -> [String]
}

@MainActor
final class APIClient: BackendServicing {
    private static let transportDiagnosticsKey = "LibreGuardLastAPITransportError"
    private static let transportDiagnosticsTimestampKey = "LibreGuardLastAPITransportErrorTimestamp"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.libreguard.libreguard-vpn-ios",
        category: "API"
    )
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
        return try await refreshSession()
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

    func loginWithGoogle(idToken: String, newsletterConsent: Bool? = nil) async throws -> LoginResponse {
        let keyPayload = try deviceKeyStore.publicKeyPayload()
        let response: LoginResponse = try await send(
            .post,
            path: "/api/login/google",
            body: GoogleLoginRequest(
                idToken: idToken,
                newsletterConsent: newsletterConsent,
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

    func register(email: String, password: String, newsletterConsent: Bool = false) async throws -> RegistrationResponse {
        let response: RegistrationResponse = try await send(
            .post,
            path: "/api/register",
            body: RegistrationRequest(email: email, password: password, newsletterConsent: newsletterConsent),
            authorized: false
        )
        return response
    }

    func requestPasswordReset(email: String) async throws -> MessageResponse {
        try await send(
            .post,
            path: "/api/account/forgot-password",
            body: ForgotPasswordRequest(email: email),
            authorized: false
        )
    }

    func resetPassword(email: String, token: String, newPassword: String) async throws -> MessageResponse {
        try await send(
            .post,
            path: "/api/account/reset-password",
            body: ResetPasswordRequest(email: email, token: token, newPassword: newPassword),
            authorized: false
        )
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

    func requestCertificate(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateJobCreatedResponse {
        try await send(
            .post,
            path: "/api/certificates/request",
            body: CertificateRequestPayload(serverId: serverId, vpnType: protocolName.certificateRequestValue)
        )
    }

    func fetchCertificateGenerationStatus(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> CertificateGenerationStatusResponse {
        try await send(
            .get,
            path: "/api/client-certificates/check-generation-status/\(serverId)?vpnType=\(protocolName.certificateRequestValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? protocolName.certificateRequestValue)"
        )
    }

    func fetchCertificateJob(jobId: Int) async throws -> CertificateJobStatusResponse {
        try await send(.get, path: "/api/certificates/jobs/\(jobId)")
    }

    func fetchUsage() async throws -> UsageQuota {
        let response: UsageQuota = try await send(.get, path: "/api/usage/quota")
        return response
    }

    func fetchConnectionEligibility() async throws -> CanConnectResponse {
        try await send(.get, path: "/api/usage/can-connect")
    }

    func fetchSubscription() async throws -> SubscriptionStatus {
        let response: SubscriptionStatus = try await send(.get, path: "/api/subscription/status")
        return response
    }

    func fetchDNSPreference() async throws -> DNSPreference {
        try await send(.get, path: "/api/dns/settings")
    }

    func updateDNSPreference(adBlockingEnabled: Bool) async throws -> DNSPreference {
        try await send(
            .put,
            path: "/api/dns/settings",
            body: UpdateDNSPreferenceRequest(adBlockingEnabled: adBlockingEnabled)
        )
    }

    func fetchAppleAccountToken() async throws -> UUID {
        let response: AppleAccountTokenResponse = try await send(.get, path: "/api/subscription/apple/account-token")
        return response.appAccountToken
    }

    func verifyAppleTransaction(_ signedTransactionInfo: String, allowTransfer: Bool) async throws -> AppleTransactionVerificationResponse {
        try await send(
            .post,
            path: "/api/subscription/apple/verify",
            body: AppleTransactionVerificationRequest(
                signedTransactionInfo: signedTransactionInfo,
                allowTransfer: allowTransfer
            )
        )
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
            if Self.shouldInvalidateSession(for: error) {
                sessionStore.clear()
                onSessionInvalidated?()
            }
            throw error
        }
    }

    private static func shouldInvalidateSession(for error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        return apiError.statusCode == 401
            || apiError.requiresLogin
            || apiError.requiresDeviceRegistration
            || apiError.code == "SESSION_EXPIRED"
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
        var requestURL = baseURL.appending(path: path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path)
        if let query = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first,
           var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) {
            components.query = String(query)
            requestURL = components.url ?? requestURL
        }
        var request = URLRequest(url: requestURL)
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
                Self.clearTransportDiagnostic()
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
            let diagnostic = Self.transportDiagnostic(for: error)
            Self.saveTransportDiagnostic(diagnostic)
            Self.logger.error("API transport request failed: \(diagnostic, privacy: .public)")
            throw APIError(message: "Unable to reach LibreGuard. Check your connection and try again.")
        }
    }

    private static func transportDiagnostic(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    private static func saveTransportDiagnostic(_ diagnostic: String) {
        guard let defaults = UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier) else { return }
        defaults.set(diagnostic, forKey: transportDiagnosticsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: transportDiagnosticsTimestampKey)
    }

    private static func clearTransportDiagnostic() {
        guard let defaults = UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier) else { return }
        defaults.removeObject(forKey: transportDiagnosticsKey)
        defaults.removeObject(forKey: transportDiagnosticsTimestampKey)
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

@MainActor
protocol VPNConfigurationResolving: AnyObject {
    var onPreparationStateChange: ((String?) -> Void)? { get set }
    func resolve(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> VPNConfigResponse
}

@MainActor
final class VPNConfigurationResolver: VPNConfigurationResolving {
    private let api: BackendServicing
    private let preparationTimeout: TimeInterval
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "libreguard-vpn-ios", category: "CertificateResolution")

    var onPreparationStateChange: ((String?) -> Void)?

    init(api: BackendServicing, preparationTimeout: TimeInterval = 90) {
        self.api = api
        self.preparationTimeout = preparationTimeout
    }

    func resolve(serverId: Int, protocol protocolName: VPNConfigurationProtocol) async throws -> VPNConfigResponse {
        do {
            let response = try await api.fetchVPNConfig(serverId: serverId, protocol: protocolName)
            onPreparationStateChange?(nil)
            return response
        } catch let error as APIError where shouldInspectCertificateStatus(after: error) {
            do {
                let response = try await recoverConfiguration(
                    after: error,
                    serverId: serverId,
                    protocol: protocolName
                )
                onPreparationStateChange?(nil)
                return response
            } catch {
                if (error as? APIError)?.code != "CERTIFICATE_PREPARATION_TIMEOUT" {
                    onPreparationStateChange?(nil)
                }
                throw error
            }
        } catch {
            onPreparationStateChange?(nil)
            throw error
        }
    }

    private func recoverConfiguration(
        after configurationError: APIError,
        serverId: Int,
        protocol protocolName: VPNConfigurationProtocol
    ) async throws -> VPNConfigResponse {
        try Task.checkCancellation()
        let status = try await api.fetchCertificateGenerationStatus(serverId: serverId, protocol: protocolName)

        if status.certificateExists == true || status.existingCertificate != nil {
            return try await api.fetchVPNConfig(serverId: serverId, protocol: protocolName)
        }

        if let pendingJob = status.pendingJob {
            beginPreparation(for: protocolName)
            try await waitForCompletion(jobId: pendingJob.id, protocol: protocolName)
            return try await api.fetchVPNConfig(serverId: serverId, protocol: protocolName)
        }

        guard status.canGenerate == true else {
            throw configurationError
        }

        beginPreparation(for: protocolName)
        return try await requestCertificateAndResolve(serverId: serverId, protocol: protocolName)
    }

    private func requestCertificateAndResolve(
        serverId: Int,
        protocol protocolName: VPNConfigurationProtocol
    ) async throws -> VPNConfigResponse {
        do {
            let created = try await api.requestCertificate(serverId: serverId, protocol: protocolName)
            try await waitForCompletion(jobId: created.jobId, protocol: protocolName)
        } catch let error as APIError where isCertificateConflict(error) {
            let status = try await api.fetchCertificateGenerationStatus(serverId: serverId, protocol: protocolName)
            if status.certificateExists == true || status.existingCertificate != nil {
                return try await api.fetchVPNConfig(serverId: serverId, protocol: protocolName)
            }

            guard let pendingJob = status.pendingJob else {
                throw error
            }
            try await waitForCompletion(jobId: pendingJob.id, protocol: protocolName)
        } catch {
            if (error as? APIError)?.code != "CERTIFICATE_PREPARATION_TIMEOUT" {
                onPreparationStateChange?(nil)
            }
            throw error
        }

        return try await api.fetchVPNConfig(serverId: serverId, protocol: protocolName)
    }

    private func shouldInspectCertificateStatus(after error: APIError) -> Bool {
        error.statusCode == 404 || error.code == "CERTIFICATE_NOT_FOUND"
    }

    private func isCertificateConflict(_ error: APIError) -> Bool {
        error.statusCode == 409 || error.code == "CERTIFICATE_PENDING" || error.code == "CERTIFICATE_EXISTS"
    }

    private func beginPreparation(for protocolName: VPNConfigurationProtocol) {
        onPreparationStateChange?("Preparing your \(protocolName.displayName) certificate…")
    }

    private func waitForCompletion(jobId: Int, protocol protocolName: VPNConfigurationProtocol) async throws {
        let deadline = Date().addingTimeInterval(preparationTimeout)
        var delayNanoseconds: UInt64 = 1_000_000_000

        while Date() < deadline {
            try Task.checkCancellation()
            let job = try await api.fetchCertificateJob(jobId: jobId)
            switch job.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "success", "succeeded", "completed":
                return
            case "failed", "cancelled", "canceled":
                onPreparationStateChange?(nil)
                throw APIError(
                    statusCode: 422,
                    message: job.errorMessage ?? "Your \(protocolName.displayName) certificate could not be created.",
                    code: "CERTIFICATE_GENERATION_FAILED"
                )
            default:
                break
            }

            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard remaining > 0 else { break }
            let delay = min(TimeInterval(delayNanoseconds) / 1_000_000_000, remaining)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            delayNanoseconds = min(delayNanoseconds * 2, 5_000_000_000)
        }

        let message = "Your \(protocolName.displayName) certificate is still being prepared. Try Connect again in a moment."
        onPreparationStateChange?(message)
        logger.info("Certificate preparation timed out while job \(jobId, privacy: .public) was still running")
        throw APIError(statusCode: 408, message: message, code: "CERTIFICATE_PREPARATION_TIMEOUT")
    }
}

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
