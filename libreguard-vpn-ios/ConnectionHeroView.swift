import SwiftUI

struct ConnectionHeroPresentation: Equatable {
    enum Tone: Equatable {
        case disconnected
        case connecting
        case connected
        case destructive
    }

    let title: String
    let description: String
    let progressLabel: String
    let actionTitle: String
    let tone: Tone

    static func make(for status: VPNConnectionState, hasQueuedReconnect: Bool) -> Self {
        switch status {
        case .invalid:
            return Self(
                title: "VPN Unavailable",
                description: "The VPN configuration is not ready yet.",
                progressLabel: "",
                actionTitle: "Retry",
                tone: .disconnected
            )
        case .disconnected:
            return Self(
                title: "Not Protected",
                description: "Your connection is not secure",
                progressLabel: "",
                actionTitle: "Connect",
                tone: .disconnected
            )
        case .connecting:
            return Self(
                title: "Connecting",
                description: "Establishing secure tunnel...",
                progressLabel: "Securing tunnel",
                actionTitle: "Cancel",
                tone: .connecting
            )
        case .connected:
            return Self(
                title: "Protected",
                description: "Secure tunnel active",
                progressLabel: "Tunnel established",
                actionTitle: "Disconnect",
                tone: .connected
            )
        case .reasserting:
            return Self(
                title: "Reconnecting",
                description: "Re-establishing secure tunnel...",
                progressLabel: "Securing tunnel",
                actionTitle: "Disconnect",
                tone: .connecting
            )
        case .disconnecting:
            return Self(
                title: "Disconnecting",
                description: "Closing secure tunnel...",
                progressLabel: "Closing tunnel",
                actionTitle: hasQueuedReconnect ? "Cancel Reconnect" : "Reconnect",
                tone: .destructive
            )
        }
    }

    var color: Color {
        switch tone {
        case .disconnected: Theme.statusDisconnected
        case .connecting: Theme.statusConnecting
        case .connected: Theme.statusConnected
        case .destructive: Theme.destructive
        }
    }
}

enum ConnectionHeroMotion {
    static let initialConnectionProgress: CGFloat = 0.06
    static let firstConnectionMilestone: CGFloat = 0.16
    static let maximumConnectionProgress: CGFloat = 0.92
    static let connectionCompletionFloor: CGFloat = 0.82

    static let initialConnectionDuration = 0.26
    static let connectionCompletionDuration = 0.62
    static let disconnectDuration = 0.62
    static let resetDuration = 0.32
    static let orbitDuration = 3.2
    static let haloHalfCycleDuration = 1.8
    static let connectedHalfCycleDuration = 2.6
    static let shimmerDuration = 1.3
}

struct ConnectionHeroView: View {
    let status: VPNConnectionState
    let hasQueuedReconnect: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var progress: CGFloat = 0
    @State private var isProgressVisible = false
    @State private var progressTask: Task<Void, Never>?

    private var presentation: ConnectionHeroPresentation {
        .make(for: status, hasQueuedReconnect: hasQueuedReconnect)
    }

