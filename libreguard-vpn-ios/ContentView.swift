//
//  ContentView.swift
//  libreguard-vpn-ios
//
//  Created by Marko Mihajlovic on 20. 6. 2026..
//

import SwiftUI

struct ContentView: View {
    @State private var authScreen: AuthScreen = .login
    @State private var selectedTab: MainTab = .home
    @State private var overlayScreen: OverlayScreen?
    @State private var registeredEmail = ""
    @State private var isDarkMode = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch authScreen {
            case .login:
                LoginView(
                    onLogin: { authScreen = .authenticated },
                    onRegister: { authScreen = .register },
                    onForgotPassword: { authScreen = .forgotPassword }
                )
            case .register:
                RegisterView(
                    onRegister: { email in
                        registeredEmail = email
                        authScreen = .emailConfirmation
                    },
                    onLogin: { authScreen = .login }
                )
            case .emailConfirmation:
                EmailConfirmationView(
                    email: registeredEmail,
                    onConfirmed: { authScreen = .authenticated },
                    onBack: { authScreen = .register }
                )
            case .forgotPassword:
                ForgotPasswordView(onBack: { authScreen = .login })
            case .authenticated:
                MainAppView(
                    selectedTab: $selectedTab,
                    overlayScreen: $overlayScreen,
                    isDarkMode: $isDarkMode,
                    onSignOut: { authScreen = .login }
                )
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
}

private enum AuthScreen {
    case login
    case register
    case emailConfirmation
    case forgotPassword
    case authenticated
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

private enum ConnectionStatus {
    case disconnected
    case connecting
    case connected

    var title: String {
        switch self {
        case .disconnected: "Not Protected"
        case .connecting: "Connecting"
        case .connected: "Protected"
        }
    }

    var description: String {
        switch self {
        case .disconnected: "Your connection is not secure"
        case .connecting: "Establishing secure connection..."
        case .connected: "Your connection is secure"
        }
    }

    var buttonTitle: String {
        switch self {
        case .disconnected: "Connect"
        case .connecting: "Cancel"
        case .connected: "Disconnect"
        }
    }

    var color: Color {
        switch self {
        case .disconnected: Theme.statusDisconnected
        case .connecting: Theme.statusConnecting
        case .connected: Theme.statusConnected
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

private struct MainAppView: View {
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
                        ServerListView(onUpgrade: { overlayScreen = .upgrade })
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
                    ("Connection", "Use Quick Connect to select the fastest available server. The current build is visual only."),
                    ("Account", "Account controls, billing, and VPN setup flows are placeholders for the next implementation phase."),
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
                subtitle: "A visual-only terms page for app navigation.",
                sections: [
                    ("Service", "The VPN service screens are mocked until networking and subscription logic are added."),
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
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isLoading = false

    let onLogin: () -> Void
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

                    PrimaryButton(title: isLoading ? "Signing in..." : "Sign In") {
                        isLoading = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            isLoading = false
                            onLogin()
                        }
                    }
                }

                DividerWithText(text: "Or continue with")

                Button(action: onLogin) {
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

                HStack(spacing: 4) {
                    Text("New here?")
                        .foregroundStyle(.secondary)
                    Button("Create an account", action: onRegister)
                        .foregroundStyle(Theme.primary)
                        .fontWeight(.semibold)
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }
}

private struct RegisterView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @State private var passwordError = ""

    let onRegister: (String) -> Void
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

                    PrimaryButton(title: "Create Account") {
                        guard password.count >= 8 else {
                            passwordError = "Password must be at least 8 characters"
                            return
                        }
                        guard password == confirmPassword else {
                            passwordError = "Passwords do not match"
                            return
                        }
                        onRegister(email.isEmpty ? "you@example.com" : email)
                    }
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
    let email: String
    let onConfirmed: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            LibreGuardLogo(size: 88)
            VStack(spacing: 8) {
                Text("Confirm Your Email")
                    .font(.system(size: 30, weight: .semibold))
                Text("We sent a confirmation link to \(email.isEmpty ? "you@example.com" : email).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            PrimaryButton(title: "Continue") {
                onConfirmed()
            }
            Button("Back", action: onBack)
                .foregroundStyle(Theme.primary)
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
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
    @State private var status: ConnectionStatus = .disconnected
    @State private var showNetworkWarning = true
    @State private var pulse = false
    let onUpgrade: () -> Void

    private let monthlyData = 2847.0
    private let monthlyLimit = 5120.0

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    header

                    if showNetworkWarning && status == .disconnected {
                        AlertCard()
                    }

                    if status == .connected {
                        ProtectedIPCard()
                        ProtectionIndicators()
                    }

                    if status == .disconnected {
                        QuickConnectCard {
                            startConnecting()
                        }
                    }

                    statusControl
                    connectedStats
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 150)
            }

            MonthlyUsageCard(monthlyData: monthlyData, monthlyLimit: monthlyLimit)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(.ultraThinMaterial.opacity(0.86))
        }
        .background(Theme.background)
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
                Text("Free Plan")
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
                    .scaleEffect(status == .connected && pulse ? 1.03 : 1)

