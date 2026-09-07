import Darwin
import Foundation
import SwiftData

@Model
final class LocalConnectionRecord {
    @Attribute(.unique) var id: UUID
    var userId: String?
    var connectedAt: Date
    var disconnectedAt: Date
    var serverId: Int?
    var serverName: String
    var country: String
    var protocolName: String?
    var downloadedBytes: Int64
    var uploadedBytes: Int64

    init(
        id: UUID = UUID(),
        userId: String? = nil,
        connectedAt: Date,
        disconnectedAt: Date,
        serverId: Int? = nil,
        serverName: String,
        country: String,
        protocolName: String? = nil,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) {
        self.id = id
        self.userId = userId
        self.connectedAt = connectedAt
        self.disconnectedAt = disconnectedAt
        self.serverId = serverId
        self.serverName = serverName
        self.country = country
        self.protocolName = protocolName
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
    }

    var duration: TimeInterval { max(0, disconnectedAt.timeIntervalSince(connectedAt)) }
}

@MainActor
protocol LocalStatisticsRecording {
    func record(
        sessionID: UUID,
        userId: String,
        connectedAt: Date,
        disconnectedAt: Date,
        server: VPNServer,
        protocolName: VPNConfigurationProtocol,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) throws
    func clear(userId: String) throws
}

@MainActor
final class SwiftDataStatisticsRecorder: LocalStatisticsRecording {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func record(
        sessionID: UUID,
        userId: String,
        connectedAt: Date,
        disconnectedAt: Date,
        server: VPNServer,
        protocolName: VPNConfigurationProtocol,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) throws {
        let descriptor = FetchDescriptor<LocalConnectionRecord>(
            predicate: #Predicate { $0.id == sessionID }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.userId = userId
            existing.connectedAt = connectedAt
            existing.disconnectedAt = disconnectedAt
            existing.serverId = server.id
            existing.serverName = server.serverName
            existing.country = server.country
            existing.protocolName = protocolName.rawValue
            existing.downloadedBytes = downloadedBytes
            existing.uploadedBytes = uploadedBytes
        } else {
            context.insert(LocalConnectionRecord(
                id: sessionID,
                userId: userId,
                connectedAt: connectedAt,
                disconnectedAt: disconnectedAt,
                serverId: server.id,
                serverName: server.serverName,
                country: server.country,
                protocolName: protocolName.rawValue,
                downloadedBytes: downloadedBytes,
                uploadedBytes: uploadedBytes
            ))
        }
        try context.save()
    }

    func clear(userId: String) throws {
        let descriptor = FetchDescriptor<LocalConnectionRecord>(
            predicate: #Predicate { $0.userId == userId }
        )
        for record in try context.fetch(descriptor) {
            context.delete(record)
        }
        try context.save()
    }
}

struct LocalStatisticsSummary {
    let records: [LocalConnectionRecord]
    let interval: DateInterval

    var filtered: [LocalConnectionRecord] {
        records.filter { interval.contains($0.connectedAt) }
    }

    var downloadedBytes: Int64 { filtered.reduce(0) { $0 + $1.downloadedBytes } }
    var uploadedBytes: Int64 { filtered.reduce(0) { $0 + $1.uploadedBytes } }
    var totalBytes: Int64 { downloadedBytes + uploadedBytes }
    var connectedDuration: TimeInterval { filtered.reduce(0) { $0 + $1.duration } }
}

extension ByteCountFormatter {
    static func libreGuardString(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        return formatter.string(fromByteCount: bytes)
    }
}

protocol TunnelTrafficSampling {
    func currentSnapshot() -> TunnelTrafficSnapshot?
}

struct SystemTunnelTrafficSampler: TunnelTrafficSampling {
    func currentSnapshot() -> TunnelTrafficSnapshot? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var downloadedBytes: Int64 = 0
        var uploadedBytes: Int64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("utun"),
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else {
                continue
            }

            downloadedBytes += Int64(data.pointee.ifi_ibytes)
            uploadedBytes += Int64(data.pointee.ifi_obytes)
        }

        return TunnelTrafficSnapshot(
            downloadedBytes: downloadedBytes,
            uploadedBytes: uploadedBytes
        )
    }
}
