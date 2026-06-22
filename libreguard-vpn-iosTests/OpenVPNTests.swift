import Foundation
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct OpenVPNTests {
    @Test func vpnConfigRequestEncodesOpenVPNProtocolAndDecodesRawProfile() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                #expect(request.url?.path == "/api/vpn/config")
                let body = try requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["serverId"] as? Int == 12)
                #expect(json["protocol"] as? String == "OPENVPN")

                return try makeResponse(request, status: 200, json: [
                    "success": true,
                    "protocol": "OpenVPN",
                    "serverName": "DE-1",
                    "serverIp": "203.0.113.10",
                    "certificateName": "OVPN_client891",
                    "configContent": openVPNSampleConfig(),
                    "encryptedPassphrase": [
                        "algorithm": "RSA-OAEP-256",
                        "keyId": "device-key-id",
                        "ciphertext": "YQ=="
                    ],
                    "issueDate": "2026-05-29T09:43:34Z",
                    "expirationDate": "2028-08-31T09:43:34Z",
                    "clientIp": "198.51.100.45",
                    "deviceId": "test-device"
                ])
            }

            let response = try await client.fetchVPNConfig(serverId: 12, protocol: .openVPN)
            #expect(response.protocolName?.lowercased() == "openvpn")
            #expect(response.certificateName == "OVPN_client891")
            #expect(response.configContent.contains("tls-crypt"))
        }
    }

    @Test func openVPNProfileParserRecognizesRepresentativeConfiguration() throws {
        let profile = try OpenVPNProfileConfiguration.parse(openVPNSampleConfig())
        #expect(profile.deviceType == "tun")
        #expect(profile.transportProtocol == "udp")
        #expect(profile.remoteEndpoints.first?.host == "23.2.3.2")
        #expect(profile.remoteEndpoints.first?.port == 1194)
        #expect(profile.usesTLSCrypt)
        #expect(profile.hasClientCertificateBlocks)
        #expect(profile.inlineBlocks["tls-crypt"]?.contains("OpenVPN Static key V1") == true)
        #expect(profile.inlineBlocks["ca"]?.contains("Content_Here") == true)
        try profile.validateMobileCompatibility()
    }

    @Test func openVPNProfileParserRejectsUnsupportedDirectives() throws {
        let unsupportedProfiles: [(String, String)] = [
            ("dev tap\nremote 1.2.3.4 1194\nclient", "tap"),
            ("client\ndev tun\nremote 1.2.3.4 1194\nfragment 1400", "fragment"),
            ("client\ndev tun\nremote 1.2.3.4 1194\nsecret static.key", "secret")
        ]

        for (profileText, expectedDirective) in unsupportedProfiles {
            do {
                let profile = try OpenVPNProfileConfiguration.parse(profileText)
                try profile.validateMobileCompatibility()
                Issue.record("Expected \(expectedDirective) to be rejected")
            } catch let error as OpenVPNProfileError {
                #expect(error.errorDescription?.contains(expectedDirective) == true)
            }
        }
    }

    @Test func openVPNProfileEnvelopeStoreRoundTripsAndClears() throws {
        let keychain = InMemorySharedKeychainStore()
        let store = OpenVPNProfileEnvelopeStore(keychain: keychain, account: "active")
        let envelope = OpenVPNProfileEnvelope(
            serverId: 12,
            serverName: "DE-1",
            serverAddress: "vpn.example.com",
            certificateName: "OVPN_client891",
            issueDate: Date(timeIntervalSince1970: 1_717_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_820_000_000),
            configContent: openVPNSampleConfig(),
            privateKeyPassphrase: "test-passphrase",
            storedAt: Date(timeIntervalSince1970: 1_717_000_100)
        )

        let persistentReference = try store.save(envelope)
        #expect(persistentReference.isEmpty == false)
        #expect(try store.load() == envelope)
        #expect(try store.load(persistentReference: persistentReference) == envelope)

        store.clear()
        #expect(try store.load() == nil)
    }

    @Test func appModelFallsBackToIKEv2WhenOpenVPNIsLocked() async throws {
        let server = try JSONDecoder().decode(VPNServer.self, from: JSONSerialization.data(withJSONObject: [
            "id": 1,
            "serverName": "DE-MULTI-1",
            "serverIp": "203.0.113.1",
            "country": "Germany",
            "city": "Frankfurt",
            "linkSpeed": 1000,
            "pricingTier": "Free",
            "load": 35,
            "activeConnections": NSNull(),
            "latencyPingPort": 5001,
            "loadDataFresh": true
        ]))

        let protocolStore = UserDefaultsVPNProtocolSelectionStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        protocolStore.selectedProtocol = .openVPN
        let vpn = SpyVPNManager()
        let app = AppModel(
            vpnManager: vpn,
            protocolSelectionStore: protocolStore,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        app.servers = [server]
        app.selectedServerID = server.id
        app.subscription = try JSONDecoder().decode(SubscriptionStatus.self, from: JSONSerialization.data(withJSONObject: [
            "plan": "Free",
            "isPro": false,
            "status": "active",
            "paymentType": NSNull(),
            "currentPeriodEnd": NSNull(),
            "cancelAtPeriodEnd": false,
            "billingCycle": "monthly",
            "activeDevices": 1,
            "maxDevices": 1,
            "canAddDevice": true
        ]))

        await app.connectSelectedServer()

        #expect(vpn.connectCalls.count == 1)
        #expect(vpn.connectCalls.first?.protocolName == .ikev2)
        #expect(app.selectedVPNProtocol == .openVPN)
    }

    @Test func protocolSelectionPersistsThroughTheStore() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = UserDefaultsVPNProtocolSelectionStore(defaults: defaults)
        store.selectedProtocol = .openVPN

        let restored = UserDefaultsVPNProtocolSelectionStore(defaults: defaults)
        #expect(restored.selectedProtocol == .openVPN)
    }

    private func makeClient(
        sessionStore: SessionStoring? = nil,
        deviceKeyStore: VPNDeviceKeyProviding? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return APIClient(
            baseURL: URL(string: "https://management.libreguard.net")!,
            urlSession: URLSession(configuration: configuration),
            sessionStore: sessionStore ?? InMemorySessionStore(),
            deviceStore: StubDeviceIdentity(),
            deviceKeyStore: deviceKeyStore ?? StubVPNDeviceKeyStore()
        )
    }

    private func withSerializedRequests<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await TestIsolation.shared.withExclusiveAccess(operation)
    }

    private func requestBody(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw APIError(message: "Missing request body")
        }
        stream.open()
        defer { stream.close() }

        let bufferSize = 4_096
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count < 0 {
                throw stream.streamError ?? APIError(message: "Unable to read request body")
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private func openVPNSampleConfig() -> String {
        """
        client
        dev tun
        proto udp
        remote 23.2.3.2 1194
        resolv-retry infinite
        nobind
        persist-key
        persist-tun
        remote-cert-tls server
        auth SHA256
        data-ciphers AES-256-GCM:AES-256-CBC
        data-ciphers-fallback AES-256-CBC
        key-direction 1
        verb 9
        <ca>
        -----BEGIN CERTIFICATE-----
        Content_Here
        -----END CERTIFICATE-----
        </ca>
        <cert>
        -----BEGIN CERTIFICATE-----
        CERTIFICATE_BODY
        -----END CERTIFICATE-----
        </cert>
        <key>
        -----BEGIN PRIVATE KEY-----
        PRIVATE_KEY_BODY
        -----END PRIVATE KEY-----
        </key>
        <tls-crypt>
        #
        # 2048 bit OpenVPN static key
        #
        -----BEGIN OpenVPN Static key V1-----
        STATIC_KEY_BODY
        -----END OpenVPN Static key V1-----
        </tls-crypt>
        """
    }
}

