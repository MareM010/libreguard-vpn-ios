//
//  ContentView.swift
//  libreguard-vpn-ios
//
//  Created by Marko Mihajlovic on 20. 6. 2026..
//

import SwiftUI
import SwiftData
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .home
    @State private var overlayScreen: OverlayScreen?
    @State private var isDarkMode = false

    var body: some View {
        let isUITestLoginMode = ProcessInfo.processInfo.environment["UITEST_FORCE_LOGIN"] == "1"
        ZStack {
            Theme.background.ignoresSafeArea()

            if isUITestLoginMode {
                LoginView(
                    onRegister: app.showRegister,
                    onForgotPassword: app.showForgotPassword
                )
            } else {
                switch app.route {
                case .launching:
                    LoginView(
                        onRegister: app.showRegister,
                        onForgotPassword: app.showForgotPassword
                    )
                    .overlay(alignment: .top) {
                        ProgressView("Restoring your secure session…")
                            .tint(Theme.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 18)
                            .allowsHitTesting(false)
                    }
                case .login:
                    LoginView(
                        onRegister: app.showRegister,
                        onForgotPassword: app.showForgotPassword
                    )
                case .register:
                    RegisterView(onLogin: { app.showLogin() })
                case let .emailConfirmation(pending):
                    EmailConfirmationView(
                        pending: pending,
                        onBack: app.showRegister
                    )
                case .forgotPassword:
                    ForgotPasswordView(onBack: { app.showLogin() })
                case let .twoFactor(challenge):
                    TwoFactorLoginView(challenge: challenge, onBack: { app.showLogin(prefill: challenge.email) })
                case .authenticated:
                    MainAppView(
                        selectedTab: $selectedTab,
                        overlayScreen: $overlayScreen,
                        isDarkMode: $isDarkMode,
                        onSignOut: { Task { await app.signOut() } }
                    )
                }
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .task { await app.start() }
        .sheet(item: $app.deviceLimitContext) { context in
            DeviceLimitView(context: context)
                .presentationDetents([.medium, .large])
        }
        .alert(item: $app.presentedError) { error in
            Alert(
                title: Text(error.code == "APP_VERSION_BLOCKED" ? "Update Required" : "LibreGuard"),
                message: Text(([error.message] + error.fieldErrors).joined(separator: "\n")),
                dismissButton: .default(Text("OK"))
            )
        }
        .onOpenURL { app.handleOpenURL($0) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, case .authenticated = app.route else { return }
            Task {
                await app.refreshAccountData(showErrors: false)
                app.refreshServers()
                await app.refreshVPNStatus()
            }
        }
    }
}

private enum MainTab: String, CaseIterable, Identifiable {
    case home = "Home"
    case servers = "Servers"
    case statistics = "Stats"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "shield"
        case .servers: "network"
        case .statistics: "chart.bar"
        case .settings: "gearshape"
        }
    }
}

private enum OverlayScreen: Identifiable {
    case help
    case privacy
    case terms
    case upgrade

    var id: String {
        switch self {
        case .help: "help"
        case .privacy: "privacy"
        case .terms: "terms"
        case .upgrade: "upgrade"
        }
    }
}

private enum Theme {
    static let primary = Color(red: 0.082, green: 0.439, blue: 0.937)
    static let statusConnected = Color(red: 0.063, green: 0.725, blue: 0.506)
    static let statusConnecting = Color(red: 0.961, green: 0.620, blue: 0.043)
    static let statusDisconnected = Color(red: 0.580, green: 0.639, blue: 0.722)
    static let destructive = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let blueBar = Color(red: 0.376, green: 0.647, blue: 0.980)
    static let purpleBar = Color(red: 0.753, green: 0.518, blue: 0.988)
    static let background = Color(.systemBackground)
    static let card = Color(.secondarySystemBackground)
    static let muted = Color(.systemGray)
    static let border = primary.opacity(0.16)
}

private extension VPNConnectionState {
    var color: Color {
        switch self {
        case .invalid, .disconnected:
            return Theme.statusDisconnected
        case .connecting, .reasserting:
            return Theme.statusConnecting
        case .connected:
            return Theme.statusConnected
        case .disconnecting:
            return Theme.destructive
        }
    }
}

private struct MainAppView: View {
    @EnvironmentObject private var app: AppModel
    @Binding var selectedTab: MainTab
    @Binding var overlayScreen: OverlayScreen?
    @Binding var isDarkMode: Bool
    let onSignOut: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ZStack {
                    switch selectedTab {
                    case .home:
                        DashboardView(onUpgrade: { overlayScreen = .upgrade })
                    case .servers:
                        ServerListView(
                            onUpgrade: { overlayScreen = .upgrade },
                            onSelectServer: { server in
                                app.selectServer(server)
                                selectedTab = .home
                            }
                        )
                    case .statistics:
                        StatisticsView()
                    case .settings:
                        SettingsView(
                            isDarkMode: $isDarkMode,
                            onNavigate: { overlayScreen = $0 },
                            onUpgrade: { overlayScreen = .upgrade },
                            onSignOut: onSignOut
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                BottomTabBar(selectedTab: $selectedTab)
            }

            if let overlayScreen {
                overlayView(for: overlayScreen)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: overlayScreen?.id)
    }

    @ViewBuilder
    private func overlayView(for screen: OverlayScreen) -> some View {
        switch screen {
        case .help:
            LegalInfoView(
                title: "Help & Support",
                subtitle: "Answers for common LibreGuard questions.",
                sections: [
                    ("Connection", "Use Quick Connect to select the fastest available server. The new IKEv2 tunnel path is being wired in now."),
                    ("Account", "Account controls, billing, and some settings screens are still placeholders while we finish the VPN integration."),
                    ("Contact", "Support messaging will be connected once backend services are available.")
                ],
                onBack: { overlayScreen = nil }
            )
        case .privacy:
            LegalInfoView(
                title: "Privacy Policy",
                subtitle: "A placeholder policy screen matching the reference flow.",
                sections: [
                    ("No Activity Logs", "LibreGuard is designed around private browsing and minimal account data."),
                    ("Payments", "The Pro plan UI highlights privacy-friendly payment options such as Monero."),
                    ("Transparency", "Final legal copy should replace this mock text before release.")
                ],
                onBack: { overlayScreen = nil }
            )
        case .terms:
            LegalInfoView(
                title: "Terms of Service",
                subtitle: "A placeholder terms page for app navigation.",
                sections: [
                    ("Service", "The VPN service screens are being connected to the live backend and Apple Personal VPN APIs."),
                    ("Usage", "Users are responsible for following applicable laws and platform policies."),
                    ("Updates", "Final terms should be reviewed before production distribution.")
                ],
                onBack: { overlayScreen = nil }
            )
        case .upgrade:
            UpgradeView(onBack: { overlayScreen = nil })
        }
    }
}

private struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false

