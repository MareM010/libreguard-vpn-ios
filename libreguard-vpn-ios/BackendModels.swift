import Foundation

enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
}

struct APIError: LocalizedError, Identifiable {
    let id = UUID()
    let statusCode: Int?
    let message: String
    let code: String?
    let fieldErrors: [String]
    let retryAfterSeconds: Int?
    let requiresLogin: Bool
    let requiresDeviceRegistration: Bool
    let deviceLimit: DeviceLimitResponse?

    var errorDescription: String? { message }

    init(
        statusCode: Int? = nil,
        message: String,
        code: String? = nil,
        fieldErrors: [String] = [],
        retryAfterSeconds: Int? = nil,
        requiresLogin: Bool = false,
        requiresDeviceRegistration: Bool = false,
        deviceLimit: DeviceLimitResponse? = nil
    ) {
        self.statusCode = statusCode
        self.message = message
        self.code = code
        self.fieldErrors = fieldErrors
        self.retryAfterSeconds = retryAfterSeconds
        self.requiresLogin = requiresLogin
        self.requiresDeviceRegistration = requiresDeviceRegistration
        self.deviceLimit = deviceLimit
    }
}

struct APIErrorEnvelope: Decodable {
    let message: String?
    let error: String?
    let errorCode: String?
    let errors: [String]?
    let retryAfterSeconds: Int?
    let requiresLogin: Bool?
    let requiresDeviceRegistration: Bool?
}

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let email: String
    let userId: String
    let deviceId: String
}

struct LoginRequest: Encodable {
    let email: String
    let password: String
    let deviceId: String
    let appVersion: String
}

struct GoogleLoginRequest: Encodable {
    let idToken: String
    let deviceId: String
    let appVersion: String
}

struct RefreshTokenRequest: Encodable {
    let refreshToken: String
    let deviceId: String
    let appVersion: String
}

struct LoginResponse: Decodable {
    let requiresTwoFactor: Bool?
    let pendingLoginToken: String?
    let token: String?
    let refreshToken: String?
    let email: String?
    let userId: String?
    let deviceId: String?
    let activeDevices: Int?
    let maxDevices: Int?
    let planType: String?
    let provider: String?
    let message: String?
    let warningRecoveryCodes: Bool?
}

struct TwoFactorLoginRequest: Encodable {
    let email: String
    let twoFactorCode: String
    let pendingLoginToken: String
    let deviceId: String
    let appVersion: String
}

struct RecoveryCodeLoginRequest: Encodable {
    let email: String
    let recoveryCode: String
    let pendingLoginToken: String
    let deviceId: String
    let appVersion: String
}

struct RegistrationRequest: Encodable {
    let email: String
    let password: String
}

struct RegistrationResponse: Decodable {
    let message: String
    let accountStatus: String?
    let userId: String
    let email: String
    let requiresEmailConfirmation: Bool
}

struct ConfirmationStatusResponse: Decodable {
    let emailConfirmed: Bool
    let message: String
    let nextStep: String?
    let email: String?
    let userId: String?
}

struct ResendConfirmationRequest: Encodable {
    let email: String
}

struct MessageResponse: Decodable {
    let message: String?
}

struct LogoutRequest: Encodable {
    let refreshToken: String
}

struct AccountDevice: Decodable, Identifiable {
    let id: Int
    let deviceIdHash: String?
    let appVersion: String?
    let deviceNickname: String?
    let lastSeenAt: Date?
    let daysSinceLastSeen: Int?

    enum CodingKeys: String, CodingKey {
        case id, deviceIdHash, deviceId, appVersion, deviceNickname, lastSeenAt, daysSinceLastSeen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        deviceIdHash = try container.decodeIfPresent(String.self, forKey: .deviceIdHash)
            ?? container.decodeIfPresent(String.self, forKey: .deviceId)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        deviceNickname = try container.decodeIfPresent(String.self, forKey: .deviceNickname)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        daysSinceLastSeen = try container.decodeIfPresent(Int.self, forKey: .daysSinceLastSeen)
    }

    var displayName: String {
        if let nickname = deviceNickname, !nickname.isEmpty { return nickname }
        guard let hash = deviceIdHash, hash.count >= 4 else { return "Device \(id)" }
        return "Device ••••\(hash.suffix(4))"
    }
}

struct DeviceLimitResponse: Decodable {
    let message: String
    let errorCode: String
    let currentDevices: Int
    let maxDevices: Int
    let planType: String
    let devices: [AccountDevice]
}

struct PasswordDeviceRemovalRequest: Encodable {
    let email: String
    let password: String
    let deviceIdToRemove: Int
}

struct OAuthDeviceRemovalRequest: Encodable {
    let idToken: String
    let provider: String
    let deviceIdToRemove: Int
}

struct DeviceRemovalResponse: Decodable {
    let success: Bool
    let message: String
    let deviceId: Int?
    let removedDeviceCount: Int
}

struct VPNServerResponse: Decodable {
    let servers: [VPNServer]
}

struct VPNServer: Decodable, Identifiable, Hashable {
    let id: Int
    let serverName: String
    let serverIp: String
    let serverHostname: String?
    let country: String
    let city: String?
    let linkSpeed: Int
    let pricingTier: String
    let load: Int?
    let activeConnections: Int?
    let latencyPingPort: Int
    let loadDataFresh: Bool

    var latencyHost: String {
        if let serverHostname, !serverHostname.isEmpty { return serverHostname }
        return serverIp
    }
}

struct UsageQuota: Decodable, Equatable {
    let bytesUsed: Int64
    let bytesLimit: Int64
    let bytesRemaining: Int64
    let usagePercentage: Double
    let isUnlimited: Bool
    let isOverLimit: Bool
    let formattedUsed: String
    let formattedLimit: String
    let formattedRemaining: String
    let cycleStart: Date?
    let cycleEnd: Date?
    let resetDate: Date?
}

struct SubscriptionStatus: Decodable, Equatable {
    let plan: String
    let isPro: Bool
    let status: String
    let paymentType: String?
    let currentPeriodEnd: Date?
    let cancelAtPeriodEnd: Bool
    let billingCycle: String
    let activeDevices: Int
    let maxDevices: Int
    let canAddDevice: Bool
}

struct TwoFactorStatus: Decodable, Equatable {
    let is2faEnabled: Bool
    let hasAuthenticator: Bool
    let recoveryCodesLeft: Int
}

struct AuthenticatorSetup: Decodable, Equatable {
    let sharedKey: String
    let authenticatorUri: String
    let manualEntryKey: String
}

struct EnableTwoFactorRequest: Encodable {
    let code: String
}

struct RecoveryCodesResponse: Decodable {
    let recoveryCodes: [String]?
    let message: String?
}

struct PendingRegistration: Codable, Equatable {
    let userId: String
    let email: String
}

enum LoginAttempt {
    case password(email: String, password: String)
    case google(idToken: String)
}

struct TwoFactorChallenge: Identifiable {
    let id = UUID()
    let email: String
    let pendingLoginToken: String
    let attempt: LoginAttempt
}

struct DeviceLimitContext: Identifiable {
    let id = UUID()
    let response: DeviceLimitResponse
    let attempt: LoginAttempt
    let afterTwoFactor: Bool

    var canRemoveInApp: Bool {
        switch attempt {
        case .google: true
        case .password: !afterTwoFactor
        }
    }
}

enum AppRoute {
    case launching
    case login
    case register
    case emailConfirmation(PendingRegistration)
    case forgotPassword
    case twoFactor(TwoFactorChallenge)
    case authenticated
}
