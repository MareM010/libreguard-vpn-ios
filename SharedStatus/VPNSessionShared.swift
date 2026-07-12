import ActivityKit
import Foundation

enum VPNSharedConstants {
    static let appGroupIdentifier = "group.net.libreguard.libreguard-vpn-ios"
}

enum VPNConnectionOrigin: String, Codable, Hashable, Sendable {
    case manual
    case quickConnect
    case autoConnect
    case onDemand
    case reconnect
}

enum VPNActivityConnectionState: String, Codable, Hashable, Sendable {
    case connected
    case reconnecting
    case disconnected
}

enum VPNDisconnectIntent: String, Codable, Sendable {
    case notify
    case suppress
}

struct TunnelTrafficSnapshot: Equatable, Sendable {
    let downloadedBytes: Int64
    let uploadedBytes: Int64

    func delta(from baseline: TunnelTrafficSnapshot) -> TunnelTrafficSnapshot {
        TunnelTrafficSnapshot(
            downloadedBytes: max(0, downloadedBytes - baseline.downloadedBytes),
            uploadedBytes: max(0, uploadedBytes - baseline.uploadedBytes)
        )
    }
}

struct VPNSessionDescriptor: Codable, Hashable, Sendable {
    let sessionID: UUID
    let serverID: Int
    let serverName: String
    let country: String
    let countryFlag: String
    let protocolName: String
    let connectedAt: Date
    let origin: VPNConnectionOrigin
    let killSwitchEnabled: Bool
    let onDemandEnabled: Bool
}

struct VPNSessionTraffic: Codable, Hashable, Sendable {
    let state: VPNActivityConnectionState
    let downloadedBytes: Int64
    let uploadedBytes: Int64
    let downloadBitsPerSecond: Double
    let uploadBitsPerSecond: Double
    let sampledAt: Date

    static func zero(at date: Date = Date()) -> VPNSessionTraffic {
        VPNSessionTraffic(
            state: .connected,
            downloadedBytes: 0,
            uploadedBytes: 0,
            downloadBitsPerSecond: 0,
            uploadBitsPerSecond: 0,
            sampledAt: date
        )
    }
}

struct VPNTrafficAccumulator {
    private(set) var baseline: TunnelTrafficSnapshot?
    private(set) var previous: TunnelTrafficSnapshot?
    private(set) var previousDate: Date?
    private var downloadedOffset: Int64
    private var uploadedOffset: Int64

    init(existingTraffic: VPNSessionTraffic? = nil) {
        downloadedOffset = existingTraffic?.downloadedBytes ?? 0
        uploadedOffset = existingTraffic?.uploadedBytes ?? 0
    }

    mutating func consume(
        _ snapshot: TunnelTrafficSnapshot,
        at date: Date,
        state: VPNActivityConnectionState = .connected
    ) -> VPNSessionTraffic {
        guard let baseline, let previous, let previousDate else {
            self.baseline = snapshot
            self.previous = snapshot
            self.previousDate = date
            return VPNSessionTraffic(
                state: state,
                downloadedBytes: downloadedOffset,
                uploadedBytes: uploadedOffset,
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: date
            )
        }

        if snapshot.downloadedBytes < previous.downloadedBytes
            || snapshot.uploadedBytes < previous.uploadedBytes {
            downloadedOffset += max(0, previous.downloadedBytes - baseline.downloadedBytes)
            uploadedOffset += max(0, previous.uploadedBytes - baseline.uploadedBytes)
            self.baseline = snapshot
            self.previous = snapshot
            self.previousDate = date
            return VPNSessionTraffic(
                state: state,
                downloadedBytes: downloadedOffset,
                uploadedBytes: uploadedOffset,
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: date
            )
        }

        let totals = snapshot.delta(from: baseline)
        let interval = max(0.001, date.timeIntervalSince(previousDate))
        let recent = snapshot.delta(from: previous)
        self.previous = snapshot
        self.previousDate = date

        return VPNSessionTraffic(
            state: state,
            downloadedBytes: downloadedOffset + totals.downloadedBytes,
            uploadedBytes: uploadedOffset + totals.uploadedBytes,
            downloadBitsPerSecond: state == .connected ? Double(recent.downloadedBytes) * 8 / interval : 0,
            uploadBitsPerSecond: state == .connected ? Double(recent.uploadedBytes) * 8 / interval : 0,
            sampledAt: date
        )
    }
}

struct VPNActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let connectionState: VPNActivityConnectionState
        let downloadedBytes: Int64
        let uploadedBytes: Int64
        let downloadBitsPerSecond: Double
        let uploadBitsPerSecond: Double
        let sampledAt: Date
    }

    let sessionID: UUID
    let serverName: String
    let countryFlag: String
    let protocolName: String
    let connectedAt: Date
}

extension VPNActivityAttributes.ContentState {
    init(traffic: VPNSessionTraffic) {
        self.init(
            connectionState: traffic.state,
            downloadedBytes: traffic.downloadedBytes,
            uploadedBytes: traffic.uploadedBytes,
            downloadBitsPerSecond: traffic.downloadBitsPerSecond,
            uploadBitsPerSecond: traffic.uploadBitsPerSecond,
            sampledAt: traffic.sampledAt
        )
    }
}

enum VPNSharedSessionStore {
    private static let descriptorKey = "vpn.shared.active-session"
    private static let trafficKey = "vpn.shared.active-traffic"
    private static let disconnectIntentKey = "vpn.shared.disconnect-intent"

    static func save(descriptor: VPNSessionDescriptor) {
        guard let data = try? JSONEncoder().encode(descriptor) else { return }
        defaults?.set(data, forKey: descriptorKey)
    }

    static func loadDescriptor() -> VPNSessionDescriptor? {
        guard let data = defaults?.data(forKey: descriptorKey) else { return nil }
        return try? JSONDecoder().decode(VPNSessionDescriptor.self, from: data)
    }

    static func save(traffic: VPNSessionTraffic) {
        guard let data = try? JSONEncoder().encode(traffic) else { return }
        defaults?.set(data, forKey: trafficKey)
    }

    static func loadTraffic() -> VPNSessionTraffic? {
        guard let data = defaults?.data(forKey: trafficKey) else { return nil }
        return try? JSONDecoder().decode(VPNSessionTraffic.self, from: data)
    }

    static func saveDisconnectIntent(_ intent: VPNDisconnectIntent?) {
        if let intent {
            defaults?.set(intent.rawValue, forKey: disconnectIntentKey)
        } else {
            defaults?.removeObject(forKey: disconnectIntentKey)
        }
    }

    static func loadDisconnectIntent() -> VPNDisconnectIntent? {
        guard let rawValue = defaults?.string(forKey: disconnectIntentKey) else { return nil }
        return VPNDisconnectIntent(rawValue: rawValue)
    }

    static func clear() {
        defaults?.removeObject(forKey: descriptorKey)
        defaults?.removeObject(forKey: trafficKey)
        defaults?.removeObject(forKey: disconnectIntentKey)
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier)
    }
}

enum VPNTrafficFormatting {
    static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func bitRate(_ bitsPerSecond: Double) -> String {
        let value = max(0, bitsPerSecond)
        if value >= 1_000_000_000 {
            return String(format: "%.1f Gbps", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1f Mbps", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0f Kbps", value / 1_000)
        }
        return String(format: "%.0f bps", value)
    }
}
