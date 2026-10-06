import Darwin
import Foundation
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct VPNSessionMetricsTests {
    @Test func nativeIPSecTrafficIncreasesSessionCounters() throws {
        var accumulator = VPNTrafficAccumulator()
        let start = Date(timeIntervalSince1970: 1_000)
        let initial = sampleInterfaces([
            InterfaceFixture(name: "ipsec1", downloadedBytes: 100, uploadedBytes: 40),
            InterfaceFixture(name: "utun0", downloadedBytes: 800, uploadedBytes: 300)
        ])
        let updated = sampleInterfaces([
            InterfaceFixture(name: "ipsec1", downloadedBytes: 1_124, uploadedBytes: 552),
            InterfaceFixture(name: "utun0", downloadedBytes: 800, uploadedBytes: 300)
        ])

        _ = accumulator.consume(try #require(initial), at: start)
        let traffic = accumulator.consume(try #require(updated), at: start.addingTimeInterval(1))

        #expect(traffic.downloadedBytes == 1_024)
        #expect(traffic.uploadedBytes == 512)
        #expect(traffic.downloadBitsPerSecond == 8_192)
        #expect(traffic.uploadBitsPerSecond == 4_096)
    }

    @Test func samplerReadsNativeIPSecWithoutAnyUTunInterface() {
        #expect(sampleInterfaces([
            InterfaceFixture(name: "ipsec0", downloadedBytes: 2_048, uploadedBytes: 512),
            InterfaceFixture(name: "en0", downloadedBytes: 90_000, uploadedBytes: 50_000),
            InterfaceFixture(name: "pdp_ip0", downloadedBytes: 80_000, uploadedBytes: 40_000)
        ]) == TunnelTrafficSnapshot(downloadedBytes: 2_048, uploadedBytes: 512))
    }

    @Test func samplerCountsLinkCountersOncePerTunnelInterface() {
        #expect(sampleInterfaces([
            InterfaceFixture(name: "ipsec1", family: AF_INET, downloadedBytes: 99_000, uploadedBytes: 99_000),
            InterfaceFixture(name: "ipsec1", downloadedBytes: 2_048, uploadedBytes: 512),
            InterfaceFixture(name: "ipsec1", family: AF_INET6, downloadedBytes: 99_000, uploadedBytes: 99_000),
            InterfaceFixture(name: "ipsec1", downloadedBytes: 2_048, uploadedBytes: 512),
            InterfaceFixture(name: "utun2", downloadedBytes: 100, uploadedBytes: 40)
        ]) == TunnelTrafficSnapshot(downloadedBytes: 2_148, uploadedBytes: 552))
    }

    @Test func samplerPreservesUTunSupport() {
        #expect(sampleInterfaces([
            InterfaceFixture(name: "utun12", downloadedBytes: 800, uploadedBytes: 300)
        ]) == TunnelTrafficSnapshot(downloadedBytes: 800, uploadedBytes: 300))
    }

    @Test func samplerDistinguishesUnavailableCountersFromAnIdleTunnel() {
        #expect(sampleInterfaces([]) == nil)
        #expect(sampleInterfaces([
            InterfaceFixture(name: "en0", downloadedBytes: 1_000, uploadedBytes: 500),
            InterfaceFixture(name: "ipsec0", hasData: false),
            InterfaceFixture(name: "utun0", family: AF_INET)
        ]) == nil)
        #expect(sampleInterfaces([
            InterfaceFixture(name: "ipsec0")
        ]) == TunnelTrafficSnapshot(downloadedBytes: 0, uploadedBytes: 0))
    }

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

private struct InterfaceFixture {
    let name: String
    var family: Int32 = AF_LINK
    var downloadedBytes: UInt32 = 0
    var uploadedBytes: UInt32 = 0
    var hasData = true
}

/// Builds the same linked list returned by getifaddrs so tests exercise the
/// production interface parsing, including address families and missing data.
private func sampleInterfaces(_ fixtures: [InterfaceFixture]) -> TunnelTrafficSnapshot? {
    guard !fixtures.isEmpty else { return SystemTunnelTrafficSampler.snapshot(from: nil) }
    let interfaces = UnsafeMutablePointer<ifaddrs>.allocate(capacity: fixtures.count)
    let addresses = UnsafeMutablePointer<sockaddr>.allocate(capacity: fixtures.count)
    let counters = UnsafeMutablePointer<if_data>.allocate(capacity: fixtures.count)
    interfaces.initialize(repeating: ifaddrs(), count: fixtures.count)
    addresses.initialize(repeating: sockaddr(), count: fixtures.count)
    counters.initialize(repeating: if_data(), count: fixtures.count)
    defer {
        for index in fixtures.indices { free(interfaces[index].ifa_name) }
        interfaces.deinitialize(count: fixtures.count)
        interfaces.deallocate()
        addresses.deinitialize(count: fixtures.count)
        addresses.deallocate()
        counters.deinitialize(count: fixtures.count)
        counters.deallocate()
    }

    for (index, fixture) in fixtures.enumerated() {
        addresses[index].sa_family = UInt8(fixture.family)
        counters[index].ifi_ibytes = fixture.downloadedBytes
        counters[index].ifi_obytes = fixture.uploadedBytes
        interfaces[index].ifa_name = strdup(fixture.name)
        interfaces[index].ifa_addr = addresses.advanced(by: index)
        interfaces[index].ifa_data = fixture.hasData ? UnsafeMutableRawPointer(counters.advanced(by: index)) : nil
        interfaces[index].ifa_next = index + 1 < fixtures.count ? interfaces.advanced(by: index + 1) : nil
    }
    return SystemTunnelTrafficSampler.snapshot(from: interfaces)
}
