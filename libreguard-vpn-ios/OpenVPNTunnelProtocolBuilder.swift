import Foundation
import NetworkExtension
import TunnelKitOpenVPNCore
import TunnelKitOpenVPNManager
internal import TunnelKitCore

protocol OpenVPNTunnelProtocolBuilding {
    nonisolated func makeTunnelProtocol(configuration: String, privateKeyPassphrase: String) throws -> NETunnelProviderProtocol
}

struct TunnelKitOpenVPNProtocolBuilder: OpenVPNTunnelProtocolBuilding {
    nonisolated init() {}

    nonisolated func makeTunnelProtocol(configuration: String, privateKeyPassphrase: String) throws -> NETunnelProviderProtocol {
        try OpenVPNProfilePreflightValidator.validate(configuration)
        let parsed = try OpenVPN.ConfigurationParser.parsed(
            fromLines: configuration.components(separatedBy: .newlines),
            isClient: true,
            passphrase: privateKeyPassphrase
        )
        var sessionBuilder = parsed.configuration.builder()
        sessionBuilder.dnsProtocol = .plain
        sessionBuilder.dnsServers = [LibreGuardDNS.regularResolverAddress]
        sessionBuilder.dnsHTTPSURL = nil
        sessionBuilder.dnsTLSServerName = nil
        let providerConfiguration = OpenVPNProvider.ConfigurationBuilder(
            sessionConfiguration: sessionBuilder.build()
        ).build()
        let tunnelProtocol = try providerConfiguration.generatedTunnelProtocol(
            withBundleIdentifier: OpenVPNConstants.tunnelBundleIdentifier,
            appGroup: OpenVPNConstants.appGroupIdentifier,
            context: OpenVPNConstants.tunnelBundleIdentifier,
            credentials: nil
        )
        if !privateKeyPassphrase.isEmpty,
           let serializedConfiguration = try? PropertyListSerialization.data(
               fromPropertyList: tunnelProtocol.providerConfiguration ?? [:],
               format: .binary,
               options: 0
           ),
           serializedConfiguration.range(of: Data(privateKeyPassphrase.utf8)) != nil {
            throw OpenVPNConfigurationError.passphraseSerializationDetected
        }
        return tunnelProtocol
    }
}

enum OpenVPNProfilePreflightValidator {
    nonisolated static func validate(_ configuration: String) throws {
        let lines = configuration.components(separatedBy: .newlines)
        var directives: [(String, [String])] = []
        var inlineBlocks = Set<String>()
        var currentBlock: String?

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let block = currentBlock {
                if line.caseInsensitiveCompare("</\(block)>") == .orderedSame {
                    inlineBlocks.insert(block)
                    currentBlock = nil
                }
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                currentBlock = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let name = tokens.first?.lowercased() else { continue }
            directives.append((name, Array(tokens.dropFirst())))
        }

        guard currentBlock == nil else { throw OpenVPNConfigurationError.malformedInlineBlock }
        guard directives.contains(where: { $0.0 == "client" }) else {
            throw OpenVPNConfigurationError.missingDirective("client")
        }
        guard directives.contains(where: { $0.0 == "dev" && $0.1.first?.lowercased() == "tun" }) else {
            throw OpenVPNConfigurationError.unsupportedDevice
        }
        guard directives.contains(where: { $0.0 == "remote" && !$0.1.isEmpty }) else {
            throw OpenVPNConfigurationError.missingDirective("remote")
        }
        guard directives.contains(where: { $0.0 == "proto" && !$0.1.isEmpty }) else {
            throw OpenVPNConfigurationError.missingDirective("proto")
        }
        for unsupported in ["fragment", "secret", "tap"] where directives.contains(where: { $0.0 == unsupported }) {
            throw OpenVPNConfigurationError.unsupportedDirective(unsupported)
        }
        for requiredBlock in ["ca", "cert", "key", "tls-crypt"] where !inlineBlocks.contains(requiredBlock) {
            throw OpenVPNConfigurationError.missingInlineBlock(requiredBlock)
        }
    }
}

enum OpenVPNConfigurationError: LocalizedError, Equatable {
    case missingDirective(String)
    case missingInlineBlock(String)
    case unsupportedDirective(String)
    case unsupportedDevice
    case malformedInlineBlock
    case passphraseSerializationDetected

    nonisolated var errorDescription: String? {
        switch self {
        case .missingDirective(let name):
            return "The OpenVPN profile is missing the required \(name) directive."
        case .missingInlineBlock(let name):
            return "The OpenVPN profile is missing the required inline <\(name)> block."
        case .unsupportedDirective(let name):
            return "The OpenVPN profile uses the unsupported \(name) directive."
        case .unsupportedDevice:
            return "The OpenVPN profile must use a TUN device."
        case .malformedInlineBlock:
            return "The OpenVPN profile contains an unclosed inline block."
        case .passphraseSerializationDetected:
            return "The OpenVPN private-key passphrase was not stored because it appeared in the tunnel configuration."
        }
    }
}
