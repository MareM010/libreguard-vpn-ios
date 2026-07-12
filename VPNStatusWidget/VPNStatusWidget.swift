import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LibreGuardWidgetBundle: WidgetBundle {
    var body: some Widget {
        LibreGuardVPNLiveActivity()
    }
}

struct LibreGuardVPNLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VPNActivityAttributes.self) { context in
            VPNLockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.04, green: 0.08, blue: 0.14))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "libreguardvpn://vpn/status"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.serverName, systemImage: "shield.fill")
                        .font(.caption.bold())
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.connectedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.attributes.countryFlag) \(context.attributes.protocolName)")
                        .font(.caption)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 18) {
                        TrafficColumn(
                            symbol: "arrow.down",
                            total: context.state.downloadedBytes,
                            rate: context.state.downloadBitsPerSecond
                        )
                        TrafficColumn(
                            symbol: "arrow.up",
                            total: context.state.uploadedBytes,
                            rate: context.state.uploadBitsPerSecond
                        )
                    }
                }
            } compactLeading: {
                Text(context.attributes.countryFlag)
            } compactTrailing: {
                Image(systemName: context.state.connectionState == .reconnecting
                    ? "arrow.triangle.2.circlepath"
                    : "shield.fill")
                    .foregroundStyle(context.state.connectionState == .reconnecting ? .orange : .green)
            } minimal: {
                Image(systemName: "shield.fill")
                    .foregroundStyle(context.state.connectionState == .reconnecting ? .orange : .green)
            }
            .widgetURL(URL(string: "libreguardvpn://vpn/status"))
        }
    }
}

private struct VPNLockScreenView: View {
    let context: ActivityViewContext<VPNActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(context.attributes.countryFlag) \(context.attributes.serverName)")
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.attributes.protocolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Label(stateTitle, systemImage: stateSymbol)
                        .font(.caption.bold())
                        .foregroundStyle(stateColor)
                    Text(context.attributes.connectedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                }
            }

            HStack(spacing: 18) {
                TrafficColumn(
                    symbol: "arrow.down",
                    total: context.state.downloadedBytes,
                    rate: context.state.downloadBitsPerSecond
                )
                Divider()
                TrafficColumn(
                    symbol: "arrow.up",
                    total: context.state.uploadedBytes,
                    rate: context.state.uploadBitsPerSecond
                )
            }

            if context.isStale {
                HStack(spacing: 4) {
                    Image(systemName: "pause.circle")
                    Text("Traffic update paused • Updated ")
                    Text(context.state.sampledAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }

    private var stateTitle: String {
        switch context.state.connectionState {
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        }
    }

    private var stateSymbol: String {
        context.state.connectionState == .reconnecting
            ? "arrow.triangle.2.circlepath"
            : "shield.fill"
    }

    private var stateColor: Color {
        switch context.state.connectionState {
        case .connected: .green
        case .reconnecting: .orange
        case .disconnected: .red
        }
    }
}

private struct TrafficColumn: View {
    let symbol: String
    let total: Int64
    let rate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(VPNTrafficFormatting.bitRate(rate), systemImage: symbol)
                .font(.subheadline.bold())
                .monospacedDigit()
            Text("Session \(VPNTrafficFormatting.byteCount(total))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
