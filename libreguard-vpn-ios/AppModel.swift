import Foundation
import Combine
import OSLog
import UserNotifications
import AuthenticationServices
import UIKit

enum SessionCleanupState: Equatable {
    case ending
    case requiresRetry
}

enum ServerRefreshTrigger: String {
    case automatic
    case startup
    case sceneActivation
    case dashboardAppearance
    case serverListAppearance
    case manual
    case autoConnect
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var route: AppRoute = .launching
    @Published var presentedError: APIError?
    @Published var deviceLimitContext: DeviceLimitContext?
    @Published var isAuthenticating = false
    @Published var isRefreshingAccount = false
    @Published var isRefreshingServers = false
    @Published var prefilledEmail = ""
    @Published var session: AuthSession? {
        didSet {
            if oldValue != session { sessionStateGeneration &+= 1 }
            if session != nil {
                hasCompletedUnauthenticatedCleanup = false
            }
            guard oldValue?.userId != session?.userId else { return }
            accountStateGeneration &+= 1
            appleRecoveryTask?.cancel()
            appleRecoveryTask = nil
            appleRecoveryAccountID = nil
            appleExpiredTransactionNeedsRetry = false
            unresolvedAppleTransactionIDs.removeAll()

            let previousAccountID = oldValue?.userId ?? "none"
            let currentAccountID = session?.userId ?? "none"
            logger.info(
                "Session account changed; previous=\(previousAccountID, privacy: .private(mask: .hash)), current=\(currentAccountID, privacy: .private(mask: .hash)), generation=\(String(self.accountStateGeneration), privacy: .public)"
            )

            // Account data is kept in memory while the authenticated view is
            // being replaced. Drop it immediately when a different account
            // takes over so the old tier cannot be shown while the new one is
            // being fetched.
            if oldValue?.userId != nil, session != nil {
                usageQuota = nil
                subscription = nil
                clearCachedPlan()
            }
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
    @Published private(set) var notificationPermissionNotice: String?
    @Published private(set) var connectionRecoveryRequired = false
    @Published private(set) var connectionAttemptPhase: VPNAttemptPhase?
    private var lastVPNRequest: VPNConnectRequest?
    private var hasObservedNativeStartup = false
    private var vpnRetryContext: VPNRetryContext?

    private struct VPNRetryContext {
        let errorID: UUID
        let request: VPNConnectRequest?
        let generation: UInt
        let userID: String?
        let failure: VPNConnectionFailure
    }

    var vpnRecoveryActionTitle: String? {
        guard let context = vpnRetryContext, presentedError?.id == context.errorID else { return nil }
        return context.failure.retryTitle
    }

    @Published private(set) var sessionCleanupState: SessionCleanupState?
    @Published var retryAfterSeconds = 0

    private let api: BackendServicing
    private let appleStore: AppleSubscriptionStoreServing
    private let google: GoogleSigning
    private var googleLoginID: UUID?
    private var googleLoginExpiryTask: Task<Void, Never>?
    private let openGoogleLinkingPage: () -> Void

    var isGoogleSignInConfigured: Bool { google.isConfigured }
    private let appleSignIn: AppleSigning
    private let appleCredentialStateChecker: AppleCredentialStateChecking
    private let appleCredentialBindingStore: AppleCredentialBindingStoring
    private let notificationCenter: NotificationCenter
    private let latencyProbe: LatencyProbing
    private let vpn: VPNManaging
    private let defaults: UserDefaults
    private let protocolSelectionStore: VPNProtocolSelectionStoring
    private let favoriteServerStore: FavoriteServerStoring
    private let statisticsRecorder: LocalStatisticsRecording?
    private let trafficSampler: TunnelTrafficSampling
    private let notificationService: VPNNotificationAuthorizing
    private let eventNotifier: VPNEventNotifying
    private let liveActivityController: VPNLiveActivityControlling
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "net.libreguard.libreguard-vpn-ios",
        category: "SessionLifecycle"
    )
    private let pendingRegistrationKey = "pending.registration"
    private let cachedPlanNameKey = "cached.plan.name"
    private let cachedPlanIsProKey = "cached.plan.isPro"
    private let cachedPlanUserIDKey = "cached.plan.userID"
    private let autoConnectEnabledKey = "vpn.autoConnect.enabled"
    private let killSwitchEnabledKey = "vpn.killSwitch.enabled"
    private let killSwitchActivationKey = "vpn.killSwitch.activation"
    private var cachedPlanName: String?
    private var cachedPlanIsPro = false
    private var cachedPlanUserID: String?
    private var hasCachedPlan = false
    private var accountStateGeneration: UInt = 0
    private var sessionStateGeneration: UInt = 0
    private var verifiedAppleSubscriptionRevision: UInt = 0
    private var serverRefreshGeneration: UInt = 0
    private var serverRefreshTask: Task<Void, Never>?
    private var latencyMeasurementTask: Task<[Int: Int], Never>?
    private var retryCountdownTask: Task<Void, Never>?
    private var sessionRestoreRetryTask: Task<Void, Never>?
    private var sessionRestoreRetryAttempt = 0
    private var isSessionRestoreRetryPending = false
    private var sessionCleanupTask: Task<Void, Never>?
    private var hasCompletedUnauthenticatedCleanup = false
    private var shouldShowSessionEndedMessage = false
    private var appleTransactionListenerTask: Task<Void, Never>?
    private var appleRecoveryTask: Task<Void, Never>?
    private var appleRecoveryAccountID: String?
    private var appleExpiredTransactionNeedsRetry = false
    private var unresolvedAppleTransactionIDs: Set<UInt64> = []
    private let appleVerificationRetryDelays: [UInt64]
    private var appleCredentialRevocationObserver: AnyCancellable?
    private var processingAppleTransactionIDs: Set<UInt64> = []
    private var vpnTransitionTask: Task<Void, Never>?
    private var trafficMonitorTask: Task<Void, Never>?
    private var liveActivityUpdateCounter = 0
    private var vpnTransitionGeneration: UInt = 0
    private var connectionPreflightGeneration: UInt = 0
    private var connectionPreflightTask: Task<Void, Never>?
    private var activeVPNTransition: VPNTransitionRequest?
    private var pendingStatisticsRequest: VPNConnectRequest?
    private var activeStatisticsSession: ActiveStatisticsSession?
    private var isExplicitDisconnectInProgress = false
    private var shouldRecoverStoppedProfileAfterExplicitDisconnect = false
    private var killSwitchIncidentSessionID: UUID?
    private var stoppedProfileRecoveryTask: Task<Void, Never>?
    private var stoppedProfileRecoveryGeneration: UInt = 0
    private var queuedVPNConnectRequest: VPNConnectRequest? {
        didSet {
            hasQueuedVPNReconnect = queuedVPNConnectRequest != nil
        }
    }

    private enum SessionCleanupIntent {
        case missingSession(showMessage: Bool)
        case invalidSession
        case manualSignOut

        var shouldShowSessionEndedMessage: Bool {
            switch self {
            case .invalidSession:
                true
            case let .missingSession(showMessage):
                showMessage
            case .manualSignOut:
                false
            }
        }
    }

    private enum StoppedProfileRecoveryTrigger: Equatable {
        case unexpectedDisconnect
        case lifecycleRefresh
        case explicitDisconnect
    }

    init(
        api: BackendServicing? = nil,
        appleStore: AppleSubscriptionStoreServing? = nil,
        google: GoogleSigning? = nil,
        openGoogleLinkingPage: (() -> Void)? = nil,
        appleSignIn: AppleSigning? = nil,
        appleCredentialStateChecker: AppleCredentialStateChecking? = nil,
        appleCredentialBindingStore: AppleCredentialBindingStoring? = nil,
        notificationCenter: NotificationCenter = .default,
        latencyProbe: LatencyProbing? = nil,
        vpnManager: VPNManaging? = nil,
        protocolSelectionStore: VPNProtocolSelectionStoring? = nil,
        favoriteServerStore: FavoriteServerStoring? = nil,
        statisticsRecorder: LocalStatisticsRecording? = nil,
        trafficSampler: TunnelTrafficSampling = SystemTunnelTrafficSampler(),
        notificationService: VPNNotificationAuthorizing? = nil,
        eventNotifier: VPNEventNotifying? = nil,
        liveActivityController: VPNLiveActivityControlling? = nil,
        defaults: UserDefaults = .standard,
        appleVerificationRetryDelays: [UInt64] = [0, 1, 3]
    ) {
        let resolvedAPI = api ?? APIClient()
        self.api = resolvedAPI
        self.appleStore = appleStore ?? AppleSubscriptionStore()
        self.appleVerificationRetryDelays = appleVerificationRetryDelays.isEmpty ? [0] : appleVerificationRetryDelays
        self.google = google ?? GoogleSignInService()
        self.openGoogleLinkingPage = openGoogleLinkingPage ?? {
            UIApplication.shared.open(URL(string: "https://management.libreguard.net/Identity/Account/Manage/ExternalLogins")!)
        }
        self.appleSignIn = appleSignIn ?? AppleSignInService()
        self.appleCredentialStateChecker = appleCredentialStateChecker ?? AppleCredentialStateService()
        self.appleCredentialBindingStore = appleCredentialBindingStore ?? AppleCredentialBindingStore()
        self.notificationCenter = notificationCenter
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
        let storedUserID = resolvedAPI.storedSession?.userId
        let persistedPlanUserID = defaults.string(forKey: cachedPlanUserIDKey)
        if let storedUserID, persistedPlanUserID == storedUserID {
            self.cachedPlanUserID = persistedPlanUserID
            self.cachedPlanName = defaults.string(forKey: cachedPlanNameKey)
            self.cachedPlanIsPro = defaults.object(forKey: cachedPlanIsProKey) != nil
                ? defaults.bool(forKey: cachedPlanIsProKey)
                : false
            self.hasCachedPlan = defaults.string(forKey: cachedPlanNameKey) != nil
                || defaults.object(forKey: cachedPlanIsProKey) != nil
        } else {
            // Before plan data was account-scoped these keys could leak the
            // previous user's tier across logout, relaunch, and reinstall-free
            // rebuilds. Discard unscoped or mismatched entries.
            self.cachedPlanUserID = nil
            self.cachedPlanName = nil
            self.cachedPlanIsPro = false
            self.hasCachedPlan = false
            defaults.removeObject(forKey: cachedPlanNameKey)
            defaults.removeObject(forKey: cachedPlanIsProKey)
            defaults.removeObject(forKey: cachedPlanUserIDKey)
        }
        self.vpnStatus = self.vpn.status
        self.vpn.onStatusChange = { [weak self] status in
            self?.handleVPNStatusChange(status)
        }
        self.vpn.onDisconnectError = { [weak self] error in
            guard let self else { return }
            self.finishVPNFailure(error)
        }
        self.vpn.onAttemptEvent = { [weak self] event in
            guard let self, event.attemptID == self.lastVPNRequest?.sessionID else { return }
            if let failure = event.failure { self.finishVPNFailure(failure) }
            else {
                self.connectionAttemptPhase = event.phase
                self.hasObservedNativeStartup = self.hasObservedNativeStartup || event.nativeStartupObserved
            }
        }
        self.vpn.setCertificatePreparationHandler { [weak self] message in
            Task { @MainActor [weak self] in
                self?.certificatePreparationMessage = message
            }
        }
        if let invalidationObserver = resolvedAPI as? SessionInvalidationObserving {
            invalidationObserver.onSessionInvalidated = { [weak self] in
                guard let self, self.api.storedSession == nil else { return }
                let invalidatedSession = self.session
                let generation = self.sessionStateGeneration
                let googleID = self.googleLoginID
                Task { @MainActor [weak self] in
                    guard let self, self.sessionStateGeneration == generation,
                          self.session == invalidatedSession, self.api.storedSession == nil,
                          self.googleLoginID == googleID else { return }
                    await self.beginSessionCleanup(intent: .invalidSession)
                }
            }
        }
        let cacheMatchesStoredAccount = storedUserID != nil && persistedPlanUserID == storedUserID
        logger.info(
            "Plan cache initialized; account=\((storedUserID ?? "none"), privacy: .private(mask: .hash)), cacheOwnerPresent=\(persistedPlanUserID != nil, privacy: .public), cacheMatchesAccount=\(cacheMatchesStoredAccount, privacy: .public), cachedPlanPresent=\(self.hasCachedPlan, privacy: .public), cachedIsPro=\(self.cachedPlanIsPro, privacy: .public)"
        )
    }

    func start() async {
        startAppleTransactionListener()
        startAppleCredentialRevocationObserver()
        guard case .launching = route else { return }
        let generation = sessionStateGeneration
        await refreshNotificationAuthorizationStatus()
        guard sessionStateGeneration == generation else { return }
        guard case .launching = route else { return }
        if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
            api.clearLocalSession()
            appleCredentialBindingStore.clear()
            clearCachedPlan()
            clearPendingRegistration()
            persistAutoConnectEnabled(false)
            persistKillSwitch(enabled: false, activation: .off)
            _ = await vpn.disconnectAndForget()
            await liveActivityController.endAll()
            VPNSharedSessionStore.clear()
            route = .login
            return
        }

        await vpn.refreshStatus()
        await recoverStoppedIKEv2ProfileIfNeeded(trigger: .lifecycleRefresh)
        guard sessionStateGeneration == generation else { return }
        guard case .launching = route else { return }
        logger.info("Launch VPN status=\(String(describing: self.vpnStatus), privacy: .public)")
        let mayHavePersistedVPN = vpnStatus.isConnected
            || vpnStatus.isBusy
            || isAutoConnectEnabled
            || isKillSwitchEnabled

        guard let storedSession = api.storedSession else {
            logger.info("Session restore skipped because no local session was present; vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)")
            await beginSessionCleanup(intent: .missingSession(showMessage: mayHavePersistedVPN))
            return
        }

        do {
            let restoredSession = try await api.restoreSession()
            guard sessionStateGeneration == generation else { return }
            guard case .launching = route else { return }
            guard let restoredSession else {
                guard api.storedSession == nil || api.storedSession == storedSession else { return }
                await beginSessionCleanup(intent: .invalidSession)
                return
            }
            guard api.storedSession == restoredSession else { return }
            logger.info("Session restore succeeded; vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)")
            session = restoredSession
            guard await checkAppleCredentialStateIfNeeded(), session == restoredSession,
                  api.storedSession == restoredSession else { return }
            await finishAuthenticatedStartup()
        } catch is CancellationError {
            return
        } catch let error as APIError where error.code == "APP_VERSION_BLOCKED" || error.code == "APP_VERSION_REQUIRED" {
            guard sessionStateGeneration == generation, case .launching = route,
                  api.storedSession == nil || api.storedSession == storedSession else { return }
            logger.error("Session restore was blocked by the app version; vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)")
            presentedError = error
            await beginSessionCleanup(intent: .missingSession(showMessage: false))
        } catch let error as APIError where isAuthenticationFailure(error) {
            guard sessionStateGeneration == generation, case .launching = route,
                  api.storedSession == nil || api.storedSession == storedSession else { return }
            logger.info("Session restore was rejected by authentication; vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)")
            await beginSessionCleanup(intent: .invalidSession)
        } catch {
            guard sessionStateGeneration == generation, case .launching = route,
                  api.storedSession == storedSession else { return }
            // Keep the same account visible during a temporary service outage.
            logger.info("Session restore deferred after a transient failure; vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)")
            session = storedSession
            guard await checkAppleCredentialStateIfNeeded(), session == storedSession,
                  api.storedSession == storedSession else { return }
            await continueWithCachedSessionAfterTransientRestoreFailure()
            guard session == storedSession, api.storedSession == storedSession else { return }
            scheduleSessionRestoreRetry()
        }
    }