    var body: some View {
        VStack(spacing: 20) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: scenePhase != .active)) { timeline in
                shield(at: timeline.date)
            }

            statusCopy

            if isProgressVisible {
                VStack(spacing: 6) {
                    ConnectionProgressBar(
                        progress: progress,
                        color: presentation.color,
                        isShimmering: status == .connecting,
                        reduceMotion: reduceMotion
                    )
                    .frame(width: 224, height: 10)

                    Text(presentation.progressLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(presentation.color.opacity(0.9))
                }
                .padding(.top, -6)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            Button(action: action) {
                Text(presentation.actionTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 15)
                    .background(Theme.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Theme.primary.opacity(0.22), radius: 12, y: 7)
            }
            .buttonStyle(ConnectionActionButtonStyle())
            .accessibilityIdentifier("vpn-primary-action")
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.22), value: isProgressVisible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(presentation.title). \(presentation.description)")
        .accessibilityValue(presentation.progressLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(presentation.actionTitle), action)
        .onAppear {
            restartProgressAnimation(for: status)
        }
        .onChange(of: status) { _, newStatus in
            restartProgressAnimation(for: newStatus)
        }
        .onChange(of: reduceMotion) { _, _ in
            restartProgressAnimation(for: status)
        }
        .onDisappear {
            progressTask?.cancel()
        }
    }

    private func shield(at date: Date) -> some View {
        let time = date.timeIntervalSinceReferenceDate
        let haloPulse = reduceMotion ? 0.5 : triangleWave(time: time, halfCycle: ConnectionHeroMotion.haloHalfCycleDuration)
        let connectedPulse = reduceMotion ? 0.5 : triangleWave(time: time, halfCycle: ConnectionHeroMotion.connectedHalfCycleDuration)
        let orbit = reduceMotion ? 0 : (time.truncatingRemainder(dividingBy: ConnectionHeroMotion.orbitDuration) / ConnectionHeroMotion.orbitDuration) * 360

        let activePulseScale: CGFloat = switch status {
        case .connecting, .reasserting:
            1 + haloPulse * 0.015
        case .connected:
            1 + connectedPulse * 0.024
        case .disconnecting:
            1 + haloPulse * 0.01
        case .invalid, .disconnected:
            1
        }

        return ZStack {
            ConnectionShieldCanvas(
                status: status,
                color: presentation.color,
                progress: progress,
                orbitDegrees: status == .disconnecting ? -orbit : orbit,
                haloPulse: haloPulse,
                connectedPulse: connectedPulse,
                reduceMotion: reduceMotion
            )
            .frame(width: 188, height: 188)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            presentation.color.opacity(innerHaloOpacity),
                            presentation.color.opacity(0.03),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 77
                    )
                )
                .frame(width: 154, height: 154)

            Button(action: action) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(presentation.color)
                    .scaleEffect(iconScale)
                    .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.42), value: status)
                    .frame(width: 128, height: 128)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(.secondarySystemBackground).opacity(0.98),
                                presentation.color.opacity(0.16),
                                Color(.secondarySystemBackground).opacity(0.98)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: Circle()
                    )
                    .shadow(
                        color: presentation.color.opacity(0.22),
                        radius: status == .connected ? 18 : 10
                    )
            }
            .buttonStyle(ConnectionShieldButtonStyle())
            .accessibilityHidden(true)
        }
        .scaleEffect(baseShieldScale * activePulseScale)
        .animation(.spring(response: 0.5, dampingFraction: 0.58), value: status)
        .animation(.easeInOut(duration: 0.35), value: presentation.tone)
    }

    private var statusCopy: some View {
        ZStack {
            VStack(spacing: 6) {
                Text(presentation.title)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(presentation.color)

                Text(presentation.description)
                    .foregroundStyle(.secondary)
            }
            .id(presentation.title)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.97)),
                    removal: .opacity.combined(with: .scale(scale: 0.98))
                )
            )
        }
        .multilineTextAlignment(.center)
        .animation(.easeOut(duration: 0.32).delay(0.08), value: presentation.title)
        .scaleEffect(status == .connecting ? 1.02 : status == .connected ? 1.01 : 1)
        .animation(.spring(response: 0.5, dampingFraction: 1), value: status)
    }

    private var baseShieldScale: CGFloat {
        switch status {
        case .invalid, .disconnected: 0.98
        case .connecting, .reasserting, .disconnecting: 1.01
        case .connected: 1.04
        }
    }

    private var iconScale: CGFloat {
        switch status {
        case .invalid, .disconnected: 0.96
        case .connecting, .reasserting, .disconnecting: 1
        case .connected: 1.05
        }
    }

    private var innerHaloOpacity: Double {
        switch status {
        case .invalid, .disconnected: 0.04
        case .connecting, .reasserting, .disconnecting: 0.12
        case .connected: 0.16
        }
    }

    private func triangleWave(time: TimeInterval, halfCycle: TimeInterval) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: halfCycle * 2) / halfCycle
        return phase <= 1 ? phase : 2 - phase
    }

    private func restartProgressAnimation(for newStatus: VPNConnectionState) {
        progressTask?.cancel()

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.16)) {
                progress = switch newStatus {
                case .invalid, .disconnected, .disconnecting: 0
                case .connecting, .reasserting: ConnectionHeroMotion.maximumConnectionProgress
                case .connected: 1
                }
                isProgressVisible = newStatus == .connecting || newStatus == .reasserting || newStatus == .disconnecting
            }
            return
        }

        progressTask = Task { @MainActor in
            switch newStatus {
            case .invalid, .disconnected:
                withAnimation(fastOutSlowIn(duration: ConnectionHeroMotion.resetDuration)) {
                    progress = 0
                }
                await sleep(ConnectionHeroMotion.resetDuration)
                guard !Task.isCancelled else { return }
                isProgressVisible = false

            case .connecting:
                isProgressVisible = true
                if progress <= 0.01 || progress >= 0.96 {
                    progress = ConnectionHeroMotion.initialConnectionProgress
                }
                if progress < ConnectionHeroMotion.firstConnectionMilestone {
                    withAnimation(linearOutSlowIn(duration: ConnectionHeroMotion.initialConnectionDuration)) {
                        progress = ConnectionHeroMotion.firstConnectionMilestone
                    }
                    await sleep(ConnectionHeroMotion.initialConnectionDuration)
                }

                while !Task.isCancelled {
                    let remaining = max(ConnectionHeroMotion.maximumConnectionProgress - progress, 0.04)
                    let target = min(
                        progress + (ConnectionHeroMotion.maximumConnectionProgress - progress) * 0.24,
                        ConnectionHeroMotion.maximumConnectionProgress
                    )
                    let duration = 0.55 + Double(remaining) * 2.2
                    withAnimation(linearOutSlowIn(duration: duration)) {
                        progress = target
                    }
                    await sleep(duration)
                }

            case .connected:
                isProgressVisible = true
                if progress < ConnectionHeroMotion.connectionCompletionFloor {
                    progress = ConnectionHeroMotion.connectionCompletionFloor
                }
                withAnimation(fastOutSlowIn(duration: ConnectionHeroMotion.connectionCompletionDuration)) {
                    progress = 1
                }
                await sleep(ConnectionHeroMotion.connectionCompletionDuration)
                guard !Task.isCancelled else { return }
                isProgressVisible = false

            case .reasserting:
                isProgressVisible = true
                withAnimation(linearOutSlowIn(duration: ConnectionHeroMotion.resetDuration)) {
                    progress = ConnectionHeroMotion.maximumConnectionProgress
                }

            case .disconnecting:
                isProgressVisible = true
                withAnimation(fastOutSlowIn(duration: ConnectionHeroMotion.disconnectDuration)) {
                    progress = 0
                }
            }
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            return
        }
    }

    private func fastOutSlowIn(duration: TimeInterval) -> Animation {
        .timingCurve(0.4, 0, 0.2, 1, duration: duration)
    }

    private func linearOutSlowIn(duration: TimeInterval) -> Animation {
        .timingCurve(0, 0, 0.2, 1, duration: duration)
    }
}

