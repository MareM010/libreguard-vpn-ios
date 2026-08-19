import Darwin
import Foundation
import SwiftASN1
import X509

enum IKEv2ClientIdentityKind: String, Equatable {
    case fqdn
    case rfc822
    case ipAddress = "ip-address"
}

enum IKEv2ClientIdentitySource: String, Equatable {
    case profile = "profile-local-id"
    case certificate = "certificate-san"
}

struct IKEv2SubjectAlternativeNameCounts: Equatable {
    let fqdn: Int
    let rfc822: Int
    let ipAddress: Int

    var total: Int { fqdn + rfc822 + ipAddress }
}

struct IKEv2ClientIdentityResolution: Equatable {
    let value: String
    let kind: IKEv2ClientIdentityKind
    let source: IKEv2ClientIdentitySource
    let sanCounts: IKEv2SubjectAlternativeNameCounts
}

protocol IKEv2CertificateIdentityResolving {
    func resolve(localIdentifier: String?, leafCertificateDER: Data) throws -> IKEv2ClientIdentityResolution
}

struct X509IKEv2CertificateIdentityResolver: IKEv2CertificateIdentityResolving {
    func resolve(localIdentifier: String?, leafCertificateDER: Data) throws -> IKEv2ClientIdentityResolution {
        let candidates: [Candidate]
        do {
            let certificate = try Certificate(derEncoded: Array(leafCertificateDER))
            let subjectAlternativeNames = try certificate.extensions.subjectAlternativeNames
            if let subjectAlternativeNames {
                candidates = Self.supportedCandidates(from: subjectAlternativeNames)
            } else {
                candidates = []
            }
        } catch {
            throw VPNConfigurationError.invalidIKEv2ClientCertificate
        }

        let counts = IKEv2SubjectAlternativeNameCounts(
            fqdn: candidates.count(where: { $0.kind == .fqdn }),
            rfc822: candidates.count(where: { $0.kind == .rfc822 }),
            ipAddress: candidates.count(where: { $0.kind == .ipAddress })
        )

        if let localIdentifier = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localIdentifier.isEmpty {
            let requested = try Self.requestedIdentity(from: localIdentifier)
            guard let match = candidates.first(where: {
                $0.kind == requested.kind && $0.comparisonValue == requested.comparisonValue
            }) else {
                throw VPNConfigurationError.mismatchedIKEv2ClientIdentity
            }
            return IKEv2ClientIdentityResolution(
                value: match.value,
                kind: match.kind,
                source: .profile,
                sanCounts: counts
            )
        }

        guard let first = candidates.first else {
            throw VPNConfigurationError.missingIKEv2ClientIdentity
        }
        return IKEv2ClientIdentityResolution(
            value: first.value,
            kind: first.kind,
            source: .certificate,
            sanCounts: counts
        )
    }

    private static func supportedCandidates(from names: SubjectAlternativeNames) -> [Candidate] {
        var candidates: [Candidate] = []
        var seen: Set<CandidateKey> = []

        for name in names {
            let candidate: Candidate?
            switch name {
            case let .dnsName(value):
                candidate = fqdnCandidate(value)
            case let .rfc822Name(value):
                candidate = rfc822Candidate(value)
            case let .ipAddress(address):
                candidate = ipAddressCandidate(bytes: Array(address.bytes))
            default:
                candidate = nil
            }

            guard let candidate, seen.insert(candidate.key).inserted else { continue }
            candidates.append(candidate)
        }
        return candidates
    }

    private static func requestedIdentity(from rawValue: String) throws -> Candidate {
        let lowercaseValue = rawValue.lowercased()

        if lowercaseValue.hasPrefix("fqdn:") {
            guard let candidate = fqdnCandidate(String(rawValue.dropFirst("fqdn:".count))) else {
                throw VPNConfigurationError.unsupportedIKEv2ClientIdentity
            }
            return candidate
        }
        if lowercaseValue.hasPrefix("rfc822:") {
            guard let candidate = rfc822Candidate(String(rawValue.dropFirst("rfc822:".count))) else {
                throw VPNConfigurationError.unsupportedIKEv2ClientIdentity
            }
            return candidate
        }
        if lowercaseValue.hasPrefix("asn1dn:") || lowercaseValue.hasPrefix("keyid:") || rawValue.contains("=") {
            throw VPNConfigurationError.unsupportedIKEv2ClientIdentity
        }
        if let canonicalIP = canonicalIPAddress(rawValue) {
            return Candidate(kind: .ipAddress, value: canonicalIP, comparisonValue: canonicalIP)
        }
        if rawValue.contains(":") {
            throw VPNConfigurationError.unsupportedIKEv2ClientIdentity
        }
        if rawValue.contains("@") {
            guard let candidate = rfc822Candidate(rawValue) else {
                throw VPNConfigurationError.unsupportedIKEv2ClientIdentity
            }
            return candidate
        }
        guard let candidate = fqdnCandidate(rawValue) else {
            throw VPNConfigurationError.unsupportedIKEv2ClientIdentity
        }
        return candidate
    }

    private static func fqdnCandidate(_ rawValue: String) -> Candidate? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }),
              !value.contains("@"),
              !value.contains("=") else {
            return nil
        }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        guard isValidDNSName(value) else { return nil }
        return Candidate(kind: .fqdn, value: value, comparisonValue: value.lowercased())
    }

    private static func isValidDNSName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  let first = label.unicodeScalars.first,
                  let last = label.unicodeScalars.last,
                  isASCIIAlphaNumeric(first),
                  isASCIIAlphaNumeric(last) else {
                return false
            }
            return label.unicodeScalars.allSatisfy {
                isASCIIAlphaNumeric($0) || $0.value == 45
            }
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
        (48...57).contains(scalar.value)
            || (65...90).contains(scalar.value)
            || (97...122).contains(scalar.value)
    }

    private static func rfc822Candidate(_ rawValue: String) -> Candidate? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              value.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else {
            return nil
        }
        return Candidate(kind: .rfc822, value: value, comparisonValue: value.lowercased())
    }

    private static func ipAddressCandidate(bytes: [UInt8]) -> Candidate? {
        guard let value = formattedIPAddress(bytes: bytes) else { return nil }
        return Candidate(kind: .ipAddress, value: value, comparisonValue: value)
    }

    private static func canonicalIPAddress(_ rawValue: String) -> String? {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, rawValue, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4) { formattedIPAddress(bytes: Array($0)) }
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, rawValue, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { formattedIPAddress(bytes: Array($0)) }
        }
        return nil
    }

    private static func formattedIPAddress(bytes: [UInt8]) -> String? {
        let family: Int32
        switch bytes.count {
        case MemoryLayout<in_addr>.size:
            family = AF_INET
        case MemoryLayout<in6_addr>.size:
            family = AF_INET6
        default:
            return nil
        }

        let address = bytes
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = output.withUnsafeMutableBufferPointer { outputBuffer in
            address.withUnsafeBytes { addressBuffer in
                inet_ntop(
                    family,
                    addressBuffer.baseAddress,
                    outputBuffer.baseAddress,
                    socklen_t(outputBuffer.count)
                )
            }
        }
        guard result != nil else { return nil }
        return String(cString: output)
    }
}

private struct Candidate: Hashable {
    let kind: IKEv2ClientIdentityKind
    let value: String
    let comparisonValue: String

    var key: CandidateKey {
        CandidateKey(kind: kind, comparisonValue: comparisonValue)
    }
}

private struct CandidateKey: Hashable {
    let kind: IKEv2ClientIdentityKind
    let comparisonValue: String
}
