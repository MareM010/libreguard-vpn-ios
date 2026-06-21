import Foundation
import SwiftData

@Model
final class LocalConnectionRecord {
    @Attribute(.unique) var id: UUID
    var connectedAt: Date
    var disconnectedAt: Date
    var serverId: Int?
    var serverName: String
    var country: String
    var downloadedBytes: Int64
    var uploadedBytes: Int64

    init(
        id: UUID = UUID(),
        connectedAt: Date,
        disconnectedAt: Date,
        serverId: Int? = nil,
        serverName: String,
        country: String,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) {
        self.id = id
        self.connectedAt = connectedAt
        self.disconnectedAt = disconnectedAt
        self.serverId = serverId
        self.serverName = serverName
        self.country = country
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
    }

    var duration: TimeInterval { max(0, disconnectedAt.timeIntervalSince(connectedAt)) }
}

@MainActor
protocol LocalStatisticsRecording {
    func record(
        connectedAt: Date,
        disconnectedAt: Date,
        server: VPNServer,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) throws
    func clear() throws
}

@MainActor
final class SwiftDataStatisticsRecorder: LocalStatisticsRecording {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func record(
        connectedAt: Date,
        disconnectedAt: Date,
        server: VPNServer,
        downloadedBytes: Int64,
        uploadedBytes: Int64
    ) throws {
        context.insert(LocalConnectionRecord(
            connectedAt: connectedAt,
            disconnectedAt: disconnectedAt,
            serverId: server.id,
            serverName: server.serverName,
            country: server.country,
            downloadedBytes: downloadedBytes,
            uploadedBytes: uploadedBytes
        ))
        try context.save()
    }

    func clear() throws {
        try context.delete(model: LocalConnectionRecord.self)
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