    /// Re-checks a session that was kept in memory after a temporary startup
    /// failure. It is deliberately public to the scene lifecycle, but is a
    /// no-op unless a retry is pending.
    func retrySessionValidationIfNeeded() async {
        guard isSessionRestoreRetryPending,
              sessionCleanupTask == nil,
              case .authenticated = route,
              let cachedSession = session ?? api.storedSession else { return }
        let generation = sessionStateGeneration
        let storedSnapshot = api.storedSession

        sessionRestoreRetryTask?.cancel()
        sessionRestoreRetryTask = nil

        do {
            let restoredSession = try await api.restoreSession()
            guard sessionStateGeneration == generation, session == cachedSession,
                  case .authenticated = route else { return }
            guard let restoredSession else {
                guard api.storedSession == nil || api.storedSession == storedSnapshot else { return }
                await beginSessionCleanup(intent: .invalidSession)
                return
            }
            guard api.storedSession == restoredSession else { return }
            logger.info("Deferred session validation succeeded; vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)")
            session = restoredSession
            guard await checkAppleCredentialStateIfNeeded(), session == restoredSession,
                  api.storedSession == restoredSession else { return }
            cancelSessionRestoreRetry()
            await finishAuthenticatedStartup()
        } catch is CancellationError {
            return
        } catch let error as APIError where isAuthenticationFailure(error) {
            guard sessionStateGeneration == generation, session == cachedSession,
                  api.storedSession == nil || api.storedSession == storedSnapshot,
                  case .authenticated = route else { return }
            logger.info("Deferred session validation was rejected by authentication; vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)")
            await beginSessionCleanup(intent: .invalidSession)
        } catch {
            guard sessionStateGeneration == generation, session == cachedSession,
                  api.storedSession == storedSnapshot, case .authenticated = route else { return }
            scheduleSessionRestoreRetry()
        }
    }

    func retrySessionCleanup() async {
        guard sessionCleanupState == .requiresRetry else { return }
        await beginSessionCleanup(intent: .missingSession(showMessage: shouldShowSessionEndedMessage))
    }

    private func finishAuthenticatedStartup() async {
        guard sessionCleanupTask == nil, let activeSession = session else { return }
        let generation = sessionStateGeneration

        route = .authenticated
        sessionCleanupState = nil
        cancelSessionRestoreRetry()
        await refreshAccountData(showErrors: false)
        guard sessionCleanupTask == nil, sessionStateGeneration == generation,
              session == activeSession, api.storedSession == activeSession else { return }

        await ensureAppleRecovery()
        guard sessionCleanupTask == nil, sessionStateGeneration == generation,
              session == activeSession, api.storedSession == activeSession else { return }

        if vpnStatus.isConnected {
            refreshServers(trigger: .startup)
            await serverRefreshTask?.value
            guard sessionCleanupTask == nil, sessionStateGeneration == generation,
                  session == activeSession, api.storedSession == activeSession else { return }
            await restoreActiveSessionIfNeeded()
        } else {
            await liveActivityController.endAll()
            guard sessionCleanupTask == nil, sessionStateGeneration == generation,
                  session == activeSession, api.storedSession == activeSession else { return }
            finalizeOrphanedSessionIfNeeded(endedAt: Date())
        }
        guard sessionCleanupTask == nil, sessionStateGeneration == generation,
              session == activeSession, api.storedSession == activeSession else { return }

        await reconcileKillSwitchOnLaunch()
        guard sessionCleanupTask == nil, sessionStateGeneration == generation,
              session == activeSession, api.storedSession == activeSession else { return }
        await reconcileAutoConnectOnLaunch()
    }

