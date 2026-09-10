//
//  ContentView.swift
//  libreguard-vpn-ios
//
//  Created by Marko Mihajlovic on 20. 6. 2026..
//

import SwiftUI
import UIKit
import SwiftData
import CoreImage.CIFilterBuiltins
import UserNotifications
import StoreKit
import AuthenticationServices

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var selectedTab: MainTab = .home
    @State private var overlayScreen: OverlayScreen?
    @AppStorage("theme_mode") private var storedThemeMode = ThemeMode.system.rawValue

    private var themeMode: ThemeMode {
        ThemeMode.fromStoredValue(storedThemeMode)
    }

    private var effectiveDarkMode: Bool {
        switch themeMode {
        case .system:
            systemColorScheme == .dark
        case .light:
            false
        case .dark:
            true
        }
    }

    var body: some View {
        let isUITestLoginMode = ProcessInfo.processInfo.environment["UITEST_FORCE_LOGIN"] == "1"
        let isUITestSettingsMode = ProcessInfo.processInfo.environment["UITEST_FORCE_SETTINGS"] == "1"
        ZStack {
            Theme.background.ignoresSafeArea()

            if isUITestLoginMode {
                LoginView(
                    onRegister: app.showRegister,
                    onForgotPassword: app.showForgotPassword
                )
            } else if isUITestSettingsMode {
                SettingsView(
                    themeMode: themeMode,
                    effectiveDarkMode: effectiveDarkMode,
                    onThemeModeChange: { selectedThemeMode in
                        storedThemeMode = selectedThemeMode.rawValue
                    },
                    onUpgrade: {},
                    onSignOut: {}
                )
            } else {
                switch app.route {
                case .launching:
                    SessionStartupView()
                case .sessionCleanup:
                    SessionCleanupView()
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
                case let .resetPassword(link):
                    ResetPasswordView(link: link, onBack: { app.showLogin(prefill: link.email) })
                case let .twoFactor(challenge):
                    TwoFactorLoginView(challenge: challenge, onBack: { app.showLogin(prefill: challenge.email) })
                case .authenticated:
                    MainAppView(
                        selectedTab: $selectedTab,
                        overlayScreen: $overlayScreen,
                        themeMode: themeMode,
                        effectiveDarkMode: effectiveDarkMode,
                        onThemeModeChange: { selectedThemeMode in
                            storedThemeMode = selectedThemeMode.rawValue
                        },
                        onSignOut: { Task { await app.signOut() } }
                    )
                }
            }
        }
        .preferredColorScheme(themeMode.colorSchemeOverride)
        .task {
            if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
                storedThemeMode = ThemeMode.system.rawValue
            }
            await app.start()
        }
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
        .confirmationDialog(
            "Disable Kill Switch and disconnect?",
            isPresented: Binding(
                get: { app.isKillSwitchDisconnectConfirmationPresented },
                set: { if !$0 { app.cancelKillSwitchDisconnect() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Disable Kill Switch & Disconnect", role: .destructive) {
                Task { await app.confirmKillSwitchDisableAndDisconnect() }
            }
            Button("Keep VPN Connected", role: .cancel) {
                app.cancelKillSwitchDisconnect()
            }
        } message: {
            Text("Your internet traffic will no longer be blocked when the VPN is unavailable.")
        }
        .onOpenURL { app.handleOpenURL($0) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await app.retrySessionValidationIfNeeded()
                guard case .authenticated = app.route else { return }
                guard await app.checkAppleCredentialStateIfNeeded() else { return }
                await app.refreshAccountData(showErrors: false)
                app.refreshServers()
                await app.refreshVPNStatus()
                await app.refreshNotificationAuthorizationStatus()
            }
        }
    }
}

private struct SessionStartupView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.primary)
            Text("Restoring your secure session…")
                .font(.headline)
            Text("Checking your LibreGuard account and VPN connection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("session-startup-view")
    }
}

