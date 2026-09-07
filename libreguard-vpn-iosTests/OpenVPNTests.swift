import Foundation
import NetworkExtension
import Testing
@testable import libreguard_vpn_ios

@MainActor
struct OpenVPNTests {
    @Test func killSwitchPolicyUsesIncludeAllNetworksForTunnelProtocols() {
        let tunnelProtocol = NETunnelProviderProtocol()
        VPNConnectionPolicy(killSwitchEnabled: true, onDemandEnabled: true).apply(to: tunnelProtocol)

        #expect(tunnelProtocol.includeAllNetworks)
        #expect(tunnelProtocol.excludeLocalNetworks == false)
        #expect(tunnelProtocol.excludeAPNs == false)
        #expect(tunnelProtocol.excludeCellularServices == false)
        #expect(tunnelProtocol.excludeDeviceCommunication == false)
        #expect(tunnelProtocol.enforceRoutes == false)
        #expect(tunnelProtocol.disconnectOnSleep == false)

        VPNConnectionPolicy.disabled.apply(to: tunnelProtocol)
        #expect(tunnelProtocol.includeAllNetworks == false)
        #expect(tunnelProtocol.enforceRoutes == false)
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

    @Test func openVPNManagerPrefersBackendServerIPsAsResolvedAddresses() {
        let server = VPNServer(
            id: 12,
            serverName: "DE-1",
            serverIp: "198.51.100.8",
            serverHostname: "vpn.example.com",
            country: "DE",
            city: "Berlin",
            linkSpeed: 1000,
            pricingTier: "Pro",
            load: nil,
            activeConnections: nil,
            latencyPingPort: 443,
            loadDataFresh: true
        )
        let response = VPNConfigResponse(
            success: true,
            protocolName: "OpenVPN",
            serverName: "DE-1",
            serverIp: " 203.0.113.10 ",
            certificateName: "OVPN_client891",
            configContent: openVPNSampleConfig(),
            encryptedPassphrase: EncryptedPassphrase(
                algorithm: "RSA-OAEP-256",
                keyId: "device-key-id",
                ciphertext: "YQ=="
            ),
            issueDate: nil,
            expirationDate: nil,
            clientIp: nil,
            deviceId: nil
        )

        #expect(
            OpenVPNManager.preferredResolvedAddresses(response: response, server: server) == [
                "203.0.113.10",
                "198.51.100.8"
            ]
        )
    }

    @Test func openVPNManagerDoesNotForceNonIPv4BackendAddressesIntoTunnelKit() {
        let server = VPNServer(
            id: 12,
            serverName: "DE-1",
            serverIp: "2001:db8::1",
            serverHostname: "vpn.example.com",
            country: "DE",
            city: "Berlin",
            linkSpeed: 1000,
            pricingTier: "Pro",
            load: nil,
            activeConnections: nil,
            latencyPingPort: 443,
            loadDataFresh: true
        )
        let response = VPNConfigResponse(
            success: true,
            protocolName: "OpenVPN",
            serverName: "DE-1",
            serverIp: "vpn.example.com",
            certificateName: "OVPN_client891",
            configContent: openVPNSampleConfig(),
            encryptedPassphrase: EncryptedPassphrase(
                algorithm: "RSA-OAEP-256",
                keyId: "device-key-id",
                ciphertext: "YQ=="
            ),
            issueDate: nil,
            expirationDate: nil,
            clientIp: nil,
            deviceId: nil
        )

        #expect(OpenVPNManager.preferredResolvedAddresses(response: response, server: server).isEmpty)
    }

