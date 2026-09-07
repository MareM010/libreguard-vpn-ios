import Foundation
import Combine
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var route: AppRoute = .launching
    @Published var presentedError: APIError?
    @Published var deviceLimitContext: DeviceLimitContext?
    @Published var isAuthenticating = false
    @Published var isRefreshingAccount = false
    @Published var isRefreshingServers = false
    @Published var prefilledEmail = ""
    @Published var session: AuthSession? {
        didSet {
            guard oldValue?.userId != session?.userId else { return }
            loadFavoriteServerIDs(for: session?.userId)
        }
    }
    @Published private(set) var favoriteServerIDs: [Int] = []
    @Published var usageQuota: UsageQuota?
    @Published var subscription: SubscriptionStatus?
    @Published private(set) var isCheckingConnectionQuota = false
    @Published var upgradePromptRequested = false
    @Published private(set) var dnsPreference: DNSPreference?
    @Published private(set) var isRefreshingDNSPreference = false
    @Published private(set) var isUpdatingAdBlocking = false
    @Published private(set) var appleSubscriptionProducts: [AppleSubscriptionProduct] = []
    @Published var selectedAppleProductID = AppleSubscriptionCatalog.annualProductID
    @Published private(set) var isLoadingAppleSubscriptions = false
    @Published private(set) var isPurchasingAppleSubscription = false
    @Published private(set) var isRestoringApplePurchases = false
    @Published var applePurchaseMessage: String?
    @Published var pendingAppleSubscriptionTransfer: PendingAppleSubscriptionTransfer?
    @Published var twoFactorStatus: TwoFactorStatus?
    @Published var authenticatorSetup: AuthenticatorSetup?
    @Published var recoveryCodes: [String] = []
    @Published var servers: [VPNServer] = []
    @Published var serverLatencies: [Int: Int] = [:]
    @Published var selectedServerID: Int?
    @Published var selectedVPNProtocol: VPNConfigurationProtocol
    @Published var vpnStatus: VPNConnectionState = .disconnected
    @Published private(set) var certificatePreparationMessage: String?
    @Published private(set) var hasQueuedVPNReconnect = false
    @Published private(set) var isAutoConnectEnabled: Bool
    @Published private(set) var isUpdatingAutoConnect = false
    @Published private(set) var isKillSwitchEnabled: Bool
    @Published private(set) var killSwitchActivationState: KillSwitchActivationState
    @Published private(set) var isUpdatingKillSwitch = false
    @Published var isKillSwitchDisconnectConfirmationPresented = false
    @Published private(set) var sessionMetrics: VPNSessionMetrics?
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var retryAfterSeconds = 0

    private let api: BackendServicing
    private let appleStore: AppleSubscriptionStoreServing
    private let google: GoogleSigning
    private let latencyProbe: LatencyProbing
    private let vpn: VPNManaging
    private let defaults: UserDefaults
    private let protocolSelectionStore: VPNProtocolSelectionStoring
    private let favoriteServerStore: FavoriteServerStoring
    private let statisticsRecorder: LocalStatisticsRecording?
    private let trafficSampler: TunnelTrafficSampling
    private let notificationService: VPNNotificationService
    private let eventNotifier: VPNEventNotifying
    private let liveActivityController: VPNLiveActivityControlling
    private let pendingRegistrationKey = "pending.registration"
    private let cachedPlanNameKey = "cached.plan.name"
    private let cachedPlanIsProKey = "cached.plan.isPro"
    private let autoConnectEnabledKey = "vpn.autoConnect.enabled"
    private let killSwitchEnabledKey = "vpn.killSwitch.enabled"
    private let killSwitchActivationKey = "vpn.killSwitch.activation"
    private var cachedPlanName: String?
    private var cachedPlanIsPro = false
    private var hasCachedPlan = false
    private var serverRefreshTask: Task<Void, Never>?
    private var retryCountdownTask: Task<Void, Never>?
    private var appleTransactionListenerTask: Task<Void, Never>?
    private var processingAppleTransactionIDs: Set<UInt64> = []
    private var vpnTransitionTask: Task<Void, Never>?
    private var trafficMonitorTask: Task<Void, Never>?
    private var liveActivityUpdateCounter = 0
    private var vpnTransitionGeneration: UInt = 0
    private var activeVPNTransition: VPNTransitionRequest?
    private var pendingStatisticsRequest: VPNConnectRequest?
    private var activeStatisticsSession: ActiveStatisticsSession?
    private var isExplicitDisconnectInProgress = false
    private var killSwitchIncidentSessionID: UUID?
    private var queuedVPNConnectRequest: VPNConnectRequest? {
        didSet {
            hasQueuedVPNReconnect = queuedVPNConnectRequest != nil
        }
    }

    init(
        api: BackendServicing? = nil,
        appleStore: AppleSubscriptionStoreServing? = nil,
        google: GoogleSigning? = nil,
        latencyProbe: LatencyProbing? = nil,
        vpnManager: VPNManaging? = nil,
        protocolSelectionStore: VPNProtocolSelectionStoring? = nil,
        favoriteServerStore: FavoriteServerStoring? = nil,
        statisticsRecorder: LocalStatisticsRecording? = nil,
        trafficSampler: TunnelTrafficSampling = SystemTunnelTrafficSampler(),
        notificationService: VPNNotificationService? = nil,
        eventNotifier: VPNEventNotifying? = nil,
        liveActivityController: VPNLiveActivityControlling? = nil,
        defaults: UserDefaults = .standard
    ) {
        let resolvedAPI = api ?? APIClient()
        self.api = resolvedAPI
        self.appleStore = appleStore ?? AppleSubscriptionStore()
        self.google = google ?? GoogleSignInService()
        self.latencyProbe = latencyProbe ?? NetworkLatencyProbe()
        self.protocolSelectionStore = protocolSelectionStore ?? UserDefaultsVPNProtocolSelectionStore(defaults: defaults)
        self.favoriteServerStore = favoriteServerStore ?? UserDefaultsFavoriteServerStore(defaults: defaults)
        self.statisticsRecorder = statisticsRecorder
        self.trafficSampler = trafficSampler
        self.notificationService = notificationService ?? VPNNotificationService()
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.eventNotifier = eventNotifier ?? (isTesting ? NoOpVPNEventNotifier() : SystemVPNEventNotifier())
        self.liveActivityController = liveActivityController ?? (isTesting
            ? NoOpVPNLiveActivityController()
            : VPNLiveActivityController())
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
        self.hasCachedPlan = defaults.string(forKey: cachedPlanNameKey) != nil
            || defaults.object(forKey: cachedPlanIsProKey) != nil
        self.vpnStatus = self.vpn.status
        self.vpn.onStatusChange = { [weak self] status in
            self?.handleVPNStatusChange(status)
        }
        self.vpn.onDisconnectError = { [weak self] error in
            self?.present(error)
        }
        self.vpn.setCertificatePreparationHandler { [weak self] message in
            Task { @MainActor [weak self] in
                self?.certificatePreparationMessage = message
            }
        }
        if let concrete = resolvedAPI as? APIClient {
            concrete.onSessionInvalidated = { [weak self] in self?.forceSignOut() }
        }
    }

    func start() async {
        startAppleTransactionListener()
        guard case .launching = route else { return }
        await refreshNotificationAuthorizationStatus()
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            api.clearLocalSession()
            clearCachedPlan()
            clearPendingRegistration()
            persistAutoConnectEnabled(false)
            persistKillSwitch(enabled: false, activation: .off)
            await vpn.disconnectAndForget()
            await liveActivityController.endAll()
            VPNSharedSessionStore.clear()
            route = .login
            return
        }
        await vpn.refreshStatus()
        if let storedSession = api.storedSession {
            do {
                session = try await api.restoreSession()
                route = .authenticated
                await refreshAccountData(showErrors: false)
                await reconcileUnfinishedAppleTransactions()
                if vpnStatus.isConnected {
                    refreshServers()
                    await serverRefreshTask?.value
                    await restoreActiveSessionIfNeeded()
                } else {
                    await liveActivityController.endAll()
                    finalizeOrphanedSessionIfNeeded(endedAt: Date())
                }
                await reconcileKillSwitchOnLaunch()
                await reconcileAutoConnectOnLaunch()
                return
            } catch let error as APIError where error.code == "APP_VERSION_BLOCKED" || error.code == "APP_VERSION_REQUIRED" {
                presentedError = error
            } catch let error as APIError where isAuthenticationFailure(error) {
                clearCachedPlan()
            } catch {
                // Keep the local account and active VPN available when the
                // refresh failed for a transient network or server reason.
                session = storedSession
                route = .authenticated
                if vpnStatus.isConnected {
                    refreshServers()
                    await serverRefreshTask?.value
                    await restoreActiveSessionIfNeeded()
                } else {
                    finalizeOrphanedSessionIfNeeded(endedAt: Date())
                }
                await reconcileKillSwitchOnLaunch()
                return
            }
        }

        await liveActivityController.endAll()
        persistAutoConnectEnabled(false)
        persistKillSwitch(enabled: false, activation: .off)
        await vpn.disconnectAndForget()
        VPNSharedSessionStore.clear()

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

    func loginWithGoogle(newsletterConsent: Bool? = nil) async {
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let idToken = try await google.signIn()
            let attempt = LoginAttempt.google(idToken: idToken, newsletterConsent: newsletterConsent)
            do {
                let response = try await api.loginWithGoogle(idToken: idToken, newsletterConsent: newsletterConsent)
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

    func register(email: String, password: String, confirmation: String, newsletterConsent: Bool = false) async {
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
            let response = try await api.register(
                email: normalizedEmail,
                password: password,
                newsletterConsent: newsletterConsent
            )
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
            case let .google(idToken, newsletterConsent):
                try await api.removeGoogleDevice(idToken: idToken, deviceId: device.id)
                deviceLimitContext = nil
                let response = try await api.loginWithGoogle(
                    idToken: idToken,
                    newsletterConsent: newsletterConsent
                )
                try await handleLogin(response, attempt: context.attempt, afterTwoFactor: false)
            }
        } catch {
            present(error)
        }
    }

    func refreshAccountData(showErrors: Bool = true) async {
        guard session != nil || api.storedSession != nil else { return }
        guard !isRefreshingAccount else { return }
        isRefreshingAccount = true
        defer { isRefreshingAccount = false }

        async let usageResult = fetchUsageResult()
        async let subscriptionResult = fetchSubscriptionResult()
        async let twoFactorResult = fetchTwoFactorStatusResult()
        async let dnsPreferenceResult = fetchDNSPreferenceResult()
        let (usage, subscription, twoFactor, dnsPreference) = await (
            usageResult,
            subscriptionResult,
            twoFactorResult,
            dnsPreferenceResult
        )

        var firstError: Error?

        switch usage {
        case let .success(value):
            usageQuota = value
        case let .failure(error):
            firstError = error
        }

        switch subscription {
        case let .success(value):
            self.subscription = value
            cachePlan(name: value.displayName, isPro: value.isPro)
        case let .failure(error):
            firstError = firstError ?? error
        }

        switch twoFactor {
        case let .success(value):
            twoFactorStatus = value
        case let .failure(error):
            firstError = firstError ?? error
        }

        switch dnsPreference {
        case let .success(value):
            self.dnsPreference = value
        case let .failure(error):
            firstError = firstError ?? error
        }

        if showErrors, let firstError {
            present(firstError)
        }
    }

    private func fetchUsageResult() async -> Result<UsageQuota, Error> {
        do {
            return .success(try await api.fetchUsage())
        } catch {
            return .failure(error)
        }
    }

    private func fetchSubscriptionResult() async -> Result<SubscriptionStatus, Error> {
        do {
            return .success(try await api.fetchSubscription())
        } catch {
            return .failure(error)
        }
    }

    private func fetchTwoFactorStatusResult() async -> Result<TwoFactorStatus, Error> {
        do {
            return .success(try await api.fetchTwoFactorStatus())
        } catch {
            return .failure(error)
        }
    }

    private func fetchDNSPreferenceResult() async -> Result<DNSPreference, Error> {
        do {
            return .success(try await api.fetchDNSPreference())
        } catch {
            return .failure(error)
        }
    }

    func refreshDNSPreference(showErrors: Bool = true) async {
        guard session != nil || api.storedSession != nil,
              !isRefreshingDNSPreference else { return }
        isRefreshingDNSPreference = true
        defer { isRefreshingDNSPreference = false }

        do {
            dnsPreference = try await api.fetchDNSPreference()
        } catch {
            if showErrors { present(error) }
        }
    }

    func loadAppleSubscriptions() async {
        guard appleSubscriptionProducts.isEmpty, !isLoadingAppleSubscriptions else { return }
        isLoadingAppleSubscriptions = true
        defer { isLoadingAppleSubscriptions = false }
        do {
            appleSubscriptionProducts = try await appleStore.loadProducts()
            if !appleSubscriptionProducts.contains(where: { $0.id == selectedAppleProductID }) {
                selectedAppleProductID = appleSubscriptionProducts.first?.id ?? AppleSubscriptionCatalog.annualProductID
            }
        } catch {
            present(error)
        }
    }

    func purchaseSelectedAppleSubscription() async {
        guard session != nil, !isPurchasingAppleSubscription else { return }
        isPurchasingAppleSubscription = true
        applePurchaseMessage = nil
        defer { isPurchasingAppleSubscription = false }

        do {
            let accountToken = try await api.fetchAppleAccountToken()
            switch try await appleStore.purchase(productID: selectedAppleProductID, appAccountToken: accountToken) {
            case let .success(transaction):
                await processAppleTransaction(transaction, allowTransfer: false)
            case .pending:
                applePurchaseMessage = "Your purchase is pending approval. Pro will activate automatically after the App Store completes it."
            case .userCancelled:
                break
            }
        } catch {
            present(error)
        }
    }

    func restoreApplePurchases() async {
        guard session != nil, !isRestoringApplePurchases else { return }
        isRestoringApplePurchases = true
        applePurchaseMessage = nil
        defer { isRestoringApplePurchases = false }

        do {
            try await appleStore.sync()
            let updates = await appleStore.currentEntitlements()
            let transactions = updates.compactMap { update -> AppleStoreTransaction? in
                guard case let .verified(transaction) = update,
                      AppleSubscriptionCatalog.productIDs.contains(transaction.productID) else { return nil }
                return transaction
            }
            guard !transactions.isEmpty else {
                applePurchaseMessage = "No active LibreGuard Pro subscription was found for this Apple Account."
                return
            }
            for transaction in transactions {
                await processAppleTransaction(transaction, allowTransfer: false)
                if pendingAppleSubscriptionTransfer != nil { break }
            }
        } catch {
            present(error)
        }
    }

    func confirmAppleSubscriptionTransfer(_ transaction: AppleStoreTransaction) async {
        isRestoringApplePurchases = true
        defer { isRestoringApplePurchases = false }
        await processAppleTransaction(transaction, allowTransfer: true)
    }

    func cancelAppleSubscriptionTransfer() {
        pendingAppleSubscriptionTransfer = nil
        applePurchaseMessage = "The Apple subscription remains linked to its previous LibreGuard account."
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
                await requestNotificationAuthorizationIfNeeded()
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
                    let request = VPNConnectRequest(
                        server: server,
                        protocolName: effectiveConnectionProtocol(),
                        onDemandEnabled: true,
                        killSwitchEnabled: isKillSwitchEnabled,
                        origin: .autoConnect
                    )
                    guard await authorizeConnection() else { return }
                    requestConnection(request)
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

    func setAdBlockingEnabled(_ enabled: Bool) async {
        guard !isUpdatingAdBlocking else { return }

        if dnsPreference == nil {
            await refreshDNSPreference(showErrors: true)
        }
        guard let current = dnsPreference,
              current.requestedEnabled != enabled else { return }

        if enabled, !current.canUseAdBlocking {
            presentedError = APIError(message: "Ad Blocking requires a Pro plan.", code: "PRO_REQUIRED")
            return
        }

        isUpdatingAdBlocking = true
        dnsPreference = current.optimisticallyRequesting(enabled)
        defer { isUpdatingAdBlocking = false }

        do {
            dnsPreference = try await api.updateDNSPreference(adBlockingEnabled: enabled)
        } catch {
            dnsPreference = current
            if let apiError = error as? APIError, apiError.code == "PRO_REQUIRED" {
                await refreshDNSPreference(showErrors: false)
            }
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
        guard session != nil, activeVPNTransition == nil else { return }
        if vpnStatus.isConnected {
            await restoreActiveSessionIfNeeded()
            await refreshTrafficMetricsOnce(updateLiveActivity: false)
        } else if vpnStatus == .disconnected || vpnStatus == .invalid {
            finalizeOrphanedSessionIfNeeded(endedAt: Date())
        }
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
        isExplicitDisconnectInProgress = true
        await refreshTrafficMetricsOnce(updateLiveActivity: true)
        cancelActiveVPNTransition()
        persistAutoConnectEnabled(false)
        persistKillSwitch(enabled: false, activation: .off)
        await vpn.disconnectAndForget()
        persistActiveStatisticsSessionIfNeeded(endedAt: Date(), notifyDisconnect: true)
        await api.logout()
        google.signOut()
        clearSessionState()
    }

    func selectServer(_ server: VPNServer) {
        selectedServerID = server.id
    }

    func isFavoriteServer(_ serverID: Int) -> Bool {
        favoriteServerIDs.contains(serverID)
    }

    func toggleFavoriteServer(_ serverID: Int) {
        guard let userID = session?.userId else { return }

        if let index = favoriteServerIDs.firstIndex(of: serverID) {
            favoriteServerIDs.remove(at: index)
        } else {
            favoriteServerIDs.insert(serverID, at: 0)
        }

        favoriteServerStore.saveFavoriteServerIDs(favoriteServerIDs, for: userID)
    }

    func deselectServer() {
        selectedServerID = nil
    }

    private func loadFavoriteServerIDs(for userID: String?) {
        favoriteServerIDs = userID.map { favoriteServerStore.favoriteServerIDs(for: $0) } ?? []
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
        startConnection(
            VPNConnectRequest(
                server: server,
                protocolName: effectiveConnectionProtocol(),
                onDemandEnabled: currentConnectionPolicy().onDemandEnabled,
                killSwitchEnabled: isKillSwitchEnabled,
                origin: .manual
            )
        )
    }

    func requestQuickConnect(origin: VPNConnectionOrigin = .quickConnect) {
        guard let server = QuickConnectRanker.bestServer(
            in: servers,
            latencies: serverLatencies,
            isProUser: isProUser
        ) else {
            presentedError = APIError(message: "No VPN server is available right now.")
            return
        }
        selectedServerID = server.id
        startConnection(
            VPNConnectRequest(
                server: server,
                protocolName: effectiveConnectionProtocol(),
                onDemandEnabled: currentConnectionPolicy().onDemandEnabled,
                killSwitchEnabled: isKillSwitchEnabled,
                origin: origin
            )
        )
        refreshServers()
    }

    func consumeUpgradePrompt() {
        upgradePromptRequested = false
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
#if DEBUG
        if url.host?.lowercased() == "debug", url.path == "/connect" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<20 where servers.isEmpty {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                requestQuickConnect(origin: .quickConnect)
            }
            return
        }
#endif
        if url.host?.lowercased() == "vpn", url.path == "/status" {
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
        if hasCachedPlan { return cachedPlanIsPro }
        if let usageQuota { return usageQuota.planTierHint.isPro }
        return false
    }

    var currentPlanDisplayName: String {
        if let subscription { return subscription.displayName }
        if hasCachedPlan {
            if let cachedPlan = AccountPlanTier(planName: cachedPlanName) {
                return cachedPlan.rawValue
            }
            return cachedPlanIsPro ? AccountPlanTier.pro.rawValue : AccountPlanTier.free.rawValue
        }
        if let usageQuota { return usageQuota.planTierHint.rawValue }
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

    var ipv6ProtectionStatus: IPv6ProtectionStatus {
        let activeProtocol = activeStatisticsSession?.protocolName
            ?? pendingStatisticsRequest?.protocolName
        return IPv6ProtectionStatus.resolve(
            connectionState: vpnStatus,
            protocolName: activeProtocol
        )
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
        await reconcileUnfinishedAppleTransactions()
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
        isExplicitDisconnectInProgress = true
        cancelActiveVPNTransition()
        persistAutoConnectEnabled(false)
        persistKillSwitch(enabled: false, activation: .off)
        persistActiveStatisticsSessionIfNeeded(endedAt: Date(), notifyDisconnect: true)
        Task { await vpn.disconnectAndForget() }
        clearSessionState()
    }

    private func clearSessionState() {
        serverRefreshTask?.cancel()
        retryCountdownTask?.cancel()
        cancelActiveVPNTransition()
        serverRefreshTask = nil
        retryCountdownTask = nil
        trafficMonitorTask?.cancel()
        trafficMonitorTask = nil
        clearCachedPlan()
        api.clearLocalSession()
        session = nil
        usageQuota = nil
        subscription = nil
        upgradePromptRequested = false
        isCheckingConnectionQuota = false
        dnsPreference = nil
        isRefreshingDNSPreference = false
        isUpdatingAdBlocking = false
        twoFactorStatus = nil
        authenticatorSetup = nil
        recoveryCodes = []
        isAuthenticating = false
        isRefreshingAccount = false
        isRefreshingServers = false
        retryAfterSeconds = 0
        processingAppleTransactionIDs.removeAll()
        pendingAppleSubscriptionTransfer = nil
        applePurchaseMessage = nil
        isPurchasingAppleSubscription = false
        isRestoringApplePurchases = false
        servers = []
        serverLatencies = [:]
        selectedServerID = nil
        vpnStatus = .disconnected
        deviceLimitContext = nil
        pendingStatisticsRequest = nil
        activeStatisticsSession = nil
        sessionMetrics = nil
        VPNSharedSessionStore.clear()
        route = .login
    }

    private func startAppleTransactionListener() {
        guard appleTransactionListenerTask == nil else { return }
        let updates = appleStore.transactionUpdates()
        appleTransactionListenerTask = Task { @MainActor [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                guard self.session != nil else { continue }
                switch update {
                case let .verified(transaction) where AppleSubscriptionCatalog.productIDs.contains(transaction.productID):
                    await self.processAppleTransaction(transaction, allowTransfer: false)
                case .unverified:
                    self.applePurchaseMessage = AppleStoreError.unverifiedTransaction.localizedDescription
                case .verified:
                    break
                }
            }
        }
    }

    private func reconcileUnfinishedAppleTransactions() async {
        guard session != nil else { return }
        for update in await appleStore.unfinishedTransactions() {
            guard case let .verified(transaction) = update,
                  AppleSubscriptionCatalog.productIDs.contains(transaction.productID) else { continue }
            await processAppleTransaction(transaction, allowTransfer: false)
            if pendingAppleSubscriptionTransfer != nil { break }
        }
    }

    private func processAppleTransaction(_ transaction: AppleStoreTransaction, allowTransfer: Bool) async {
        guard session != nil,
              processingAppleTransactionIDs.insert(transaction.id).inserted else { return }
        defer { processingAppleTransactionIDs.remove(transaction.id) }

        do {
            let response = try await api.verifyAppleTransaction(
                transaction.signedTransactionInfo,
                allowTransfer: allowTransfer
            )
            subscription = response.subscription
            cachePlan(name: response.subscription.displayName, isPro: response.subscription.isPro)
            usageQuota = try? await api.fetchUsage()
            await refreshDNSPreference(showErrors: false)
            await appleStore.finish(transactionID: transaction.id)
            applePurchaseMessage = response.transferred
                ? "Your Apple subscription was moved to this LibreGuard account and Pro is now active."
                : "LibreGuard Pro is now active."
        } catch let error as APIError where error.code == "APPLE_SUBSCRIPTION_TRANSFER_REQUIRED" && !allowTransfer {
            pendingAppleSubscriptionTransfer = PendingAppleSubscriptionTransfer(transaction: transaction)
        } catch {
            present(error)
        }
    }

    private func reconcileAutoConnectOnLaunch() async {
        guard isAutoConnectEnabled,
              vpnStatus == .disconnected || vpnStatus == .invalid else { return }
        refreshServers()
        await serverRefreshTask?.value
        guard isAutoConnectEnabled,
              vpnStatus == .disconnected || vpnStatus == .invalid else { return }
        requestQuickConnect(origin: .autoConnect)
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

    private func startConnection(_ request: VPNConnectRequest) {
        guard !isCheckingConnectionQuota else { return }
        guard shouldPreflightConnection else {
            requestConnection(request)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, await authorizeConnection() else { return }
            requestConnection(request)
        }
    }

    private var shouldPreflightConnection: Bool {
        !isProUser && (session != nil || api.storedSession != nil)
    }

    private func authorizeConnection() async -> Bool {
        guard shouldPreflightConnection else { return true }

        isCheckingConnectionQuota = true
        defer { isCheckingConnectionQuota = false }

        do {
            let eligibility = try await api.fetchConnectionEligibility()
            usageQuota = try? await api.fetchUsage()
            guard !eligibility.allowed else { return true }
            upgradePromptRequested = true
            return false
        } catch {
            // The backend documents this preflight as fail-open for availability.
            return true
        }
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
        isExplicitDisconnectInProgress = false
        killSwitchIncidentSessionID = nil
        vpnStatus = .connecting
        VPNSharedSessionStore.saveDisconnectIntent(nil)
        VPNSharedSessionStore.save(
            descriptor: makeSessionDescriptor(
                for: request,
                connectedAt: Date(),
                isEstablished: false
            )
        )

        vpnTransitionTask = Task { [weak self] in
            guard let self else { return }
            do {
                await requestNotificationAuthorizationIfNeeded()
                if request.origin == .autoConnect || request.origin == .onDemand {
                    let descriptor = makeSessionDescriptor(for: request, connectedAt: Date())
                    await eventNotifier.emit(VPNNotificationPayload(
                        event: .autoConnect,
                        descriptor: descriptor,
                        traffic: nil
                    ))
                }
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
                // startVPNTunnel() can return before Network Extension has
                // advanced its observable status from .disconnected. Keep the
                // request pending until the real .connected callback arrives;
                // clearing it here loses the session descriptor and prevents
                // traffic monitoring from ever starting.
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
        isExplicitDisconnectInProgress = true
        VPNSharedSessionStore.saveDisconnectIntent(preservingQueuedConnection ? .suppress : .notify)
        vpnStatus = .disconnecting

        vpnTransitionTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await vpn.apply(
                policy: VPNConnectionPolicy(
                    killSwitchEnabled: isKillSwitchEnabled,
                    onDemandEnabled: false
                )
            )
            await refreshTrafficMetricsOnce(updateLiveActivity: true)
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

        let previousStatus = vpnStatus
        vpnStatus = status

        switch status {
        case .invalid, .disconnected:
            activeVPNTransition = nil
            if let active = activeStatisticsSession,
               active.descriptor.killSwitchEnabled,
               !isExplicitDisconnectInProgress,
               killSwitchIncidentSessionID != active.descriptor.sessionID {
                triggerKillSwitchNotification(for: active)
            }
            let hasQueuedConnection = queuedVPNConnectRequest != nil
            let suppressDisconnect = hasQueuedConnection
                || killSwitchIncidentSessionID == activeStatisticsSession?.descriptor.sessionID
            persistActiveStatisticsSessionIfNeeded(
                endedAt: Date(),
                notifyDisconnect: !suppressDisconnect
            )
            isExplicitDisconnectInProgress = false
            guard let queuedRequest = queuedVPNConnectRequest else { return }
            queuedVPNConnectRequest = nil
            beginConnect(queuedRequest)
        case .connected:
            activeVPNTransition = nil
            if previousStatus == .reasserting, let metrics = sessionMetrics {
                publishSessionMetrics(metrics.replacingState(.connected))
            } else {
                beginStatisticsSessionIfNeeded()
            }
        case .reasserting:
            if let active = activeStatisticsSession {
                let reconnecting = VPNSessionMetrics(
                    descriptor: active.descriptor,
                    traffic: active.traffic
                ).replacingState(.reconnecting)
                publishSessionMetrics(reconnecting)
                Task { [liveActivityController] in
                    await liveActivityController.update(
                        descriptor: reconnecting.descriptor,
                        traffic: reconnecting.traffic
                    )
                }
                if active.descriptor.killSwitchEnabled,
                   !isExplicitDisconnectInProgress,
                   killSwitchIncidentSessionID != active.descriptor.sessionID {
                    triggerKillSwitchNotification(for: active)
                }
            }
        case .connecting, .disconnecting:
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
        trafficMonitorTask?.cancel()
        trafficMonitorTask = nil
        if activeStatisticsSession == nil {
            VPNSharedSessionStore.clear()
        }
    }

    private func cachePlan(name: String, isPro: Bool) {
        cachedPlanName = name
        cachedPlanIsPro = isPro
        hasCachedPlan = true
        defaults.set(name, forKey: cachedPlanNameKey)
        defaults.set(isPro, forKey: cachedPlanIsProKey)
    }

    private func isAuthenticationFailure(_ error: APIError) -> Bool {
        error.statusCode == 401
            || error.requiresLogin
            || error.requiresDeviceRegistration
            || error.code == "SESSION_EXPIRED"
    }

    private func clearCachedPlan() {
        cachedPlanName = nil
        cachedPlanIsPro = false
        hasCachedPlan = false
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
        let descriptor: VPNSessionDescriptor
        var accumulator: VPNTrafficAccumulator
        var traffic: VPNSessionTraffic
    }

    func beginStatisticsSessionIfNeeded() {
        guard activeStatisticsSession == nil,
              let userId = session?.userId,
              let request = pendingStatisticsRequest else {
            return
        }

        let connectionDate = vpn.connectedDate ?? Date()
        let descriptor: VPNSessionDescriptor
        if let storedDescriptor = VPNSharedSessionStore.loadDescriptor(),
           storedDescriptor.sessionID == request.sessionID {
            descriptor = storedDescriptor.isEstablished
                ? storedDescriptor
                : storedDescriptor.established(at: connectionDate)
        } else {
            descriptor = makeSessionDescriptor(
                for: request,
                connectedAt: connectionDate,
                isEstablished: true
            )
        }
        let connectedAt = descriptor.connectedAt
        let initialTraffic = VPNSharedSessionStore.loadTraffic() ?? .zero(at: connectedAt)
        activeStatisticsSession = ActiveStatisticsSession(
            userId: userId,
            server: request.server,
            protocolName: request.protocolName,
            descriptor: descriptor,
            accumulator: VPNTrafficAccumulator(existingTraffic: initialTraffic),
            traffic: initialTraffic
        )
        pendingStatisticsRequest = nil
        publishSessionMetrics(VPNSessionMetrics(descriptor: descriptor, traffic: initialTraffic))
        startTrafficMonitoring(emitConnectedNotification: true)
    }

    func restoreActiveSessionIfNeeded() async {
        guard activeStatisticsSession == nil,
              vpnStatus.isConnected,
              let userId = session?.userId,
              let storedDescriptor = VPNSharedSessionStore.loadDescriptor() else { return }

        let protocolName = VPNConfigurationProtocol.allCases.first(where: {
            $0.displayName.caseInsensitiveCompare(storedDescriptor.protocolName) == .orderedSame
                || ($0 == .ikev2 && storedDescriptor.protocolName == "IKEv2/IPSec")
        }) ?? .ikev2
        let connectionDate = vpn.connectedDate ?? storedDescriptor.connectedAt
        let descriptor = storedDescriptor.isEstablished
            ? storedDescriptor
            : storedDescriptor.established(at: connectionDate)
        let server = serverForSession(descriptor)
        selectedServerID = descriptor.serverID
        var traffic = VPNSharedSessionStore.loadTraffic() ?? .zero(at: descriptor.connectedAt)

        if protocolName == .ikev2,
           let checkpoint = VPNSharedSessionStore.loadCheckpoint(),
           checkpoint.sessionID == descriptor.sessionID,
           let snapshot = await vpn.currentTrafficSnapshot() ?? trafficSampler.currentSnapshot() {
            let gap = snapshot.delta(from: checkpoint.snapshot)
            traffic = VPNSessionTraffic(
                state: vpnStatus == .reasserting ? .reconnecting : .connected,
                downloadedBytes: saturatingAdd(traffic.downloadedBytes, gap.downloadedBytes),
                uploadedBytes: saturatingAdd(traffic.uploadedBytes, gap.uploadedBytes),
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: Date()
            )
            VPNSharedSessionStore.save(traffic: traffic, sessionID: descriptor.sessionID)
            VPNSharedSessionStore.save(
                checkpoint: VPNTrafficCheckpoint(
                    sessionID: descriptor.sessionID,
                    snapshot: snapshot,
                    sampledAt: traffic.sampledAt
                )
            )
        }

        VPNSharedSessionStore.save(descriptor: descriptor)
        activeStatisticsSession = ActiveStatisticsSession(
            userId: userId,
            server: server,
            protocolName: protocolName,
            descriptor: descriptor,
            accumulator: VPNTrafficAccumulator(existingTraffic: traffic),
            traffic: traffic
        )
        publishSessionMetrics(VPNSessionMetrics(descriptor: descriptor, traffic: traffic))
        startTrafficMonitoring(emitConnectedNotification: false)
    }

    func startTrafficMonitoring(emitConnectedNotification: Bool) {
        trafficMonitorTask?.cancel()
        liveActivityUpdateCounter = 0
        trafficMonitorTask = Task { [weak self] in
            guard let self else { return }
            await refreshTrafficMetricsOnce(updateLiveActivity: false)
            guard let active = activeStatisticsSession else { return }
            await liveActivityController.start(descriptor: active.descriptor, traffic: active.traffic)
            if emitConnectedNotification {
                await eventNotifier.emit(VPNNotificationPayload(
                    event: .connected,
                    descriptor: active.descriptor,
                    traffic: active.traffic
                ))
            }

            while !Task.isCancelled, vpnStatus.isConnected {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                liveActivityUpdateCounter += 1
                await refreshTrafficMetricsOnce(
                    updateLiveActivity: liveActivityUpdateCounter.isMultiple(of: 5)
                )
            }
        }
    }

    func refreshTrafficMetricsOnce(updateLiveActivity: Bool) async {
        guard let sessionID = activeStatisticsSession?.descriptor.sessionID else { return }
        let snapshot = await vpn.currentTrafficSnapshot()
            ?? (activeStatisticsSession?.protocolName == .ikev2 ? trafficSampler.currentSnapshot() : nil)
        guard let snapshot,
              var active = activeStatisticsSession,
              active.descriptor.sessionID == sessionID else { return }

        active.traffic = active.accumulator.consume(snapshot, at: Date())
        activeStatisticsSession = active
        let metrics = VPNSessionMetrics(descriptor: active.descriptor, traffic: active.traffic)
        publishSessionMetrics(metrics)
        if active.protocolName == .ikev2 {
            VPNSharedSessionStore.save(
                checkpoint: VPNTrafficCheckpoint(
                    sessionID: active.descriptor.sessionID,
                    snapshot: snapshot,
                    sampledAt: active.traffic.sampledAt
                )
            )
        }
        if updateLiveActivity {
            await liveActivityController.update(descriptor: active.descriptor, traffic: active.traffic)
        }
    }

    func publishSessionMetrics(_ metrics: VPNSessionMetrics) {
        VPNSharedSessionStore.save(descriptor: metrics.descriptor)
        let persistedTraffic = VPNSharedSessionStore.save(
            traffic: metrics.traffic,
            sessionID: metrics.descriptor.sessionID
        )
        let persistedMetrics = VPNSessionMetrics(
            descriptor: metrics.descriptor,
            traffic: persistedTraffic
        )
        sessionMetrics = persistedMetrics
        if var active = activeStatisticsSession,
           active.descriptor.sessionID == persistedMetrics.descriptor.sessionID {
            active.traffic = persistedMetrics.traffic
            activeStatisticsSession = active
        }
    }

    func persistActiveStatisticsSessionIfNeeded(
        endedAt: Date,
        notifyDisconnect: Bool = true
    ) {
        guard let activeStatisticsSession else {
            pendingStatisticsRequest = nil
            if VPNSharedSessionStore.loadDescriptor()?.isEstablished == false {
                VPNSharedSessionStore.clear()
            }
            return
        }

        trafficMonitorTask?.cancel()
        trafficMonitorTask = nil
        let finalTraffic = VPNSessionTraffic(
            state: .disconnected,
            downloadedBytes: activeStatisticsSession.traffic.downloadedBytes,
            uploadedBytes: activeStatisticsSession.traffic.uploadedBytes,
            downloadBitsPerSecond: 0,
            uploadBitsPerSecond: 0,
            sampledAt: endedAt
        )
        let finalMetrics = VPNSessionMetrics(
            descriptor: activeStatisticsSession.descriptor,
            traffic: finalTraffic
        )
        VPNSharedSessionStore.save(descriptor: finalMetrics.descriptor)
        let persistedFinalTraffic = VPNSharedSessionStore.save(
            traffic: finalMetrics.traffic,
            sessionID: finalMetrics.descriptor.sessionID
        )
        sessionMetrics = VPNSessionMetrics(
            descriptor: finalMetrics.descriptor,
            traffic: persistedFinalTraffic
        )

        if let statisticsRecorder {
            try? statisticsRecorder.record(
                sessionID: activeStatisticsSession.descriptor.sessionID,
                userId: activeStatisticsSession.userId,
                connectedAt: activeStatisticsSession.descriptor.connectedAt,
                disconnectedAt: max(endedAt, activeStatisticsSession.descriptor.connectedAt),
                server: activeStatisticsSession.server,
                protocolName: activeStatisticsSession.protocolName,
                downloadedBytes: persistedFinalTraffic.downloadedBytes,
                uploadedBytes: persistedFinalTraffic.uploadedBytes
            )
        }

        Task { [liveActivityController, eventNotifier] in
            await liveActivityController.end(
                descriptor: activeStatisticsSession.descriptor,
                traffic: persistedFinalTraffic
            )
            if notifyDisconnect {
                await eventNotifier.emit(VPNNotificationPayload(
                    event: .disconnected,
                    descriptor: activeStatisticsSession.descriptor,
                    traffic: persistedFinalTraffic
                ))
            }
        }

        VPNSharedSessionStore.clear()
        self.activeStatisticsSession = nil
        pendingStatisticsRequest = nil
    }

    func finalizeOrphanedSessionIfNeeded(endedAt: Date) {
        guard let descriptor = VPNSharedSessionStore.loadDescriptor() else { return }

        guard descriptor.isEstablished,
              let userId = session?.userId else {
            VPNSharedSessionStore.clear()
            return
        }

        let protocolName = VPNConfigurationProtocol.allCases.first(where: {
            $0.displayName.caseInsensitiveCompare(descriptor.protocolName) == .orderedSame
                || ($0 == .ikev2 && descriptor.protocolName == "IKEv2/IPSec")
        }) ?? .ikev2
        let server = serverForSession(descriptor)
        let storedTraffic = VPNSharedSessionStore.loadTraffic() ?? .zero(at: descriptor.connectedAt)
        let finalTraffic = VPNSessionTraffic(
            state: .disconnected,
            downloadedBytes: storedTraffic.downloadedBytes,
            uploadedBytes: storedTraffic.uploadedBytes,
            downloadBitsPerSecond: 0,
            uploadBitsPerSecond: 0,
            sampledAt: max(endedAt, storedTraffic.sampledAt)
        )

        if let statisticsRecorder {
            try? statisticsRecorder.record(
                sessionID: descriptor.sessionID,
                userId: userId,
                connectedAt: descriptor.connectedAt,
                disconnectedAt: max(finalTraffic.sampledAt, descriptor.connectedAt),
                server: server,
                protocolName: protocolName,
                downloadedBytes: finalTraffic.downloadedBytes,
                uploadedBytes: finalTraffic.uploadedBytes
            )
        }

        sessionMetrics = VPNSessionMetrics(descriptor: descriptor, traffic: finalTraffic)
        VPNSharedSessionStore.clear()
    }

    func serverForSession(_ descriptor: VPNSessionDescriptor) -> VPNServer {
        if let server = servers.first(where: { $0.id == descriptor.serverID }) {
            return server
        }
        return VPNServer(
            id: descriptor.serverID,
            serverName: descriptor.serverName,
            serverIp: "",
            serverHostname: nil,
            country: descriptor.country,
            city: nil,
            linkSpeed: 0,
            pricingTier: "Free",
            load: nil,
            activeConnections: nil,
            latencyPingPort: 0,
            loadDataFresh: false
        )
    }

    func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    func triggerKillSwitchNotification(for active: ActiveStatisticsSession) {
        killSwitchIncidentSessionID = active.descriptor.sessionID
        let reconnecting = VPNSessionMetrics(
            descriptor: active.descriptor,
            traffic: active.traffic
        ).replacingState(.reconnecting)
        publishSessionMetrics(reconnecting)
        Task { [liveActivityController, eventNotifier] in
            await liveActivityController.update(
                descriptor: reconnecting.descriptor,
                traffic: reconnecting.traffic
            )
            await eventNotifier.emit(VPNNotificationPayload(
                event: .killSwitch,
                descriptor: reconnecting.descriptor,
                traffic: reconnecting.traffic
            ))
        }
    }

    func makeSessionDescriptor(
        for request: VPNConnectRequest,
        connectedAt: Date,
        isEstablished: Bool = true
    ) -> VPNSessionDescriptor {
        VPNSessionDescriptor(
            sessionID: request.sessionID,
            serverID: request.server.id,
            serverName: request.server.serverName,
            country: request.server.country,
            countryFlag: request.server.flagEmoji,
            protocolName: request.protocolName == .ikev2 ? "IKEv2/IPSec" : request.protocolName.displayName,
            connectedAt: connectedAt,
            isEstablished: isEstablished,
            origin: request.origin,
            killSwitchEnabled: request.killSwitchEnabled,
            onDemandEnabled: request.onDemandEnabled
        )
    }
}

extension AppModel {
    func refreshNotificationAuthorizationStatus() async {
        await notificationService.refreshAuthorizationStatus()
        notificationAuthorizationStatus = notificationService.authorizationStatus
    }

    func requestNotificationAuthorizationIfNeeded() async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        await notificationService.requestAuthorizationIfNeeded()
        notificationAuthorizationStatus = notificationService.authorizationStatus
    }

    func openNotificationSettings() {
        notificationService.openSystemSettings()
    }
}
