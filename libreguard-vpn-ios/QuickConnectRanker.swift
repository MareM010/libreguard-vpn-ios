import Foundation

struct QuickConnectRanker {
    static let maximumLatencyMilliseconds = 400

    struct RankedServer: Equatable {
        let server: VPNServer
        let score: Double
        let latency: Int
        let load: Int
    }

    static func bestServer(
        in servers: [VPNServer],
        latencies: [Int: Int],
        isProUser: Bool
    ) -> VPNServer? {
        rankedServers(in: servers, latencies: latencies, isProUser: isProUser).first?.server
    }

    static func rankedServers(
        in servers: [VPNServer],
        latencies: [Int: Int],
        isProUser: Bool
    ) -> [RankedServer] {
        servers
            .filter { isProUser || !$0.requiresProSubscription }
            .map { server in
                let latency = normalizedLatency(latencies[server.id])
                let load = normalizedLoad(for: server)
                let latencyQuality = 1 - Double(latency) / Double(maximumLatencyMilliseconds)
                let loadQuality = 1 - pow(Double(load) / 100, 2)
                let proBonus = isProUser && server.requiresProSubscription ? 10.0 : 0.0

                return RankedServer(
                    server: server,
                    score: 45 * latencyQuality + 45 * loadQuality + proBonus,
                    latency: latency,
                    load: load
                )
            }
            .sorted(by: ranksAhead)
    }

    private static func normalizedLatency(_ latency: Int?) -> Int {
        min(max(latency ?? maximumLatencyMilliseconds, 0), maximumLatencyMilliseconds)
    }

    private static func normalizedLoad(for server: VPNServer) -> Int {
        guard server.loadDataFresh, let load = server.load else { return 100 }
        return min(max(load, 0), 100)
    }

    private static func ranksAhead(_ lhs: RankedServer, _ rhs: RankedServer) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.latency != rhs.latency { return lhs.latency < rhs.latency }
        if lhs.load != rhs.load { return lhs.load < rhs.load }
        let nameOrder = lhs.server.serverName.localizedStandardCompare(rhs.server.serverName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.server.id < rhs.server.id
    }
}
