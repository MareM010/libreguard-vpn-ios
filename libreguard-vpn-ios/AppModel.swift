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
    @Published var selectedVPNProtocol: VPNConfigurationProtocol
    @Published var vpnStatus: VPNConnectionState = .disconnected
    @Published private(set) var hasQueuedVPNReconnect = false
    @Published private(set) var isAutoConnectEnabled: Bool
    @Published private(set) var isUpdatingAutoConnect = false
    @Published private(set) var isKillSwitchEnabled: Bool
    @Published private(set) var killSwitchActivationState: KillSwitchActivationState
    @Published private(set) var isUpdatingKillSwitch = false
    @Published var isKillSwitchDisconnectConfirmationPresented = false
    @Published var retryAfterSeconds = 0

    private let api: BackendServicing
    private let google: GoogleSigning
    private let latencyProbe: LatencyProbing
    private let vpn: VPNManaging
    private let defaults: UserDefaults
    private let protocolSelectionStore: VPNProtocolSelectionStoring
    private let statisticsRecorder: LocalStatisticsRecording?
    private let trafficSampler: TunnelTrafficSampling
    private let pendingRegistrationKey = "pending.registration"
    private let cachedPlanNameKey = "cached.plan.name"
    private let cachedPlanIsProKey = "cached.plan.isPro"
    private let autoConnectEnabledKey = "vpn.autoConnect.enabled"
    private let killSwitchEnabledKey = "vpn.killSwitch.enabled"
    private let killSwitchActivationKey = "vpn.killSwitch.activation"
    private var cachedPlanName: String?
    private var cachedPlanIsPro = false
    private var serverRefreshTask: Task<Void, Never>?
    private var retryCountdownTask: Task<Void, Never>?
    private var vpnTransitionTask: Task<Void, Never>?
    private var vpnTransitionGeneration: UInt = 0
    private var activeVPNTransition: VPNTransitionRequest?
    private var pendingStatisticsRequest: VPNConnectRequest?
    private var activeStatisticsSession: ActiveStatisticsSession?
    private var queuedVPNConnectRequest: VPNConnectRequest? {
        didSet {
            hasQueuedVPNReconnect = queuedVPNConnectRequest != nil
        }
    }

    init(
        api: BackendServicing? = nil,
        google: GoogleSigning? = nil,
        latencyProbe: LatencyProbing? = nil,
        vpnManager: VPNManaging? = nil,
        protocolSelectionStore: VPNProtocolSelectionStoring? = nil,
        statisticsRecorder: LocalStatisticsRecording? = nil,
        trafficSampler: TunnelTrafficSampling = SystemTunnelTrafficSampler(),
        defaults: UserDefaults = .standard
    ) {
        let resolvedAPI = api ?? APIClient()
        self.api = resolvedAPI
        self.google = google ?? GoogleSignInService()
        self.latencyProbe = latencyProbe ?? NetworkLatencyProbe()
        self.protocolSelectionStore = protocolSelectionStore ?? UserDefaultsVPNProtocolSelectionStore(defaults: defaults)
        self.statisticsRecorder = statisticsRecorder
        self.trafficSampler = trafficSampler
        self.selectedVPNProtocol = self.protocolSelectionStore.selectedProtocol
        self.isAutoConnectEnabled = defaults.bool(forKey: "vpn.autoConnect.enabled")
        self.isKillSwitchEnabled = defaults.bool(forKey: "vpn.killSwitch.enabled")
        self.killSwitchActivationState = KillSwitchActivationState(
            rawValue: defaults.string(forKey: "vpn.killSwitch.activation") ?? ""
        ) ?? (defaults.bool(forKey: "vpn.killSwitch.enabled") ? .armed : .off)
        self.vpn = vpnManager ?? VPNManagerCoordinator(api: resolvedAPI)
        self.defaults = defaults
        self.cachedPlanName = defaults.string(forKey: cachedPlanNameKey)
        self.cachedPlanIsPro = defaults.object(forKey: cachedPlanIsProKey) != nil
            ? defaults.bool(forKey: cachedPlanIsProKey)
            : false
        self.vpnStatus = self.vpn.status
        self.vpn.onStatusChange = { [weak self] status in
            self?.handleVPNStatusChange(status)
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
            clearCachedPlan()
            clearPendingRegistration()
            persistAutoConnectEnabled(false)
            persistKillSwitch(enabled: false, activation: .off)
            await vpn.disconnectAndForget()
            route = .login
            return
        }
        await vpn.refreshStatus()
        if api.storedSession != nil {
            do {
                session = try await api.restoreSession()
                route = .authenticated
                await refreshAccountData(showErrors: false)
                await reconcileKillSwitchOnLaunch()
                await reconcileAutoConnectOnLaunch()
                return
            } catch let error as APIError where error.code == "APP_VERSION_BLOCKED" || error.code == "APP_VERSION_REQUIRED" {
                presentedError = error
            } catch {
                clearCachedPlan()
                // A stale session falls through to registration or login.
            }
        }

        persistAutoConnectEnabled(false)
        persistKillSwitch(enabled: false, activation: .off)
        await vpn.disconnectAndForget()

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

    func requestPasswordReset(email: String) async -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else {
            presentedError = APIError(message: "Enter your email address.")
            return false
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            _ = try await api.requestPasswordReset(email: normalizedEmail)
            prefilledEmail = normalizedEmail
            return true
        } catch {
            present(error)
            return false
        }
    }

    func resetPassword(_ link: PasswordResetLink, newPassword: String, confirmation: String) async -> Bool {
        guard newPassword.count >= 8 else {
            presentedError = APIError(message: "Password must be at least 8 characters.")
            return false
        }
        guard newPassword == confirmation else {
            presentedError = APIError(message: "Passwords do not match.")
            return false
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            _ = try await api.resetPassword(email: link.email, token: link.token, newPassword: newPassword)
            showLogin(prefill: link.email)
            presentedError = APIError(message: "Your password has been reset. Sign in with your new password.")
            return true
        } catch {
            present(error)
            return false
        }
    }

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
            cachePlan(name: values.1.displayName, isPro: values.1.isPro)
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
                    self.selectedServerID = nil
                }
            } catch is CancellationError {
            } catch {
                present(error)
            }
        }
    }

    func setAutoConnectEnabled(_ enabled: Bool) async {
        guard enabled != isAutoConnectEnabled, !isUpdatingAutoConnect else { return }
        isUpdatingAutoConnect = true
        defer { isUpdatingAutoConnect = false }

        do {
            if enabled {
                if vpnStatus.isConnected || vpnStatus.isBusy {
                    let configured = try await vpn.apply(policy: currentConnectionPolicy(autoConnectOverride: true))
                    if isKillSwitchEnabled, configured {
                        persistKillSwitch(enabled: true, activation: .active)
                    }
                } else {
                    refreshServers()
                    await serverRefreshTask?.value
                    guard let server = QuickConnectRanker.bestServer(
                        in: servers,
                        latencies: serverLatencies,
                        isProUser: isProUser
                    ) else {
                        throw APIError(message: "No VPN server is available right now.")
                    }
                    selectedServerID = server.id
                    requestConnection(
                        VPNConnectRequest(
                            server: server,
                            protocolName: effectiveConnectionProtocol(),
                            onDemandEnabled: true,
                            killSwitchEnabled: isKillSwitchEnabled
                        )
                    )
                    await vpnTransitionTask?.value
                    guard vpnStatus != .disconnected, vpnStatus != .invalid else {
                        _ = try? await vpn.apply(policy: currentConnectionPolicy(autoConnectOverride: false))
                        return
                    }
                }
            } else {
                let configured = try await vpn.apply(policy: currentConnectionPolicy(autoConnectOverride: false))
                if isKillSwitchEnabled, configured {
                    persistKillSwitch(enabled: true, activation: .active)
                }
            }

            persistAutoConnectEnabled(enabled)
        } catch {
            if enabled {
                _ = try? await vpn.apply(policy: currentConnectionPolicy(autoConnectOverride: false))
            }
            persistAutoConnectEnabled(false)
            present(error)
        }
    }

    func setKillSwitchEnabled(_ enabled: Bool) async {
        guard enabled != isKillSwitchEnabled, !isUpdatingKillSwitch else { return }
        if enabled, !isProUser {
            presentedError = APIError(message: "Kill Switch requires a Pro plan.")
            return
        }

        isUpdatingKillSwitch = true
        defer { isUpdatingKillSwitch = false }

        if enabled {
            persistKillSwitch(enabled: true, activation: .armed)
            guard vpnStatus.isConnected else { return }
            do {
                let configured = try await vpn.apply(policy: currentConnectionPolicy())
                persistKillSwitch(enabled: true, activation: configured ? .active : .armed)
            } catch {
                present(error)
            }
            return
        }

        do {
            _ = try await vpn.apply(
                policy: VPNConnectionPolicy.appPolicy(
                    autoConnectEnabled: isAutoConnectEnabled,
                    killSwitchEnabled: false
                )
            )
            persistKillSwitch(enabled: false, activation: .off)
        } catch {
            present(error)
        }
    }

    func cancelKillSwitchDisconnect() {
        isKillSwitchDisconnectConfirmationPresented = false
    }

    func confirmKillSwitchDisableAndDisconnect() async {
        isKillSwitchDisconnectConfirmationPresented = false
        await setKillSwitchEnabled(false)
        guard !isKillSwitchEnabled else { return }
        requestVPNDisconnect(bypassingKillSwitchConfirmation: true)
        await vpnTransitionTask?.value
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
        cancelActiveVPNTransition()
        persistAutoConnectEnabled(false)
        persistKillSwitch(enabled: false, activation: .off)
        await vpn.disconnectAndForget()
        persistActiveStatisticsSessionIfNeeded(endedAt: Date())
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

    func selectVPNProtocol(_ protocolName: VPNConfigurationProtocol) {
        guard canSelect(protocolName: protocolName) else {
            if protocolName == .openVPN {
                presentedError = APIError(message: "OpenVPN requires a Pro plan.")
            }
            return
        }
        selectedVPNProtocol = protocolName
        protocolSelectionStore.selectedProtocol = protocolName
    }

    func requestConnectionToSelectedServer() {
        guard let server = selectedServer else {
            requestQuickConnect()
            return
        }
        guard canUse(server: server) else {
            presentedError = APIError(message: "This server requires a Pro plan.")
            return
        }
        requestConnection(
            VPNConnectRequest(
                server: server,
                protocolName: effectiveConnectionProtocol(),
                onDemandEnabled: currentConnectionPolicy().onDemandEnabled,
                killSwitchEnabled: isKillSwitchEnabled
            )
        )
    }

    func requestQuickConnect() {
        guard let server = QuickConnectRanker.bestServer(
            in: servers,
            latencies: serverLatencies,
            isProUser: isProUser
        ) else {
            presentedError = APIError(message: "No VPN server is available right now.")
            return
        }
        selectedServerID = server.id
        requestConnection(
            VPNConnectRequest(
                server: server,
                protocolName: effectiveConnectionProtocol(),
                onDemandEnabled: currentConnectionPolicy().onDemandEnabled,
                killSwitchEnabled: isKillSwitchEnabled
            )
        )
        refreshServers()
    }

    func requestVPNDisconnect(bypassingKillSwitchConfirmation: Bool = false) {
        if isKillSwitchEnabled, !bypassingKillSwitchConfirmation,
           vpnStatus != .disconnected, vpnStatus != .invalid {
            isKillSwitchDisconnectConfirmationPresented = true
            return
        }
        queuedVPNConnectRequest = nil

        switch vpnStatus {
        case .invalid, .disconnected:
            cancelActiveVPNTransition()
        case .disconnecting:
            break
        case .connecting, .connected, .reasserting:
            beginDisconnect(preservingQueuedConnection: false)
        }
    }

    func performVPNPrimaryAction() {
        switch vpnStatus {
        case .invalid, .disconnected:
            requestConnectionToSelectedServer()
        case .connecting, .connected, .reasserting:
            requestVPNDisconnect()
        case .disconnecting:
            if hasQueuedVPNReconnect {
                requestVPNDisconnect()
            } else {
                requestConnectionToSelectedServer()
            }
        }
    }

    func connectSelectedServer() async {
        requestConnectionToSelectedServer()
        let task = vpnTransitionTask
        await task?.value
    }

    func disconnectVPN() async {
        requestVPNDisconnect()
        let task = vpnTransitionTask
        await task?.value
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "libreguardvpn" else {
            _ = google.handle(url: url)
            return
        }
        guard url.host?.lowercased() == "account",
              url.path == "/reset-password",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let email = components.queryItems?.first(where: { $0.name == "email" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let token = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !email.isEmpty,
              !token.isEmpty else {
            presentedError = APIError(message: "This password reset link is invalid. Request a new one and try again.")
            route = .forgotPassword
            return
        }
        prefilledEmail = email
        route = .resetPassword(PasswordResetLink(email: email, token: token))
    }

    var isProUser: Bool {
        if let subscription { return subscription.isPro }
        if let usageQuota { return usageQuota.planTierHint.isPro }
        return cachedPlanIsPro
    }

    var currentPlanDisplayName: String {
        if let subscription { return subscription.displayName }
        if let usageQuota { return usageQuota.planTierHint.rawValue }
        if let cachedPlan = AccountPlanTier(planName: cachedPlanName) {
            return cachedPlan.rawValue
        }
        return AccountPlanTier.free.rawValue
    }

    var shouldShowUpgradePrompt: Bool {
        !isProUser
    }

    var maxDeviceCount: Int {
        subscription?.maxDevices ?? (isProUser ? 3 : 1)
    }

    var isOpenVPNAvailable: Bool {
        canSelect(protocolName: .openVPN)
    }

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
        if let planTier = response.planTier {
            cachePlan(name: planTier.rawValue, isPro: planTier.isPro)
        }
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
        cancelActiveVPNTransition()
        persistAutoConnectEnabled(false)
        persistKillSwitch(enabled: false, activation: .off)
        persistActiveStatisticsSessionIfNeeded(endedAt: Date())
        Task { await vpn.disconnectAndForget() }
        clearSessionState()
    }

    private func clearSessionState() {
        serverRefreshTask?.cancel()
        retryCountdownTask?.cancel()
        cancelActiveVPNTransition()
        serverRefreshTask = nil
        retryCountdownTask = nil
        clearCachedPlan()
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
        pendingStatisticsRequest = nil
        activeStatisticsSession = nil
        route = .login
    }

    private func reconcileAutoConnectOnLaunch() async {
        guard isAutoConnectEnabled,
              vpnStatus == .disconnected || vpnStatus == .invalid else { return }
        refreshServers()
        await serverRefreshTask?.value
        guard isAutoConnectEnabled,
              vpnStatus == .disconnected || vpnStatus == .invalid else { return }
        requestQuickConnect()
    }

    private func reconcileKillSwitchOnLaunch() async {
        guard isKillSwitchEnabled, killSwitchActivationState == .active else { return }
        do {
            let configured = try await vpn.apply(policy: currentConnectionPolicy())
            if !configured {
                persistKillSwitch(enabled: true, activation: .armed)
            }
        } catch {
            persistKillSwitch(enabled: true, activation: .armed)
        }
    }

    private func persistAutoConnectEnabled(_ enabled: Bool) {
        isAutoConnectEnabled = enabled
        defaults.set(enabled, forKey: autoConnectEnabledKey)
    }

    private func persistKillSwitch(enabled: Bool, activation: KillSwitchActivationState) {
        isKillSwitchEnabled = enabled
        killSwitchActivationState = activation
        defaults.set(enabled, forKey: killSwitchEnabledKey)
        defaults.set(activation.rawValue, forKey: killSwitchActivationKey)
    }

    private func currentConnectionPolicy(autoConnectOverride: Bool? = nil) -> VPNConnectionPolicy {
        VPNConnectionPolicy.appPolicy(
            autoConnectEnabled: autoConnectOverride ?? isAutoConnectEnabled,
            killSwitchEnabled: isKillSwitchEnabled
        )
    }

    private var selectedServer: VPNServer? {
        guard let selectedServerID else { return nil }
        return servers.first(where: { $0.id == selectedServerID })
    }

    private func canUse(server: VPNServer) -> Bool {
        if server.requiresProSubscription {
            return isProUser
        }
        return true
    }

    private func canSelect(protocolName: VPNConfigurationProtocol) -> Bool {
        guard protocolName.requiresProSubscription else { return true }
        return isProUser
    }

    private func effectiveConnectionProtocol() -> VPNConfigurationProtocol {
        if selectedVPNProtocol.requiresProSubscription, !isProUser {
            return .ikev2
        }
        return selectedVPNProtocol
    }

    private func requestConnection(_ request: VPNConnectRequest) {
        selectedServerID = request.server.id

        switch vpnStatus {
        case .invalid, .disconnected:
            if case .connect = activeVPNTransition {
                queuedVPNConnectRequest = request
                beginDisconnect(preservingQueuedConnection: true)
            } else {
                queuedVPNConnectRequest = nil
                beginConnect(request)
            }
        case .connecting, .connected, .reasserting:
            queuedVPNConnectRequest = request
            beginDisconnect(preservingQueuedConnection: true)
        case .disconnecting:
            queuedVPNConnectRequest = request
        }
    }

    private func beginConnect(_ request: VPNConnectRequest) {
        vpnTransitionTask?.cancel()
        vpnTransitionGeneration &+= 1
        let generation = vpnTransitionGeneration
        activeVPNTransition = .connect(request)
        pendingStatisticsRequest = request
        vpnStatus = .connecting

        vpnTransitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await vpn.connect(
                    to: request.server,
                    protocol: request.protocolName,
                    policy: VPNConnectionPolicy(
                        killSwitchEnabled: request.killSwitchEnabled,
                        onDemandEnabled: request.onDemandEnabled
                    )
                )
                guard generation == vpnTransitionGeneration, !Task.isCancelled else { return }
                if request.killSwitchEnabled {
                    persistKillSwitch(enabled: true, activation: .active)
                }
                activeVPNTransition = nil
                handleVPNStatusChange(vpn.status)
            } catch is CancellationError {
                return
            } catch {
                guard generation == vpnTransitionGeneration, !Task.isCancelled else { return }
                activeVPNTransition = nil
                handleVPNStatusChange(vpn.status)
                present(error)
            }
        }
    }

    private func beginDisconnect(preservingQueuedConnection: Bool) {
        if !preservingQueuedConnection {
            queuedVPNConnectRequest = nil
        }

        vpnTransitionTask?.cancel()
        vpnTransitionGeneration &+= 1
        let generation = vpnTransitionGeneration
        activeVPNTransition = .disconnect
        vpnStatus = .disconnecting

        vpnTransitionTask = Task { [weak self] in
            guard let self else { return }
            await vpn.disconnect()
            guard generation == vpnTransitionGeneration, !Task.isCancelled else { return }
            activeVPNTransition = nil
            handleVPNStatusChange(vpn.status)
        }
    }

    private func handleVPNStatusChange(_ status: VPNConnectionState) {
        if case .connect = activeVPNTransition,
           status == .disconnected || status == .invalid {
            vpnStatus = .connecting
            return
        }

        if activeVPNTransition == .disconnect,
           status != .disconnected,
           status != .invalid,
           status != .disconnecting {
            vpnStatus = .disconnecting
            return
        }

        vpnStatus = status

        switch status {
        case .invalid, .disconnected:
            activeVPNTransition = nil
            persistActiveStatisticsSessionIfNeeded(endedAt: Date())
            guard let queuedRequest = queuedVPNConnectRequest else { return }
            queuedVPNConnectRequest = nil
            beginConnect(queuedRequest)
        case .connected:
            activeVPNTransition = nil
            beginStatisticsSessionIfNeeded()
        case .connecting, .reasserting, .disconnecting:
            break
        }
    }

    private func cancelActiveVPNTransition() {
        vpnTransitionGeneration &+= 1
        vpnTransitionTask?.cancel()
        vpnTransitionTask = nil
        activeVPNTransition = nil
        queuedVPNConnectRequest = nil
        pendingStatisticsRequest = nil
    }

    private func cachePlan(name: String, isPro: Bool) {
        cachedPlanName = name
        cachedPlanIsPro = isPro
        defaults.set(name, forKey: cachedPlanNameKey)
        defaults.set(isPro, forKey: cachedPlanIsProKey)
    }

    private func clearCachedPlan() {
        cachedPlanName = nil
        cachedPlanIsPro = false
        defaults.removeObject(forKey: cachedPlanNameKey)
        defaults.removeObject(forKey: cachedPlanIsProKey)
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

private extension AppModel {
    struct ActiveStatisticsSession {
        let userId: String
        let server: VPNServer
        let protocolName: VPNConfigurationProtocol
        let connectedAt: Date
        let baselineSnapshot: TunnelTrafficSnapshot?
    }

    func beginStatisticsSessionIfNeeded() {
        guard activeStatisticsSession == nil,
              let userId = session?.userId,
              let request = pendingStatisticsRequest else {
            return
        }

        activeStatisticsSession = ActiveStatisticsSession(
            userId: userId,
            server: request.server,
            protocolName: request.protocolName,
            connectedAt: Date(),
            baselineSnapshot: trafficSampler.currentSnapshot()
        )
        pendingStatisticsRequest = nil
    }

    func persistActiveStatisticsSessionIfNeeded(endedAt: Date) {
        guard let activeStatisticsSession else {
            pendingStatisticsRequest = nil
            return
        }

        defer {
            self.activeStatisticsSession = nil
            self.pendingStatisticsRequest = nil
        }

        guard let statisticsRecorder else { return }

        let snapshot = trafficSampler.currentSnapshot()
        let totals = if let baseline = activeStatisticsSession.baselineSnapshot, let snapshot {
            snapshot.delta(from: baseline)
        } else {
            TunnelTrafficSnapshot(downloadedBytes: 0, uploadedBytes: 0)
        }

        try? statisticsRecorder.record(
            userId: activeStatisticsSession.userId,
            connectedAt: activeStatisticsSession.connectedAt,
            disconnectedAt: max(endedAt, activeStatisticsSession.connectedAt),
            server: activeStatisticsSession.server,
            protocolName: activeStatisticsSession.protocolName,
            downloadedBytes: totals.downloadedBytes,
            uploadedBytes: totals.uploadedBytes
        )
    }
}