    let onRegister: () -> Void
    let onForgotPassword: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Spacer(minLength: 36)

                VStack(spacing: 14) {
                    LibreGuardLogo(size: 96)
                    Text("Welcome Back")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Sign in to your LibreGuard account")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

                VStack(spacing: 16) {
                    FormField(label: "Email", text: $email, icon: "envelope", placeholder: "you@example.com")
                    PasswordField(label: "Password", text: $password, showPassword: $showPassword)

                    HStack {
                        Spacer()
                        Button("Forgot password?", action: onForgotPassword)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.primary)
                    }

                    PrimaryButton(
                        title: app.isAuthenticating ? "Signing in..." : "Sign In",
                        accessibilityIdentifier: "login-sign-in-button"
                    ) {
                        Task { await app.login(email: email, password: password) }
                    }
                    .disabled(app.isAuthenticating)
                }

                DividerWithText(text: "Or continue with")

                Button {
                    Task { await app.loginWithGoogle() }
                } label: {
                    HStack(spacing: 12) {
                        GoogleGlyph()
                        Text("Sign in with Google")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
                }
                .buttonStyle(.plain)
                .disabled(app.isAuthenticating)
                .accessibilityIdentifier("google-sign-in-button")

                HStack(spacing: 4) {
                    Text("New here?")
                        .foregroundStyle(.secondary)
                    Button("Create an account", action: onRegister)
                        .foregroundStyle(Theme.primary)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("create-account-button")
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .accessibilityIdentifier("login-screen")
        .onAppear {
            if email.isEmpty { email = app.prefilledEmail }
        }
    }
}

private struct RegisterView: View {
    @EnvironmentObject private var app: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @State private var passwordError = ""

    let onLogin: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 14) {
                    LibreGuardLogo(size: 88)
                    Text("Create Account")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Join LibreGuard for secure browsing")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 24)

                VStack(spacing: 16) {
                    FormField(label: "Email", text: $email, icon: "envelope", placeholder: "you@example.com")
                    PasswordField(label: "Password", text: $password, showPassword: $showPassword, hint: "Must be at least 8 characters")
                    PasswordField(label: "Confirm Password", text: $confirmPassword, showPassword: $showConfirmPassword)

                    if !passwordError.isEmpty {
                        Text(passwordError)
                            .font(.subheadline)
                            .foregroundStyle(Theme.destructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Theme.destructive.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.destructive.opacity(0.45)))
                    }

                    Text("By creating an account, you agree to our Terms of Service and Privacy Policy")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Theme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border.opacity(0.8)))

                    PrimaryButton(title: app.isAuthenticating ? "Creating Account..." : "Create Account") {
                        guard password.count >= 8 else {
                            passwordError = "Password must be at least 8 characters"
                            return
                        }
                        guard password == confirmPassword else {
                            passwordError = "Passwords do not match"
                            return
                        }
                        passwordError = ""
                        Task { await app.register(email: email, password: password, confirmation: confirmPassword) }
                    }
                    .disabled(app.isAuthenticating)
                }

                HStack(spacing: 4) {
                    Text("Already have an account?")
                        .foregroundStyle(.secondary)
                    Button("Sign in", action: onLogin)
                        .foregroundStyle(Theme.primary)
                        .fontWeight(.semibold)
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }
}

private struct EmailConfirmationView: View {
    @EnvironmentObject private var app: AppModel
    @State private var resendSeconds = 0
    @State private var isChecking = false

    let pending: PendingRegistration
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            LibreGuardLogo(size: 88)
            VStack(spacing: 8) {
                Text("Confirm Your Email")
                    .font(.system(size: 30, weight: .semibold))
                Text("We sent a confirmation link to \(pending.email).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: isChecking ? "Checking..." : "I've Confirmed My Email") {
                Task {
                    isChecking = true
                    _ = await app.checkConfirmation(pending, showErrors: true)
                    isChecking = false
                }
            }
            .disabled(isChecking)
            Button(resendSeconds > 0 ? "Resend in \(resendSeconds)s" : "Resend confirmation email") {
                Task {
                    if await app.resendConfirmation(email: pending.email) {
                        resendSeconds = 60
                    }
                }
            }
            .disabled(resendSeconds > 0)
            .foregroundStyle(Theme.primary)
            Button("Back", action: onBack)
                .foregroundStyle(Theme.primary)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: pending.userId) {
            while !Task.isCancelled {
                if await app.checkConfirmation(pending) { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: resendSeconds) {
            guard resendSeconds > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            if resendSeconds > 0 { resendSeconds -= 1 }
        }
    }
}

private struct TwoFactorLoginView: View {
    @EnvironmentObject private var app: AppModel
    @State private var code = ""
    @State private var useRecoveryCode = false

