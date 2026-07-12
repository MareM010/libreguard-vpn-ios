import Foundation
import UserNotifications

enum VPNNotificationEvent: String, Codable, Sendable {
    case connected
    case disconnected
    case autoConnect
    case killSwitch
}

struct VPNNotificationPayload: Sendable {
    let event: VPNNotificationEvent
    let descriptor: VPNSessionDescriptor
    let traffic: VPNSessionTraffic?

    var identifier: String {
        "vpn.\(descriptor.sessionID.uuidString).\(event.rawValue)"
    }
}

enum VPNNotificationEmitter {
    private static let deliveredEventKey = "vpn.notification.delivered-events"

    static func emit(_ payload: VPNNotificationPayload) async {
        guard markPendingIfNew(payload.identifier) else { return }

        let content = UNMutableNotificationContent()
        content.title = title(for: payload.event)
        content.body = body(for: payload)
        content.sound = .default
        content.threadIdentifier = "vpn-status"
        content.userInfo = [
            "sessionID": payload.descriptor.sessionID.uuidString,
            "event": payload.event.rawValue
        ]

        do {
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
            )
        } catch {
            unmark(payload.identifier)
        }
    }

    static func clearDeduplication(for sessionID: UUID) {
        guard let defaults else { return }
        let prefix = "vpn.\(sessionID.uuidString)."
        let remaining = deliveredIdentifiers.filter { !$0.hasPrefix(prefix) }
        defaults.set(Array(remaining), forKey: deliveredEventKey)
    }

    private static func title(for event: VPNNotificationEvent) -> String {
        switch event {
        case .connected: "VPN Connected"
        case .disconnected: "VPN Disconnected"
        case .autoConnect: "Auto-Connect Triggered"
        case .killSwitch: "Kill Switch Triggered"
        }
    }

    private static func body(for payload: VPNNotificationPayload) -> String {
        let server = "\(payload.descriptor.countryFlag) \(payload.descriptor.serverName)"
        switch payload.event {
        case .connected:
            return "Connected to \(server) via \(payload.descriptor.protocolName)."
        case .autoConnect:
            return "Connecting automatically to \(server) via \(payload.descriptor.protocolName)."
        case .killSwitch:
            return "The VPN connection dropped. Internet traffic is blocked while LibreGuard reconnects."
        case .disconnected:
            guard let traffic = payload.traffic else {
                return "Disconnected from \(server) (\(payload.descriptor.protocolName))."
            }
            let down = VPNTrafficFormatting.byteCount(traffic.downloadedBytes)
            let up = VPNTrafficFormatting.byteCount(traffic.uploadedBytes)
            let duration = durationString(
                traffic.sampledAt.timeIntervalSince(payload.descriptor.connectedAt)
            )
            return "\(server) • \(duration) • ↓ \(down)  ↑ \(up) • \(payload.descriptor.protocolName)"
        }
    }

    private static func durationString(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h \((seconds / 60) % 60)m"
        }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private static func markPendingIfNew(_ identifier: String) -> Bool {
        guard let defaults else { return true }
        var identifiers = deliveredIdentifiers
        guard !identifiers.contains(identifier) else { return false }
        identifiers.insert(identifier)
        defaults.set(Array(identifiers.suffix(64)), forKey: deliveredEventKey)
        return true
    }

    private static func unmark(_ identifier: String) {
        guard let defaults else { return }
        var identifiers = deliveredIdentifiers
        identifiers.remove(identifier)
        defaults.set(Array(identifiers), forKey: deliveredEventKey)
    }

    private static var deliveredIdentifiers: Set<String> {
        Set(defaults?.stringArray(forKey: deliveredEventKey) ?? [])
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier)
    }
}