                Circle()
                    .fill(status.color.opacity(0.18))
                    .frame(width: 132, height: 132)

                Image(systemName: "shield")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(status.color)

                if status == .connecting {
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
                if status == .disconnected {
                    startConnecting()
                } else if status == .connected {
                    status = .disconnected
                }
            }
            .disabled(status == .connecting)
            .opacity(status == .connecting ? 0.65 : 1)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var connectedStats: some View {
        if status == .connected {
            VStack(spacing: 22) {
                HStack(spacing: 10) {
                    StatMini(icon: "clock", value: "00:12:48", label: "Duration")
                    StatMini(icon: "speedometer", value: "12.8 Mbps", label: "Speed")
                    StatMini(icon: "globe", value: "New York", label: "Location")
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

    private func startConnecting() {
        status = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            status = .connected
            showNetworkWarning = false
        }
    }
}

private struct ServerListView: View {
    @State private var query = ""
    @State private var selectedServerID = "1"
    @State private var favorites: Set<String> = []
    @State private var protocolName = "IKEv2/IPSec"
    @State private var refreshing = false
    let onUpgrade: () -> Void

    private let servers = ServerLocation.samples

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
                        ProtocolButton(title: "IKEv2/IPSec", isSelected: protocolName == "IKEv2/IPSec") {
                            protocolName = "IKEv2/IPSec"
                        }
                        ProtocolButton(title: "OpenVPN", isSelected: false, badge: "PRO") {
                            onUpgrade()
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
                        refreshing = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { refreshing = false }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 19, weight: .semibold))
                            .rotationEffect(.degrees(refreshing ? 360 : 0))
                            .frame(width: 48, height: 48)
                            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    .animation(.linear(duration: 0.7), value: refreshing)
                }
            }
            .padding(24)
            .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedServers, id: \.country) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text(group.code)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Theme.primary.opacity(0.12), in: Capsule())
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
                                        isSelected: selectedServerID == server.id,
                                        isFavorite: favorites.contains(server.id),
                                        onSelect: { selectedServerID = server.id },
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
    }

    private var filteredServers: [ServerLocation] {
        guard !query.isEmpty else { return servers }
        return servers.filter {
            $0.country.localizedCaseInsensitiveContains(query) ||
            $0.city.localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedServers: [(country: String, code: String, servers: [ServerLocation])] {
        let countries = Dictionary(grouping: filteredServers, by: \.country)
        return countries.keys.sorted().compactMap { country in
            guard let list = countries[country] else { return nil }
            return (country, list.first?.code ?? "--", list)
        }
    }
}

private struct StatisticsView: View {
    @State private var timeRange = "This Week"
    private let days = DailyUsage.samples

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

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        SummaryCard(icon: "waveform.path.ecg", value: "8.72 GB", label: "Total Data", color: Theme.primary)
                        SummaryCard(icon: "clock", value: "17h 9m", label: "Connected", color: Theme.statusConnected)
                        SummaryCard(icon: "arrow.down", value: "8.75 GB", label: "Downloaded", color: Theme.blueBar)
                        SummaryCard(icon: "arrow.up", value: "2.05 GB", label: "Uploaded", color: Theme.purpleBar)
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
                                ForEach(days) { day in
                                    UsageBar(day: day, maxValue: days.map { $0.download + $0.upload }.max() ?? 1)
                                }
                            }
                        }
                    }

                    CardContainer {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("Recent Connections", systemImage: "calendar")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            ForEach(ConnectionHistory.samples) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.location)
                                            .font(.subheadline.weight(.semibold))
                                        Text(item.time)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(item.data)
                                            .font(.subheadline.weight(.semibold))
                                        Text(item.duration)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if item.id != ConnectionHistory.samples.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }

                    CardContainer {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Insights", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.headline)
                                .foregroundStyle(Theme.primary)
                            Text("Your daily average is 1.25 GB")
                            Text("Most active day: Thursday")
                            Text("Peak usage time: Evening (6-10 PM)")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.background)
    }
}

private struct SettingsView: View {
    @Binding var isDarkMode: Bool
    @State private var autoConnect = true
    @State private var killSwitch = false
    @State private var splitTunneling = false
    @State private var twoFactorAuth = false
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
                    UpgradeCard(action: onUpgrade)

                    SettingsSection(title: "Security") {
                        ToggleRow(icon: "iphone", title: "Two-Factor Authentication", subtitle: "Add extra layer of security", isOn: $twoFactorAuth)
                        ToggleRow(icon: "shield.checkered", title: "Threat Protection", subtitle: "Block ads, trackers & malware", isOn: $threatProtection)
                    }

                    SettingsSection(title: "Connection") {
                        ToggleRow(icon: "power", title: "Auto-Connect", subtitle: "Connect on app launch", isOn: $autoConnect)
                        ToggleRow(icon: "shield", title: "Kill Switch", subtitle: "Block internet if VPN drops", isOn: $killSwitch)
                        ToggleRow(icon: "wifi", title: "Split Tunneling", subtitle: "Exclude apps from VPN", isOn: $splitTunneling)
                    }

