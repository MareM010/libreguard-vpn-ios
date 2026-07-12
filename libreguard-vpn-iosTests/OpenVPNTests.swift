import Foundation
import NetworkExtension
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct OpenVPNTests {
    @Test func killSwitchPolicyAppliesStrictRoutingToTunnelProtocols() {
        let tunnelProtocol = NETunnelProviderProtocol()
        VPNConnectionPolicy(killSwitchEnabled: true, onDemandEnabled: true).apply(to: tunnelProtocol)

        #expect(tunnelProtocol.includeAllNetworks)
        #expect(tunnelProtocol.excludeLocalNetworks == false)
        #expect(tunnelProtocol.excludeAPNs == false)
        #expect(tunnelProtocol.excludeCellularServices == false)
        #expect(tunnelProtocol.excludeDeviceCommunication == false)
        #expect(tunnelProtocol.enforceRoutes)
        #expect(tunnelProtocol.disconnectOnSleep == false)

        VPNConnectionPolicy.disabled.apply(to: tunnelProtocol)
        #expect(tunnelProtocol.includeAllNetworks == false)
    }

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

    @Test func tunnelKitRejectsIncompleteOpenVPNConfiguration() {
        let builder = TunnelKitOpenVPNProtocolBuilder()
        #expect(throws: (any Error).self) {
            _ = try builder.makeTunnelProtocol(
                configuration: "client\ndev tun\nproto udp\nremote vpn.example.com 1194",
                privateKeyPassphrase: "not-serialized"
            )
        }
    }

    @Test func openVPNPreflightRequiresInlineClientIdentityAndTLSCrypt() throws {
        try OpenVPNProfilePreflightValidator.validate(openVPNSampleConfig())

        for (directive, expectedError) in [
            ("fragment 1400", OpenVPNConfigurationError.unsupportedDirective("fragment")),
            ("secret static.key", OpenVPNConfigurationError.unsupportedDirective("secret"))
        ] {
            #expect(throws: expectedError) {
                try OpenVPNProfilePreflightValidator.validate(openVPNSampleConfig() + "\n" + directive)
            }
        }
    }

    @Test func openVPNProviderMessageCodecRoundTripsDiagnostics() throws {
        let diagnostics = OpenVPNRuntimeDiagnostics(
            state: .connected,
            serverId: 12,
            serverName: "DE-1",
            serverAddress: "vpn.example.com",
            connectedAt: Date(timeIntervalSince1970: 1_820_000_000),
            engine: .tunnelKit,
            canStartConnections: true
        )
        let requestData = try JSONEncoder().encode(OpenVPNProviderRequest(type: .diagnostics))
        let request = try OpenVPNProviderMessageCodec.decodeRequest(from: requestData)
        #expect(request.type == .diagnostics)

        let responseData = try OpenVPNProviderMessageCodec.encodeResponse(
            type: request.type,
            diagnostics: diagnostics
        )
        let response = try OpenVPNProviderMessageCodec.decodeResponse(from: responseData)

        #expect(response.success == true)
        #expect(response.type == .diagnostics)
        #expect(response.diagnostics == diagnostics)
        #expect(response.error == nil)
    }

    @Test func openVPNMetadataRoundTripsWithoutSecrets() throws {
        let metadata = OpenVPNConnectionMetadata(
            serverId: 12,
            serverName: "DE-1",
            serverAddress: "vpn.example.com"
        )
        try OpenVPNConnectionMetadataStore.save(metadata)
        #expect(OpenVPNConnectionMetadataStore.load() == metadata)
        OpenVPNConnectionMetadataStore.clear()
        #expect(OpenVPNConnectionMetadataStore.load() == nil)
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

    @Test func appModelUnlocksOpenVPNWhenQuotaIndicatesUnlimitedPlan() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let app = AppModel(vpnManager: SpyVPNManager(), defaults: defaults)
        app.usageQuota = try JSONDecoder().decode(UsageQuota.self, from: JSONSerialization.data(withJSONObject: [
            "bytesUsed": 2_048,
            "bytesLimit": 0,
            "bytesRemaining": 0,
            "usagePercentage": 0,
            "isUnlimited": true,
            "isOverLimit": false,
            "formattedUsed": "2 KB",
            "formattedLimit": "Unlimited",
            "formattedRemaining": "Unlimited",
            "cycleStart": NSNull(),
            "cycleEnd": NSNull(),
            "resetDate": NSNull()
        ]))

        #expect(app.isProUser == true)
        #expect(app.currentPlanDisplayName == "Pro")
        #expect(app.isOpenVPNAvailable == true)
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

    private func makeResponse(_ request: URLRequest, status: Int, json: Any) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else {
            throw APIError(message: "Missing request URL")
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: nil
        ) else {
            throw APIError(message: "Failed to build test response")
        }
        return (response, try JSONSerialization.data(withJSONObject: json))
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

    func connect(to server: VPNServer, protocol protocolName: VPNConfigurationProtocol, policy: VPNConnectionPolicy) async throws {
        connectCalls.append(Call(serverID: server.id, protocolName: protocolName))
        status = .connected
        onStatusChange?(status)
    }

    func apply(policy: VPNConnectionPolicy) async throws -> Bool { true }

    func disconnect() async {
        status = .disconnected
        onStatusChange?(status)
    }

    func disconnectAndForget() async {
        status = .disconnected
        onStatusChange?(status)
    }
}
