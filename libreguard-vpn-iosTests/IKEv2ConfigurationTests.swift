import Foundation
import NetworkExtension
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct IKEv2ConfigurationTests {
    private let resolver = X509IKEv2CertificateIdentityResolver()

    @Test func sswanProfileUsesNestedIdentitiesAndCanonicalProposalPrecedence() throws {
        let profile = try decodeProfile(
            """
            {
              "name":"IKEV2_client1124",
              "id":"must-not-be-used",
              "uuid":"profile-uuid",
              "type":"ikev2-cert",
              "ike-proposal":"aes256-sha384-modp3072",
              "esp-proposal":"aes256-sha384-modp3072",
              "remote":{
                "addr":"167.86.87.129",
                "id":"de-multi-2.libreguard.net",
                "ike":"aes128-sha256-modp2048",
                "esp":"aes128-sha256"
              },
              "local":{
                "id":"client@example.com",
                "p12":"UEs=",
                "password":"[ENCRYPTED_PASSPHRASE]",
                "rsa-pss":true
              }
            }
            """
        )

        #expect(profile.name == "IKEV2_client1124")
        #expect(profile.localIdentifier == "client@example.com")
        #expect(profile.remoteIdentifier == "de-multi-2.libreguard.net")
        #expect(profile.ikeProposal == "aes256-sha384-modp3072")
        #expect(profile.espProposal == "aes256-sha384-modp3072")
        #expect(profile.localUsesRSAPSS)
    }

    @Test func sswanProfileFallsBackToLegacyRemoteProposals() throws {
        let profile = try decodeProfile(
            """
            {
              "name":"IKEV2_client1124",
              "type":"ikev2-cert",
              "remote":{
                "addr":"167.86.87.129",
                "ike":"aes256-sha256-modp2048",
                "esp":"aes256-sha256"
              },
              "local":{"p12":"UEs=","password":"[ENCRYPTED_PASSPHRASE]"}
            }
            """
        )

        #expect(profile.localIdentifier == nil)
        #expect(profile.ikeProposal == "aes256-sha256-modp2048")
        #expect(profile.espProposal == "aes256-sha256")
    }

    @Test func certificateSANFallbackUsesFirstSupportedIdentityAndDeduplicates() throws {
        let resolution = try resolver.resolve(
            localIdentifier: nil,
            leafCertificateDER: IKEv2CertificateFixtures.multiSANDER
        )

        #expect(resolution.value == "client@example.com")
        #expect(resolution.kind == .rfc822)
        #expect(resolution.source == .certificate)
        #expect(resolution.sanCounts == IKEv2SubjectAlternativeNameCounts(fqdn: 1, rfc822: 1, ipAddress: 2))
    }

    @Test func explicitLocalIdentifiersMustMatchTheCorrespondingCertificateSANType() throws {
        let cases: [(String, String, IKEv2ClientIdentityKind)] = [
            ("fqdn:CLIENT.EXAMPLE.COM", "client.example.com", .fqdn),
            ("rfc822:CLIENT@EXAMPLE.COM", "client@example.com", .rfc822),
            ("192.0.2.42", "192.0.2.42", .ipAddress),
            ("2001:0db8:0:0:0:0:0:42", "2001:db8::42", .ipAddress)
        ]

        for (requested, expected, kind) in cases {
            let resolution = try resolver.resolve(
                localIdentifier: requested,
                leafCertificateDER: IKEv2CertificateFixtures.multiSANDER
            )
            #expect(resolution.value == expected)
            #expect(resolution.kind == kind)
            #expect(resolution.source == .profile)
        }
    }

    @Test func invalidOrUncertifiedLocalIdentifiersAreRejectedWithoutFallback() {
        #expect(throws: VPNConfigurationError.mismatchedIKEv2ClientIdentity) {
            try resolver.resolve(
                localIdentifier: "different.example.com",
                leafCertificateDER: IKEv2CertificateFixtures.multiSANDER
            )
        }

        let unsupportedIdentities = [
            "asn1dn:CN=IKEV2_test_client",
            "keyid:client-key",
            "CN=IKEV2_test_client",
            "fqdn:-client.example.com",
            "fqdn:client..example.com",
            "fqdn:*.example.com",
            "client/example.com"
        ]
        for unsupported in unsupportedIdentities {
            #expect(throws: VPNConfigurationError.unsupportedIKEv2ClientIdentity) {
                try resolver.resolve(
                    localIdentifier: unsupported,
                    leafCertificateDER: IKEv2CertificateFixtures.multiSANDER
                )
            }
        }
    }

    @Test func missingOrMalformedCertificateSANsProduceActionableErrors() {
        #expect(throws: VPNConfigurationError.missingIKEv2ClientIdentity) {
            try resolver.resolve(
                localIdentifier: nil,
                leafCertificateDER: IKEv2CertificateFixtures.subjectOnlyDER
            )
        }
        #expect(throws: VPNConfigurationError.invalidIKEv2ClientCertificate) {
            try resolver.resolve(
                localIdentifier: nil,
                leafCertificateDER: Data([0x30, 0x01, 0x00])
            )
        }
    }

    @Test func securityImporterReturnsThePrivateKeyLeafCertificate() throws {
        let imported = try SecurityPKCS12IdentityImporter().importIdentity(
            from: IKEv2CertificateFixtures.multiSANPKCS12,
            passphrase: IKEv2CertificateFixtures.passphrase
        )

        #expect(imported.data == IKEv2CertificateFixtures.multiSANPKCS12)
        #expect(imported.leafCertificateDER == IKEv2CertificateFixtures.multiSANDER)
        #expect(throws: VPNConfigurationError.invalidPKCS12Payload) {
            try SecurityPKCS12IdentityImporter().importIdentity(
                from: IKEv2CertificateFixtures.multiSANPKCS12,
                passphrase: "wrong-passphrase"
            )
        }
    }

    @Test func translatorBuildsCertificateBackedIdentifiersAndKeepsIKEOnlyDHOutOfChildPFS() throws {
        let translator = VPNConfigurationTranslator(deviceKeyStore: StubVPNDeviceKeyStore())
        let vpnProtocol = try translator.makeProtocol(
            server: makeServer(),
            response: makeResponse(
                configContent: try makeConfigContent(
                    localIdentifier: "client.example.com",
                    espProposal: "aes256-sha256"
                )
            )
        )

        #expect(vpnProtocol.localIdentifier == "client.example.com")
        #expect(vpnProtocol.remoteIdentifier == "de-multi-2.libreguard.net")
        #expect(vpnProtocol.identityData == IKEv2CertificateFixtures.multiSANPKCS12)
        #expect(vpnProtocol.certificateType.rawValue == 6)
        #expect(vpnProtocol.enablePFS == false)
        #expect(vpnProtocol.includeAllNetworks == false)
        #expect(vpnProtocol.enforceRoutes == false)
    }

    @Test func translatorEnforcesRoutesOnlyWithIKEv2KillSwitch() throws {
        let translator = VPNConfigurationTranslator(deviceKeyStore: StubVPNDeviceKeyStore())
        let policy = VPNConnectionPolicy(killSwitchEnabled: true, onDemandEnabled: false)
        let vpnProtocol = try translator.makeProtocol(
            server: makeServer(),
            response: makeResponse(
                configContent: try makeConfigContent(
                    localIdentifier: "client.example.com",
                    espProposal: "aes256-sha256"
                )
            ),
            policy: policy
        )

        #expect(vpnProtocol.includeAllNetworks)
        #expect(vpnProtocol.enforceRoutes)
    }

    @Test func translatorUsesCertificateSANInsteadOfDisplayNamesAndEnablesESPRequestedPFS() throws {
        let translator = VPNConfigurationTranslator(deviceKeyStore: StubVPNDeviceKeyStore())
        let vpnProtocol = try translator.makeProtocol(
            server: makeServer(),
            response: makeResponse(
                configContent: try makeConfigContent(
                    localIdentifier: nil,
                    espProposal: "aes256-sha256-modp2048"
                )
            )
        )

        #expect(vpnProtocol.localIdentifier == "client@example.com")
        #expect(vpnProtocol.localIdentifier != "IKEV2_profile_display_name")
        #expect(vpnProtocol.localIdentifier != "IKEV2_certificate_display_name")
        #expect(vpnProtocol.localIdentifier != "must-not-be-used-as-an-initiator-identity")
        #expect(vpnProtocol.localIdentifier != "profile-uuid")
        #expect(vpnProtocol.localIdentifier != "DE-MULTI-2")
        #expect(vpnProtocol.localIdentifier != "fallback.libreguard.net")
        #expect(vpnProtocol.enablePFS)
    }

    private func decodeProfile(_ json: String) throws -> SSWANProfile {
        try JSONDecoder().decode(SSWANProfile.self, from: Data(json.utf8))
    }

    private func makeConfigContent(localIdentifier: String?, espProposal: String) throws -> String {
        var local: [String: Any] = [
            "p12": IKEv2CertificateFixtures.multiSANPKCS12.base64EncodedString(),
            "password": "[ENCRYPTED_PASSPHRASE]",
            "rsa-pss": true
        ]
        if let localIdentifier {
            local["id"] = localIdentifier
        }

        let profile: [String: Any] = [
            "name": "IKEV2_profile_display_name",
            "id": "must-not-be-used-as-an-initiator-identity",
            "uuid": "profile-uuid",
            "type": "ikev2-cert",
            "remote": [
                "addr": "167.86.87.129",
                "id": "de-multi-2.libreguard.net",
                "ike": "aes256-sha256-modp2048",
                "esp": espProposal
            ],
            "local": local
        ]
        let data = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        return try #require(String(data: data, encoding: .utf8))
    }

    private func makeResponse(configContent: String) -> VPNConfigResponse {
        VPNConfigResponse(
            success: true,
            protocolName: "IKEv2/IPSec",
            serverName: "DE-MULTI-2",
            serverIp: "167.86.87.129",
            certificateName: "IKEV2_certificate_display_name",
            configContent: configContent,
            encryptedPassphrase: EncryptedPassphrase(
                algorithm: "RSA-OAEP-256",
                keyId: "device-key-id",
                ciphertext: "YQ=="
            ),
            issueDate: nil,
            expirationDate: nil,
            clientIp: nil,
            deviceId: "test-device"
        )
    }

    private func makeServer() -> VPNServer {
        VPNServer(
            id: 12,
            serverName: "DE-MULTI-2",
            serverIp: "167.86.87.129",
            serverHostname: "fallback.libreguard.net",
            country: "DE",
            city: "Frankfurt",
            linkSpeed: 1000,
            pricingTier: "Pro",
            load: nil,
            activeConnections: nil,
            latencyPingPort: 443,
            loadDataFresh: true
        )
    }
}