private struct ConnectionShieldCanvas: View {
    let status: VPNConnectionState
    let color: Color
    let progress: CGFloat
    let orbitDegrees: Double
    let haloPulse: CGFloat
    let connectedPulse: CGFloat
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            let strokeWidth = min(size.width, size.height) * 0.055
            let ringInset = strokeWidth / 2 + 8
            let ringRect = CGRect(
                x: ringInset,
                y: ringInset,
                width: size.width - ringInset * 2,
                height: size.height - ringInset * 2
            )
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = ringRect.width / 2

            context.fill(
                Path(ellipseIn: CGRect(x: 5, y: 5, width: size.width - 10, height: size.height - 10)),
                with: .color(color.opacity(backgroundHaloOpacity))
            )

            if status == .connecting || status == .reasserting || status == .disconnecting {
                let pulseRadius = min(size.width, size.height) * (0.46 + haloPulse * 0.09)
                let pulseRect = CGRect(
                    x: center.x - pulseRadius,
                    y: center.y - pulseRadius,
                    width: pulseRadius * 2,
                    height: pulseRadius * 2
                )
                context.fill(
                    Path(ellipseIn: pulseRect),
                    with: .color(color.opacity(Double((1 - haloPulse) * 0.10)))
                )
            }

            context.stroke(
                Path(ellipseIn: ringRect),
                with: .color(color.opacity(0.13)),
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
            )

            let sweep = max(0, min(progress, 1)) * 360
            if sweep > 1 {
                var progressPath = Path()
                progressPath.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + sweep),
                    clockwise: false
                )
                context.stroke(
                    progressPath,
                    with: .conicGradient(
                        Gradient(colors: [
                            Theme.primary.opacity(0.18),
                            color.opacity(0.95),
                            Theme.primary.opacity(0.78),
                            color.opacity(0.95),
                            Theme.primary.opacity(0.18)
                        ]),
                        center: center,
                        angle: .degrees(-90)
                    ),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
            }

            if !reduceMotion,
               status == .connecting || status == .reasserting || status == .disconnecting {
                var orbitPath = Path()
                orbitPath.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(orbitDegrees - 110),
                    endAngle: .degrees(orbitDegrees - 18),
                    clockwise: false
                )
                context.stroke(
                    orbitPath,
                    with: .conicGradient(
                        Gradient(colors: [
                            .clear,
                            Theme.primary.opacity(0.12),
                            color.opacity(0.92),
                            Theme.primary.opacity(0.48),
                            .clear
                        ]),
                        center: center
                    ),
                    style: StrokeStyle(lineWidth: strokeWidth * 0.9, lineCap: .round)
                )
            }
        }
    }

    private var backgroundHaloOpacity: Double {
        switch status {
        case .invalid, .disconnected: 0.05
        case .connecting, .reasserting, .disconnecting: 0.08 + Double(haloPulse) * 0.08
        case .connected: 0.10 + Double(connectedPulse) * 0.06
        }
    }
}

private struct ConnectionProgressBar: View {
    let progress: CGFloat
    let color: Color
    let isShimmering: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isShimmering || reduceMotion)) { timeline in
            GeometryReader { proxy in
                let width = proxy.size.width * max(0, min(progress, 1))
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: ConnectionHeroMotion.shimmerDuration)
                    / ConnectionHeroMotion.shimmerDuration

                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.12))

                    Capsule()
                        .fill(color.opacity(0.24))
                        .frame(width: width)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Theme.primary.opacity(0.88),
                                    color,
                                    Color.white.opacity(isShimmering ? 0.48 : 0.76)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width)
                        .overlay(alignment: .leading) {
                            if isShimmering && !reduceMotion && width > proxy.size.height {
                                LinearGradient(
                                    colors: [.clear, Color.white.opacity(0.4), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: proxy.size.width * 0.22)
                                .offset(x: (width + proxy.size.width * 0.22) * phase - proxy.size.width * 0.22)
                                .mask(Capsule().frame(width: width))
                            }
                        }
                }
            }
        }
        .clipShape(Capsule())
    }
}

private struct ConnectionShieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct ConnectionActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