                    SettingsSection(title: "Protocol") {
                        NavigationRow(icon: "lock", title: "VPN Protocol", subtitle: "WireGuard")
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
    var body: some View {
        CardContainer {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("203.0.113.45")
                        .strikethrough()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 4) {
                    Text("VPN IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("198.51.100.78")
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

private struct MonthlyUsageCard: View {
    let monthlyData: Double
    let monthlyLimit: Double

    private var percentage: Double { monthlyData / monthlyLimit }

    var body: some View {
        CardContainer {
            VStack(spacing: 9) {
                HStack {
                    Text("Monthly Data Usage")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("2.78 / 5 GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressBar(progress: percentage, color: Theme.primary, height: 8)
                HStack {
                    Text("55.6% used")
                        .foregroundStyle(Theme.primary)
                    Spacer()
                    Text("2.22 GB left")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.medium))
            }
        }
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
    let server: ServerLocation
    let isSelected: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onFavorite: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Text(server.code)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.primary)
                        .frame(width: 34, height: 34)
                        .background(Theme.primary.opacity(0.12), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.city)
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 5) {
                            Text(server.country)
                            Text("-")
                            Text(server.name)
                                .fontDesign(.monospaced)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Label("\(server.ping)ms", systemImage: "wifi")
                        Label("\(server.load)%", systemImage: "internaldrive")
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

                ProgressBar(progress: Double(server.load) / 100, color: loadColor(server.load), height: 5)
            }
            .padding(13)
            .background(isSelected ? Theme.primary.opacity(0.06) : Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Theme.primary : Theme.border, lineWidth: isSelected ? 1.4 : 1))
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func loadColor(_ load: Int) -> Color {
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
                Text(String(format: "%.2f GB", (day.download + day.upload) / 1024))
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
                        Text(price)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(highlighted ? Theme.primary : .primary)
                        + Text("/month")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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

private struct ServerLocation: Identifiable {
    let id: String
    let country: String
    let code: String
    let city: String
    let name: String
    let ping: Int
    let load: Int

    static let samples = [
        ServerLocation(id: "1", country: "United States", code: "US", city: "New York", name: "US-MULTI-1", ping: 12, load: 45),
        ServerLocation(id: "2", country: "United States", code: "US", city: "Los Angeles", name: "US-MULTI-20", ping: 28, load: 62),
        ServerLocation(id: "8", country: "Canada", code: "CA", city: "Toronto", name: "CA-MULTI-2", ping: 22, load: 33),
        ServerLocation(id: "3", country: "United Kingdom", code: "UK", city: "London", name: "UK-MULTI-5", ping: 45, load: 38),
        ServerLocation(id: "4", country: "Germany", code: "DE", city: "Frankfurt", name: "DE-MULTI-1", ping: 52, load: 51),
        ServerLocation(id: "9", country: "France", code: "FR", city: "Paris", name: "FR-MULTI-9", ping: 48, load: 55),
        ServerLocation(id: "10", country: "Netherlands", code: "NL", city: "Amsterdam", name: "NL-MULTI-4", ping: 41, load: 48),
        ServerLocation(id: "5", country: "Japan", code: "JP", city: "Tokyo", name: "JP-MULTI-3", ping: 98, load: 29),
        ServerLocation(id: "6", country: "Singapore", code: "SG", city: "Singapore", name: "SG-MULTI-12", ping: 112, load: 67),
        ServerLocation(id: "7", country: "Australia", code: "AU", city: "Sydney", name: "AU-MULTI-7", ping: 145, load: 42)
    ]
}

private struct DailyUsage: Identifiable {
    let id = UUID()
    let date: String
    let upload: Double
    let download: Double

    static let samples = [
        DailyUsage(date: "Mon", upload: 245, download: 1240),
        DailyUsage(date: "Tue", upload: 310, download: 1580),
        DailyUsage(date: "Wed", upload: 189, download: 890),
        DailyUsage(date: "Thu", upload: 420, download: 2100),
        DailyUsage(date: "Fri", upload: 380, download: 1920),
        DailyUsage(date: "Sat", upload: 156, download: 780),
        DailyUsage(date: "Today", upload: 98, download: 450)
    ]
}

private struct ConnectionHistory: Identifiable {
    let id = UUID()
    let location: String
    let time: String
    let duration: String
    let data: String

    static let samples = [
        ConnectionHistory(location: "New York, US", time: "2 hours ago", duration: "1h 42m", data: "450 MB"),
        ConnectionHistory(location: "London, UK", time: "Yesterday", duration: "3h 15m", data: "1.2 GB"),
        ConnectionHistory(location: "Tokyo, JP", time: "2 days ago", duration: "45m", data: "280 MB"),
        ConnectionHistory(location: "Frankfurt, DE", time: "3 days ago", duration: "2h 08m", data: "890 MB")
    ]
}

#Preview {
    ContentView()
}