    let challenge: TwoFactorChallenge
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LibreGuardLogo(size: 88)
                VStack(spacing: 8) {
                    Text("Two-Factor Authentication")
                        .font(.system(size: 28, weight: .semibold))
                    Text(useRecoveryCode
                         ? "Enter one of your LibreGuard recovery codes."
                         : "Enter the six-digit code from your authenticator app.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                FormField(
                    label: useRecoveryCode ? "Recovery Code" : "Authentication Code",
                    text: $code,
                    icon: useRecoveryCode ? "key" : "number",
                    placeholder: useRecoveryCode ? "xxxx-xxxx" : "123456"
                )

                PrimaryButton(title: app.isAuthenticating ? "Verifying..." : "Verify") {
                    Task { await app.verifyTwoFactor(challenge, code: code, recovery: useRecoveryCode) }
                }
                .disabled(app.isAuthenticating)

                Button(useRecoveryCode ? "Use authenticator code" : "Use a recovery code") {
                    code = ""
                    useRecoveryCode.toggle()
                }
                .foregroundStyle(Theme.primary)

                Button("Back to Sign In", action: onBack)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }
}

private struct DeviceLimitView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDeviceID: Int?

    let context: DeviceLimitContext

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your \(context.response.planType) plan allows \(context.response.maxDevices) active device(s). Select one to remove before signing in here.")
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(context.response.devices) { device in
                            Button {
                                selectedDeviceID = device.id
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedDeviceID == device.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedDeviceID == device.id ? Theme.primary : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.displayName).font(.subheadline.weight(.semibold))
                                        Text(deviceMetadata(device))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selectedDeviceID == device.id ? Theme.primary : Theme.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if context.canRemoveInApp {
                    PrimaryButton(title: removalButtonTitle) {
                        guard let selectedDeviceID,
                              let device = context.response.devices.first(where: { $0.id == selectedDeviceID }) else { return }
                        Task { await app.removeDeviceAndRetry(device, context: context) }
                    }
                    .disabled(selectedDeviceID == nil || app.isAuthenticating || app.retryAfterSeconds > 0)
                } else {
                    Text("This account uses two-factor authentication. The current backend cannot authorize password-based device removal during this login step.")
                        .font(.caption)
                        .foregroundStyle(Theme.destructive)
                    PrimaryButton(title: "Manage Devices on Web") {
                        openURL(URL(string: "https://management.libreguard.net/Account/Manage/Devices")!)
                    }
                }
            }
            .padding(20)
            .navigationTitle("Device Limit Reached")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        app.deviceLimitContext = nil
                        dismiss()
                    }
                }
            }
        }
    }

    private func deviceMetadata(_ device: AccountDevice) -> String {
        var parts: [String] = []
        if let version = device.appVersion { parts.append("App \(version)") }
        if let lastSeenAt = device.lastSeenAt { parts.append("Seen \(lastSeenAt.formatted(.relative(presentation: .named)))") }
        return parts.isEmpty ? "Active device" : parts.joined(separator: " • ")
    }

    private var removalButtonTitle: String {
        if app.retryAfterSeconds > 0 { return "Try again in \(app.retryAfterSeconds)s" }
        return app.isAuthenticating ? "Removing..." : "Remove Device and Continue"
    }
}

private struct ForgotPasswordView: View {
    @State private var email = ""
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            LibreGuardLogo(size: 88)
            VStack(spacing: 8) {
                Text("Reset Password")
                    .font(.system(size: 30, weight: .semibold))
                Text("Enter your email and we will send reset instructions.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            FormField(label: "Email", text: $email, icon: "envelope", placeholder: "you@example.com")
            PrimaryButton(title: "Send Reset Link", action: onBack)
            Button("Back to Sign In", action: onBack)
                .foregroundStyle(Theme.primary)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showNetworkWarning = true
    @State private var pulse = false
    let onUpgrade: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    header

                    if showNetworkWarning && (status == .disconnected || status == .invalid) {
                        AlertCard()
                    }

                    if status.isConnected {
                        ProtectedIPCard(server: selectedServer)
                        ProtectionIndicators()
                    }

                    if status == .disconnected || status == .invalid {
                        if let selectedServer {
                            SelectedServerCard(
                                server: selectedServer,
                                onClearSelection: {
                                    app.deselectServer()
                                }
                            )
                        } else {
                            QuickConnectCard {
                                Task { await app.connectSelectedServer() }
                            }
                        }
                    }

                    statusControl
                    connectedStats
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 150)
            }

