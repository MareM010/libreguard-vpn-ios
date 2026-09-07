import Foundation

enum IPv6PacketFilter {
    static func shouldDrop(_ packet: Data) -> Bool {
        guard let firstByte = packet.first else { return false }
        return (firstByte >> 4) == 6
    }
}

enum OpenVPNIPv6Protection {
    static func isEnabled(in providerConfiguration: [String: Any]?) -> Bool {
        providerConfiguration?[OpenVPNConstants.ipv6BlockingConfigurationKey] as? Bool == true
    }
}
