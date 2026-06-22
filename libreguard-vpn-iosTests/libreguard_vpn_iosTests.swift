import Foundation
import SwiftData
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct libreguard_vpn_iosTests {
    @Test func loginDecodesTwoFactorChallenge() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                #expect(request.url?.path == "/api/login")
                let body = try requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["deviceId"] as? String == "test-device")
                #expect(json["appVersion"] as? String == "1.0-test")
                #expect(json["devicePublicKey"] as? String == "base64-spki")
                #expect(json["devicePublicKeyId"] as? String == "device-key-id")
                #expect(json["devicePublicKeyAlgorithm"] as? String == "RSA-OAEP-256")
                return try response(request, status: 200, json: [
                    "requiresTwoFactor": true,
                    "pendingLoginToken": "pending-token",
                    "email": "person@example.com",
                    "userId": "user-1",
                    "deviceId": "test-device",
                    "message": "Two-factor authentication required."
                ])
            }

            let result = try await client.login(email: "person@example.com", password: "secret")
            #expect(result.requiresTwoFactor == true)
            #expect(result.pendingLoginToken == "pending-token")
        }
    }

    @Test func deviceLimitErrorIncludesSelectableDevices() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                try response(request, status: 409, json: [
                    "message": "Device limit reached.",
                    "errorCode": "DEVICE_LIMIT_EXCEEDED",
                    "currentDevices": 1,
                    "maxDevices": 1,
                    "planType": "Free",
                    "devices": [[
                        "id": 42,
                        "deviceIdHash": "abcdef123456",
                        "appVersion": "1.0",
                        "deviceNickname": "Old iPhone",
                        "lastSeenAt": "2026-06-21T16:00:00.1234567Z",
                        "daysSinceLastSeen": 0
                    ]]
                ])
            }

            do {
                _ = try await client.login(email: "person@example.com", password: "secret")
                Issue.record("Expected a device-limit error")
            } catch let error as APIError {
                #expect(error.code == "DEVICE_LIMIT_EXCEEDED")
                #expect(error.deviceLimit?.devices.first?.id == 42)
                #expect(error.deviceLimit?.devices.first?.displayName == "Old iPhone")
            }
        }
    }

    @Test func protectedRequestRotatesRefreshTokenAndRetriesOnce() async throws {
        try await withSerializedRequests {
            let store = InMemorySessionStore(session: AuthSession(
                accessToken: "expired-access",
                refreshToken: "old-refresh",
                email: "person@example.com",
                userId: "user-1",
                deviceId: "test-device"
            ))
            var quotaAttempts = 0
            let client = makeClient(sessionStore: store) { request in
                switch request.url?.path {
                case "/api/login/refresh":
                    let body = try requestBody(from: request)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["devicePublicKey"] as? String == "base64-spki")
                    #expect(json["devicePublicKeyId"] as? String == "device-key-id")
                    #expect(json["devicePublicKeyAlgorithm"] as? String == "RSA-OAEP-256")
                    return try response(request, status: 200, json: [
                        "token": "new-access",
                        "refreshToken": "new-refresh",
                        "email": "person@example.com",
                        "userId": "user-1",
                        "deviceId": "test-device"
                    ])
                case "/api/usage/quota":
                    quotaAttempts += 1
                    if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired-access" {
                        return try response(request, status: 401, json: ["message": "Expired"])
                    }
                    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
                    return try response(request, status: 200, json: quotaJSON)
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let quota = try await client.fetchUsage()
            #expect(quota.isUnlimited == false)
            #expect(quotaAttempts == 2)
            #expect(store.session?.refreshToken == "new-refresh")
        }
    }

    @Test func vpnConfigRequestEncodesProtocolAndServer() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                #expect(request.url?.path == "/api/vpn/config")
                let body = try requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["serverId"] as? Int == 12)
                #expect(json["protocol"] as? String == "IKEV2")

                return try response(request, status: 200, json: [
                    "success": true,
                    "protocol": "IKEV2",
                    "serverName": "DE-1",
                    "serverIp": "203.0.113.10",
                    "certificateName": "IKEV2_client1",
                    "configContent": "{\"local\":{\"p12\":\"UEs=\",\"password\":\"[ENCRYPTED_PASSPHRASE]\"},\"remote\":{\"addr\":\"vpn.libreguard.net\"}}",
                    "encryptedPassphrase": [
                        "algorithm": "RSA-OAEP-256",
                        "keyId": "device-key-id",
                        "ciphertext": "YQ=="
                    ],
                    "issueDate": "2026-06-21T16:00:00Z",
                    "expirationDate": "2028-06-21T16:00:00Z",
                    "clientIp": "198.51.100.45",
                    "deviceId": "test-device"
                ])
            }

            let response = try await client.fetchVPNConfig(serverId: 12, protocol: .ikev2)
            #expect(response.serverName == "DE-1")
            #expect(response.protocolName == "IKEV2")
            #expect(response.encryptedPassphrase.algorithm == "RSA-OAEP-256")
        }
    }

    @Test func localStatisticsAggregateAndClearWithoutNetworking() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: LocalConnectionRecord.self, configurations: configuration)
        let context = ModelContext(container)
        let recorder = SwiftDataStatisticsRecorder(context: context)
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

        let start = Date().addingTimeInterval(-600)
        try recorder.record(
            connectedAt: start,
            disconnectedAt: Date(),
            server: server,
            downloadedBytes: 1_000,
            uploadedBytes: 250
        )
        let records = try context.fetch(FetchDescriptor<LocalConnectionRecord>())
        let summary = LocalStatisticsSummary(
            records: records,
            interval: DateInterval(start: start.addingTimeInterval(-1), end: Date().addingTimeInterval(1))
        )
        #expect(summary.totalBytes == 1_250)
        #expect(summary.connectedDuration >= 599)

        try recorder.clear()
        #expect(try context.fetchCount(FetchDescriptor<LocalConnectionRecord>()) == 0)
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

    private func response(_ request: URLRequest, status: Int, json: Any) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else {
            throw APIError(message: "Missing request URL")
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/2",
            headerFields: status == 429 ? ["Retry-After": "30"] : nil
        ) else {
            throw APIError(message: "Failed to build test response")
        }
        return (response, try JSONSerialization.data(withJSONObject: json))
    }

    private var quotaJSON: [String: Any] {
        [
            "bytesUsed": 1_024,
            "bytesLimit": 5_120,
            "bytesRemaining": 4_096,
            "usagePercentage": 20.0,
            "isUnlimited": false,
            "isOverLimit": false,
            "formattedUsed": "1 KB",
            "formattedLimit": "5 KB",
            "formattedRemaining": "4 KB",
            "cycleStart": "2026-06-01T00:00:00Z",
            "cycleEnd": "2026-07-01T00:00:00Z",
            "resetDate": "2026-07-01T00:00:00Z"
        ]
    }
}

private actor TestIsolation {
    static let shared = TestIsolation()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withExclusiveAccess<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        isLocked = true
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

@MainActor
private final class InMemorySessionStore: SessionStoring {
    private(set) var session: AuthSession?

    init(session: AuthSession? = nil) { self.session = session }
    func save(_ session: AuthSession) throws { self.session = session }
    func clear() { session = nil }
}

@MainActor
private final class StubDeviceIdentity: DeviceIdentifying {
    let deviceId = "test-device"
    let appVersion = "1.0-test"
}

@MainActor
private final class StubVPNDeviceKeyStore: VPNDeviceKeyProviding {
    func publicKeyPayload() throws -> DevicePublicKeyPayload {
        DevicePublicKeyPayload(
            devicePublicKey: "base64-spki",
            devicePublicKeyId: "device-key-id",
            devicePublicKeyAlgorithm: "RSA-OAEP-256"
        )
    }

    func decryptPassphrase(from encryptedPassphrase: EncryptedPassphrase) throws -> String {
        "test-passphrase"
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: APIError(message: "Missing test handler"))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