private final class InMemorySharedKeychainStore: SharedKeychainDataStoring {
    private var values: [String: Data] = [:]
    private var references: [String: Data] = [:]

    func data(for account: String) -> Data? {
        values[account]
    }

    func set(_ data: Data, for account: String) throws {
        values[account] = data
        if references[account] == nil {
            references[account] = Data(UUID().uuidString.utf8)
        }
    }

    func remove(_ account: String) {
        values.removeValue(forKey: account)
        references.removeValue(forKey: account)
    }

    func persistentReference(for account: String) throws -> Data? {
        references[account]
    }

    func data(forPersistentReference persistentReference: Data) throws -> Data? {
        guard let match = references.first(where: { $0.value == persistentReference }) else { return nil }
        return values[match.key]
    }
}

@MainActor
private final class SpyVPNManager: VPNManaging {
    struct Call: Equatable {
        let serverID: Int
        let protocolName: VPNConfigurationProtocol
    }

    var status: VPNConnectionState = .disconnected
    var onStatusChange: ((VPNConnectionState) -> Void)?
    var onDisconnectError: ((Error) -> Void)?
    private(set) var connectCalls: [Call] = []

    func refreshStatus() async {}

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol) async throws {
        connectCalls.append(Call(serverID: server.id, protocolName: protocolName))
        status = .connected
        onStatusChange?(status)
    }

    func disconnect() async {
        status = .disconnected
        onStatusChange?(status)
    }

    func disconnectAndForget() async {
        status = .disconnected
        onStatusChange?(status)
    }
}
