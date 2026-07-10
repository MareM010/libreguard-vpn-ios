import Foundation
import Testing
@testable import libreguard_vpn_ios

struct QuickConnectRankerTests {
    @Test func balancesLatencyAndNonlinearLoadPenalty() throws {
        let lowLatencyBusy = try makeServer(id: 1, name: "Busy", load: 90)
        let slightlySlowerLightlyLoaded = try makeServer(id: 2, name: "Light", load: 20)

        let best = QuickConnectRanker.bestServer(
            in: [lowLatencyBusy, slightlySlowerLightlyLoaded],
            latencies: [1: 20, 2: 55],
            isProUser: false
        )

        #expect(best?.id == 2)
    }

    @Test func freeUsersCannotRankProServers() throws {
        let free = try makeServer(id: 1, name: "Free", load: 70)
        let pro = try makeServer(id: 2, name: "Pro", tier: "Premium", load: 5)

        let best = QuickConnectRanker.bestServer(
            in: [free, pro],
            latencies: [1: 150, 2: 5],
            isProUser: false
        )

        #expect(best?.id == free.id)
    }

    @Test func proServerBonusBreaksClosePerformanceComparisonForProUsers() throws {
        let free = try makeServer(id: 1, name: "Free", load: 20)
        let pro = try makeServer(id: 2, name: "Pro", tier: "Premium", load: 20)

        let best = QuickConnectRanker.bestServer(
            in: [free, pro],
            latencies: [1: 40, 2: 75],
            isProUser: true
        )

        #expect(best?.id == pro.id)
    }

    @Test func missingMetricsUseConservativeDefaultsAndTiesAreDeterministic() throws {
        let missing = try makeServer(id: 1, name: "Missing", load: nil, loadDataFresh: false)
        let measured = try makeServer(id: 2, name: "Measured", load: 80)
        let beta = try makeServer(id: 4, name: "Beta", load: 20)
        let alpha = try makeServer(id: 3, name: "Alpha", load: 20)

        let ranked = QuickConnectRanker.rankedServers(
            in: [missing, measured, beta, alpha],
            latencies: [2: 300, 3: 50, 4: 50],
            isProUser: false
        )

        #expect(ranked.map(\.server.id) == [3, 4, 2, 1])
    }

    private func makeServer(
        id: Int,
        name: String,
        tier: String = "Free",
        load: Int?,
        loadDataFresh: Bool = true
    ) throws -> VPNServer {
        try JSONDecoder().decode(VPNServer.self, from: JSONSerialization.data(withJSONObject: [
            "id": id,
            "serverName": name,
            "serverIp": "203.0.113.\(id)",
            "country": "Germany",
            "city": "Frankfurt",
            "linkSpeed": 1000,
            "pricingTier": tier,
            "load": load.map { NSNumber(value: $0) } ?? NSNull(),
            "activeConnections": NSNull(),
            "latencyPingPort": 5001,
            "loadDataFresh": loadDataFresh
        ]))
    }
}
