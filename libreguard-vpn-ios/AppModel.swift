import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var route: AppRoute = .launching
    @Published var presentedError: APIError?
    @Published var deviceLimitContext: DeviceLimitContext?
    @Published var isAuthenticating = false
    @Published var isRefreshingAccount = false
    @Published var isRefreshingServers = false
    @Published var prefilledEmail = ""
    @Published var session: AuthSession?
    @Published var usageQuota: UsageQuota?
    @Published var subscription: SubscriptionStatus?
    @Published var twoFactorStatus: TwoFactorStatus?
    @Published var authenticatorSetup: AuthenticatorSetup?
    @Published var recoveryCodes: [String] = []
    @Published var servers: [VPNServer] = []
    @Published var serverLatencies: [Int: Int] = [:]
    @Published var selectedServerID: Int?
    @Published var vpnStatus: VPNConnectionState = .disconnected
    @Published var retryAfterSeconds = 0

    private let api: BackendServicing
    private let google: GoogleSigning
    private let latencyProbe: LatencyProbing
    private let vpn: VPNManaging
    private let defaults: UserDefaults
    private let pendingRegistrationKey = "pending.registration"
    private var serverRefreshTask: Task<Void, Never>?
    private var retryCountdownTask: Task<Void, Never>?

    init(
        api: BackendServicing? = nil,
        google: GoogleSigning? = nil,
        latencyProbe: LatencyProbing? = nil,
        vpnManager: VPNManaging? = nil,
        defaults: UserDefaults = .standard
    ) {
        let resolvedAPI = api ?? APIClient()
        self.api = resolvedAPI
        self.google = google ?? GoogleSignInService()
        self.latencyProbe = latencyProbe ?? NetworkLatencyProbe()
        self.vpn = vpnManager ?? PersonalVPNManager(api: resolvedAPI)
        self.defaults = defaults
        self.vpnStatus = self.vpn.status
        self.vpn.onStatusChange = { [weak self] status in
            self?.vpnStatus = status
        }
        self.vpn.onDisconnectError = { [weak self] error in
            self?.present(error)
        }
        if let concrete = resolvedAPI as? APIClient {
            concrete.onSessionInvalidated = { [weak self] in self?.forceSignOut() }
        }
    }

    func start() async {
        guard case .launching = route else { return }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            api.clearLocalSession()
            clearPendingRegistration()
            route = .login
            return
        }
        await vpn.refreshStatus()
        if api.storedSession != nil {
            do {
                session = try await api.restoreSession()
                route = .authenticated
                await refreshAccountData(showErrors: false)
                return
            } catch let error as APIError where error.code == "APP_VERSION_BLOCKED" || error.code == "APP_VERSION_REQUIRED" {
                presentedError = error
            } catch {
                // A stale session falls through to registration or login.
            }
        }

        if let pending = loadPendingRegistration() {
            prefilledEmail = pending.email
            route = .emailConfirmation(pending)
        } else {
            route = .login
        }
    }

    func showLogin(prefill email: String? = nil) {
        if let email { prefilledEmail = email }
        route = .login
    }

    func showRegister() { route = .register }
    func showForgotPassword() { route = .forgotPassword }

    func login(email: String, password: String) async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            presentedError = APIError(message: "Enter your email and password.")
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let attempt = LoginAttempt.password(email: normalizedEmail, password: password)
        do {
            let response = try await api.login(email: normalizedEmail, password: password)
            try await handleLogin(response, attempt: attempt, afterTwoFactor: false)
        } catch {
            handle(error, attempt: attempt, afterTwoFactor: false)
        }
    }

    func loginWithGoogle() async {
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let idToken = try await google.signIn()
            let attempt = LoginAttempt.google(idToken: idToken)
            do {
                let response = try await api.loginWithGoogle(idToken: idToken)
                try await handleLogin(response, attempt: attempt, afterTwoFactor: false)
            } catch {
                handle(error, attempt: attempt, afterTwoFactor: false)
            }
        } catch let error as APIError {
            presentedError = error
        } catch {
            presentedError = APIError(message: error.localizedDescription)
        }
    }

    func register(email: String, password: String, confirmation: String) async {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard password.count >= 8 else {
            presentedError = APIError(message: "Password must be at least 8 characters.")
            return
        }
        guard password == confirmation else {
            presentedError = APIError(message: "Passwords do not match.")
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let response = try await api.register(email: normalizedEmail, password: password)
            let pending = PendingRegistration(userId: response.userId, email: response.email)
            savePendingRegistration(pending)
            prefilledEmail = response.email
            route = .emailConfirmation(pending)
        } catch {
            present(error)
        }
    }

    func checkConfirmation(_ pending: PendingRegistration, showErrors: Bool = false) async -> Bool {
        do {
            let status = try await api.confirmationStatus(userId: pending.userId)
            if status.emailConfirmed {
                clearPendingRegistration()
                showLogin(prefill: status.email ?? pending.email)
                return true
            }
        } catch let error as APIError where error.statusCode == 404 {
            // Registration intentionally returns a synthetic ID for existing accounts.
        } catch {
            if showErrors { present(error) }
        }
        return false
    }

    func resendConfirmation(email: String) async -> Bool {
        do {
            try await api.resendConfirmation(email: email)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func verifyTwoFactor(_ challenge: TwoFactorChallenge, code: String, recovery: Bool) async {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentedError = APIError(message: recovery ? "Enter a recovery code." : "Enter your authenticator code.")
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let response = recovery
                ? try await api.verifyRecoveryCode(challenge, code: code)
                : try await api.verifyTwoFactor(challenge, code: code)
            try await handleLogin(response, attempt: challenge.attempt, afterTwoFactor: true)
        } catch {
            handle(error, attempt: challenge.attempt, afterTwoFactor: true)
        }
    }

    func removeDeviceAndRetry(_ device: AccountDevice, context: DeviceLimitContext) async {
        guard context.canRemoveInApp, retryAfterSeconds == 0 else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            switch context.attempt {
            case let .password(email, password):
                try await api.removePasswordDevice(email: email, password: password, deviceId: device.id)
                deviceLimitContext = nil
                let response = try await api.login(email: email, password: password)
                try await handleLogin(response, attempt: context.attempt, afterTwoFactor: false)
            case let .google(idToken):
                try await api.removeGoogleDevice(idToken: idToken, deviceId: device.id)
                deviceLimitContext = nil
                let response = try await api.loginWithGoogle(idToken: idToken)
                try await handleLogin(response, attempt: context.attempt, afterTwoFactor: false)
            }
        } catch {
            present(error)
        }
    }

    func refreshAccountData(showErrors: Bool = true) async {
        guard session != nil || api.storedSession != nil else { return }
        isRefreshingAccount = true
        defer { isRefreshingAccount = false }
        do {
            async let usage = api.fetchUsage()
            async let subscription = api.fetchSubscription()
            async let twoFactor = api.fetchTwoFactorStatus()
            let values = try await (usage, subscription, twoFactor)
            usageQuota = values.0
            self.subscription = values.1
            twoFactorStatus = values.2
        } catch {
            if showErrors { present(error) }
        }
    }

    func refreshServers() {
        serverRefreshTask?.cancel()
        serverRefreshTask = Task { [weak self] in
            guard let self else { return }
            isRefreshingServers = true
            defer { isRefreshingServers = false }
            do {
                let fetched = try await api.fetchServers()
                guard !Task.isCancelled else { return }
                servers = fetched
                serverLatencies = await latencyProbe.measure(fetched)
                if let selectedServerID = self.selectedServerID,
                   !fetched.contains(where: { $0.id == selectedServerID }) {
                    self.selectedServerID = bestAccessibleServer(in: fetched)?.id
                } else if self.selectedServerID == nil {
                    self.selectedServerID = bestAccessibleServer(in: fetched)?.id
                }
            } catch is CancellationError {
            } catch {
                present(error)
            }
        }
    }

    func refreshVPNStatus() async {
        await vpn.refreshStatus()
    }

    func loadTwoFactorSetup() async {
        do {
            authenticatorSetup = try await api.setupTwoFactor()
        } catch { present(error) }
    }

    func enableTwoFactor(code: String) async -> Bool {
        do {
            recoveryCodes = try await api.enableTwoFactor(code: code)
            twoFactorStatus = try await api.fetchTwoFactorStatus()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func disableTwoFactor() async {
        do {
            try await api.disableTwoFactor()
            authenticatorSetup = nil
            recoveryCodes = []
            twoFactorStatus = try await api.fetchTwoFactorStatus()
        } catch { present(error) }
    }

    func generateRecoveryCodes() async -> Bool {
        do {
            recoveryCodes = try await api.generateRecoveryCodes()
            twoFactorStatus = try await api.fetchTwoFactorStatus()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func signOut() async {
        await vpn.disconnectAndForget()
        await api.logout()
        google.signOut()
        clearSessionState()
    }

    func selectServer(_ server: VPNServer) {
        selectedServerID = server.id
    }

    func deselectServer() {
        selectedServerID = nil
    }

    func connectSelectedServer() async {
        guard let server = selectedServer ?? bestAccessibleServer(in: servers) else {
            presentedError = APIError(message: "No VPN server is available right now.")
            return
        }
        guard canUse(server: server) else {
            presentedError = APIError(message: "This server requires a Pro plan.")
            return
        }
        do {
            try await vpn.connect(to: server, protocol: .ikev2)
            selectedServerID = server.id
        } catch {
            present(error)
        }
    }

    func disconnectVPN() async {
        await vpn.disconnect()
    }

    func handleOpenURL(_ url: URL) { _ = google.handle(url: url) }

    private func handleLogin(_ response: LoginResponse, attempt: LoginAttempt, afterTwoFactor: Bool) async throws {
        if response.requiresTwoFactor == true {
            guard let pendingToken = response.pendingLoginToken,
                  let email = response.email else {
                throw APIError(message: "The server did not return a valid two-factor challenge.")
            }
            route = .twoFactor(TwoFactorChallenge(email: email, pendingLoginToken: pendingToken, attempt: attempt))
            return
        }
        session = try api.adoptSession(from: response)
        clearPendingRegistration()
        deviceLimitContext = nil
        route = .authenticated
        await refreshAccountData(showErrors: false)
        if response.warningRecoveryCodes == true {
            presentedError = APIError(message: "A recovery code was used. Generate a new set from Settings.")
        }
    }

    private func handle(_ error: Error, attempt: LoginAttempt, afterTwoFactor: Bool) {
        if let apiError = error as? APIError, let limit = apiError.deviceLimit {
            deviceLimitContext = DeviceLimitContext(response: limit, attempt: attempt, afterTwoFactor: afterTwoFactor)
            return
        }
        if let apiError = error as? APIError, apiError.code == "EMAIL_NOT_VERIFIED" {
            presentedError = apiError
            return
        }
        present(error)
    }

    private func present(_ error: Error) {
        if let apiError = error as? APIError {
            if apiError.requiresLogin || apiError.requiresDeviceRegistration {
                forceSignOut()
            }
            if let retryAfter = apiError.retryAfterSeconds, retryAfter > 0 {
                beginRetryCountdown(retryAfter)
            }
            presentedError = apiError
        } else {
            presentedError = APIError(message: error.localizedDescription)
        }
    }

    private func forceSignOut() {
        Task { await vpn.disconnectAndForget() }
        clearSessionState()
    }

    private func clearSessionState() {
        serverRefreshTask?.cancel()
        retryCountdownTask?.cancel()
        serverRefreshTask = nil
        retryCountdownTask = nil
        api.clearLocalSession()
        session = nil
        usageQuota = nil
        subscription = nil
        twoFactorStatus = nil
        authenticatorSetup = nil
        recoveryCodes = []
        isAuthenticating = false
        isRefreshingAccount = false
        isRefreshingServers = false
        retryAfterSeconds = 0
        servers = []
        serverLatencies = [:]
        selectedServerID = nil
        vpnStatus = .disconnected
        deviceLimitContext = nil
        route = .login
    }

    private var selectedServer: VPNServer? {
        guard let selectedServerID else { return nil }
        return servers.first(where: { $0.id == selectedServerID })
    }

    private func bestAccessibleServer(in servers: [VPNServer]) -> VPNServer? {
        let candidates = servers.filter { canUse(server: $0) }
        let pool = candidates.isEmpty ? servers : candidates
        return pool.min { lhs, rhs in
            let lhsLatency = serverLatencies[lhs.id] ?? Int.max
            let rhsLatency = serverLatencies[rhs.id] ?? Int.max
            if lhsLatency == rhsLatency {
                return lhs.serverName < rhs.serverName
            }
            return lhsLatency < rhsLatency
        }
    }

    private func canUse(server: VPNServer) -> Bool {
        if server.pricingTier.caseInsensitiveCompare("Premium") == .orderedSame {
            return subscription?.isPro == true
        }
        return true
    }

    private func beginRetryCountdown(_ seconds: Int) {
        retryCountdownTask?.cancel()
        retryAfterSeconds = seconds
        retryCountdownTask = Task { [weak self] in
            guard let self else { return }
            while retryAfterSeconds > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { retryAfterSeconds -= 1 }
            }
        }
    }

    private func savePendingRegistration(_ pending: PendingRegistration) {
        if let data = try? JSONEncoder().encode(pending) { defaults.set(data, forKey: pendingRegistrationKey) }
    }

    private func loadPendingRegistration() -> PendingRegistration? {
        guard let data = defaults.data(forKey: pendingRegistrationKey) else { return nil }
        return try? JSONDecoder().decode(PendingRegistration.self, from: data)
    }

    private func clearPendingRegistration() { defaults.removeObject(forKey: pendingRegistrationKey) }
}
