import CryptoKit
import Foundation
import NetworkExtension
import OSLog

final class VPNConfigurationTranslator {
    private let deviceKeyStore: VPNDeviceKeyProviding
    private let pkcs12Importer: PKCS12IdentityImporting
    private let certificateIdentityResolver: IKEv2CertificateIdentityResolving
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "libreguard-vpn-ios",
        category: "IKEv2Configuration"
    )

    init(
        deviceKeyStore: VPNDeviceKeyProviding = VPNDeviceKeyStore(),
        pkcs12Importer: PKCS12IdentityImporting = SecurityPKCS12IdentityImporter(),
        certificateIdentityResolver: IKEv2CertificateIdentityResolving = X509IKEv2CertificateIdentityResolver()
    ) {
        self.deviceKeyStore = deviceKeyStore
        self.pkcs12Importer = pkcs12Importer
        self.certificateIdentityResolver = certificateIdentityResolver
    }

    func makeProtocol(
        server: VPNServer,
        response: VPNConfigResponse,
        policy: VPNConnectionPolicy = .disabled
    ) throws -> NEVPNProtocolIKEv2 {
        let profile = try decodeProfile(from: response.configContent)
        let passphrase = try deviceKeyStore.decryptPassphrase(from: response.encryptedPassphrase)
        try validateSanitizedPassword(profile.localPassword)
        let importedIdentity = try decodePKCS12(profile: profile, passphrase: passphrase)
        let clientIdentity = try certificateIdentityResolver.resolve(
            localIdentifier: profile.localIdentifier,
            leafCertificateDER: importedIdentity.leafCertificateDER
        )
        let enablePFS = shouldEnablePFS(profile: profile)

        let counts = clientIdentity.sanCounts
        let fingerprint = abbreviatedFingerprint(for: importedIdentity.leafCertificateDER)
        logger.info(
            "Resolved IKEv2 client identity source=\(clientIdentity.source.rawValue, privacy: .public) type=\(clientIdentity.kind.rawValue, privacy: .public) dnsSANs=\(counts.fqdn, privacy: .public) emailSANs=\(counts.rfc822, privacy: .public) ipSANs=\(counts.ipAddress, privacy: .public) certificateFingerprint=\(fingerprint, privacy: .public) identity=\(clientIdentity.value, privacy: .private(mask: .hash))"
        )

        let vpnProtocol = NEVPNProtocolIKEv2()
        let serverAddress = resolvedServerAddress(from: profile, response: response, server: server)
        vpnProtocol.serverAddress = serverAddress
        vpnProtocol.remoteIdentifier = resolvedRemoteIdentifier(from: profile, server: server, fallback: serverAddress)
        vpnProtocol.localIdentifier = clientIdentity.value
        vpnProtocol.authenticationMethod = NEVPNIKEAuthenticationMethod(rawValue: 1)!
        vpnProtocol.useExtendedAuthentication = false
        vpnProtocol.identityData = importedIdentity.data
        vpnProtocol.identityDataPassword = passphrase
        vpnProtocol.certificateType = NEVPNIKEv2CertificateType(rawValue: profile.localUsesRSAPSS ? 6 : 1) ?? NEVPNIKEv2CertificateType(rawValue: 1)!
        vpnProtocol.deadPeerDetectionRate = NEVPNIKEv2DeadPeerDetectionRate(rawValue: 2)!
        vpnProtocol.disableMOBIKE = false
        vpnProtocol.disableRedirect = false
        vpnProtocol.enablePFS = enablePFS
        vpnProtocol.enableRevocationCheck = false
        vpnProtocol.strictRevocationCheck = false
        vpnProtocol.useConfigurationAttributeInternalIPSubnet = false
        policy.apply(to: vpnProtocol)

        if let ikeParameters = vpnProtocol.value(forKey: "IKESecurityAssociationParameters") as? NEVPNIKEv2SecurityAssociationParameters
            ?? vpnProtocol.value(forKey: "ikeSecurityAssociationParameters") as? NEVPNIKEv2SecurityAssociationParameters {
            apply(proposal: profile.ikeProposal, to: ikeParameters, isChild: false, enablePFS: enablePFS)
        }

        if let childParameters = vpnProtocol.value(forKey: "childSecurityAssociationParameters") as? NEVPNIKEv2SecurityAssociationParameters {
            apply(proposal: profile.espProposal, to: childParameters, isChild: true, enablePFS: enablePFS)
        }

        return vpnProtocol
    }

    private func decodeProfile(from configContent: String) throws -> SSWANProfile {
        guard let data = configContent.data(using: .utf8) else {
            throw VPNConfigurationError.invalidConfigContent
        }
        do {
            return try JSONDecoder().decode(SSWANProfile.self, from: data)
        } catch {
            throw VPNConfigurationError.invalidConfigContent
        }
    }

    private func validateSanitizedPassword(_ password: String?) throws {
        guard let password, !password.isEmpty else { return }
        guard password == VPNConfigurationTranslatorConstants.encryptedPassphrasePlaceholder else {
            throw VPNConfigurationError.unexpectedPlaintextPassword
        }
    }

    private func decodePKCS12(profile: SSWANProfile, passphrase: String) throws -> ImportedPKCS12Identity {
        guard let base64 = profile.localP12Base64?.sanitizedBase64,
              let p12Data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            throw VPNConfigurationError.invalidPKCS12Payload
        }
        return try pkcs12Importer.importIdentity(from: p12Data, passphrase: passphrase)
    }

    private func resolvedServerAddress(from profile: SSWANProfile, response: VPNConfigResponse, server: VPNServer) -> String {
        profile.remoteAddress?.sanitizedString
            ?? server.serverHostname?.sanitizedString
            ?? response.serverIp.sanitizedString
            ?? server.serverIp.sanitizedString
            ?? response.serverName.sanitizedString
            ?? server.serverName
    }

    private func resolvedRemoteIdentifier(from profile: SSWANProfile, server: VPNServer, fallback: String) -> String? {
        if let remoteIdentifier = profile.remoteIdentifier?.sanitizedString {
            return remoteIdentifier
        }
        if let hostname = server.serverHostname?.sanitizedString, !hostname.isEmpty {
            return hostname
        }
        guard let candidate = profile.remoteAddress?.sanitizedString ?? fallback.sanitizedString,
              candidate.isLikelyHostname else {
            return nil
        }
        return candidate
    }

    private func shouldEnablePFS(profile: SSWANProfile) -> Bool {
        containsPFS(profile.espProposal)
    }

    private func abbreviatedFingerprint(for certificateDER: Data) -> String {
        SHA256.hash(data: certificateDER)
            .prefix(6)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func containsPFS(_ proposal: String?) -> Bool {
        guard let proposal else { return false }
        let tokens = proposal.lowercased().proposalTokens
        return tokens.contains(where: { $0.hasPrefix("modp") || $0.hasPrefix("ecp") || $0.hasPrefix("curve") || $0 == "pfs" })
    }

    private func apply(proposal: String?, to parameters: NEVPNIKEv2SecurityAssociationParameters, isChild: Bool, enablePFS: Bool) {
        let tokens = proposal?.lowercased().proposalTokens ?? []

        if let encryption = Self.parseEncryptionAlgorithm(from: tokens) {
            parameters.encryptionAlgorithm = encryption
        }

        if let integrity = Self.parseIntegrityAlgorithm(from: tokens) {
            parameters.integrityAlgorithm = integrity
        }

        if let group = Self.parseDiffieHellmanGroup(from: tokens) {
            parameters.diffieHellmanGroup = group
        } else if isChild, enablePFS {
            parameters.diffieHellmanGroup = NEVPNIKEv2DiffieHellmanGroup(rawValue: 14) ?? parameters.diffieHellmanGroup
        }
    }

    private static func parseEncryptionAlgorithm(from tokens: [String]) -> NEVPNIKEv2EncryptionAlgorithm? {
        if tokens.contains(where: { $0.hasPrefix("chacha20poly1305") }) {
            return NEVPNIKEv2EncryptionAlgorithm(rawValue: 7)
        }
        if tokens.contains(where: { $0.hasPrefix("aes256gcm") }) {
            return NEVPNIKEv2EncryptionAlgorithm(rawValue: 6)
        }
        if tokens.contains(where: { $0.hasPrefix("aes128gcm") }) {
            return NEVPNIKEv2EncryptionAlgorithm(rawValue: 5)
        }
        if tokens.contains(where: { $0.hasPrefix("aes256") }) {
            return NEVPNIKEv2EncryptionAlgorithm(rawValue: 4)
        }
        if tokens.contains(where: { $0.hasPrefix("aes128") }) {
            return NEVPNIKEv2EncryptionAlgorithm(rawValue: 3)
        }
        if tokens.contains(where: { $0.hasPrefix("3des") }) {
            return NEVPNIKEv2EncryptionAlgorithm(rawValue: 2)
        }
        if tokens.contains(where: { $0 == "des" }) {
            return NEVPNIKEv2EncryptionAlgorithm(rawValue: 1)
        }
        return NEVPNIKEv2EncryptionAlgorithm(rawValue: 4)
    }

    private static func parseIntegrityAlgorithm(from tokens: [String]) -> NEVPNIKEv2IntegrityAlgorithm? {
        if tokens.contains(where: { $0.hasPrefix("sha512") }) {
            return NEVPNIKEv2IntegrityAlgorithm(rawValue: 5)
        }
        if tokens.contains(where: { $0.hasPrefix("sha384") }) {
            return NEVPNIKEv2IntegrityAlgorithm(rawValue: 4)
        }
        if tokens.contains(where: { $0.hasPrefix("sha256") || $0.hasPrefix("prfsha256") }) {
            return NEVPNIKEv2IntegrityAlgorithm(rawValue: 3)
        }
        if tokens.contains(where: { $0.hasPrefix("sha160") || $0.hasPrefix("sha1") }) {
            return NEVPNIKEv2IntegrityAlgorithm(rawValue: 2)
        }
        return NEVPNIKEv2IntegrityAlgorithm(rawValue: 3)
    }

    private static func parseDiffieHellmanGroup(from tokens: [String]) -> NEVPNIKEv2DiffieHellmanGroup? {
        if tokens.contains(where: { $0.contains("group14") || $0.contains("modp2048") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 14)
        }
        if tokens.contains(where: { $0.contains("group15") || $0.contains("modp3072") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 15)
        }
        if tokens.contains(where: { $0.contains("group16") || $0.contains("modp4096") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 16)
        }
        if tokens.contains(where: { $0.contains("group17") || $0.contains("modp6144") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 17)
        }
        if tokens.contains(where: { $0.contains("group18") || $0.contains("modp8192") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 18)
        }
        if tokens.contains(where: { $0.contains("group19") || $0.contains("ecp256") || $0.contains("p256") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 19)
        }
        if tokens.contains(where: { $0.contains("group20") || $0.contains("ecp384") || $0.contains("p384") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 20)
        }
        if tokens.contains(where: { $0.contains("group21") || $0.contains("ecp521") || $0.contains("p521") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 21)
        }
        if tokens.contains(where: { $0.contains("group31") || $0.contains("x25519") || $0.contains("curve25519") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 31)
        }
        if tokens.contains(where: { $0.contains("group32") || $0.contains("curve448") }) {
            return NEVPNIKEv2DiffieHellmanGroup(rawValue: 32)
        }
        return nil
    }
}

