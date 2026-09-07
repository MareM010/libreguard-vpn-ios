import Foundation
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct IPv6ProtectionTests {
    @Test func packetFilterDropsIPv6AndPreservesIPv4() {
        #expect(IPv6PacketFilter.shouldDrop(Data([0x60, 0x00, 0x00, 0x00])))
        #expect(!IPv6PacketFilter.shouldDrop(Data([0x45, 0x00, 0x00, 0x00])))
        #expect(!IPv6PacketFilter.shouldDrop(Data()))

        let packets = [
            (Data([0x60, 0x00]), true),
            (Data([0x45, 0x00]), false)
        ]
        for (packet, expected) in packets {
            #expect(IPv6PacketFilter.shouldDrop(packet) == expected)
        }
    }

    @Test func missingOrFalseOpenVPNBlockConfigurationFailsClosed() {
        #expect(!OpenVPNIPv6Protection.isEnabled(in: nil))
        #expect(!OpenVPNIPv6Protection.isEnabled(in: [:]))
        #expect(!OpenVPNIPv6Protection.isEnabled(in: [OpenVPNConstants.ipv6BlockingConfigurationKey: false]))
        #expect(OpenVPNIPv6Protection.isEnabled(in: [OpenVPNConstants.ipv6BlockingConfigurationKey: true]))
    }

    @Test func protectionStatusMatchesConnectionAndProtocol() {
        #expect(
            IPv6ProtectionStatus.resolve(
                connectionState: .disconnected,
                protocolName: .openVPN
            ) == .off
        )
        #expect(
            IPv6ProtectionStatus.resolve(
                connectionState: .connected,
                protocolName: .openVPN
            ) == .blocked
        )
        #expect(
            IPv6ProtectionStatus.resolve(
                connectionState: .reasserting,
                protocolName: .ikev2IPSec
            ) == .bestEffort
        )
    }
}