    @Test func certificateRequestUsesCanonicalIKEv2ProtocolValue() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                #expect(request.url?.path == "/api/certificates/request")
                let body = try self.requestBody(from: request)
                let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(json["serverId"] as? Int == 12)
                #expect(json["vpnType"] as? String == "IKEV2/IPSec")
                return try self.makeResponse(request, status: 200, json: [
                    "jobId": 90,
                    "requestedName": "IKEV2_client90",
                    "status": "Pending"
                ])
            }

            let response = try await client.requestCertificate(serverId: 12, protocol: .ikev2)
            #expect(response.jobId == 90)
        }
    }

    @Test func certificateResolverCreatesAndWaitsBeforeRefetchingOpenVPNConfig() async throws {
        try await withSerializedRequests {
            var configAttempts = 0
            var requestedJob = false
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    configAttempts += 1
                    if configAttempts == 1 {
                        return try self.makeResponse(request, status: 404, json: [
                            "message": "No valid OpenVPN certificate found for this server. Please contact administrator to create one.",
                            "deviceId": "test-device"
                        ])
                    }
                    return try self.makeResponse(request, status: 200, json: [
                        "success": true,
                        "protocol": "OpenVPN",
                        "serverName": "DE-1",
                        "serverIp": "203.0.113.10",
                        "certificateName": "OVPN_client91",
                        "configContent": self.openVPNSampleConfig(),
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
                case "/api/client-certificates/check-generation-status/12":
                    #expect(request.url?.query == "vpnType=OPENVPN")
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": true,
                        "certificateExists": false,
                        "jobPending": false
                    ])
                case "/api/certificates/request":
                    requestedJob = true
                    let body = try self.requestBody(from: request)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["serverId"] as? Int == 12)
                    #expect(json["vpnType"] as? String == "OPENVPN")
                    return try self.makeResponse(request, status: 200, json: [
                        "jobId": 91,
                        "requestedName": "OVPN_client91",
                        "status": "Pending"
                    ])
                case "/api/certificates/jobs/91":
                    return try self.makeResponse(request, status: 200, json: [
                        "id": 91,
                        "status": "Success",
                        "jobType": "OPENVPN_CREATE",
                        "requestedName": "OVPN_client91",
                        "outputCertificateId": 7
                    ])
                default:
                    throw APIError(message: "Unexpected endpoint: \(request.url?.absoluteString ?? "nil")")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 2)
            var preparationMessages: [String] = []
            var preparationCleared = false
            resolver.onPreparationStateChange = { message in
                if let message {
                    preparationMessages.append(message)
                } else {
                    preparationCleared = true
                }
            }
            let response = try await resolver.resolve(serverId: 12, protocol: .openVPN)

            #expect(requestedJob)
            #expect(configAttempts == 2)
            #expect(response.certificateName == "OVPN_client91")
            #expect(preparationMessages.first?.contains("Preparing your OpenVPN certificate") == true)
            #expect(preparationCleared)
        }
    }

    @Test func certificateResolverCreatesAndReturnsIKEv2ConfigurationForMessageOnly404() async throws {
        try await withSerializedRequests {
            var configAttempts = 0
            var requestedJob = false
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    let body = try self.requestBody(from: request)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["protocol"] as? String == "IKEV2")
                    configAttempts += 1
                    if configAttempts == 1 {
                        return try self.makeResponse(request, status: 404, json: [
                            "message": "No valid IKEV2 certificate found for this server. Please contact administrator to create one.",
                            "deviceId": "test-device"
                        ])
                    }
                    return try self.makeResponse(request, status: 200, json: [
                        "success": true,
                        "protocol": "IKEV2",
                        "serverName": "DE-1",
                        "serverIp": "203.0.113.10",
                        "certificateName": "IKEV2_client93",
                        "configContent": self.ikev2SampleConfig(),
                        "encryptedPassphrase": [
                            "algorithm": "RSA-OAEP-256",
                            "keyId": "device-key-id",
                            "ciphertext": "YQ=="
                        ],
                        "issueDate": "2026-05-29T09:43:34Z",
                        "expirationDate": "2028-08-31T09:43:34Z",
                        "deviceId": "test-device"
                    ])
                case "/api/client-certificates/check-generation-status/12":
                    #expect(request.url?.query == "vpnType=IKEV2/IPSec")
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": true,
                        "certificateExists": false,
                        "jobPending": false
                    ])
                case "/api/certificates/request":
                    requestedJob = true
                    let body = try self.requestBody(from: request)
                    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(json["serverId"] as? Int == 12)
                    #expect(json["vpnType"] as? String == "IKEV2/IPSec")
                    return try self.makeResponse(request, status: 200, json: [
                        "jobId": 93,
                        "requestedName": "IKEV2_client93",
                        "status": "Pending"
                    ])
                case "/api/certificates/jobs/93":
                    return try self.makeResponse(request, status: 200, json: [
                        "id": 93,
                        "status": "Success",
                        "jobType": "IKEV2_CREATE",
                        "requestedName": "IKEV2_client93",
                        "outputCertificateId": 8
                    ])
                default:
                    throw APIError(message: "Unexpected endpoint: \(request.url?.absoluteString ?? "nil")")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 2)
            let response = try await resolver.resolve(serverId: 12, protocol: .ikev2)

            #expect(requestedJob)
            #expect(configAttempts == 2)
            #expect(response.certificateName == "IKEV2_client93")
            #expect(response.configContent == ikev2SampleConfig())
        }
    }

    @Test func certificateResolverUsesExistingConfigurationWithoutRequestingAJob() async throws {
        try await withSerializedRequests {
            var requestCount = 0
            let client = makeClient { request in
                requestCount += 1
                #expect(request.url?.path == "/api/vpn/config")
                return try self.makeResponse(request, status: 200, json: [
                    "success": true,
                    "protocol": "OpenVPN",
                    "serverName": "DE-1",
                    "serverIp": "203.0.113.10",
                    "certificateName": "OVPN_existing",
                    "configContent": self.openVPNSampleConfig(),
                    "encryptedPassphrase": ["algorithm": "RSA-OAEP-256", "keyId": "device-key-id", "ciphertext": "YQ=="],
                    "issueDate": "2026-05-29T09:43:34Z",
                    "expirationDate": "2028-08-31T09:43:34Z"
                ])
            }

            let resolver = VPNConfigurationResolver(api: client)
            let response = try await resolver.resolve(serverId: 12, protocol: .openVPN)

            #expect(requestCount == 1)
            #expect(response.certificateName == "OVPN_existing")
        }
    }

    @Test func certificateResolverSurfacesTerminalJobFailureWithoutRefetchingConfig() async throws {
        try await withSerializedRequests {
            var configAttempts = 0
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    configAttempts += 1
                    return try self.makeResponse(request, status: 404, json: ["errorCode": "CERTIFICATE_NOT_FOUND"])
                case "/api/client-certificates/check-generation-status/12":
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": true,
                        "certificateExists": false,
                        "jobPending": false
                    ])
                case "/api/certificates/request":
                    return try self.makeResponse(request, status: 200, json: ["jobId": 94, "status": "Pending"])
                case "/api/certificates/jobs/94":
                    return try self.makeResponse(request, status: 200, json: [
                        "id": 94,
                        "status": "Failed",
                        "errorMessage": "The certificate worker could not provision this certificate."
                    ])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 1)
            do {
                _ = try await resolver.resolve(serverId: 12, protocol: .openVPN)
                Issue.record("Expected certificate generation to fail")
            } catch let error as APIError {
                #expect(error.code == "CERTIFICATE_GENERATION_FAILED")
                #expect(error.message == "The certificate worker could not provision this certificate.")
            }
            #expect(configAttempts == 1)
        }
    }

    @Test func certificateResolverRetainsPreparationMessageAfterTimeout() async throws {
        try await withSerializedRequests {
            var configAttempts = 0
            var preparationMessage: String?
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    configAttempts += 1
                    return try self.makeResponse(request, status: 404, json: ["errorCode": "CERTIFICATE_NOT_FOUND"])
                case "/api/client-certificates/check-generation-status/12":
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": true,
                        "certificateExists": false,
                        "jobPending": false
                    ])
                case "/api/certificates/request":
                    return try self.makeResponse(request, status: 200, json: ["jobId": 95, "status": "Pending"])
                case "/api/certificates/jobs/95":
                    return try self.makeResponse(request, status: 200, json: ["id": 95, "status": "Running"])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 0.01)
            resolver.onPreparationStateChange = { message in
                if message?.contains("still being prepared") == true {
                    preparationMessage = message
                }
            }

            do {
                _ = try await resolver.resolve(serverId: 12, protocol: .openVPN)
                Issue.record("Expected certificate preparation to time out")
            } catch let error as APIError {
                #expect(error.code == "CERTIFICATE_PREPARATION_TIMEOUT")
            }
            #expect(configAttempts == 1)
            #expect(preparationMessage?.contains("still being prepared") == true)
        }
    }

    @Test func certificateResolverStopsPollingWhenConnectTaskIsCancelled() async throws {
        try await withSerializedRequests {
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    return try self.makeResponse(request, status: 404, json: ["errorCode": "CERTIFICATE_NOT_FOUND"])
                case "/api/client-certificates/check-generation-status/12":
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": true,
                        "certificateExists": false,
                        "jobPending": false
                    ])
                case "/api/certificates/request":
                    return try self.makeResponse(request, status: 200, json: ["jobId": 96, "status": "Pending"])
                case "/api/certificates/jobs/96":
                    return try self.makeResponse(request, status: 200, json: ["id": 96, "status": "Running"])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 10)
            let task = Task { @MainActor in
                try await resolver.resolve(serverId: 12, protocol: .openVPN)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()

            do {
                _ = try await task.value
                Issue.record("Expected certificate resolution to be cancelled")
            } catch is CancellationError {
                // Expected: polling must stop with the connect task.
            }
        }
    }

    @Test func certificateResolverDoesNotCreateDuplicateWhenConfigurationArtifactIsMissing() async throws {
        try await withSerializedRequests {
            var configAttempts = 0
            var requestAttempts = 0
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    configAttempts += 1
                    return try self.makeResponse(request, status: 404, json: [
                        "message": "Configuration file not found."
                    ])
                case "/api/client-certificates/check-generation-status/12":
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": false,
                        "certificateExists": true,
                        "existingCertificate": [
                            "id": 17,
                            "name": "IKEV2_client17",
                            "vpnType": "IKEV2/IPSec",
                            "expirationDate": "2028-08-31T09:43:34Z"
                        ]
                    ])
                case "/api/certificates/request":
                    requestAttempts += 1
                    throw APIError(message: "Certificate creation must not be requested")
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 1)
            do {
                _ = try await resolver.resolve(serverId: 12, protocol: .ikev2)
                Issue.record("Expected the missing configuration artifact error")
            } catch let error as APIError {
                #expect(error.statusCode == 404)
                #expect(error.message == "Configuration file not found.")
            }
            #expect(configAttempts == 2)
            #expect(requestAttempts == 0)
        }
    }

    @Test func certificateResolverDoesNotInspectStatusForUnrelatedConfigFailure() async {
        await withSerializedRequests {
            var requestCount = 0
            let client = makeClient { request in
                requestCount += 1
                #expect(request.url?.path == "/api/vpn/config")
                return try self.makeResponse(request, status: 500, json: [
                    "message": "An error occurred while retrieving the VPN configuration."
                ])
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 1)
            await #expect(throws: APIError.self) {
                try await resolver.resolve(serverId: 12, protocol: .ikev2)
            }
            #expect(requestCount == 1)
        }
    }

    @Test func certificateResolverJoinsPendingJobWithoutRequestingAnotherCertificate() async throws {
        try await withSerializedRequests {
            var configAttempts = 0
            var requestAttempts = 0
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    configAttempts += 1
                    if configAttempts == 1 {
                        return try self.makeResponse(request, status: 404, json: [
                            "message": "No valid OpenVPN certificate found for this server. Please contact administrator to create one."
                        ])
                    }
                    return try self.makeResponse(request, status: 200, json: [
                        "success": true,
                        "protocol": "OpenVPN",
                        "serverName": "DE-1",
                        "serverIp": "203.0.113.10",
                        "certificateName": "OVPN_client92",
                        "configContent": self.openVPNSampleConfig(),
                        "encryptedPassphrase": ["algorithm": "RSA-OAEP-256", "keyId": "device-key-id", "ciphertext": "YQ=="],
                        "issueDate": "2026-05-29T09:43:34Z",
                        "expirationDate": "2028-08-31T09:43:34Z"
                    ])
                case "/api/client-certificates/check-generation-status/12":
                    #expect(request.url?.query == "vpnType=OPENVPN")
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": false,
                        "certificateExists": false,
                        "jobPending": true,
                        "pendingJob": ["id": 92, "status": "Pending"]
                    ])
                case "/api/certificates/request":
                    requestAttempts += 1
                    throw APIError(message: "Certificate creation must not be requested")
                case "/api/certificates/jobs/92":
                    return try self.makeResponse(request, status: 200, json: ["id": 92, "status": "Success"])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 2)
            let response = try await resolver.resolve(serverId: 12, protocol: .openVPN)

            #expect(response.certificateName == "OVPN_client92")
            #expect(requestAttempts == 0)
            #expect(configAttempts == 2)
        }
    }

    @Test func certificateResolverReconcilesMessageOnlyConflictWithWinningJob() async throws {
        try await withSerializedRequests {
            var configAttempts = 0
            var requestAttempts = 0
            var statusAttempts = 0
            let client = makeClient { request in
                switch request.url?.path {
                case "/api/vpn/config":
                    configAttempts += 1
                    if configAttempts == 1 {
                        return try self.makeResponse(request, status: 404, json: [
                            "message": "No valid OpenVPN certificate found for this server. Please contact administrator to create one."
                        ])
                    }
                    return try self.makeResponse(request, status: 200, json: [
                        "success": true,
                        "protocol": "OpenVPN",
                        "serverName": "DE-1",
                        "serverIp": "203.0.113.10",
                        "certificateName": "OVPN_client92",
                        "configContent": self.openVPNSampleConfig(),
                        "encryptedPassphrase": ["algorithm": "RSA-OAEP-256", "keyId": "device-key-id", "ciphertext": "YQ=="],
                        "issueDate": "2026-05-29T09:43:34Z",
                        "expirationDate": "2028-08-31T09:43:34Z"
                    ])
                case "/api/certificates/request":
                    requestAttempts += 1
                    return try self.makeResponse(request, status: 409, json: [
                        "message": "You already have a pending or running job for this server and VPN type."
                    ])
                case "/api/client-certificates/check-generation-status/12":
                    #expect(request.url?.query == "vpnType=OPENVPN")
                    statusAttempts += 1
                    if statusAttempts == 1 {
                        return try self.makeResponse(request, status: 200, json: [
                            "canGenerate": true,
                            "certificateExists": false,
                            "jobPending": false
                        ])
                    }
                    return try self.makeResponse(request, status: 200, json: [
                        "canGenerate": false,
                        "certificateExists": false,
                        "jobPending": true,
                        "vpnType": "OpenVPN",
                        "pendingJob": ["id": 92, "status": "Pending"]
                    ])
                case "/api/certificates/jobs/92":
                    return try self.makeResponse(request, status: 200, json: ["id": 92, "status": "Success"])
                default:
                    throw APIError(message: "Unexpected endpoint")
                }
            }

            let resolver = VPNConfigurationResolver(api: client, preparationTimeout: 2)
            _ = try await resolver.resolve(serverId: 12, protocol: .openVPN)
            #expect(requestAttempts == 1)
            #expect(statusAttempts == 2)
            #expect(configAttempts == 2)
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

    @Test func tunnelKitReplacesProfileDNSWithLibreGuardPrivateResolver() throws {
        let publicResolver = "8.8.8.8"
        let filteredResolver = "10.254.0.54"
        let builder = TunnelKitOpenVPNProtocolBuilder()
        let tunnelProtocol = try builder.makeTunnelProtocol(
            configuration: openVPNSampleConfig() + "\ndhcp-option DNS \(publicResolver)",
            privateKeyPassphrase: "test-passphrase"
        )
        let providerConfiguration = try #require(tunnelProtocol.providerConfiguration)
        #expect(providerConfiguration[OpenVPNConstants.ipv6BlockingConfigurationKey] as? Bool == true)
        let serialized = try PropertyListSerialization.data(
            fromPropertyList: providerConfiguration,
            format: .binary,
            options: 0
        )

        #expect(serialized.range(of: Data(LibreGuardDNS.regularResolverAddress.utf8)) != nil)
        #expect(serialized.range(of: Data(publicResolver.utf8)) == nil)
        #expect(serialized.range(of: Data(filteredResolver.utf8)) == nil)
    }

    @Test func tunnelKitUsesCellularSafeTunnelMTU() throws {
        let tunnelProtocol = try TunnelKitOpenVPNProtocolBuilder().makeTunnelProtocol(
            configuration: openVPNSampleConfig(),
            privateKeyPassphrase: "test-passphrase"
        )
        let providerConfiguration = try #require(tunnelProtocol.providerConfiguration)
        let sessionConfiguration = try #require(
            providerConfiguration["sessionConfiguration"] as? [String: Any]
        )

        #expect(sessionConfiguration["mtu"] as? Int == 1280)
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

    private func ikev2SampleConfig() -> String {
        """
        {"name":"IKEV2_client93","type":"ikev2-cert","remote":{"addr":"vpn.libreguard.net"},"local":{"p12":"UEs=","password":"[ENCRYPTED_PASSPHRASE]","rsa-pss":false},"ike-proposal":"aes256-sha256-modp2048","esp-proposal":"aes256-sha256-modp2048"}
        """
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