private enum VPNConfigurationTranslatorConstants {
    static let encryptedPassphrasePlaceholder = "[ENCRYPTED_PASSPHRASE]"
}

enum VPNConfigurationError: LocalizedError, Equatable {
    case invalidConfigContent
    case unexpectedPlaintextPassword
    case invalidPKCS12Payload
    case invalidIKEv2ClientCertificate
    case missingIKEv2ClientIdentity
    case unsupportedIKEv2ClientIdentity
    case mismatchedIKEv2ClientIdentity

    var errorDescription: String? {
        switch self {
        case .invalidConfigContent:
            return "The VPN configuration file could not be decoded."
        case .unexpectedPlaintextPassword:
            return "The VPN configuration exposed a plaintext certificate password and was rejected."
        case .invalidPKCS12Payload:
            return "The VPN certificate bundle is invalid."
        case .invalidIKEv2ClientCertificate:
            return "The VPN client certificate could not be inspected for a compatible IKEv2 identity."
        case .missingIKEv2ClientIdentity:
            return "This VPN certificate cannot be used for IKEv2 on iOS because it has no DNS, email, or IP Subject Alternative Name. Request a new certificate and try again."
        case .unsupportedIKEv2ClientIdentity:
            return "The VPN profile requests a client identity format that native IKEv2 on iOS does not support."
        case .mismatchedIKEv2ClientIdentity:
            return "The VPN profile's client identity does not match a DNS, email, or IP Subject Alternative Name in its certificate."
        }
    }
}

private extension String {
    var sanitizedString: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var sanitizedBase64: String {
        components(separatedBy: .whitespacesAndNewlines).joined()
    }

    var proposalTokens: [String] {
        components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    var isLikelyHostname: Bool {
        guard !isEmpty else { return false }
        return rangeOfCharacter(from: .letters) != nil
    }
}