    private func continueWithCachedSessionAfterTransientRestoreFailure() async {
        guard sessionCleanupTask == nil, let activeSession = session else { return }
        let generation = sessionStateGeneration

        route = .authenticated
        sessionCleanupState = nil
        if vpnStatus.isConnected {
            refreshServers(trigger: .startup)
            await serverRefreshTask?.value
            guard sessionCleanupTask == nil, sessionStateGeneration == generation,
                  session == activeSession, api.storedSession == activeSession else { return }
            await restoreActiveSessionIfNeeded()
        } else {
            finalizeOrphanedSessionIfNeeded(endedAt: Date())
        }
        guard sessionCleanupTask == nil, sessionStateGeneration == generation,
              session == activeSession, api.storedSession == activeSession else { return }
        await reconcileKillSwitchOnLaunch()
    }

    private func scheduleSessionRestoreRetry() {
        guard sessionCleanupTask == nil,
              session != nil,
              case .authenticated = route else { return }

        sessionRestoreRetryTask?.cancel()
        isSessionRestoreRetryPending = true
        let retryDelays = [2, 4, 8, 16, 30]
        let delay = retryDelays[min(sessionRestoreRetryAttempt, retryDelays.count - 1)]
        sessionRestoreRetryAttempt += 1

        sessionRestoreRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.sessionRestoreRetryTask = nil
            await self.retrySessionValidationIfNeeded()
        }
    }

    private func cancelSessionRestoreRetry() {
        sessionRestoreRetryTask?.cancel()
        sessionRestoreRetryTask = nil
        sessionRestoreRetryAttempt = 0
        isSessionRestoreRetryPending = false
    }

    private func beginSessionCleanup(intent: SessionCleanupIntent) async {
        // `APIClient` can invoke its invalidation callback just after startup
        // has handled the same failed refresh. Once the profile was safely
        // cleaned up, that late callback must be a no-op rather than briefly
        // showing the blocker a second time.
        guard !hasCompletedUnauthenticatedCleanup else { return }

        if intent.shouldShowSessionEndedMessage {
            shouldShowSessionEndedMessage = true
        }
        if let task = sessionCleanupTask {
            await task.value
            return
        }

        cancelSessionRestoreRetry()
        sessionCleanupState = .ending
        route = .sessionCleanup
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSessionCleanup()
        }
        sessionCleanupTask = task
        await task.value
    }

    private func performSessionCleanup() async {
        isExplicitDisconnectInProgress = true
        await refreshTrafficMetricsOnce(updateLiveActivity: true)
        cancelActiveVPNTransition()
        persistAutoConnectEnabled(false)
        persistKillSwitch(enabled: false, activation: .off)

        let cleanupResult = await vpn.disconnectAndForget()
        logger.info("Unauthenticated VPN cleanup finished stopped=\(cleanupResult.tunnelStopped, privacy: .public) onDemandDisabled=\(cleanupResult.onDemandDisabled, privacy: .public) removed=\(cleanupResult.profileRemoved, privacy: .public)")

        guard cleanupResult.isSafeForUnauthenticatedLogin else {
            sessionCleanupState = .requiresRetry
            sessionCleanupTask = nil
            return
        }

        await liveActivityController.endAll()
        persistActiveStatisticsSessionIfNeeded(endedAt: Date(), notifyDisconnect: true)
        clearSessionState(route: nil)
        hasCompletedUnauthenticatedCleanup = true
        sessionCleanupState = nil
        sessionCleanupTask = nil

        if let pending = loadPendingRegistration() {
            prefilledEmail = pending.email
            route = .emailConfirmation(pending)
        } else {
            route = .login
        }

        if shouldShowSessionEndedMessage {
            presentedError = APIError(
                message: "Your sign-in session ended. Auto-Connect was turned off and the VPN was disconnected.",
                code: "SESSION_ENDED"
            )
        }
        shouldShowSessionEndedMessage = false
    }

    func showLogin(prefill email: String? = nil) {
        guard sessionCleanupState == nil else { return }
        cancelGoogleLogin()
        if let email { prefilledEmail = email }
        route = .login
    }

    func showRegister() {
        guard sessionCleanupState == nil else { return }
        cancelGoogleLogin()
        route = .register
    }

    func showForgotPassword() {
        guard sessionCleanupState == nil else { return }
        cancelGoogleLogin()
        route = .forgotPassword
    }

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
        guard !isAuthenticating, sessionCleanupState == nil else { return }
        cancelGoogleLogin()
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
        guard !isAuthenticating, sessionCleanupState == nil else { return }
        guard google.isConfigured else {
            presentedError = APIError(message: "Google sign-in is not configured for this build.")
            return
        }
        cancelGoogleLogin()
        let id = UUID()
        googleLoginID = id
        presentedError = nil
        isAuthenticating = true
        defer { if googleLoginID == id { isAuthenticating = false } }
        do {
            let begin = try await api.beginGoogleLogin(newsletterConsent: newsletterConsent)
            guard googleLoginID == id else { return }
            guard begin.expiresAt > Date(), begin.expiresAt.timeIntervalSinceNow <= 660 else {
                throw APIError(message: "Google sign-in expired. Start again.", code: "GOOGLE_LOGIN_EXPIRED")
            }
            scheduleGoogleExpiry(begin.expiresAt, id: id)
            let authorization = try await google.signIn(attempt: begin)
            guard googleLoginID == id, begin.expiresAt > Date() else { return }
            let response = try await api.completeGoogleLogin(attempt: begin, authorization: authorization)
            guard googleLoginID == id else { return }
            try await handleLogin(response, attempt: .google, afterTwoFactor: false)
        } catch is CancellationError {
            if googleLoginID == id { cancelGoogleLogin() }
        } catch {
            guard googleLoginID == id else { return }
            handle(error, attempt: .google, afterTwoFactor: false)
        }
    }

    func cancelGoogleLogin() {
        googleLoginID = nil
        googleLoginExpiryTask?.cancel()
        googleLoginExpiryTask = nil
        google.signOut()
        if case let .twoFactor(challenge) = route, case .google = challenge.attempt {
            route = .login
        }
        if let context = deviceLimitContext, case .google = context.attempt {
            deviceLimitContext = nil
        }
        isAuthenticating = false
    }

    private func scheduleGoogleExpiry(_ expiresAt: Date, id: UUID) {
        googleLoginExpiryTask?.cancel()
        googleLoginExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, expiresAt.timeIntervalSinceNow) * 1_000_000_000))
            } catch { return }
            guard let self, self.googleLoginID == id else { return }
            self.cancelGoogleLogin()
            self.route = .login
            self.presentedError = APIError(message: "Google sign-in expired. Start again.", code: "GOOGLE_LOGIN_EXPIRED")
        }
    }

    func prepareAppleSignIn(_ request: ASAuthorizationAppleIDRequest) {
        guard !isAuthenticating, sessionCleanupState == nil else { return }
        cancelGoogleLogin()
        presentedError = nil
        isAuthenticating = true
        appleSignIn.prepare(request)
    }

    func completeAppleSignIn(
        _ result: Result<ASAuthorization, Error>,
        newsletterConsent: Bool? = nil
    ) async {
        defer { isAuthenticating = false }
        do {
            let credential = try appleSignIn.credential(from: result)
            let attempt = LoginAttempt.apple(
                idToken: credential.idToken,
                nonce: credential.nonce,
                newsletterConsent: newsletterConsent,
                userIdentifier: credential.userIdentifier
            )
            do {
                let response = try await api.loginWithApple(
                    idToken: credential.idToken,
                    nonce: credential.nonce,
                    newsletterConsent: newsletterConsent
                )
                try await handleLogin(response, attempt: attempt, afterTwoFactor: false)
            } catch {
                handle(error, attempt: attempt, afterTwoFactor: false)
            }
        } catch where Self.isAppleSignInCancellation(error) {
            // Cancellation is a normal outcome of the system account sheet.
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
            guard sessionCleanupState == nil else { return }
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
        guard !isAuthenticating, retryAfterSeconds == 0, sessionCleanupState == nil else { return }
        if case .google = challenge.attempt {
            guard googleLoginID != nil, case let .twoFactor(active) = route, active.id == challenge.id else { return }
        }
        let googleID = googleLoginID
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentedError = APIError(message: recovery ? "Enter a recovery code." : "Enter your authenticator code.")
            return
        }
        isAuthenticating = true
        defer {
            if case .google = challenge.attempt {
                if googleLoginID == googleID { isAuthenticating = false }
            } else { isAuthenticating = false }
        }
        do {
            let response = recovery
                ? try await api.verifyRecoveryCode(challenge, code: code)
                : try await api.verifyTwoFactor(challenge, code: code)
            if case .google = challenge.attempt, googleLoginID != googleID { return }
            try await handleLogin(response, attempt: challenge.attempt, afterTwoFactor: true)
        } catch {
            if case .google = challenge.attempt {
                guard googleLoginID == googleID else { return }
                if let failure = error as? APIError,
                   ["INVALID_TWO_FACTOR_CODE", "INVALID_RECOVERY_CODE", "RATE_LIMIT_EXCEEDED", "SECURITY_CONTROL_UNAVAILABLE"].contains(failure.code ?? "") {
                    if let delay = failure.retryAfterSeconds, delay > 0 { beginRetryCountdown(delay) }
                    presentedError = failure
                    return
                }
            }
            handle(error, attempt: challenge.attempt, afterTwoFactor: true)
        }
    }

    func removeDeviceAndRetry(_ device: AccountDevice, context: DeviceLimitContext) async {
        guard context.canRemoveInApp, retryAfterSeconds == 0, !isAuthenticating else { return }
        let googleID = googleLoginID
        isAuthenticating = true
        defer {
            if case .google = context.attempt {
                if googleLoginID == googleID { isAuthenticating = false }
            } else { isAuthenticating = false }
        }
        do {
            switch context.attempt {
            case let .password(email, password):
                try await api.removePasswordDevice(email: email, password: password, deviceId: device.id)
                deviceLimitContext = nil
                let response = try await api.login(email: email, password: password)
                try await handleLogin(response, attempt: context.attempt, afterTwoFactor: false)
            case .google:
                guard let token = context.response.loginContinuationToken,
                      googleID != nil, deviceLimitContext?.id == context.id else { return }
                // The capability is single use. Drop it before the request; a lost
                // response requires a fresh interactive login, never a retry.
                deviceLimitContext = nil
                let response = try await api.continueGoogleLogin(token: token, deviceIdsToRemove: [device.id])
                guard googleLoginID == googleID else { return }
                try await handleLogin(response, attempt: .google, afterTwoFactor: context.afterTwoFactor)
            case let .apple(idToken, nonce, newsletterConsent, _):
                try await api.removeAppleDevice(idToken: idToken, nonce: nonce, deviceId: device.id)
                deviceLimitContext = nil
                let response = try await api.loginWithApple(
                    idToken: idToken,
                    nonce: nonce,
                    newsletterConsent: newsletterConsent
                )
                try await handleLogin(response, attempt: context.attempt, afterTwoFactor: false)
            }
        } catch {
            if case .google = context.attempt {
                guard googleLoginID == googleID else { return }
                handle(error, attempt: .google, afterTwoFactor: context.afterTwoFactor)
            } else {
                present(error)
            }
        }
    }

    func refreshAccountData(showErrors: Bool = true) async {
        guard let accountUserID = (session ?? api.storedSession)?.userId else { return }
        guard !isRefreshingAccount else { return }
        let refreshGeneration = accountStateGeneration
        let subscriptionRevision = verifiedAppleSubscriptionRevision
        logger.info(
            "Account refresh started; account=\(accountUserID, privacy: .private(mask: .hash)), generation=\(String(refreshGeneration), privacy: .public)"
        )
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

        // A refresh may have started for the previous account and completed
        // after logout/login switched the session. Its results must never be
        // allowed to overwrite the current account's tier or other account
        // state.
        let currentAccountUserID = (session ?? api.storedSession)?.userId
        guard accountStateGeneration == refreshGeneration,
              currentAccountUserID == accountUserID else {
            logger.warning(
                "Account refresh discarded as stale; requestedAccount=\(accountUserID, privacy: .private(mask: .hash)), currentAccount=\((currentAccountUserID ?? "none"), privacy: .private(mask: .hash)), requestedGeneration=\(String(refreshGeneration), privacy: .public), currentGeneration=\(String(self.accountStateGeneration), privacy: .public)"
            )
            return
        }

        var firstError: Error?

        switch usage {
        case let .success(value):
            usageQuota = value
        case let .failure(error):
            firstError = error
        }

        switch subscription {
        case let .success(value):
            if verifiedAppleSubscriptionRevision == subscriptionRevision {
                self.subscription = value
                cachePlan(name: value.displayName, isPro: value.isPro)
                logger.info(
                    "Subscription refresh applied; account=\(accountUserID, privacy: .private(mask: .hash)), plan=\(value.displayName, privacy: .public), isPro=\(value.isPro, privacy: .public)"
                )
            } else {
                logger.info("Discarded subscription refresh that started before Apple purchase verification completed")
            }
        case let .failure(error):
            logger.error(
                "Subscription refresh failed; account=\(accountUserID, privacy: .private(mask: .hash)), error=\(String(describing: error), privacy: .public)"
            )
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
            logApplePurchaseFailure(error, stage: "loading subscription plans")
            applePurchaseMessage = "Subscription plans could not be loaded. Check your connection and retry."
        }
    }

    func purchaseSelectedAppleSubscription() async {
        guard let accountUserID = session?.userId,
              !isPurchasingAppleSubscription, !isRestoringApplePurchases else { return }
        let generation = accountStateGeneration
        isPurchasingAppleSubscription = true
        applePurchaseMessage = nil
        defer { isPurchasingAppleSubscription = false }

        var stage = "recovering previous purchases"
        do {
            await ensureAppleRecovery()
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            if appleExpiredTransactionNeedsRetry {
                appleExpiredTransactionNeedsRetry = false
                applePurchaseMessage = "This previous Apple subscription has expired. Select Subscribe again to start a new purchase."
                return
            }
            if !unresolvedAppleTransactionIDs.isEmpty {
                applePurchaseMessage = "A previous Apple purchase has not been confirmed yet. Retry Restore Purchases before subscribing again."
                return
            }
            if pendingAppleSubscriptionTransfer != nil {
                applePurchaseMessage = "Confirm or cancel the existing Apple subscription transfer before subscribing."
                return
            }
            guard appleStore.canMakePayments else {
                applePurchaseMessage = "Purchases are not available for this Apple Account right now."
                return
            }
            guard appleSubscriptionProducts.contains(where: { $0.id == selectedAppleProductID }) else {
                applePurchaseMessage = "This subscription plan is unavailable. Retry loading plans."
                return
            }

            stage = "checking existing Apple subscriptions"
            let existing = (await appleStore.currentEntitlements()).filter(isLibreGuardAppleUpdate)
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            if !existing.isEmpty {
                for update in existing {
                    guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                    await processAppleUpdate(update)
                    if pendingAppleSubscriptionTransfer != nil { return }
                }
                guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                let currentStatus = try? await api.fetchSubscription()
                guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                if let currentStatus {
                    subscription = currentStatus
                    cachePlan(name: currentStatus.displayName, isPro: currentStatus.isPro)
                }
                applePurchaseMessage = currentStatus?.isPro == true
                    ? "Pro is already active on this account. Manage or restore your Apple subscription."
                    : "An existing Apple subscription could not be confirmed with LibreGuard. Restore it before purchasing another plan."
                return
            }

            stage = "checking LibreGuard subscription status"
            let currentStatus = try await api.fetchSubscription()
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            subscription = currentStatus
            cachePlan(name: currentStatus.displayName, isPro: currentStatus.isPro)
            if currentStatus.isPro {
                applePurchaseMessage = "Pro is already active on this account. Manage or restore your subscription."
                return
            }

            stage = "reading the StoreKit environment"
            let environment = try await appleStore.purchaseEnvironment()
            guard environment != .xcode else { throw AppleStoreError.unsupportedEnvironment }
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            stage = "requesting the Apple account token"
            let accountToken = try await api.fetchAppleAccountToken(environment: environment)
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            stage = "starting the StoreKit purchase"
            switch try await appleStore.purchase(productID: selectedAppleProductID, appAccountToken: accountToken) {
            case let .success(transaction):
                guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                await processAppleTransaction(transaction, allowTransfer: false)
            case .pending:
                guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                applePurchaseMessage = "Your purchase is pending approval. Pro will activate automatically after the App Store completes it."
            case .userCancelled:
                guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                applePurchaseMessage = "Purchase cancelled."
            }
        } catch {
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            logApplePurchaseFailure(error, stage: stage)
            if let apiError = error as? APIError, isAuthenticationFailure(apiError) {
                present(error)
            } else {
                applePurchaseMessage = applePurchaseErrorMessage(error)
            }
        }
    }

    func restoreApplePurchases() async {
        guard let accountUserID = session?.userId,
              !isRestoringApplePurchases, !isPurchasingAppleSubscription else { return }
        let generation = accountStateGeneration
        isRestoringApplePurchases = true
        applePurchaseMessage = nil
        defer { isRestoringApplePurchases = false }

        do {
            try await appleStore.sync()
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            let current = await appleStore.currentEntitlements()
            let unfinished = await appleStore.unfinishedTransactions()
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            var seenIDs = Set<UInt64>()
            let eligible = (current + unfinished).filter { update in
                guard isLibreGuardAppleUpdate(update) else { return false }
                if case let .verified(transaction) = update {
                    return seenIDs.insert(transaction.id).inserted
                }
                return true
            }
            guard !eligible.isEmpty else {
                let currentStatus = try? await api.fetchSubscription()
                guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                if let currentStatus {
                    subscription = currentStatus
                    cachePlan(name: currentStatus.displayName, isPro: currentStatus.isPro)
                }
                applePurchaseMessage = currentStatus?.isPro == true
                    ? "Pro is active on this LibreGuard account. There is no iOS App Store purchase to restore for this Apple Account."
                    : "No active iOS App Store subscription was found for this Apple Account."
                return
            }
            for update in eligible {
                guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
                await processAppleUpdate(update)
                if pendingAppleSubscriptionTransfer != nil { break }
            }
        } catch {
            guard isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            logApplePurchaseFailure(error, stage: "restoring Apple purchases")
            applePurchaseMessage = "Purchases could not be restored. Check your connection and try again."
        }
    }

    func confirmAppleSubscriptionTransfer(_ transaction: AppleStoreTransaction) async {
        isRestoringApplePurchases = true
        defer { isRestoringApplePurchases = false }
        pendingAppleSubscriptionTransfer = nil
        await processAppleTransaction(transaction, allowTransfer: true)
    }

    func cancelAppleSubscriptionTransfer() {
        pendingAppleSubscriptionTransfer = nil
        applePurchaseMessage = "The Apple subscription remains linked to its previous LibreGuard account."
    }

    func refreshServers(trigger: ServerRefreshTrigger = .automatic) {
        guard !isRefreshingServers else {
            logger.debug("Server refresh coalesced; trigger=\(trigger.rawValue, privacy: .public)")
            return
        }

        serverRefreshGeneration &+= 1
        let generation = serverRefreshGeneration
        let accountGeneration = accountStateGeneration
        let startedAt = DispatchTime.now().uptimeNanoseconds
        isRefreshingServers = true
        logger.debug(
            "Server refresh started; trigger=\(trigger.rawValue, privacy: .public), vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)"
        )

        serverRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.serverRefreshGeneration == generation {
                    self.latencyMeasurementTask = nil
                    self.isRefreshingServers = false
                    let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                    self.logger.debug(
                        "Server refresh finished; trigger=\(trigger.rawValue, privacy: .public), elapsedMs=\(Int((Double(elapsed) / 1_000_000).rounded()), privacy: .public)"
                    )
                }
            }

            do {
                let fetched = try await self.api.fetchServers()
                guard self.isCurrentServerRefresh(
                    generation: generation,
                    accountGeneration: accountGeneration
                ) else { return }

                self.servers = fetched
                let serverIDs = Set(fetched.map(\.id))
                self.serverLatencies = self.serverLatencies.filter { serverIDs.contains($0.key) }
                if let selectedServerID = self.selectedServerID,
                   !serverIDs.contains(selectedServerID) {
                    self.selectedServerID = nil
                }

                guard self.canMeasureServerLatencies else {
                    self.logger.debug(
                        "Server latency skipped; trigger=\(trigger.rawValue, privacy: .public), vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)"
                    )
                    return
                }

                let latencyTask = Task { @MainActor [latencyProbe = self.latencyProbe] in
                    await latencyProbe.measure(fetched)
                }
                self.latencyMeasurementTask = latencyTask
                let measuredLatencies = await latencyTask.value

                guard self.isCurrentServerRefresh(
                    generation: generation,
                    accountGeneration: accountGeneration
                ), self.canMeasureServerLatencies else {
                    self.logger.debug(
                        "Server latency result discarded; trigger=\(trigger.rawValue, privacy: .public), vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)"
                    )
                    return
                }

                self.serverLatencies = measuredLatencies
                self.logger.debug(
                    "Server latency measured; trigger=\(trigger.rawValue, privacy: .public), serverCount=\(fetched.count, privacy: .public), resultCount=\(measuredLatencies.count, privacy: .public)"
                )
            } catch is CancellationError {
                self.logger.debug("Server refresh cancelled; trigger=\(trigger.rawValue, privacy: .public)")
            } catch {
                guard self.isCurrentServerRefresh(
                    generation: generation,
                    accountGeneration: accountGeneration
                ) else { return }
                self.present(error)
            }
        }
    }

    private var canMeasureServerLatencies: Bool {
        vpnStatus == .disconnected || vpnStatus == .invalid
    }

    private func isCurrentServerRefresh(generation: UInt, accountGeneration: UInt) -> Bool {
        generation == serverRefreshGeneration
            && accountGeneration == accountStateGeneration
            && !Task.isCancelled
    }

    private func cancelLatencyMeasurement(reason: String) {
        guard let task = latencyMeasurementTask else { return }
        task.cancel()
        latencyMeasurementTask = nil
        logger.debug(
            "Server latency measurement cancelled; reason=\(reason, privacy: .public), vpnStatus=\(String(describing: self.vpnStatus), privacy: .public)"
        )
    }

    func setAutoConnectEnabled(_ enabled: Bool) async {
        guard enabled != isAutoConnectEnabled, !isUpdatingAutoConnect else { return }
        if enabled, !isProUser {
            logger.info("Auto-Connect upgrade requested while current account is not Pro")
            upgradePromptRequested = true
            return
        }
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
                    refreshServers(trigger: .autoConnect)
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
            upgradePromptRequested = true
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
            upgradePromptRequested = true
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
        await recoverStoppedIKEv2ProfileIfNeeded(trigger: .lifecycleRefresh)
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
        // Remote logout is best effort. Never leave a locally active tunnel
        // up while waiting for it to finish.
        async let remoteLogout: Void = api.logout()
        cancelGoogleLogin()
        await beginSessionCleanup(intent: .manualSignOut)
        await remoteLogout
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
                requestUpgrade()
                presentedError = APIError(message: "OpenVPN requires a Pro plan.")
            }
            return
        }
        vpnRetryContext = nil
        selectedVPNProtocol = protocolName
        protocolSelectionStore.selectedProtocol = protocolName
    }

    func requestConnectionToSelectedServer() {
        guard let server = selectedServer else {
            requestQuickConnect()
            return
        }
        guard canUse(server: server) else {
            upgradePromptRequested = true
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
    }

    func consumeUpgradePrompt() {
        upgradePromptRequested = false
    }

    func requestUpgrade() {
        logger.info("Upgrade screen requested; isPro=\(self.isProUser, privacy: .public)")
        upgradePromptRequested = true
    }

    func dismissUpgrade() {
        upgradePromptRequested = false
    }

    func handleOpenVPNSelection() {
        let entitled = isOpenVPNAvailable
        logger.info("OpenVPN selection tapped; isEntitled=\(entitled, privacy: .public), isPro=\(self.isProUser, privacy: .public)")
        if entitled {
            selectVPNProtocol(.openVPN)
        } else {
            requestUpgrade()
        }
    }

    func requestVPNDisconnect(bypassingKillSwitchConfirmation: Bool = false) {
        if isKillSwitchEnabled, !bypassingKillSwitchConfirmation,
           vpnStatus != .disconnected, vpnStatus != .invalid {
            isKillSwitchDisconnectConfirmationPresented = true
            return
        }
        cancelConnectionPreflight()
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
        guard sessionCleanupState == nil else { return }
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
        guard sessionCleanupState == nil else { return }
        if response.requiresTwoFactor == true {
            guard let pendingToken = response.pendingLoginToken,
                  let email = response.email else {
                throw APIError(message: "The server did not return a valid two-factor challenge.")
            }
            route = .twoFactor(TwoFactorChallenge(email: email, pendingLoginToken: pendingToken, attempt: attempt))
            return
        }
        let adoptedSession = try api.adoptSession(from: response)
        do {
            switch attempt {
            case let .apple(_, _, _, userIdentifier):
                try appleCredentialBindingStore.save(AppleCredentialBinding(
                    userIdentifier: userIdentifier,
                    backendUserId: adoptedSession.userId
                ))
            case .password, .google:
                appleCredentialBindingStore.clear()
            }
        } catch {
            api.clearLocalSession()
            appleCredentialBindingStore.clear()
            throw APIError(
                message: "Your Apple credential could not be stored securely. Please try again.",
                code: "SECURE_STORAGE_FAILED"
            )
        }
        if case .google = attempt { cancelGoogleLogin() }
        session = adoptedSession
        logger.info(
            "Login adopted account=\(adoptedSession.userId, privacy: .private(mask: .hash)), responsePlanPresent=\(response.planTier != nil, privacy: .public), responsePlan=\((response.planTier?.rawValue ?? "none"), privacy: .public), generation=\(String(self.accountStateGeneration), privacy: .public)"
        )
        if let planTier = response.planTier {
            cachePlan(name: planTier.rawValue, isPro: planTier.isPro)
        }
        clearPendingRegistration()
        deviceLimitContext = nil
        route = .authenticated
        await refreshAccountData(showErrors: false)
        await ensureAppleRecovery()
        if response.warningRecoveryCodes == true {
            presentedError = APIError(message: "A recovery code was used. Generate a new set from Settings.")
        }
    }

    private func handle(_ error: Error, attempt: LoginAttempt, afterTwoFactor: Bool) {
        if let apiError = error as? APIError, let limit = apiError.deviceLimit {
            if case .google = attempt {
                guard let id = googleLoginID, let token = limit.loginContinuationToken, !token.isEmpty,
                      let expiresAt = limit.loginContinuationExpiresAt, expiresAt > Date(),
                      expiresAt.timeIntervalSinceNow <= 660 else {
                    cancelGoogleLogin()
                    route = .login
                    presentedError = APIError(message: "Google sign-in must be restarted.", code: "GOOGLE_LOGIN_EXPIRED")
                    return
                }
                scheduleGoogleExpiry(expiresAt, id: id)
            }
            deviceLimitContext = DeviceLimitContext(response: limit, attempt: attempt, afterTwoFactor: afterTwoFactor)
            return
        }
        if case .google = attempt {
            cancelGoogleLogin()
            route = .login
            if let apiError = error as? APIError, apiError.code == "GOOGLE_LINK_REQUIRED" {
                openGoogleLinkingPage()
                presentedError = APIError(message: "Sign in to your existing LibreGuard account on the management website, link Google, then try Google sign-in again.", code: "GOOGLE_LINK_REQUIRED")
                return
            }
            if error is CancellationError { return }
            if let failure = error as? APIError {
                if let delay = failure.retryAfterSeconds, delay > 0 { beginRetryCountdown(delay) }
                presentedError = failure
            } else {
                presentedError = APIError(message: "Google sign-in failed. Start again.")
            }
            return
        }
        if let apiError = error as? APIError, apiError.code == "EMAIL_NOT_VERIFIED" {
            presentedError = apiError
            return
        }
        present(error)
    }

    private func finishVPNFailure(_ error: Error) {
        if error is CancellationError { return }
        if let failure = error as? VPNConnectionFailure {
            let retryRequest = queuedVPNConnectRequest ?? lastVPNRequest
            if failure.kind != .protectedSwitch {
                activeVPNTransition = nil
                queuedVPNConnectRequest = nil
                pendingStatisticsRequest = nil
                connectionAttemptPhase = nil
                connectionRecoveryRequired = failure.kind == .stopFailed || vpn.status.isBusy
                handleVPNStatusChange(vpn.status)
                // A terminal status alone cannot clear an unverified cleanup failure.
                if failure.kind == .stopFailed { connectionRecoveryRequired = true }
            }
            let shown = APIError(message: failure.localizedDescription, code: "VPN_" + failure.kind.rawValue.uppercased())
            presentedError = shown
            if failure.retryTitle != nil, retryRequest != nil || failure.kind == .stopFailed {
                vpnRetryContext = VPNRetryContext(errorID: shown.id, request: retryRequest,
                    generation: vpnTransitionGeneration, userID: session?.userId, failure: failure)
            } else { vpnRetryContext = nil }
        } else {
            activeVPNTransition = nil
            pendingStatisticsRequest = nil
            handleVPNStatusChange(vpn.status)
            present(error)
        }
    }

    func retryVPNSetup(errorID: UUID) {
        guard let context = vpnRetryContext, context.errorID == errorID,
              context.generation == vpnTransitionGeneration,
              context.userID == session?.userId, sessionCleanupState == nil else { return }
        vpnRetryContext = nil
        presentedError = nil
        guard let failedRequest = context.request else {
            beginDisconnect(preservingQueuedConnection: false)
            return
        }
        let request = VPNConnectRequest(server: failedRequest.server, protocolName: failedRequest.protocolName,
            onDemandEnabled: currentConnectionPolicy().onDemandEnabled,
            killSwitchEnabled: isKillSwitchEnabled, origin: .manual)
        startConnection(request)
    }

    func retryVPNRecovery() {
        guard let context = vpnRetryContext else { return }
        retryVPNSetup(errorID: context.errorID)
    }

    private func present(_ error: Error) {
        if error is CancellationError { return }
        if let apiError = error as? APIError {
            if isAuthenticationFailure(apiError) {
                forceSignOut()
                return
            }
            if let retryAfter = apiError.retryAfterSeconds, retryAfter > 0 {
                beginRetryCountdown(retryAfter)
            }
            presentedError = apiError
        } else {
            presentedError = APIError(message: error.localizedDescription)
        }
    }

    private static func isAppleSignInCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == ASAuthorizationError.errorDomain
            && error.code == ASAuthorizationError.canceled.rawValue
    }

    private func forceSignOut() {
        let generation = sessionStateGeneration
        let currentSession = session
        let storedSnapshot = api.storedSession
        let googleID = googleLoginID
        Task { @MainActor [weak self] in
            guard let self, self.sessionStateGeneration == generation,
                  self.session == currentSession, self.api.storedSession == storedSnapshot,
                  self.googleLoginID == googleID else { return }
            await self.beginSessionCleanup(intent: .invalidSession)
        }
    }

    private func clearSessionState(route nextRoute: AppRoute? = .login) {
        cancelGoogleLogin()
        let previousAccountID = (session ?? api.storedSession)?.userId ?? "none"
        logger.info(
            "Clearing local account state; account=\(previousAccountID, privacy: .private(mask: .hash)), hasNextRoute=\(nextRoute != nil, privacy: .public)"
        )
        serverRefreshGeneration &+= 1
        serverRefreshTask?.cancel()
        cancelLatencyMeasurement(reason: "sessionCleared")
        retryCountdownTask?.cancel()
        cancelSessionRestoreRetry()
        cancelActiveVPNTransition()
        serverRefreshTask = nil
        retryCountdownTask = nil
        trafficMonitorTask?.cancel()
        trafficMonitorTask = nil
        clearCachedPlan()
        api.clearLocalSession()
        appleCredentialBindingStore.clear()
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
        vpnStatus = vpn.status
        deviceLimitContext = nil
        pendingStatisticsRequest = nil
        activeStatisticsSession = nil
        sessionMetrics = nil
        VPNSharedSessionStore.clear()
        if let nextRoute {
            route = nextRoute
        }
    }

    @discardableResult
    func checkAppleCredentialStateIfNeeded() async -> Bool {
        guard let binding = appleCredentialBindingStore.load() else { return true }
        guard let activeSession = session ?? api.storedSession else {
            appleCredentialBindingStore.clear()
            return false
        }
        guard binding.backendUserId == activeSession.userId else {
            // A provider change or account switch must not carry an Apple
            // credential identifier into another LibreGuard session.
            appleCredentialBindingStore.clear()
            return true
        }

        let generation = sessionStateGeneration
        do {
            switch try await appleCredentialStateChecker.credentialState(for: binding.userIdentifier) {
            case .authorized, .unknown:
                guard sessionStateGeneration == generation,
                      session == activeSession || (session == nil && api.storedSession == activeSession) else { return false }
                return true
            case .revoked, .notFound, .transferred:
                guard sessionStateGeneration == generation,
                      session == activeSession || (session == nil && api.storedSession == activeSession) else { return false }
                await beginSessionCleanup(intent: .invalidSession)
                return false
            }
        } catch {
            // Credential-state lookup is network-backed. Availability failures
            // must not turn into an offline logout.
            logger.info("Apple credential state check deferred after a transient failure")
            return true
        }
    }

    private func startAppleCredentialRevocationObserver() {
        guard appleCredentialRevocationObserver == nil else { return }
        appleCredentialRevocationObserver = notificationCenter
            .publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    _ = await self?.checkAppleCredentialStateIfNeeded()
                }
            }
    }

    private func startAppleTransactionListener() {
        guard appleTransactionListenerTask == nil else { return }
        let updates = appleStore.transactionUpdates()
        appleTransactionListenerTask = Task { @MainActor [weak self] in
            for await update in updates {
                guard let self, !Task.isCancelled else { return }
                guard self.session != nil else { continue }
                await self.processAppleUpdate(update)
            }
        }
    }

    private func ensureAppleRecovery() async {
        guard let accountUserID = session?.userId else { return }
        if appleRecoveryAccountID != accountUserID {
            appleRecoveryTask?.cancel()
            appleRecoveryTask = nil
            appleRecoveryAccountID = accountUserID
        }
        if appleRecoveryTask == nil {
            appleRecoveryTask = Task { @MainActor [weak self] in
                await self?.reconcileUnfinishedAppleTransactions()
            }
        }
        await appleRecoveryTask?.value
    }

    private func reconcileUnfinishedAppleTransactions() async {
        guard let accountUserID = session?.userId else { return }
        let generation = accountStateGeneration
        let current = await appleStore.currentEntitlements()
        guard !Task.isCancelled, isCurrentAppleAccount(accountUserID, generation: generation) else { return }
        let unfinished = await appleStore.unfinishedTransactions()
        var seenIDs = Set<UInt64>()
        for update in current + unfinished {
            guard !Task.isCancelled, isCurrentAppleAccount(accountUserID, generation: generation) else { return }
            if case let .verified(transaction) = update,
               !seenIDs.insert(transaction.id).inserted { continue }
            await processAppleUpdate(update)
            if pendingAppleSubscriptionTransfer != nil { break }
        }
    }

    private func isLibreGuardAppleUpdate(_ update: AppleStoreUpdate) -> Bool {
        switch update {
        case let .verified(transaction): AppleSubscriptionCatalog.productIDs.contains(transaction.productID)
        case let .unverified(productID, _): AppleSubscriptionCatalog.productIDs.contains(productID)
        }
    }

    private func processAppleUpdate(_ update: AppleStoreUpdate) async {
        guard isLibreGuardAppleUpdate(update) else { return }
        switch update {
        case let .verified(transaction):
            await processAppleTransaction(transaction, allowTransfer: false)
        case .unverified:
            applePurchaseMessage = AppleStoreError.unverifiedTransaction.localizedDescription
        }
    }

    private func isCurrentAppleAccount(_ userID: String, generation: UInt) -> Bool {
        accountStateGeneration == generation && session?.userId == userID
    }

    private func processAppleTransaction(_ transaction: AppleStoreTransaction, allowTransfer: Bool) async {
        guard let accountUserID = session?.userId,
              processingAppleTransactionIDs.insert(transaction.id).inserted else { return }
        defer { processingAppleTransactionIDs.remove(transaction.id) }
        guard transaction.environment != .xcode else {
            applePurchaseMessage = AppleStoreError.unsupportedEnvironment.localizedDescription
            return
        }
        let transactionGeneration = accountStateGeneration
        logger.info(
            "Apple subscription verification started; account=\(accountUserID, privacy: .private(mask: .hash)), environment=\(String(describing: transaction.environment), privacy: .public), allowTransfer=\(allowTransfer, privacy: .public)"
        )

        for (attempt, delay) in appleVerificationRetryDelays.enumerated() {
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            guard !Task.isCancelled, isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
            do {
                let response = try await api.verifyAppleTransaction(
                    transaction.signedTransactionInfo,
                    allowTransfer: allowTransfer,
                    environment: transaction.environment
                )
                guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                let usage = try? await api.fetchUsage()
                guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                verifiedAppleSubscriptionRevision &+= 1
                subscription = response.subscription
                cachePlan(name: response.subscription.displayName, isPro: response.subscription.isPro)
                usageQuota = usage
                await refreshDNSPreference(showErrors: false)
                guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                await appleStore.finish(transactionID: transaction.id)
                guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                unresolvedAppleTransactionIDs.remove(transaction.id)
                logger.info("Apple subscription verification applied; account=\(accountUserID, privacy: .private(mask: .hash)), isPro=\(response.subscription.isPro, privacy: .public), transferred=\(response.transferred, privacy: .public)")
                applePurchaseMessage = response.transferred
                    ? "Your Apple subscription was moved to this LibreGuard account and Pro is now active."
                    : (response.subscription.isPro ? "LibreGuard Pro is now active." : "Apple confirmed the transaction, but the subscription is not currently active.")
                return
            } catch let error as APIError {
                guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                if error.code == "APPLE_SUBSCRIPTION_TRANSFER_REQUIRED", !allowTransfer {
                    unresolvedAppleTransactionIDs.insert(transaction.id)
                    pendingAppleSubscriptionTransfer = PendingAppleSubscriptionTransfer(transaction: transaction)
                    return
                }
                if isRetryableAppleVerificationError(error), attempt + 1 < appleVerificationRetryDelays.count { continue }
                logApplePurchaseFailure(error, stage: "verifying the Apple transaction")
                if error.code == "APPLE_TRANSACTION_NOT_ENTITLED",
                   let expirationDate = transaction.expirationDate,
                   expirationDate <= Date() {
                    let current = await appleStore.currentEntitlements()
                    guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                    if !current.contains(where: isLibreGuardAppleUpdate) {
                        await appleStore.finish(transactionID: transaction.id)
                        guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                        unresolvedAppleTransactionIDs.remove(transaction.id)
                        appleExpiredTransactionNeedsRetry = true
                        applePurchaseMessage = "This previous Apple subscription has expired. Select Subscribe again to start a new purchase."
                        return
                    }
                }
                unresolvedAppleTransactionIDs.insert(transaction.id)
                applePurchaseMessage = applePurchaseErrorMessage(error)
                return
            } catch {
                guard isCurrentAppleAccount(accountUserID, generation: transactionGeneration) else { return }
                logApplePurchaseFailure(error, stage: "verifying the Apple transaction")
                unresolvedAppleTransactionIDs.insert(transaction.id)
                applePurchaseMessage = applePurchaseErrorMessage(error)
                return
            }
        }
    }

    private func isRetryableAppleVerificationError(_ error: APIError) -> Bool {
        error.code == "TRANSPORT_FAILURE"
            || error.code == "APPLE_VERIFICATION_RETRY"
            || error.code == "APPLE_VERIFICATION_UNAVAILABLE"
            || (error.statusCode ?? 0) >= 500
    }

    private func applePurchaseErrorMessage(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return error.localizedDescription }
        if (apiError.statusCode ?? 0) >= 500 {
            return "LibreGuard could not confirm this Apple purchase yet. Retry Restore Purchases when connected."
        }
        switch apiError.code {
        case "APPLE_ACCOUNT_TOKEN_MISMATCH":
            return "This Apple purchase is linked to a different account. Contact support to resolve the account link."
        case "APPLE_SUBSCRIPTION_FAMILY_CONFLICT":
            return "Another active Apple subscription is already linked to this account."
        case "ACTIVE_EXTERNAL_SUBSCRIPTION":
            return "An active Pro subscription from another payment provider is already linked to this account."
        case "APPLE_SANDBOX_TESTER_REQUIRED":
            return "This account is not enabled for Apple Sandbox purchases."
        case "APPLE_TRANSACTION_NOT_ENTITLED":
            return "The Apple subscription is not currently active."
        case "APPLE_VERIFICATION_RETRY", "APPLE_VERIFICATION_UNAVAILABLE", "TRANSPORT_FAILURE":
            return "LibreGuard could not confirm this Apple purchase yet. Retry Restore Purchases when connected."
        default:
            return apiError.localizedDescription
        }
    }

    private func logApplePurchaseFailure(_ error: Error, stage: String) {
        if let apiError = error as? APIError {
            logger.error("Apple purchase failed while \(stage, privacy: .public); HTTP=\(apiError.statusCode ?? 0, privacy: .public), backendCode=\(apiError.code ?? "none", privacy: .public)")
        } else {
            let nsError = error as NSError
            logger.error("Apple purchase failed while \(stage, privacy: .public) [\(nsError.domain, privacy: .public):\(nsError.code, privacy: .public)]")
        }
    }

    private func reconcileAutoConnectOnLaunch() async {
        guard isAutoConnectEnabled,
              vpnStatus == .disconnected || vpnStatus == .invalid else { return }
        refreshServers(trigger: .autoConnect)
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
        vpnRetryContext = nil
        cancelConnectionPreflight()
        let generation = connectionPreflightGeneration
        guard shouldPreflightConnection else {
            requestConnection(request)
            return
        }
        connectionPreflightTask = Task { @MainActor [weak self] in
            guard let self, await authorizeConnection(generation: generation),
                  generation == connectionPreflightGeneration, !Task.isCancelled else { return }
            connectionPreflightTask = nil
            requestConnection(request)
        }
    }

    private var shouldPreflightConnection: Bool {
        !isProUser && (session != nil || api.storedSession != nil)
    }

    private func authorizeConnection(generation requestedGeneration: UInt? = nil) async -> Bool {
        guard shouldPreflightConnection else { return true }
        let generation = requestedGeneration ?? connectionPreflightGeneration
        let userID = (session ?? api.storedSession)?.userId
        func isCurrent() -> Bool {
            generation == connectionPreflightGeneration && !Task.isCancelled
                && userID == (session ?? api.storedSession)?.userId
        }
        guard isCurrent() else { return false }

        isCheckingConnectionQuota = true
        defer {
            if generation == connectionPreflightGeneration { isCheckingConnectionQuota = false }
        }

        do {
            let eligibility = try await api.fetchConnectionEligibility()
            guard isCurrent() else { return false }
            let usage = try? await api.fetchUsage()
            guard isCurrent() else { return false }
            usageQuota = usage
            guard !eligibility.allowed else { return true }
            upgradePromptRequested = true
            return false
        } catch {
            // The backend documents this preflight as fail-open for availability.
            return isCurrent()
        }
    }

    private func cancelConnectionPreflight() {
        connectionPreflightGeneration &+= 1
        connectionPreflightTask?.cancel()
        connectionPreflightTask = nil
        isCheckingConnectionQuota = false
    }

    private func requestConnection(_ request: VPNConnectRequest) {
        let previousProtocol = vpn.connectedProtocol ?? activeStatisticsSession?.protocolName
            ?? pendingStatisticsRequest?.protocolName
            ?? lastVPNRequest?.protocolName
            ?? VPNSharedSessionStore.loadDescriptor().flatMap { VPNConfigurationProtocol.fromSessionName($0.protocolName) }
        if isKillSwitchEnabled, vpn.protectionIsInstalled,
           let previousProtocol, previousProtocol.transportProtocol != request.protocolName.transportProtocol {
            finishVPNFailure(VPNConnectionFailure(kind: .protectedSwitch))
            return
        }
        vpnRetryContext = nil
        if connectionRecoveryRequired {
            queuedVPNConnectRequest = request
            beginDisconnect(preservingQueuedConnection: true)
            return
        }
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
        cancelStoppedProfileRecovery()
        cancelLatencyMeasurement(reason: "connectionStarted")
        vpnTransitionTask?.cancel()
        vpnTransitionGeneration &+= 1
        let generation = vpnTransitionGeneration
        activeVPNTransition = .connect(request)
        lastVPNRequest = request
        vpnRetryContext = nil
        connectionRecoveryRequired = false
        connectionAttemptPhase = .preparing
        hasObservedNativeStartup = false
        pendingStatisticsRequest = request
        isExplicitDisconnectInProgress = false
        shouldRecoverStoppedProfileAfterExplicitDisconnect = false
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
                try Task.checkCancellation()
                try await vpn.connect(request: request)
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
                finishVPNFailure(error)
            }
        }
    }

    private func beginDisconnect(preservingQueuedConnection: Bool) {
        if !preservingQueuedConnection {
            queuedVPNConnectRequest = nil
        }

        cancelStoppedProfileRecovery()
        cancelLatencyMeasurement(reason: "disconnectionStarted")
        vpnTransitionTask?.cancel()
        vpnTransitionGeneration &+= 1
        let generation = vpnTransitionGeneration
        activeVPNTransition = .disconnect
        isExplicitDisconnectInProgress = true
        shouldRecoverStoppedProfileAfterExplicitDisconnect = !preservingQueuedConnection && !isKillSwitchEnabled
        VPNSharedSessionStore.saveDisconnectIntent(preservingQueuedConnection ? .suppress : .notify)
        vpnStatus = .disconnecting

        vpnTransitionTask = Task { [weak self] in
            guard let self else { return }
            if isKillSwitchEnabled {
                _ = try? await vpn.apply(
                    policy: VPNConnectionPolicy(
                        killSwitchEnabled: true,
                        onDemandEnabled: false
                    )
                )
            }
            // The provider read is bounded; a Live Activity update must not
            // hold up native teardown. Final activity state is sent separately.
            await refreshTrafficMetricsOnce(updateLiveActivity: false)
            let stopped = await vpn.stopAndWait(releaseProtection: !isKillSwitchEnabled)
            guard generation == vpnTransitionGeneration, !Task.isCancelled else { return }
            guard stopped.isSafe else {
                finishVPNFailure(VPNConnectionFailure(kind: .stopFailed))
                return
            }
            connectionRecoveryRequired = false
            await recoverStoppedIKEv2ProfileIfNeeded(trigger: .explicitDisconnect)
            guard generation == vpnTransitionGeneration, !Task.isCancelled else { return }
            activeVPNTransition = nil
            handleVPNStatusChange(vpn.status)
        }
    }

    private func handleVPNStatusChange(_ status: VPNConnectionState) {
        if status != .disconnected, status != .invalid {
            cancelLatencyMeasurement(reason: "vpnStatusChanged")
        }

        if case .connect = activeVPNTransition,
           status == .disconnected || status == .invalid {
            // Native start can initially return the previous terminal snapshot.
            // Attempt failures and the bounded startup deadline finish this wait.
            if !hasObservedNativeStartup {
                vpnStatus = .connecting
                return
            }
            finishVPNFailure(VPNConnectionFailure(kind: .connectionFailed))
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
        var stoppedProfileRecoveryTrigger: StoppedProfileRecoveryTrigger?

        switch status {
        case .invalid, .disconnected:
            connectionRecoveryRequired = false
            connectionAttemptPhase = nil
            let shouldRecoverUnexpectedProfile = canStartStoppedIKEv2ProfileRecovery(
                trigger: .unexpectedDisconnect
            )
            let shouldRecoverExplicitProfile = canStartStoppedIKEv2ProfileRecovery(
                trigger: .explicitDisconnect
            )
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

            if let queuedRequest = queuedVPNConnectRequest {
                queuedVPNConnectRequest = nil
                beginConnect(queuedRequest)
                // A queued connection is about to create a fresh full-tunnel
                // configuration, so it wins over stopped-profile recovery.
            } else if shouldRecoverExplicitProfile {
                stoppedProfileRecoveryTrigger = .explicitDisconnect
            } else if shouldRecoverUnexpectedProfile {
                stoppedProfileRecoveryTrigger = .unexpectedDisconnect
            }
        case .connected:
            connectionRecoveryRequired = false
            connectionAttemptPhase = .connected
            shouldRecoverStoppedProfileAfterExplicitDisconnect = false
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

        if let stoppedProfileRecoveryTrigger {
            scheduleStoppedIKEv2ProfileRecovery(trigger: stoppedProfileRecoveryTrigger)
        }
    }

    private func recoverStoppedIKEv2ProfileIfNeeded(
        trigger: StoppedProfileRecoveryTrigger
    ) async {
        if let stoppedProfileRecoveryTask {
            await stoppedProfileRecoveryTask.value
            return
        }
        guard canStartStoppedIKEv2ProfileRecovery(trigger: trigger) else { return }

        stoppedProfileRecoveryGeneration &+= 1
        let generation = stoppedProfileRecoveryGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performStoppedIKEv2ProfileRecovery(trigger: trigger)
            guard self.stoppedProfileRecoveryGeneration == generation else { return }
            self.stoppedProfileRecoveryTask = nil
        }
        stoppedProfileRecoveryTask = task
        await task.value
    }

    private func scheduleStoppedIKEv2ProfileRecovery(
        trigger: StoppedProfileRecoveryTrigger
    ) {
        // The status handler already checked the established descriptor before
        // finalizing statistics. Finalization clears that descriptor, so recheck
        // only the current routing/transition conditions when scheduling.
        guard stoppedProfileRecoveryTask == nil,
              canContinueStoppedIKEv2ProfileRecovery(trigger: trigger) else { return }

        stoppedProfileRecoveryGeneration &+= 1
        let generation = stoppedProfileRecoveryGeneration
        stoppedProfileRecoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.performStoppedIKEv2ProfileRecovery(trigger: trigger)
            guard self.stoppedProfileRecoveryGeneration == generation else { return }
            self.stoppedProfileRecoveryTask = nil
        }
    }

    private func performStoppedIKEv2ProfileRecovery(
        trigger: StoppedProfileRecoveryTrigger
    ) async {
        guard canContinueStoppedIKEv2ProfileRecovery(trigger: trigger) else { return }

        let result = await vpn.recoverStoppedProfile(for: .ikev2)
        guard !Task.isCancelled,
              canContinueStoppedIKEv2ProfileRecovery(trigger: trigger) else { return }

        if trigger == .explicitDisconnect {
            shouldRecoverStoppedProfileAfterExplicitDisconnect = false
        }

        guard result.isSafe else {
            let diagnostic = result.diagnostic ?? "The IKEv2 profile could not release its stopped routing."
            logger.error("\(diagnostic, privacy: .public)")
            present(APIError(
                message: "Could not restore normal internet routing after the VPN stopped. Please try disconnecting again.",
                code: "VPN_STOPPED_PROFILE_RECOVERY_FAILED"
            ))
            return
        }

        if result.isApplicable {
            logger.info("Recovered stopped IKEv2 profile routing")
        }

        guard trigger != .explicitDisconnect,
              isAutoConnectEnabled,
              session != nil,
              vpnStatus == .disconnected || vpnStatus == .invalid,
              activeVPNTransition == nil,
              queuedVPNConnectRequest == nil else { return }
        await reconcileAutoConnectOnLaunch()
    }

    private func canStartStoppedIKEv2ProfileRecovery(
        trigger: StoppedProfileRecoveryTrigger
    ) -> Bool {
        guard vpnStatus == .disconnected || vpnStatus == .invalid,
              !isKillSwitchEnabled else { return false }

        switch trigger {
        case .unexpectedDisconnect, .lifecycleRefresh:
            guard !isExplicitDisconnectInProgress,
                  activeVPNTransition == nil,
                  queuedVPNConnectRequest == nil,
                  let descriptor = activeStatisticsSession?.descriptor ?? VPNSharedSessionStore.loadDescriptor() else {
                return false
            }
            return descriptor.isEstablished && isIKEv2Session(descriptor)
        case .explicitDisconnect:
            return shouldRecoverStoppedProfileAfterExplicitDisconnect
                && queuedVPNConnectRequest == nil
        }
    }

    private func canContinueStoppedIKEv2ProfileRecovery(
        trigger: StoppedProfileRecoveryTrigger
    ) -> Bool {
        guard vpnStatus == .disconnected || vpnStatus == .invalid,
              !isKillSwitchEnabled,
              queuedVPNConnectRequest == nil else { return false }

        switch trigger {
        case .unexpectedDisconnect, .lifecycleRefresh:
            return !isExplicitDisconnectInProgress && activeVPNTransition == nil
        case .explicitDisconnect:
            return shouldRecoverStoppedProfileAfterExplicitDisconnect
        }
    }

    private func isIKEv2Session(_ descriptor: VPNSessionDescriptor) -> Bool {
        descriptor.protocolName == VPNConfigurationProtocol.ikev2.displayName
            || descriptor.protocolName == "IKEv2/IPSec"
    }

    private func cancelStoppedProfileRecovery() {
        stoppedProfileRecoveryGeneration &+= 1
        stoppedProfileRecoveryTask?.cancel()
        stoppedProfileRecoveryTask = nil
    }

    private func cancelActiveVPNTransition() {
        cancelConnectionPreflight()
        cancelStoppedProfileRecovery()
        vpnTransitionGeneration &+= 1
        vpnTransitionTask?.cancel()
        vpnTransitionTask = nil
        activeVPNTransition = nil
        queuedVPNConnectRequest = nil
        vpnRetryContext = nil
        lastVPNRequest = nil
        connectionAttemptPhase = nil
        connectionRecoveryRequired = false
        shouldRecoverStoppedProfileAfterExplicitDisconnect = false
        pendingStatisticsRequest = nil
        trafficMonitorTask?.cancel()
        trafficMonitorTask = nil
        if activeStatisticsSession == nil {
            VPNSharedSessionStore.clear()
        }
    }

    private func cachePlan(name: String, isPro: Bool) {
        guard let userID = (session ?? api.storedSession)?.userId else { return }
        cachedPlanName = name
        cachedPlanIsPro = isPro
        cachedPlanUserID = userID
        hasCachedPlan = true
        defaults.set(name, forKey: cachedPlanNameKey)
        defaults.set(isPro, forKey: cachedPlanIsProKey)
        defaults.set(userID, forKey: cachedPlanUserIDKey)
        logger.info(
            "Plan cache updated; account=\(userID, privacy: .private(mask: .hash)), plan=\(name, privacy: .public), isPro=\(isPro, privacy: .public)"
        )
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
        cachedPlanUserID = nil
        hasCachedPlan = false
        defaults.removeObject(forKey: cachedPlanNameKey)
        defaults.removeObject(forKey: cachedPlanIsProKey)
        defaults.removeObject(forKey: cachedPlanUserIDKey)
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
        updateNotificationPermissionNotice()
    }

    private func updateNotificationPermissionNotice() {
        if notificationAuthorizationStatus == .denied {
            notificationPermissionNotice = "Notifications are off. Your VPN still works, but connection and safety alerts won’t appear."
        } else if notificationAuthorizationStatus != .notDetermined {
            notificationPermissionNotice = nil
        }
    }

    func requestNotificationAuthorizationIfNeeded() async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
           notificationService is VPNNotificationService { return }
        let result = await notificationService.requestAuthorizationIfNeeded()
        notificationAuthorizationStatus = notificationService.authorizationStatus
        updateNotificationPermissionNotice()
        if result == .failed {
            notificationPermissionNotice = "Couldn’t request notification permission. Try again from Notifications in the app’s Settings."
        }
    }

    func openNotificationSettings() {
        notificationService.openSystemSettings()
    }
}