private struct SessionCleanupView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(Theme.primary)

            Text("Ending expired VPN session")
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if app.sessionCleanupState == .ending {
                ProgressView()
                    .tint(Theme.primary)
                    .padding(.top, 4)
            } else if app.sessionCleanupState == .requiresRetry {
                Button("Retry Cleanup") {
                    Task { await app.retrySessionCleanup() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .padding(.top, 4)
                .accessibilityIdentifier("session-cleanup-retry-button")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("session-cleanup-view")
    }

    private var message: String {
        switch app.sessionCleanupState {
        case .requiresRetry:
            "LibreGuard is still waiting for iOS to stop the VPN profile. Retry cleanup before signing in again."
        case .ending, nil:
            "Auto-Connect is being turned off and the VPN profile is being disconnected before sign-in is shown."
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

enum ThemeMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    static func fromStoredValue(_ rawValue: String?) -> ThemeMode {
        guard let rawValue, let mode = ThemeMode(rawValue: rawValue) else { return .system }
        return mode
    }

    var colorSchemeOverride: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var icon: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .light:
            "sun.max.fill"
        case .dark:
            "moon.fill"
        }
    }

    func subtitle(effectiveDarkMode: Bool) -> String {
        switch self {
        case .system:
            "Following system theme • Currently \(effectiveDarkMode ? "Dark" : "Light")"
        case .light:
            "Manual theme override • Always Light"
        case .dark:
            "Manual theme override • Always Dark"
        }
    }

    func buttonTitle(effectiveDarkMode: Bool, isSelected: Bool) -> String {
        switch self {
        case .system:
            isSelected ? "System • \(effectiveDarkMode ? "Dark" : "Light")" : "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }
}

private enum OverlayScreen: Identifiable {
    case upgrade

    var id: String {
        switch self {
        case .upgrade: "upgrade"
        }
    }
}

enum Theme {
    static let primary = Color(red: 0.082, green: 0.439, blue: 0.937)
    static let statusConnected = Color(red: 0.063, green: 0.725, blue: 0.506)
    static let statusConnecting = Color(red: 0.961, green: 0.620, blue: 0.043)
    static let warning = Color(red: 0.960, green: 0.680, blue: 0.050)
    static let statusDisconnected = Color(red: 0.580, green: 0.639, blue: 0.722)
    static let destructive = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let blueBar = Color(red: 0.376, green: 0.647, blue: 0.980)
    static let purpleBar = Color(red: 0.753, green: 0.518, blue: 0.988)
    static let background = Color(.systemBackground)
    static let card = Color(.secondarySystemBackground)
    static let muted = Color(.systemGray)
    static let border = primary.opacity(0.16)
}

extension VPNConnectionState {
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
    let themeMode: ThemeMode
    let effectiveDarkMode: Bool
    let onThemeModeChange: (ThemeMode) -> Void
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
                        StatisticsView(userId: app.session?.userId)
                    case .settings:
                        SettingsView(
                            themeMode: themeMode,
                            effectiveDarkMode: effectiveDarkMode,
                            onThemeModeChange: onThemeModeChange,
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
        .onChange(of: app.upgradePromptRequested) { _, requested in
            guard requested else { return }
            overlayScreen = .upgrade
            app.consumeUpgradePrompt()
        }
    }

    @ViewBuilder
    private func overlayView(for screen: OverlayScreen) -> some View {
        switch screen {
        case .upgrade:
            UpgradeView(onBack: { overlayScreen = nil })
        }
    }
}

private struct LoginView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
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
                            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

                SignInWithAppleButton(.signIn) { request in
                    app.prepareAppleSignIn(request)
                } onCompletion: { result in
                    Task { await app.completeAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(app.isAuthenticating)
                .accessibilityIdentifier("apple-sign-in-button")

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
                .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(app.isAuthenticating)
                .accessibilityIdentifier("google-sign-in-button")

                HStack(spacing: 4) {
                    Text("New here?")
                        .foregroundStyle(.secondary)
                    Button("Create an account", action: onRegister)
                        .foregroundStyle(Theme.primary)
                        .fontWeight(.semibold)
                        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var newsletterConsent = false
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

                    Toggle(isOn: $newsletterConsent) {
                        Text("Yes, I’d like to receive occasional LibreGuard news, product updates, and other relevant information by email. I can unsubscribe at any time.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .tint(Theme.primary)
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("newsletter-consent-checkbox")

                    DividerWithText(text: "Or continue with")

                    SignInWithAppleButton(.continue) { request in
                        app.prepareAppleSignIn(request)
                    } onCompletion: { result in
                        Task {
                            await app.completeAppleSignIn(
                                result,
                                newsletterConsent: newsletterConsent
                            )
                        }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(app.isAuthenticating)
                    .accessibilityIdentifier("apple-register-button")

                    Button {
                        Task { await app.loginWithGoogle(newsletterConsent: newsletterConsent) }
                    } label: {
                        HStack(spacing: 12) {
                            GoogleGlyph()
                            Text("Continue with Google")
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(app.isAuthenticating)
                    .accessibilityIdentifier("google-register-button")

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
                        Task {
                            await app.register(
                                email: email,
                                password: password,
                                confirmation: confirmPassword,
                                newsletterConsent: newsletterConsent
                            )
                        }
                    }
                    .disabled(app.isAuthenticating)
                }

                HStack(spacing: 4) {
                    Text("Already have an account?")
                        .foregroundStyle(.secondary)
                    Button("Sign in", action: onLogin)
                        .foregroundStyle(Theme.primary)
                        .fontWeight(.semibold)
                        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Button("Back", action: onBack)
                .foregroundStyle(Theme.primary)
                .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    placeholder: useRecoveryCode ? "xxxx-xxxx" : "123456",
                    keyboardType: useRecoveryCode ? .default : .numberPad
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
                .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button("Back to Sign In", action: onBack)
                    .foregroundStyle(.secondary)
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .rippleEffect(tint: Theme.primary, shape: Capsule())
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
    @EnvironmentObject private var app: AppModel
    @State private var email = ""
    @State private var didSendRequest = false
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LibreGuardLogo(size: 88)
                VStack(spacing: 8) {
                    Text("Reset Password")
                        .font(.system(size: 30, weight: .semibold))
                    Text(didSendRequest
                         ? "If an account matches this email address, reset instructions are on their way."
                         : "Enter your email and we will send reset instructions.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                FormField(label: "Email", text: $email, icon: "envelope", placeholder: "you@example.com")
                PrimaryButton(
                    title: app.isAuthenticating
                        ? "Sending..."
                        : (didSendRequest ? "Send Another Email" : "Send Reset Link"),
                    accessibilityIdentifier: "forgot-password-send-button"
                ) {
                    Task { didSendRequest = await app.requestPasswordReset(email: email) }
                }
                .disabled(app.isAuthenticating)
                Button("Back to Sign In", action: onBack)
                    .foregroundStyle(Theme.primary)
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .accessibilityIdentifier("forgot-password-screen")
        .onAppear {
            if email.isEmpty { email = app.prefilledEmail }
        }
    }
}

private struct ResetPasswordView: View {
    @EnvironmentObject private var app: AppModel
    let link: PasswordResetLink
    let onBack: () -> Void
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var showNewPassword = false
    @State private var showConfirmation = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                LibreGuardLogo(size: 88)
                VStack(spacing: 8) {
                    Text("Choose a New Password")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Set a new password for \(link.email).")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 16) {
                    PasswordField(label: "New Password", text: $newPassword, showPassword: $showNewPassword, hint: "Must be at least 8 characters")
                    PasswordField(label: "Confirm New Password", text: $confirmation, showPassword: $showConfirmation)
                    PrimaryButton(
                        title: app.isAuthenticating ? "Resetting..." : "Reset Password",
                        accessibilityIdentifier: "reset-password-submit-button"
                    ) {
                        Task { _ = await app.resetPassword(link, newPassword: newPassword, confirmation: confirmation) }
                    }
                    .disabled(app.isAuthenticating)
                }
                Button("Back to Sign In", action: onBack)
                    .foregroundStyle(Theme.primary)
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .accessibilityIdentifier("reset-password-screen")
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var app: AppModel
    let onUpgrade: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 720 || status.isConnected
            let referenceHeight: CGFloat = if status.isConnected {
                700
            } else if selectedServer != nil {
                compact ? 560 : 740
            } else {
                compact ? 500 : 680
            }
            let scale = min(1, proxy.size.height / referenceHeight)

            VStack(spacing: compact ? 10 : 22) {
                header(compact: compact)

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
                            app.requestQuickConnect()
                        }
                    }
                }

                statusControl(compact: compact)
                connectedStats(compact: compact)

                Spacer(minLength: compact ? 2 : 8)

                MonthlyUsageCard(
                    quota: app.usageQuota,
                    isPro: app.isProUser,
                    onUpgrade: onUpgrade
                )
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.top, compact ? 10 : 24)
            .padding(.bottom, compact ? 8 : 12)
            .frame(
                width: proxy.size.width / scale,
                height: proxy.size.height / scale,
                alignment: .top
            )
            .scaleEffect(scale, anchor: .topLeading)
        }
        .background(Theme.background)
        .task {
            if app.usageQuota == nil || app.subscription == nil {
                await app.refreshAccountData(showErrors: false)
            }
            app.refreshServers()
            await app.refreshVPNStatus()
        }
    }

    private var status: VPNConnectionState { app.vpnStatus }
    private var selectedServer: VPNServer? {
        guard let selectedServerID = app.selectedServerID else { return nil }
        return app.servers.first(where: { $0.id == selectedServerID })
    }

    private func header(compact: Bool) -> some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 12) {
                    LibreGuardLogo(size: compact ? 34 : 40)
                    Text("LibreGuard")
                        .font(.system(size: compact ? 21 : 24, weight: .semibold, design: .rounded))
                }
                Spacer()
                Text("\(app.currentPlanDisplayName) Plan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
        }
    }

    private func statusControl(compact: Bool) -> some View {
        ConnectionHeroView(
            status: status,
            hasQueuedReconnect: app.hasQueuedVPNReconnect,
            preparationMessage: app.certificatePreparationMessage,
            isCompact: compact,
            action: app.performVPNPrimaryAction
        )
        .animation(.easeInOut(duration: 0.25), value: app.hasQueuedVPNReconnect)
        .padding(.top, compact ? 0 : 8)
    }

    @ViewBuilder
    private func connectedStats(compact: Bool) -> some View {
        if status.isConnected {
            VStack(spacing: compact ? 10 : 22) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: compact ? 4 : 16),
                        count: compact ? 4 : 2
                    ),
                    spacing: compact ? 8 : 16
                ) {
                    SessionDurationStat(connectedAt: app.sessionMetrics?.descriptor.connectedAt)
                    StatMini(
                        icon: "arrow.down",
                        value: VPNTrafficFormatting.bitRate(app.sessionMetrics?.traffic.downloadBitsPerSecond ?? 0),
                        label: "Download"
                    )
                    StatMini(
                        icon: "arrow.up",
                        value: VPNTrafficFormatting.bitRate(app.sessionMetrics?.traffic.uploadBitsPerSecond ?? 0),
                        label: "Upload"
                    )
                    StatMini(
                        icon: "globe",
                        value: selectedServer?.city
                            ?? selectedServer?.country
                            ?? app.sessionMetrics?.descriptor.country
                            ?? "Auto",
                        label: "Location"
                    )
                }

                CardContainer {
                    VStack(spacing: compact ? 8 : 12) {
                        HStack {
                            Text("Current Session Traffic")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(app.sessionMetrics?.descriptor.protocolName ?? app.selectedVPNProtocol.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 20) {
                            SessionTrafficTotal(
                                icon: "arrow.down.circle.fill",
                                title: "Downloaded",
                                bytes: app.sessionMetrics?.traffic.downloadedBytes ?? 0,
                                color: Theme.blueBar
                            )
                            SessionTrafficTotal(
                                icon: "arrow.up.circle.fill",
                                title: "Uploaded",
                                bytes: app.sessionMetrics?.traffic.uploadedBytes ?? 0,
                                color: Theme.purpleBar
                            )
                        }
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
                            badge: app.isOpenVPNAvailable ? nil : "PRO"
                        ) {
                            if app.isOpenVPNAvailable {
                                app.selectVPNProtocol(.openVPN)
                            } else {
                                onUpgrade()
                            }
                        }
                    }
                    Text(app.isOpenVPNAvailable ? "Your current plan includes OpenVPN access." : "Upgrade to Pro to unlock OpenVPN.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))

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
                    .rippleEffect(tint: .white, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

                    if !favoriteServers.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(Theme.primary)
                                    .frame(width: 28, height: 28)
                                    .background(Theme.primary.opacity(0.12), in: Circle())
                                Text("Favourites")
                                    .font(.subheadline.weight(.semibold))
                                Text("(\(favoriteServers.count))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(spacing: 8) {
                                ForEach(favoriteServers) { server in
                                    serverRow(for: server)
                                        .transition(
                                            .asymmetric(
                                                insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .scale(scale: 0.96).combined(with: .opacity)
                                            )
                                        )
                                }
                            }
                        }
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
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
                                    serverRow(for: server)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: app.favoriteServerIDs)
        }
        .background(Theme.background)
        .task {
            if app.servers.isEmpty { app.refreshServers() }
        }
    }

    @ViewBuilder
    private func serverRow(for server: VPNServer) -> some View {
        ServerRow(
            server: server,
            isSelected: app.selectedServerID == server.id,
            isFavorite: app.isFavoriteServer(server.id),
            latency: app.serverLatencies[server.id],
            onSelect: {
                if server.requiresProSubscription,
                   !app.isProUser {
                    onUpgrade()
                } else {
                    onSelectServer(server)
                }
            },
            onFavorite: {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    app.toggleFavoriteServer(server.id)
                }
            }
        )
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

    private var favoriteServers: [VPNServer] {
        app.favoriteServerIDs.compactMap { favoriteID in
            filteredServers.first(where: { $0.id == favoriteID })
        }
    }

    private func countryFlag(_ country: String) -> String {
        CountryFlagResolver.flagEmoji(for: country)
    }
}

private struct StatisticsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.modelContext) private var modelContext
    @Query private var records: [LocalConnectionRecord]
    private let userId: String?
    @State private var timeRange = "This Week"
    @State private var confirmClear = false

    init(userId: String?) {
        self.userId = userId
        if let userId {
            _records = Query(
                filter: #Predicate<LocalConnectionRecord> { $0.userId == userId },
                sort: \LocalConnectionRecord.connectedAt,
                order: .reverse
            )
        } else {
            _records = Query(
                filter: #Predicate<LocalConnectionRecord> { $0.userId == "__no-user__" },
                sort: \LocalConnectionRecord.connectedAt,
                order: .reverse
            )
        }
    }

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
                            Label("No Statistics Yet", systemImage: "chart.bar.xaxis")
                        } description: {
                            Text("LibreGuard records your VPN sessions on this device for the currently signed-in account.")
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
                        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))

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
                        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Clear My Statistics", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(Theme.destructive.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .rippleEffect(tint: Theme.destructive, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    CardContainer {
                        Label("Statistics stay on this device and are separated per signed-in account.", systemImage: "lock.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
        .confirmationDialog("Clear all local statistics?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Statistics", role: .destructive) {
                if let userId = app.session?.userId {
                    try? SwiftDataStatisticsRecorder(context: modelContext).clear(userId: userId)
                }
            }
        } message: {
            Text("This cannot be undone. Only statistics for the current account will be removed from this device.")
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
    @Environment(\.openURL) private var openURL
    let themeMode: ThemeMode
    let effectiveDarkMode: Bool
    let onThemeModeChange: (ThemeMode) -> Void
    @State private var splitTunneling = false
    @State private var showTwoFactorManagement = false
    @State private var showProtocolSelection = false
    @State private var showDNSSettings = false
    @State private var showSignOutConfirmation = false

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
                    UpgradeCard(action: onUpgrade)

                    SettingsSection(title: "Security") {
                        NavigationRow(
                            icon: "iphone",
                            title: "Two-Factor Authentication",
                            subtitle: app.twoFactorStatus?.is2faEnabled == true
                                ? "Enabled • \(app.twoFactorStatus?.recoveryCodesLeft ?? 0) recovery codes"
                                : "Not enabled"
                        ) { showTwoFactorManagement = true }
                        ToggleRow(
                            icon: "shield.checkered",
                            title: "Ad Blocking",
                            subtitle: adBlockingSubtitle,
                            isOn: Binding(
                                get: { app.dnsPreference?.requestedEnabled ?? false },
                                set: { enabled in
                                    if enabled, app.dnsPreference?.canUseAdBlocking == false {
                                        onUpgrade()
                                    } else {
                                        Task { await app.setAdBlockingEnabled(enabled) }
                                    }
                                }
                            )
                        )
                        .disabled(app.dnsPreference == nil || app.isUpdatingAdBlocking)
                    }

                    SettingsSection(title: "Theme") {
                        ThemeModeSelector(
                            selectedThemeMode: themeMode,
                            effectiveDarkMode: effectiveDarkMode,
                            onThemeModeChange: onThemeModeChange
                        )
                    }

                    SettingsSection(title: "Connection") {
                        ToggleRow(
                            icon: "power",
                            title: "Auto-Connect",
                            subtitle: app.isUpdatingAutoConnect
                                ? "Updating VPN configuration…"
                                : "Reconnect on Wi-Fi or cellular, including after restart",
                            isOn: Binding(
                                get: { app.isAutoConnectEnabled },
                                set: { enabled in
                                    Task { await app.setAutoConnectEnabled(enabled) }
                                }
                            )
                        )
                        .disabled(app.isUpdatingAutoConnect)
                        ToggleRow(
                            icon: "shield",
                            title: "Kill Switch",
                            subtitle: killSwitchSubtitle,
                            isOn: Binding(
                                get: { app.isKillSwitchEnabled },
                                set: { enabled in
                                    if enabled, !app.isProUser {
                                        onUpgrade()
                                    } else {
                                        Task { await app.setKillSwitchEnabled(enabled) }
                                    }
                                }
                            )
                        )
                        .disabled(app.isUpdatingKillSwitch)
                        ToggleRow(icon: "wifi", title: "Split Tunneling", subtitle: "Exclude apps from VPN", isOn: $splitTunneling)
                    }

                    SettingsSection(title: "Protocol") {
                        NavigationRow(
                            icon: "lock",
                            title: "VPN Protocol",
                            subtitle: app.selectedVPNProtocol.displayName
                        ) {
                            showProtocolSelection = true
                        }
                        NavigationRow(
                            icon: "globe",
                            title: "LibreGuard DNS",
                            subtitle: dnsSettingsSubtitle
                        ) {
                            showDNSSettings = true
                        }
                    }

                    SettingsSection(title: "Preferences") {
                        NavigationRow(
                            icon: "bell",
                            title: "Notifications",
                            subtitle: notificationSubtitle
                        ) {
                            if app.notificationAuthorizationStatus == .notDetermined {
                                Task { await app.requestNotificationAuthorizationIfNeeded() }
                            } else {
                                app.openNotificationSettings()
                            }
                        }
                    }

                    SettingsSection(title: "Support") {
                        NavigationRow(icon: "questionmark.circle", title: "Help & Support") {
                            _ = openURL(URL(string: "https://libreguard.net/Support")!)
                        }
                        NavigationRow(icon: "doc.text", title: "Privacy Policy") {
                            _ = openURL(URL(string: "https://libreguard.net/Privacy")!)
                        }
                        NavigationRow(icon: "doc.text", title: "Terms of Service") {
                            _ = openURL(URL(string: "https://libreguard.net/Terms")!)
                        }
                        NavigationRow(icon: "chevron.left.forwardslash.chevron.right", title: "Source Code") {
                            _ = openURL(URL(string: "https://github.com/MareM010/libreguard-vpn-ios")!)
                        }
                        NavigationRow(icon: "chevron.left.forwardslash.chevron.right", title: "Open Source Licenses") {
                            _ = openURL(URL(string: "https://github.com/MareM010/libreguard-vpn-ios/blob/main/THIRD_PARTY_NOTICES.md")!)
                        }
                    }

                    Button { showSignOutConfirmation = true } label: {
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
                    .rippleEffect(tint: Theme.destructive, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))

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
        .task { await app.refreshNotificationAuthorizationStatus() }
        .sheet(isPresented: $showTwoFactorManagement) {
            TwoFactorManagementView()
        }
        .sheet(isPresented: $showProtocolSelection) {
            VPNProtocolSelectionView(onUpgrade: onUpgrade)
        }
        .sheet(isPresented: $showDNSSettings) {
            LibreGuardDNSSettingsView(onUpgrade: onUpgrade)
        }
        .confirmationDialog(
            "Sign out of LibreGuard?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive, action: onSignOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to sign in again to use LibreGuard.")
        }
        .task {
            await app.refreshDNSPreference(showErrors: false)
            if app.twoFactorStatus == nil { await app.refreshAccountData(showErrors: false) }
        }
    }

    private var adBlockingSubtitle: String {
        guard let preference = app.dnsPreference else {
            return app.isRefreshingDNSPreference ? "Loading DNS preference…" : "Checking account availability…"
        }
        if app.isUpdatingAdBlocking {
            return preference.requestedEnabled ? "Enabling protected DNS…" : "Disabling protected DNS…"
        }
        if !preference.canUseAdBlocking {
            return preference.requestedEnabled
                ? "Paused • Saved preference requires Pro"
                : "Pro • Block ads and trackers"
        }
        if preference.requestedEnabled, preference.effectiveEnabled {
            return "Enabled • Applies within \(preference.propagationSeconds) seconds"
        }
        if preference.requestedEnabled {
            return "Requested • Regular DNS is currently active"
        }
        return "Off • Private DNS remains active"
    }

    private var dnsSettingsSubtitle: String {
        guard let preference = app.dnsPreference else { return "Automatic private resolver" }
        return preference.effectiveEnabled
            ? "Automatic • Ad blocking enabled"
            : "Automatic • Private resolver"
    }

    private var killSwitchSubtitle: String {
        if app.isUpdatingKillSwitch {
            return "Updating protected network configuration…"
        }
        switch app.killSwitchActivationState {
        case .off:
            return app.isProUser ? "Block traffic while the VPN reconnects" : "Pro • Block traffic if the VPN drops"
        case .armed:
            return "Armed • Activates on your next VPN connection"
        case .active:
            return "Active • Traffic is blocked if the VPN drops"
        }
    }

    private var notificationSubtitle: String {
        switch app.notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Enabled • Connection and safety alerts"
        case .denied:
            return "Disabled • Tap to open system settings"
        case .notDetermined:
            return "Tap to enable connection and safety alerts"
        @unknown default:
            return "Manage in system settings"
        }
    }
}

