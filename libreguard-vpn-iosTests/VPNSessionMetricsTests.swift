import Foundation
import Testing
@testable import libreguard_vpn_ios

struct VPNSessionMetricsTests {
    @Test func accumulatorProducesSessionTotalsAndSeparateLiveRates() {
        var accumulator = VPNTrafficAccumulator()
        let start = Date(timeIntervalSince1970: 1_000)

        let initial = accumulator.consume(
            TunnelTrafficSnapshot(downloadedBytes: 100, uploadedBytes: 40),
            at: start
        )
        let updated = accumulator.consume(
            TunnelTrafficSnapshot(downloadedBytes: 600, uploadedBytes: 240),
            at: start.addingTimeInterval(2)
        )

        #expect(initial.downloadedBytes == 0)
        #expect(initial.uploadedBytes == 0)
        #expect(updated.downloadedBytes == 500)
        #expect(updated.uploadedBytes == 200)
        #expect(updated.downloadBitsPerSecond == 2_000)
        #expect(updated.uploadBitsPerSecond == 800)
    }

    @Test func accumulatorRebasesWhenTunnelCountersReset() {
        var accumulator = VPNTrafficAccumulator()
        let start = Date(timeIntervalSince1970: 2_000)
        _ = accumulator.consume(
            TunnelTrafficSnapshot(downloadedBytes: 1_000, uploadedBytes: 500),
            at: start
        )
        _ = accumulator.consume(
            TunnelTrafficSnapshot(downloadedBytes: 1_500, uploadedBytes: 700),
            at: start.addingTimeInterval(1)
        )

        let reset = accumulator.consume(
            TunnelTrafficSnapshot(downloadedBytes: 20, uploadedBytes: 10),
            at: start.addingTimeInterval(2)
        )
        let afterReset = accumulator.consume(
            TunnelTrafficSnapshot(downloadedBytes: 120, uploadedBytes: 60),
            at: start.addingTimeInterval(3)
        )

        #expect(reset.downloadedBytes == 500)
        #expect(reset.downloadBitsPerSecond == 0)
        #expect(afterReset.downloadedBytes == 600)
        #expect(afterReset.uploadedBytes == 250)
        #expect(afterReset.downloadBitsPerSecond == 800)
        #expect(afterReset.uploadBitsPerSecond == 400)
    }

    @Test func trafficFormattingUsesReadableTotalsAndBitRates() {
        #expect(VPNTrafficFormatting.bitRate(12_800_000) == "12.8 Mbps")
        #expect(VPNTrafficFormatting.bitRate(640_000) == "640 Kbps")
        #expect(VPNTrafficFormatting.byteCount(1_048_576).contains("1"))
        #expect(VPNTrafficFormatting.byteCount(1_048_576).contains("MB"))
    }
}