            MonthlyUsageCard(quota: app.usageQuota)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial.opacity(0.86))
        }
        .background(Theme.background)
        .task {
            if app.usageQuota == nil || app.subscription == nil {
                await app.refreshAccountData(showErrors: false)
            }
            app.refreshServers()
            await app.refreshVPNStatus()
        }
        .onChange(of: app.vpnStatus) { _, newValue in
            showNetworkWarning = newValue == .disconnected || newValue == .invalid
        }
    }

    private var status: VPNConnectionState { app.vpnStatus }
    private var selectedServer: VPNServer? {
        guard let selectedServerID = app.selectedServerID else { return nil }
        return app.servers.first(where: { $0.id == selectedServerID })
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 12) {
                    LibreGuardLogo(size: 40)
                    Text("LibreGuard")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                }
                Spacer()
                Text("\(app.subscription?.plan ?? "—") Plan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }

    private var statusControl: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(status.color.opacity(0.12))
                    .frame(width: 168, height: 168)
                    .overlay(Circle().stroke(status.color.opacity(0.25), lineWidth: 1))
                    .shadow(color: status.color.opacity(0.18), radius: 28)
                    .scaleEffect(status.isConnected && pulse ? 1.03 : 1)

                Circle()
                    .fill(status.color.opacity(0.18))
                    .frame(width: 132, height: 132)

                Image(systemName: "shield")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(status.color)

                if status == .connecting || status == .reasserting {
                    Circle()
                        .stroke(status.color, lineWidth: 2)
                        .frame(width: 168, height: 168)
                        .scaleEffect(pulse ? 1.20 : 1)
                        .opacity(pulse ? 0 : 0.8)
                }
            }
            .onAppear { pulse = true }
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 8) {
                Text(status.title)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(status.color)
                Text(status.description)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            PrimaryButton(title: status.buttonTitle, maxWidth: 220) {
                if status == .disconnected || status == .invalid {
                    Task { await app.connectSelectedServer() }
                } else if status.isConnected || status == .reasserting {
                    Task { await app.disconnectVPN() }
                }
            }
            .disabled(status.isBusy)
            .opacity(status.isBusy ? 0.65 : 1)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var connectedStats: some View {
        if status.isConnected {
            VStack(spacing: 22) {
                HStack(spacing: 10) {
                    StatMini(icon: "clock", value: "00:12:48", label: "Duration")
                    StatMini(icon: "speedometer", value: "12.8 Mbps", label: "Speed")
                    StatMini(icon: "globe", value: selectedServer?.city ?? selectedServer?.country ?? "Auto", label: "Location")
                }

                CardContainer {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Bandwidth Usage")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("55.9% of 5GB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressBar(progress: 0.559, color: Theme.primary, height: 10)
                        HStack {
                            Label("12.8 Mbps", systemImage: "arrow.down")
                            Spacer()
                            Label("4.1 Mbps", systemImage: "arrow.up")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ServerListView: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var favorites: Set<Int> = []
    let onUpgrade: () -> Void
    let onSelectServer: (VPNServer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Server Locations")
                    .font(.system(size: 26, weight: .semibold))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Connection Protocol")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ProtocolButton(
                            title: "IKEv2/IPSec",
                            isSelected: app.selectedVPNProtocol == .ikev2 || app.selectedVPNProtocol == .ikev2IPSec
                        ) {
                            app.selectVPNProtocol(.ikev2)
                        }
                        ProtocolButton(
                            title: "OpenVPN",
                            isSelected: app.selectedVPNProtocol == .openVPN,
                            badge: "PRO"
                        ) {
                            if app.subscription?.isPro == true {
                                app.selectVPNProtocol(.openVPN)
                            } else {
                                onUpgrade()
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search locations...", text: $query)
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))

                    Button {
                        app.refreshServers()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 19, weight: .semibold))
                            .rotationEffect(.degrees(app.isRefreshingServers ? 360 : 0))
                            .frame(width: 48, height: 48)
                            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    .disabled(app.isRefreshingServers)
                    .animation(.linear(duration: 0.7), value: app.isRefreshingServers)
                }
            }
            .padding(24)
            .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if app.servers.isEmpty && app.isRefreshingServers {
                        ProgressView("Refreshing healthy servers…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if groupedServers.isEmpty {
                        ContentUnavailableView("No Servers Found", systemImage: "network.slash", description: Text("Try a different search or refresh the list."))
                    }

                    ForEach(groupedServers, id: \.country) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                FlagBadge(flag: group.flag, size: 28)
                                Text(group.country)
                                    .font(.subheadline.weight(.semibold))
                                Text("(\(group.servers.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(spacing: 8) {
                                ForEach(group.servers) { server in
                                    ServerRow(
                                        server: server,
                                        isSelected: app.selectedServerID == server.id,
                                        isFavorite: favorites.contains(server.id),
                                        latency: app.serverLatencies[server.id],
                                        onSelect: {
                                            if server.requiresProSubscription,
                                               app.subscription?.isPro != true {
                                                onUpgrade()
                                            } else {
                                                onSelectServer(server)
                                            }
                                        },
                                        onFavorite: {
                                            if favorites.contains(server.id) {
                                                favorites.remove(server.id)
                                            } else {
                                                favorites.insert(server.id)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .task {
            if app.servers.isEmpty { app.refreshServers() }
        }
    }

    private var filteredServers: [VPNServer] {
        guard !query.isEmpty else { return app.servers }
        return app.servers.filter {
            $0.country.localizedCaseInsensitiveContains(query) ||
            ($0.city?.localizedCaseInsensitiveContains(query) ?? false) ||
            $0.serverName.localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedServers: [(country: String, flag: String, servers: [VPNServer])] {
        let countries = Dictionary(grouping: filteredServers, by: \.country)
        return countries.keys.sorted().compactMap { country in
            guard let list = countries[country] else { return nil }
            return (country, countryFlag(country), list)
        }
    }

    private func countryFlag(_ country: String) -> String {
        CountryFlagResolver.flagEmoji(for: country)
    }
}

private struct StatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocalConnectionRecord.connectedAt, order: .reverse) private var records: [LocalConnectionRecord]
    @State private var timeRange = "This Week"
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Statistics")
                    .font(.system(size: 26, weight: .semibold))
                Text("Track your VPN usage")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    SegmentedPicker(selection: $timeRange, options: ["This Week", "This Month"])

                    if summary.filtered.isEmpty {
                        ContentUnavailableView {
                            Label("No Local Statistics Yet", systemImage: "chart.bar.xaxis")
                        } description: {
                            Text("LibreGuard will record sessions here when the VPN tunnel begins supplying real connection and byte metrics.")
                        }
                        .padding(.vertical, 44)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            SummaryCard(icon: "waveform.path.ecg", value: ByteCountFormatter.libreGuardString(from: summary.totalBytes), label: "Total Data", color: Theme.primary)
                            SummaryCard(icon: "clock", value: durationString(summary.connectedDuration), label: "Connected", color: Theme.statusConnected)
                            SummaryCard(icon: "arrow.down", value: ByteCountFormatter.libreGuardString(from: summary.downloadedBytes), label: "Downloaded", color: Theme.blueBar)
                            SummaryCard(icon: "arrow.up", value: ByteCountFormatter.libreGuardString(from: summary.uploadedBytes), label: "Uploaded", color: Theme.purpleBar)
                        }

                        CardContainer {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack {
                                    Text("Daily Usage")
                                        .font(.headline)
                                    Spacer()
                                    HStack(spacing: 10) {
                                        LegendDot(color: Theme.blueBar, text: "Download")
                                        LegendDot(color: Theme.purpleBar, text: "Upload")
                                    }
                                }

                                VStack(spacing: 14) {
                                    ForEach(dailyUsage) { day in
                                        UsageBar(day: day, maxValue: dailyUsage.map { $0.download + $0.upload }.max() ?? 1)
                                    }
                                }
                            }
                        }

                        CardContainer {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("Recent Connections", systemImage: "calendar")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                ForEach(Array(summary.filtered.prefix(10))) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.serverName)
                                                .font(.subheadline.weight(.semibold))
                                            Text(item.connectedAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text(ByteCountFormatter.libreGuardString(from: item.downloadedBytes + item.uploadedBytes))
                                                .font(.subheadline.weight(.semibold))
                                            Text(durationString(item.duration))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if item.id != summary.filtered.prefix(10).last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }

                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear Local Statistics", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Theme.destructive.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }

                    CardContainer {
                        Label("Statistics are stored only on this device and are never shared.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .confirmationDialog("Clear all local statistics?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Statistics", role: .destructive) {
                try? SwiftDataStatisticsRecorder(context: modelContext).clear()
            }
        } message: {
            Text("This cannot be undone. No data will be removed from the LibreGuard account because these statistics never leave this device.")
        }
    }

    private var summary: LocalStatisticsSummary {
        LocalStatisticsSummary(records: records, interval: selectedInterval)
    }

    private var selectedInterval: DateInterval {
        let component: Calendar.Component = timeRange == "This Week" ? .weekOfYear : .month
        return Calendar.current.dateInterval(of: component, for: Date())
            ?? DateInterval(start: .distantPast, end: .distantFuture)
    }

    private var dailyUsage: [DailyUsage] {
        let grouped = Dictionary(grouping: summary.filtered) { Calendar.current.startOfDay(for: $0.connectedAt) }
        return grouped.keys.sorted().map { day in
            let values = grouped[day] ?? []
            return DailyUsage(
                date: day.formatted(.dateTime.weekday(.abbreviated)),
                upload: Double(values.reduce(0) { $0 + $1.uploadedBytes }),
                download: Double(values.reduce(0) { $0 + $1.downloadedBytes })
            )
        }
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "0m"
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Binding var isDarkMode: Bool
    @State private var autoConnect = true
    @State private var killSwitch = false
    @State private var splitTunneling = false
    @State private var showTwoFactorManagement = false
    @State private var threatProtection = true
    @State private var notifications = true

    let onNavigate: (OverlayScreen) -> Void
    let onUpgrade: () -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 26, weight: .semibold))
                Text("Configure your VPN preferences")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    AccountCard(email: app.session?.email)

                    if app.subscription?.isPro != true {
                        UpgradeCard(action: onUpgrade)
                    }

                    SettingsSection(title: "Security") {
                        NavigationRow(
                            icon: "iphone",
                            title: "Two-Factor Authentication",
                            subtitle: app.twoFactorStatus?.is2faEnabled == true
                                ? "Enabled • \(app.twoFactorStatus?.recoveryCodesLeft ?? 0) recovery codes"
                                : "Not enabled"
                        ) { showTwoFactorManagement = true }
                        ToggleRow(icon: "shield.checkered", title: "Threat Protection", subtitle: "Block ads, trackers & malware", isOn: $threatProtection)
                    }

                    SettingsSection(title: "Connection") {
                        ToggleRow(icon: "power", title: "Auto-Connect", subtitle: "Connect on app launch", isOn: $autoConnect)
                        ToggleRow(icon: "shield", title: "Kill Switch", subtitle: "Block internet if VPN drops", isOn: $killSwitch)
                        ToggleRow(icon: "wifi", title: "Split Tunneling", subtitle: "Exclude apps from VPN", isOn: $splitTunneling)
                    }

                    SettingsSection(title: "Protocol") {
                        NavigationRow(icon: "lock", title: "VPN Protocol", subtitle: app.selectedVPNProtocol.displayName)
                        NavigationRow(icon: "globe", title: "DNS Settings", subtitle: "Custom DNS servers")
                    }

                    SettingsSection(title: "Preferences") {
                        ToggleRow(icon: "moon", title: "Dark Mode", subtitle: "Toggle dark theme", isOn: $isDarkMode)
                        ToggleRow(icon: "bell", title: "Notifications", subtitle: "Connection status alerts", isOn: $notifications)
                        NavigationRow(icon: "character.book.closed", title: "Language", subtitle: "English")
                    }

                    SettingsSection(title: "Support") {
                        NavigationRow(icon: "questionmark.circle", title: "Help & Support") { onNavigate(.help) }
                        NavigationRow(icon: "doc.text", title: "Privacy Policy") { onNavigate(.privacy) }
                        NavigationRow(icon: "doc.text", title: "Terms of Service") { onNavigate(.terms) }
                    }

                    Button(action: onSignOut) {
                        HStack {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(Theme.destructive)
                        .padding(16)
                        .background(Theme.destructive.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.destructive.opacity(0.45)))
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        Text("LibreGuard v1.0.0")
                        Text("Open-source privacy VPN")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .sheet(isPresented: $showTwoFactorManagement) {
            TwoFactorManagementView()
        }
        .task {
            if app.twoFactorStatus == nil { await app.refreshAccountData(showErrors: false) }
        }
    }
}

private struct TwoFactorManagementView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var verificationCode = ""
    @State private var confirmDisable = false
    @State private var confirmRegenerate = false
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if app.twoFactorStatus?.is2faEnabled == true {
                        enabledContent
                    } else if let setup = app.authenticatorSetup {
                        setupContent(setup)
                    } else {
                        ProgressView("Preparing authenticator setup…")
                            .padding(.vertical, 60)
                    }

                    if !app.recoveryCodes.isEmpty {
                        recoveryCodeCard(app.recoveryCodes)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Two-Factor Authentication")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if app.twoFactorStatus == nil { await app.refreshAccountData(showErrors: false) }
            if app.twoFactorStatus?.is2faEnabled != true && app.authenticatorSetup == nil {
                await app.loadTwoFactorSetup()
            }
        }
        .onDisappear {
            app.recoveryCodes = []
            if app.twoFactorStatus?.is2faEnabled != true { app.authenticatorSetup = nil }
        }
        .confirmationDialog("Disable two-factor authentication?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Disable 2FA", role: .destructive) {
                Task {
                    isWorking = true
                    await app.disableTwoFactor()
                    isWorking = false
                }
            }
        } message: {
            Text("Your account will no longer require an authenticator code at login.")
        }
        .confirmationDialog("Generate new recovery codes?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
            Button("Generate New Codes", role: .destructive) {
                Task {
                    isWorking = true
                    _ = await app.generateRecoveryCodes()
                    isWorking = false
                }
            }
        } message: {
            Text("All existing recovery codes will stop working.")
        }
    }

    private var enabledContent: some View {
        VStack(spacing: 16) {
            CardContainer {
                HStack(spacing: 12) {
                    IconBox(systemName: "checkmark.shield.fill", color: Theme.statusConnected, background: Theme.statusConnected.opacity(0.12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Authenticator Enabled").font(.headline)
                        Text("\(app.twoFactorStatus?.recoveryCodesLeft ?? 0) recovery codes remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Button { confirmRegenerate = true } label: {
                Label("Generate New Recovery Codes", systemImage: "key.horizontal")
                    .frame(maxWidth: .infinity)
                    .padding(15)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Button(role: .destructive) { confirmDisable = true } label: {
                Label("Disable Two-Factor Authentication", systemImage: "shield.slash")
                    .frame(maxWidth: .infinity)
                    .padding(15)
                    .background(Theme.destructive.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(isWorking)
        }
    }

    private func setupContent(_ setup: AuthenticatorSetup) -> some View {
        VStack(spacing: 18) {
            CardContainer {
                VStack(spacing: 14) {
                    Text("1. Scan this code").font(.headline)
                    QRCodeView(value: setup.authenticatorUri)
                        .frame(width: 210, height: 210)
                    Text("Or enter this key manually")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(setup.sharedKey)
                        .font(.system(.footnote, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            CardContainer {
                VStack(alignment: .leading, spacing: 12) {
                    Text("2. Verify the six-digit code").font(.headline)
                    FormField(label: "Authentication Code", text: $verificationCode, icon: "number", placeholder: "123456")
                    PrimaryButton(title: isWorking ? "Verifying..." : "Enable 2FA") {
                        Task {
                            isWorking = true
                            _ = await app.enableTwoFactor(code: verificationCode)
                            isWorking = false
                        }
                    }
                    .disabled(isWorking || verificationCode.isEmpty)
                }
            }
        }
    }

    private func recoveryCodeCard(_ codes: [String]) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 14) {
                Label("Save Your Recovery Codes", systemImage: "exclamationmark.shield")
                    .font(.headline)
                    .foregroundStyle(Theme.statusConnecting)
                Text("These codes are shown once. Store them somewhere safe; LibreGuard does not save them on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(codes, id: \.self) { code in
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copy All") { UIPasteboard.general.string = codes.joined(separator: "\n") }
                    Spacer()
                    ShareLink(item: codes.joined(separator: "\n")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
            }
        }
    }
}

private struct QRCodeView: View {
    let value: String

    var body: some View {
        if let image = makeImage() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Authenticator QR code")
        } else {
            ContentUnavailableView("QR Code Unavailable", systemImage: "qrcode")
        }
    }

    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private struct UpgradeView: View {
    let onBack: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: onBack) {
                    Label("Back", systemImage: "arrow.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    LibreGuardLogo(size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Upgrade to Pro")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Unlock premium privacy and performance")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                PlanCard(
                    title: "Free Plan",
                    price: "$0",
                    badge: "Current Plan",
                    highlighted: false,
                    features: [
                        ("Access on 1 device only", true),
                        ("Free servers", true),
                        ("5GB data per month", true),
                        ("Pro servers", false),
                        ("Unlimited data", false),
                        ("Custom DNS servers", false)
                    ]
                )

                PlanCard(
                    title: "Pro Plan",
                    price: "$4",
                    badge: "Popular",
                    highlighted: true,
                    features: [
                        ("Access on unlimited devices", true),
                        ("Pro servers", true),
                        ("Unlimited data", true),
                        ("Custom VPN configuration", true),
                        ("Ad Blocking", true),
                        ("Split Tunneling", true)
                    ]
                )

                VStack(spacing: 12) {
                    PaymentButton(icon: "bitcoinsign.circle", title: "Pay with Monero (XMR)", subtitle: "Recommended for privacy", badge: "Preferred", highlighted: true)
                    PaymentButton(icon: "creditcard", title: "Pay with Card", subtitle: "Visa, Mastercard, Amex", badge: nil, highlighted: false)
                }

                CardContainer {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Why we recommend Monero (XMR)", systemImage: "bitcoinsign.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                        Text("Monero provides transaction privacy, aligning with LibreGuard's focus on private access. This copy is placeholder content for the visual build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

private struct LegalInfoView: View {
    let title: String
    let subtitle: String
    let sections: [(String, String)]
    let onBack: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: onBack) {
                    Label("Back", systemImage: "arrow.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 28, weight: .semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }

                ForEach(sections, id: \.0) { section in
                    CardContainer {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.0)
                                .font(.headline)
                            Text(section.1)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

private struct BottomTabBar: View {
    @Binding var selectedTab: MainTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 22, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(selectedTab == tab ? Theme.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
    }
}

private struct LibreGuardLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Theme.primary, Theme.primary.opacity(0.70)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "shield.fill")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.primary.opacity(0.25), radius: size * 0.16, y: size * 0.08)
    }
}

private struct FormField: View {
    let label: String
    @Binding var text: String
    let icon: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
        }
    }
}

private struct PasswordField: View {
    let label: String
    @Binding var text: String
    @Binding var showPassword: Bool
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Group {
                    if showPassword {
                        TextField("Password", text: $text)
                    } else {
                        SecureField("Password", text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PrimaryButton: View {
    let title: String
    var maxWidth: CGFloat? = nil
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: maxWidth ?? .infinity)
                .padding(.vertical, 15)
                .background(Theme.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Theme.primary.opacity(0.22), radius: 12, y: 7)
        }
        .buttonStyle(ScaleButtonStyle())
        .modifier(AccessibilityIdentifierModifier(identifier: accessibilityIdentifier))
    }
}

private struct AccessibilityIdentifierModifier: ViewModifier {
    let identifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

private struct CardContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
}

private struct AlertCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.shield")
                .foregroundStyle(Theme.destructive)
            VStack(alignment: .leading, spacing: 3) {
                Text("Unsecured Network")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.destructive)
                Text("Connect to VPN for protection on public WiFi")
                    .font(.caption)
                    .foregroundStyle(Theme.destructive.opacity(0.8))
            }
            Spacer()
        }
        .padding(14)
        .background(Theme.destructive.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.destructive.opacity(0.45)))
    }
}

private struct ProtectedIPCard: View {
    let server: VPNServer?

    var body: some View {
        CardContainer {
            HStack(spacing: 16) {
                FlagBadge(flag: server?.flagEmoji ?? "🌐")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected Server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(server?.serverName ?? "Auto Select")
                        .foregroundStyle(.primary)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpoint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(server?.serverHostname ?? server?.serverIp ?? "—")
                        .foregroundStyle(Theme.primary)
                }
            }
            .font(.subheadline.weight(.medium))
        }
    }
}

private struct ProtectionIndicators: View {
    var body: some View {
        HStack(spacing: 10) {
            ProtectionBadge(text: "DNS Protected")
            ProtectionBadge(text: "IPv6 Blocked")
            ProtectionBadge(text: "WebRTC Safe")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProtectionBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(Theme.statusConnected)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.caption2.weight(.medium))
    }
}

private struct QuickConnectCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconBox(systemName: "bolt.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick Connect")
                        .font(.subheadline.weight(.semibold))
                    Text("Connect to fastest server")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct SelectedServerCard: View {
    let server: VPNServer
    let onClearSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FlagBadge(flag: server.flagEmoji)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.serverName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Selected server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClearSelection) {
                ZStack {
                    Circle()
                        .fill(Color(.systemGray5))
                        .frame(width: 28, height: 28)
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear selected server")
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
}

private struct FlagBadge: View {
    let flag: String
    var size: CGFloat = 34

    var body: some View {
        Text(flag)
            .font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(Theme.primary.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

private struct MonthlyUsageCard: View {
    let quota: UsageQuota?

    var body: some View {
        CardContainer {
            VStack(spacing: 9) {
                HStack {
                    Text("Monthly Data Usage")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(quotaText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressBar(progress: progress, color: quota?.isOverLimit == true ? Theme.destructive : Theme.primary, height: 8)
                HStack {
                    Text(usageText)
                        .foregroundStyle(quota?.isOverLimit == true ? Theme.destructive : Theme.primary)
                    Spacer()
                    Text(remainingText)
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
            }
        }
    }

    private var progress: Double {
        guard let quota, !quota.isUnlimited else { return quota == nil ? 0 : 1 }
        return quota.usagePercentage / 100
    }

    private var quotaText: String {
        guard let quota else { return "Loading…" }
        return quota.isUnlimited ? "\(quota.formattedUsed) / Unlimited" : "\(quota.formattedUsed) / \(quota.formattedLimit)"
    }

    private var usageText: String {
        guard let quota else { return "—" }
        if quota.isUnlimited { return "Unlimited plan" }
        return String(format: "%.1f%% used", quota.usagePercentage)
    }

    private var remainingText: String {
        guard let quota else { return "—" }
        if quota.isUnlimited { return "No data limit" }
        if quota.isOverLimit { return "Limit reached" }
        if let resetDate = quota.resetDate { return "Resets \(resetDate.formatted(date: .abbreviated, time: .omitted))" }
        return "\(quota.formattedRemaining) left"
    }
}

private struct StatMini: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ServerRow: View {
    let server: VPNServer
    let isSelected: Bool
    let isFavorite: Bool
    let latency: Int?
    let onSelect: () -> Void
    let onFavorite: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    FlagBadge(flag: server.flagEmoji)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.city ?? server.country)
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 5) {
                            Text(server.pricingTierLabel)
                            Text("-")
                            Text(server.serverName)
                                .fontDesign(.monospaced)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Label(latency.map { "\($0)ms" } ?? "—", systemImage: "wifi")
                        Label(loadLabel, systemImage: "internaldrive")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    Button(action: onFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? Theme.primary : .secondary)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isSelected ? Theme.primary : .secondary)
                }

                ProgressBar(progress: loadProgress, color: loadColor, height: 5)
            }
            .padding(13)
            .background(isSelected ? Theme.primary.opacity(0.06) : Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Theme.primary : Theme.border, lineWidth: isSelected ? 1.4 : 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var loadLabel: String {
        guard server.loadDataFresh, let load = server.load else { return "Unavailable" }
        return "\(load)%"
    }

    private var loadProgress: Double {
        guard server.loadDataFresh, let load = server.load else { return 0 }
        return Double(load) / 100
    }

    private var loadColor: Color {
        guard server.loadDataFresh, let load = server.load else { return Theme.statusDisconnected }
        if load < 40 { return Theme.statusConnected }
        if load < 70 { return Theme.statusConnecting }
        return Theme.destructive
    }
}

private struct ProtocolButton: View {
    let title: String
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(isSelected ? Theme.primary : Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Color.clear : Theme.border))
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.primary, in: Capsule())
                        .offset(x: 5, y: -7)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SummaryCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 10) {
                IconBox(systemName: icon, color: color)
                Text(value)
                    .font(.headline)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SegmentedPicker: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(option)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == option ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(selection == option ? Theme.primary : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
    }
}

private struct UsageBar: View {
    let day: DailyUsage
    let maxValue: Double

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(day.date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Spacer()
                Text(ByteCountFormatter.libreGuardString(from: Int64(day.download + day.upload)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                Capsule()
                    .fill(Theme.blueBar)
                    .frame(width: max(12, CGFloat(day.download / maxValue) * 210), height: 28)
                Capsule()
                    .fill(Theme.purpleBar)
                    .frame(width: max(8, CGFloat(day.upload / maxValue) * 210), height: 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                content
            }
        }
    }
}

private struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        CardContainer {
            HStack(spacing: 12) {
                IconBox(systemName: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(Theme.primary)
            }
        }
    }
}

private struct NavigationRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            CardContainer {
                HStack(spacing: 12) {
                    IconBox(systemName: icon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct UpgradeCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    IconBox(systemName: "crown.fill", color: .white, background: Theme.primary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upgrade to Pro")
                            .font(.headline)
                        Text("Unlock unlimited data, faster servers, and premium features")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Text("✓ Unlimited bandwidth")
                    Text("✓ Priority servers")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                PrimaryButton(title: "Upgrade Now", action: action)
            }
            .padding(18)
            .background(Theme.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.primary, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

private struct AccountCard: View {
    let email: String?

    var body: some View {
        CardContainer {
            HStack(spacing: 12) {
                IconBox(systemName: "person.crop.circle.fill", color: Theme.primary, background: Theme.primary.opacity(0.12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Account")
                        .font(.headline)
                    Text(email ?? "Signed in account")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(email.map { "Account, signed in as \($0)" } ?? "Account")
    }
}

private struct PlanCard: View {
    let title: String
    let price: String
    let badge: String
    let highlighted: Bool
    let features: [(String, Bool)]

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(highlighted ? Theme.primary : .primary)
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(price)
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(highlighted ? Theme.primary : .primary)
                            Text("/month")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(highlighted ? .white : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(highlighted ? Theme.primary : Color(.tertiarySystemFill), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(features, id: \.0) { feature in
                        HStack(spacing: 10) {
                            Image(systemName: feature.1 ? "checkmark" : "xmark")
                                .foregroundStyle(feature.1 ? Theme.primary : .secondary)
                                .frame(width: 18)
                            Text(feature.0)
                                .font(.subheadline)
                                .foregroundStyle(feature.1 ? .primary : .secondary)
                        }
                    }
                }
            }
        }
        .background(highlighted ? Theme.primary.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(highlighted ? Theme.primary : Color.clear, lineWidth: highlighted ? 1.5 : 0))
    }
}

private struct PaymentButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    let highlighted: Bool

    var body: some View {
        Button {} label: {
            HStack(spacing: 12) {
                IconBox(systemName: icon, color: highlighted ? Theme.primary : .secondary, background: highlighted ? Theme.primary.opacity(0.14) : Color(.tertiarySystemFill))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.primary.opacity(0.13), in: Capsule())
                }
            }
            .padding(15)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(highlighted ? Theme.primary : Theme.border, lineWidth: highlighted ? 1.5 : 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct ProgressBar: View {
    let progress: Double
    let color: Color
    var height: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geometry.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

private struct IconBox: View {
    let systemName: String
    var color: Color = Theme.primary
    var background: Color = Theme.primary.opacity(0.11)

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct DividerWithText: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

private struct GoogleGlyph: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white)
            Text("G")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primary)
        }
        .frame(width: 22, height: 22)
        .overlay(Circle().stroke(Color(.systemGray4)))
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DailyUsage: Identifiable {
    let id = UUID()
    let date: String
    let upload: Double
    let download: Double

}

#Preview {
    ContentView()
        .environmentObject(AppModel())
        .modelContainer(for: LocalConnectionRecord.self, inMemory: true)
}
