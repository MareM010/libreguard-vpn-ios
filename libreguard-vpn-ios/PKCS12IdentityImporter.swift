import Foundation
import Security

struct ImportedPKCS12Identity {
    let data: Data
    let leafCertificateDER: Data
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

        return ImportedPKCS12Identity(
            data: data,
            leafCertificateDER: SecCertificateCopyData(certificate) as Data
        )
    }
}