private struct LibreGuardDNSSettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let onUpgrade: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    CardContainer {
                        HStack(alignment: .top, spacing: 14) {
                            IconBox(systemName: "shield.lefthalf.filled")
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Automatic private DNS")
                                    .font(.headline)
                                Text("LibreGuard sends system DNS requests to its private resolver while your VPN is connected.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    SettingsSection(title: "Resolver") {
                        CardContainer {
                            VStack(spacing: 12) {
                                DNSDetailRow(title: "Address", value: LibreGuardDNS.regularResolverAddress)
                                Divider()
                                DNSDetailRow(title: "Selection", value: "Automatic")
                                Divider()
                                DNSDetailRow(title: "Account mode", value: accountMode)
                                if let preference = app.dnsPreference {
                                    Divider()
                                    DNSDetailRow(
                                        title: "Propagation",
                                        value: "Up to \(preference.propagationSeconds) seconds"
                                    )
                                }
                            }
                        }
                    }

                    SettingsSection(title: "Ad Blocking") {
                        CardContainer {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(adBlockingStatus, systemImage: adBlockingStatusIcon)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(adBlockingStatusColor)
                                Text(adBlockingExplanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if app.dnsPreference?.canUseAdBlocking == false {
                            Button(action: onUpgrade) {
                                Label("Upgrade to Pro", systemImage: "crown.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(14)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.primary)
                            .rippleEffect(tint: .white, shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }

                    Text("The filtering resolver is selected securely by LibreGuard servers according to your account. It is not exposed as a custom DNS option, and no public fallback resolver is configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .background(Theme.background)
            .navigationTitle("LibreGuard DNS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .rippleEffect(tint: Theme.primary, shape: Capsule())
                }
            }
        }
        .task { await app.refreshDNSPreference(showErrors: false) }
    }

    private var accountMode: String {
        guard let preference = app.dnsPreference else { return "Loading…" }
        return preference.effectiveEnabled || preference.normalizedEffectiveMode == "filtered"
            ? "Filtered"
            : "Regular"
    }

    private var adBlockingStatus: String {
        guard let preference = app.dnsPreference else { return "Checking availability" }
        if !preference.canUseAdBlocking, preference.requestedEnabled { return "Paused" }
        if preference.effectiveEnabled { return "Enabled" }
        if preference.requestedEnabled { return "Requested" }
        return preference.canUseAdBlocking ? "Off" : "Pro feature"
    }

    private var adBlockingStatusIcon: String {
        app.dnsPreference?.effectiveEnabled == true ? "checkmark.shield.fill" : "shield"
    }

    private var adBlockingStatusColor: Color {
        app.dnsPreference?.effectiveEnabled == true ? Theme.statusConnected : .secondary
    }

    private var adBlockingExplanation: String {
        guard let preference = app.dnsPreference else {
            return "Loading your account DNS preference."
        }
        if !preference.canUseAdBlocking, preference.requestedEnabled {
            return "Your saved preference will resume when this account has an active Pro subscription. You can turn it off from the main Settings screen."
        }
        if !preference.canUseAdBlocking {
            return "Upgrade to Pro to block ads and trackers through LibreGuard DNS."
        }
        if preference.effectiveEnabled {
            return "Eligible VPN sessions are routed through LibreGuard's filtered resolver."
        }
        if preference.requestedEnabled {
            return "Your preference is saved, but regular DNS is currently active."
        }
        return "Private DNS is active without server-side ad filtering."
    }
}

private struct DNSDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct VPNProtocolSelectionView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let onUpgrade: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Choose the protocol used for new VPN connections.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProtocolButton(
                    title: "IKEv2/IPSec",
                    isSelected: app.selectedVPNProtocol == .ikev2 || app.selectedVPNProtocol == .ikev2IPSec
                ) {
                    app.selectVPNProtocol(.ikev2)
                    dismiss()
                }

                ProtocolButton(
                    title: "OpenVPN",
                    isSelected: app.selectedVPNProtocol == .openVPN,
                    badge: app.isOpenVPNAvailable ? nil : "PRO"
                ) {
                    guard app.isOpenVPNAvailable else {
                        dismiss()
                        onUpgrade()
                        return
                    }
                    app.selectVPNProtocol(.openVPN)
                    dismiss()
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("VPN Protocol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .rippleEffect(tint: Theme.primary, shape: Capsule())
                }
            }
        }
        .presentationDetents([.medium])
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
                        .rippleEffect(tint: Theme.primary, shape: Capsule())
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
            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(isWorking)

            Button(role: .destructive) { confirmDisable = true } label: {
                Label("Disable Two-Factor Authentication", systemImage: "shield.slash")
                    .frame(maxWidth: .infinity)
                    .padding(15)
                    .background(Theme.destructive.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            }
            .rippleEffect(tint: Theme.destructive, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    FormField(
                        label: "Authentication Code",
                        text: $verificationCode,
                        icon: "number",
                        placeholder: "123456",
                        keyboardType: .numberPad
                    )
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
                        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer()
                    ShareLink(item: codes.joined(separator: "\n")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @EnvironmentObject private var app: AppModel
    @State private var isManagingSubscriptions = false
    let onBack: () -> Void

    private var selectedProduct: AppleSubscriptionProduct? {
        app.appleSubscriptionProducts.first { $0.id == app.selectedAppleProductID }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                Button(action: onBack) {
                    Label("Back", systemImage: "arrow.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 12) {
                    LibreGuardLogo(size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.shouldShowUpgradePrompt ? "Upgrade to Pro" : "You are on Pro")
                            .font(.system(size: 26, weight: .semibold))
                        Text(app.shouldShowUpgradePrompt
                             ? "Unlock premium privacy and performance"
                             : "Premium servers, OpenVPN, and unlimited monthly data are already active.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if app.shouldShowUpgradePrompt {
                    PlanCard(
                        title: "Free Plan",
                        price: "$0",
                        billingPeriod: "/month",
                        badge: "Current Plan",
                        highlighted: false,
                        features: [
                            ("Access on 1 device", true),
                            ("Free servers", true),
                            ("5GB data per month", true),
                            ("IKEv2 protocol", true),
                            ("Premium servers", false),
                            ("OpenVPN protocol", false)
                        ]
                    )

                    PlanCard(
                        title: "Pro Plan",
                        price: selectedProduct?.displayPrice ?? "—",
                        billingPeriod: selectedProduct?.period == .annual ? "/year" : "/month",
                        badge: "Upgrade",
                        highlighted: true,
                        features: [
                            ("Access on up to 3 devices", true),
                            ("Premium servers", true),
                            ("Unlimited data", true),
                            ("OpenVPN protocol", true),
                            ("IKEv2 protocol", true),
                            ("Usage tracked each billing cycle", true)
                        ]
                    )

                    if app.isLoadingAppleSubscriptions {
                        ProgressView("Loading App Store subscriptions…")
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        VStack(spacing: 12) {
                            ForEach(app.appleSubscriptionProducts) { product in
                                AppleSubscriptionOption(
                                    product: product,
                                    isSelected: app.selectedAppleProductID == product.id,
                                    action: { app.selectedAppleProductID = product.id }
                                )
                            }
                        }
                    }

                    CardContainer {
                        VStack(spacing: 12) {
                            PrimaryButton(
                                title: app.isPurchasingAppleSubscription ? "Completing Purchase…" : "Subscribe with Apple"
                            ) {
                                Task { await app.purchaseSelectedAppleSubscription() }
                            }
                            .disabled(selectedProduct == nil || app.isPurchasingAppleSubscription || app.isRestoringApplePurchases)

                            Button(app.isRestoringApplePurchases ? "Restoring…" : "Restore Purchases") {
                                Task { await app.restoreApplePurchases() }
                            }
                            .font(.subheadline.weight(.semibold))
                            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .disabled(app.isPurchasingAppleSubscription || app.isRestoringApplePurchases)

                            if let message = app.applePurchaseMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }

                            Text("Payment will be charged to your Apple Account. Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            HStack(spacing: 18) {
                                Link("Terms of Service", destination: URL(string: "https://libreguard.net/Terms")!)
                                Link("Privacy Policy", destination: URL(string: "https://libreguard.net/Privacy")!)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    PlanCard(
                        title: "Pro Plan",
                        price: "Active",
                        billingPeriod: "",
                        badge: "Current Plan",
                        highlighted: true,
                        features: [
                            ("Access on up to \(app.maxDeviceCount) devices", true),
                            ("Premium servers", true),
                            ("Unlimited data", true),
                            ("OpenVPN protocol", true),
                            ("IKEv2 protocol", true),
                            ("Usage tracked each billing cycle", true)
                        ]
                    )

                    CardContainer {
                        VStack(alignment: .leading, spacing: 12) {
                            PlanDetailRow(title: "Status", value: app.subscription?.status.capitalized ?? "Active")
                            PlanDetailRow(title: "Billing cycle", value: app.subscription?.billingCycle.capitalized ?? "Monthly")
                            PlanDetailRow(title: "Active devices", value: "\(app.subscription?.activeDevices ?? 0) / \(app.maxDeviceCount)")
                            if let currentPeriodEnd = app.subscription?.currentPeriodEnd {
                                PlanDetailRow(
                                    title: "Current period ends",
                                    value: currentPeriodEnd.formatted(date: .abbreviated, time: .omitted)
                                )
                            }
                        }
                    }

                    if app.subscription?.isAppleBilled == true {
                        Button("Manage Apple Subscription") {
                            isManagingSubscriptions = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(15)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
                        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    MonthlyUsageCard(quota: app.usageQuota, isPro: app.isProUser)
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            if app.shouldShowUpgradePrompt { await app.loadAppleSubscriptions() }
        }
        .confirmationDialog(
            "Move Apple subscription to this account?",
            isPresented: Binding(
                get: { app.pendingAppleSubscriptionTransfer != nil },
                set: { if !$0, app.pendingAppleSubscriptionTransfer != nil { app.cancelAppleSubscriptionTransfer() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move Subscription", role: .destructive) {
                guard let transaction = app.pendingAppleSubscriptionTransfer?.transaction else { return }
                app.pendingAppleSubscriptionTransfer = nil
                Task { await app.confirmAppleSubscriptionTransfer(transaction) }
            }
            Button("Keep on Previous Account", role: .cancel) {
                app.cancelAppleSubscriptionTransfer()
            }
        } message: {
            Text("Pro access will be removed from the LibreGuard account currently linked to this Apple subscription and activated on the account signed in here.")
        }
        .manageSubscriptionsSheet(isPresented: $isManagingSubscriptions)
    }
}

private struct AppleSubscriptionOption: View {
    let product: AppleSubscriptionProduct
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.primary : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(product.period == .annual ? "Annual" : "Monthly")
                            .font(.subheadline.weight(.semibold))
                        if product.period == .annual {
                            Text("BEST VALUE")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.primary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.primary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(product.period == .annual ? "Billed once per year" : "Billed monthly")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.headline)
            }
            .padding(15)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Theme.primary : Theme.border, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("\(product.period == .annual ? "Annual" : "Monthly") subscription, \(product.displayPrice)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PlanDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
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
                .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        Image("LibreGuardLogo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

private struct FormField: View {
    let label: String
    @Binding var text: String
    let icon: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default

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
                    .keyboardType(keyboardType)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))

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
        .rippleEffect(tint: .white, shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
    @EnvironmentObject private var app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            ProtectionBadge(text: app.dnsPreference?.effectiveEnabled == true ? "Ad Blocking" : "Private DNS")
            ProtectionBadge(
                text: app.ipv6ProtectionStatus.label,
                systemImage: app.ipv6ProtectionStatus == .bestEffort ? "exclamationmark.shield" : "checkmark.shield",
                color: app.ipv6ProtectionStatus == .bestEffort ? Theme.statusConnecting : Theme.statusConnected
            )
            ProtectionBadge(text: "WebRTC Safe")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct ProtectionBadge: View {
    let text: String
    var systemImage = "checkmark.shield"
    var color = Theme.statusConnected

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
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
                    Text("Connect to the best available server")
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
        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SelectedServerCard: View {
    let server: VPNServer
    let onClearSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                FlagBadge(flag: server.flagEmoji)
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.serverName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(server.country)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
            .rippleEffect(tint: Theme.primary, shape: Circle())
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
            .font(.system(size: size * 0.68))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct MonthlyUsageCard: View {
    let quota: UsageQuota?
    let isPro: Bool
    let onUpgrade: (() -> Void)?

    init(
        quota: UsageQuota?,
        isPro: Bool = false,
        onUpgrade: (() -> Void)? = nil
    ) {
        self.quota = quota
        self.isPro = isPro
        self.onUpgrade = onUpgrade
    }

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
                if !isPro {
                    ProgressBar(progress: progress, color: quota?.usageTint(isPro: isPro) ?? Theme.primary, height: 8)
                }
                HStack {
                    Text(usageText)
                        .foregroundStyle(quota?.usageTint(isPro: isPro) ?? Theme.primary)
                    Spacer()
                    Text(remainingText)
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))

                if shouldShowUpgrade, let onUpgrade {
                    Button(action: onUpgrade) {
                        Label("Upgrade to Pro", systemImage: "arrow.up.circle.fill")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(quota?.usageTint(isPro: isPro) ?? Theme.primary)
                    .rippleEffect(tint: .white, shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityIdentifier("monthly-usage-upgrade")
                }
            }
        }
    }

    private var progress: Double {
        quota?.displayProgress(isPro: isPro) ?? 0
    }

    private var quotaText: String {
        guard let quota else { return "Loading…" }
        return quota.dashboardUsageHeadline(isPro: isPro)
    }

    private var usageText: String {
        guard let quota else { return "—" }
        return quota.usageSummaryText(isPro: isPro)
    }

    private var remainingText: String {
        guard let quota else { return "—" }
        return quota.usageDetailText(isPro: isPro)
    }

    private var shouldShowUpgrade: Bool {
        guard let quota, !isPro else { return false }
        return quota.isOverLimit || (quota.usagePercentage ?? 0) >= 80
    }
}

private extension UsageQuota {
    func displayProgress(isPro: Bool) -> Double {
        if isPro || isUnlimited {
            let percentage = usagePercentage ?? 0
            return percentage > 0 ? min(max(percentage / 100, 0.08), 1) : 0.08
        }
        return min(max((usagePercentage ?? 0) / 100, 0), 1)
    }

    func usageTint(isPro: Bool) -> Color {
        guard !isPro && !isUnlimited else { return Theme.primary }
        if isOverLimit || (usagePercentage ?? 0) >= 100 { return Theme.destructive }
        if (usagePercentage ?? 0) >= 80 { return Theme.warning }
        return Theme.primary
    }

    func dashboardUsageHeadline(isPro: Bool) -> String {
        "\(formattedUsed) / \(isPro || isUnlimited ? "Unlimited" : (formattedLimit ?? "5 GB"))"
    }

    func usageSummaryText(isPro: Bool) -> String {
        if isPro || isUnlimited { return "\(formattedUsed) used this cycle" }
        return String(format: "%.1f%% used", usagePercentage ?? 0)
    }

    func usageDetailText(isPro: Bool) -> String {
        if isPro || isUnlimited {
            if let resetDate {
                return "Cycle resets \(resetDate.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Unlimited monthly data"
        }
        if isOverLimit || (usagePercentage ?? 0) >= 100 { return "Limit reached" }
        if let resetDate { return "Resets \(resetDate.formatted(date: .abbreviated, time: .omitted))" }
        return "\(formattedRemaining ?? "0 B") left"
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

private struct SessionDurationStat: View {
    let connectedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: connectedAt ?? .now, by: 1)) { context in
            StatMini(
                icon: "clock",
                value: durationString(at: context.date),
                label: "Duration"
            )
        }
    }

    private func durationString(at date: Date) -> String {
        guard let connectedAt else { return "00:00:00" }
        let seconds = max(0, Int(date.timeIntervalSince(connectedAt)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

private struct SessionTrafficTotal: View {
    let icon: String
    let title: String
    let bytes: Int64
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(VPNTrafficFormatting.byteCount(bytes))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
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
        // The favourite control is positioned in the space above the load bar.
        // Aligning to the top of the content keeps its centre at the midpoint
        // between the card's top edge and the progress bar.
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        FlagBadge(flag: server.flagEmoji)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(server.city ?? server.country)
                                    .font(.subheadline.weight(.semibold))

                                if server.requiresProSubscription {
                                    Text("PRO")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Theme.primary, in: Capsule())
                                        .accessibilityLabel("Pro server")
                                }
                            }
                            Text(server.serverName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .lineLimit(1)

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 5) {
                                Image(systemName: "wifi")
                                    .foregroundStyle(latencyColor)
                                Text(latency.map { "\($0)ms" } ?? "—")
                            }
                            HStack(spacing: 5) {
                                Image(systemName: "internaldrive")
                                    .foregroundStyle(loadColor)
                                Text(loadLabel)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                        // Reserve space for the independent favourite button.
                        Color.clear
                            .frame(width: 34)
                    }

                    ProgressBar(progress: loadProgress, color: loadColor, height: 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ScaleButtonStyle())
            .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity)

            Button(action: onFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isFavorite ? Theme.primary : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isFavorite)
                    .frame(width: 34, height: 34)
            }
            .offset(y: favoriteVerticalOffset)
            .buttonStyle(.plain)
            .rippleEffect(tint: Theme.primary, shape: Circle())
            .accessibilityLabel(isFavorite ? "Remove \(server.serverName) from favourites" : "Add \(server.serverName) to favourites")
            .accessibilityIdentifier("favorite-server-\(server.id)")
        }
        .padding(13)
        .background(isSelected ? Theme.primary.opacity(0.06) : Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Theme.primary : Theme.border, lineWidth: isSelected ? 1.4 : 1))
    }

    private var favoriteVerticalOffset: CGFloat {
        let cardInset: CGFloat = 13
        let serverInfoRowHeight: CGFloat = 34
        let progressBarGap: CGFloat = 10
        let favoriteControlSize: CGFloat = 34
        let progressBarTopFromCardTop = cardInset + serverInfoRowHeight + progressBarGap
        let midpointFromCardTop = progressBarTopFromCardTop / 2
        let contentOriginFromCardTop = cardInset

        return midpointFromCardTop - contentOriginFromCardTop - favoriteControlSize / 2
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

    private var latencyColor: Color {
        guard let latency else { return Theme.statusDisconnected }
        if latency < 100 { return Theme.statusConnected }
        if latency <= 200 { return Theme.primary }
        return Theme.statusDisconnected
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
        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .rippleEffect(tint: color, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

private struct ThemeModeSelector: View {
    let selectedThemeMode: ThemeMode
    let effectiveDarkMode: Bool
    let onThemeModeChange: (ThemeMode) -> Void

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    IconBox(systemName: "circle.lefthalf.filled")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Theme")
                            .font(.subheadline.weight(.semibold))
                        Text(selectedThemeMode.subtitle(effectiveDarkMode: effectiveDarkMode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    ForEach(ThemeMode.allCases) { mode in
                        let isSelected = selectedThemeMode == mode

                        Button {
                            onThemeModeChange(mode)
                        } label: {
                            Label {
                                Text(mode.buttonTitle(
                                    effectiveDarkMode: effectiveDarkMode,
                                    isSelected: isSelected
                                ))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .allowsTightening(true)
                            } icon: {
                                Image(systemName: mode.icon)
                            }
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 9)
                            .foregroundStyle(isSelected ? Theme.primary : Theme.muted)
                            .background(
                                isSelected ? Theme.primary.opacity(0.12) : Theme.background,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(
                                        isSelected ? Theme.primary.opacity(0.35) : Theme.border,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("theme-\(mode.rawValue)-button")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme-section")
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
                    .rippleEffect(tint: Theme.primary, shape: Capsule())
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
        .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct UpgradeCard: View {
    @EnvironmentObject private var app: AppModel
    let action: () -> Void

    var body: some View {
        Group {
            if app.shouldShowUpgradePrompt {
                Button(action: action) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            IconBox(systemName: "crown.fill", color: .white, background: Theme.primary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Upgrade to Pro")
                                    .font(.headline)
                                Text("Unlock unlimited monthly data, premium servers, and OpenVPN access")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            Text("✓ Unlimited bandwidth")
                            Text("✓ Up to 3 devices")
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
                .rippleEffect(tint: Theme.primary, shape: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                CardContainer {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            IconBox(systemName: "checkmark.shield.fill", color: .white, background: Theme.statusConnected)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("You are a Pro user")
                                    .font(.headline)
                                Text("Premium servers, OpenVPN, DNS ad blocking, and unlimited monthly data are enabled on this account.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 12) {
                            Text("Used: \(app.usageQuota?.formattedUsed ?? "—")")
                            Text("Devices: \(app.subscription?.activeDevices ?? 0)/\(app.maxDeviceCount)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .background(Theme.statusConnected.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.statusConnected.opacity(0.5), lineWidth: 1.5))
            }
        }
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
    let billingPeriod: String
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
                            Text(billingPeriod)
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
