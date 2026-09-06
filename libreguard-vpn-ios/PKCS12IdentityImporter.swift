import Foundation
import Security

enum IKEv2ClientCertificateKeyType: String, Equatable {
    case rsa
    case ecdsa256 = "ecdsa-p256"
    case ecdsa384 = "ecdsa-p384"
    case ecdsa521 = "ecdsa-p521"
}

struct ImportedPKCS12Identity {
    let data: Data
    let leafCertificateDER: Data
    let keyType: IKEv2ClientCertificateKeyType
}

protocol PKCS12IdentityImporting {
    func importIdentity(from data: Data, passphrase: String) throws -> ImportedPKCS12Identity
}

struct SecurityPKCS12IdentityImporter: PKCS12IdentityImporting {
    func importIdentity(from data: Data, passphrase: String) throws -> ImportedPKCS12Identity {
        let options: NSDictionary = [kSecImportExportPassphrase as String: passphrase]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let importedItems = items as? [[String: Any]],
              let identityValue = importedItems.lazy.compactMap({
                  $0[kSecImportItemIdentity as String]
              }).first else {
            throw VPNConfigurationError.invalidPKCS12Payload
        }
        let cfIdentity = identityValue as CFTypeRef
        guard CFGetTypeID(cfIdentity) == SecIdentityGetTypeID() else {
            throw VPNConfigurationError.invalidPKCS12Payload
        }
        let identity = unsafeBitCast(cfIdentity, to: SecIdentity.self)

        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            throw VPNConfigurationError.invalidPKCS12Payload
        }

        let keyType = try certificateKeyType(certificate)

        return ImportedPKCS12Identity(
            data: data,
            leafCertificateDER: SecCertificateCopyData(certificate) as Data,
            keyType: keyType
        )
    }

    private func certificateKeyType(_ certificate: SecCertificate) throws -> IKEv2ClientCertificateKeyType {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(publicKey) as? [String: Any],
              let rawKeyType = attributes[kSecAttrKeyType as String] as? String else {
            throw VPNConfigurationError.invalidIKEv2ClientCertificate
        }

        if rawKeyType == kSecAttrKeyTypeRSA as String {
            return .rsa
        }

        guard rawKeyType == kSecAttrKeyTypeECSECPrimeRandom as String,
              let keySize = attributes[kSecAttrKeySizeInBits as String] as? NSNumber else {
            throw VPNConfigurationError.unsupportedIKEv2ClientCertificateType
        }

        switch keySize.intValue {
        case 256:
            return .ecdsa256
        case 384:
            return .ecdsa384
        case 521:
            return .ecdsa521
        default:
            throw VPNConfigurationError.unsupportedIKEv2ClientCertificateType
        }
    }
}
