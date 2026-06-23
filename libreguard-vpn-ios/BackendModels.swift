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

enum AccountPlanTier: String {
    case free = "Free"
    case pro = "Pro"

    init?(planName: String?) {
        guard let normalized = planName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "free":
            self = .free
        case "pro", "premium":
            self = .pro
        default:
            return nil
        }
    }

    var isPro: Bool {
        self == .pro
    }
}

struct LoginRequest: Encodable {
    let email: String
    let password: String
    let deviceId: String
    let appVersion: String
    let devicePublicKey: String
    let devicePublicKeyId: String
    let devicePublicKeyAlgorithm: String
}

struct GoogleLoginRequest: Encodable {
    let idToken: String
    let deviceId: String
    let appVersion: String
    let devicePublicKey: String
    let devicePublicKeyId: String
    let devicePublicKeyAlgorithm: String
}

struct RefreshTokenRequest: Encodable {
    let refreshToken: String
    let deviceId: String
    let appVersion: String
    let devicePublicKey: String
    let devicePublicKeyId: String
    let devicePublicKeyAlgorithm: String
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

    var planTier: AccountPlanTier? {
        AccountPlanTier(planName: planType)
    }
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

    var pricingTierLabel: String {
        pricingTier.caseInsensitiveCompare("Premium") == .orderedSame ? "Pro" : pricingTier
    }

    var requiresProSubscription: Bool {
        pricingTierLabel.caseInsensitiveCompare("Pro") == .orderedSame
    }

    var flagEmoji: String {
        CountryFlagResolver.flagEmoji(for: country)
    }
}

struct DevicePublicKeyPayload: Encodable, Equatable {
    let devicePublicKey: String
    let devicePublicKeyId: String
    let devicePublicKeyAlgorithm: String
}

enum CountryFlagResolver {
    private static let fallbackFlag = "🌐"

    private static let aliases: [String: String] = [
        "AE": "AE",
        "AFGHANISTAN": "AF",
        "ALBANIA": "AL",
        "ARGENTINA": "AR",
        "AUSTRALIA": "AU",
        "AUSTRIA": "AT",
        "BELGIUM": "BE",
        "BOSNIA": "BA",
        "BOSNIAANDHERZEGOVINA": "BA",
        "BRAZIL": "BR",
        "BULGARIA": "BG",
        "CANADA": "CA",
        "CHILE": "CL",
        "CHINA": "CN",
        "CROATIA": "HR",
        "CZECHREPUBLIC": "CZ",
        "CZECHIA": "CZ",
        "DENMARK": "DK",
        "EGYPT": "EG",
        "ESTONIA": "EE",
        "FINLAND": "FI",
        "FRANCE": "FR",
        "GERMANY": "DE",
        "GREECE": "GR",
        "HONGKONG": "HK",
        "HUNGARY": "HU",
        "ICELAND": "IS",
        "INDIA": "IN",
        "INDONESIA": "ID",
        "IRELAND": "IE",
        "ISRAEL": "IL",
        "ITALY": "IT",
        "JAPAN": "JP",
        "KAZAKHSTAN": "KZ",
        "LATVIA": "LV",
        "LITHUANIA": "LT",
        "LUXEMBOURG": "LU",
        "MALAYSIA": "MY",
        "MEXICO": "MX",
        "MOLDOVA": "MD",
        "NETHERLANDS": "NL",
        "NEWZEALAND": "NZ",
        "NORWAY": "NO",
        "PAKISTAN": "PK",
        "PHILIPPINES": "PH",
        "POLAND": "PL",
        "PORTUGAL": "PT",
        "REPUBLICOFKOREA": "KR",
        "ROMANIA": "RO",
        "RUSSIA": "RU",
        "SERBIA": "RS",
        "SINGAPORE": "SG",
        "SLOVAKIA": "SK",
        "SLOVENIA": "SI",
        "SOUTHAFRICA": "ZA",
        "SOUTHKOREA": "KR",
        "SPAIN": "ES",
        "SWEDEN": "SE",
        "SWITZERLAND": "CH",
        "TAIWAN": "TW",
        "THAILAND": "TH",
        "TURKEY": "TR",
        "UAE": "AE",
        "UK": "GB",
        "UNITEDARABEMIRATES": "AE",
        "UNITEDKINGDOM": "GB",
        "UNITEDSTATES": "US",
        "UNITEDSTATESOFAMERICA": "US",
        "USA": "US",
        "VIETNAM": "VN"
    ]

    private static let normalizedAliases: [String: String] = {
        var resolved: [String: String] = [:]
        for (key, value) in aliases {
            resolved[normalize(key)] = value
        }
        return resolved
    }()

    private static let regionNameIndex: [String: String] = {
        let locale = Locale(identifier: "en_US_POSIX")
        var index: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            if let name = locale.localizedString(forRegionCode: region.identifier) {
                index[normalize(name)] = region.identifier
            }
        }
        return index
    }()

    static func flagEmoji(for regionNameOrCode: String) -> String {
        let normalized = normalize(regionNameOrCode)
        guard !normalized.isEmpty else { return fallbackFlag }

        if let regionCode = normalizedAliases[normalized] ?? regionNameIndex[normalized] {
            return flagEmojiForRegionCode(regionCode)
        }

        if normalized.count == 2, Locale.Region.isoRegions.contains(where: { $0.identifier == normalized }) {
            return flagEmojiForRegionCode(normalized)
        }

        if let iso3Code = iso3To2[normalized] {
            return flagEmojiForRegionCode(iso3Code)
        }

        return fallbackFlag
    }

    private static func flagEmojiForRegionCode(_ regionCode: String) -> String {
        let code = regionCode.uppercased()
        guard code.count == 2 else { return fallbackFlag }
        let scalars = code.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            guard let value = UnicodeScalar(0x1F1E6 + Int(scalar.value) - 65) else { return nil }
            return value
        }
        return scalars.count == 2 ? String(String.UnicodeScalarView(scalars)) : fallbackFlag
    }

    private static func normalize(_ string: String) -> String {
        let folded = string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let filtered = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(filtered).components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private static let iso3To2: [String: String] = [
        "ARE": "AE",
        "GBR": "GB",
        "USA": "US",
        "VNM": "VN"
    ]
}

enum VPNConfigurationProtocol: String, Codable, CaseIterable {
    case ikev2 = "IKEV2"
    case ikev2IPSec = "IKEV2/IPSEC"
    case openVPN = "OPENVPN"

    var displayName: String {
        switch self {
        case .ikev2: return "IKEv2"
        case .ikev2IPSec: return "IKEv2/IPSec"
        case .openVPN: return "OpenVPN"
        }
    }

    var requiresProSubscription: Bool {
        self == .openVPN
    }
}

struct VPNConfigRequest: Encodable {
    let serverId: Int
    let protocolName: VPNConfigurationProtocol

    enum CodingKeys: String, CodingKey {
        case serverId
        case protocolName = "protocol"
    }
}

struct EncryptedPassphrase: Decodable, Equatable {
    let algorithm: String
    let keyId: String
    let ciphertext: String

    var ciphertextData: Data? {
        Data(base64Encoded: ciphertext.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct VPNConfigResponse: Decodable, Equatable {
    let success: Bool?
    let protocolName: String?
    let serverName: String
    let serverIp: String
    let certificateName: String?
    let configContent: String
    let encryptedPassphrase: EncryptedPassphrase
    let issueDate: Date?
    let expirationDate: Date?
    let clientIp: String?
    let deviceId: String?

    enum CodingKeys: String, CodingKey {
        case success
        case protocolName = "protocol"
        case serverName
        case serverIp
        case certificateName
        case configContent
        case encryptedPassphrase
        case issueDate
        case expirationDate
        case clientIp
        case deviceId
    }
}

struct SSWANProfile: Decodable, Equatable {
    let name: String?
    let uuid: String?
    let type: String?
    let remoteAddress: String?
    let localP12Base64: String?
    let localPassword: String?
    let localUsesRSAPSS: Bool
    let ikeProposal: String?
    let espProposal: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case uuid
        case type
        case remote
        case local
        case ikeProposal = "ike-proposal"
        case espProposal = "esp-proposal"
    }

    private enum RemoteKeys: String, CodingKey {
        case addr
    }

    private enum LocalKeys: String, CodingKey {
        case p12
        case password
        case rsaPSS = "rsa-pss"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        ikeProposal = try container.decodeIfPresent(String.self, forKey: .ikeProposal)
        espProposal = try container.decodeIfPresent(String.self, forKey: .espProposal)

        if let remote = try? container.nestedContainer(keyedBy: RemoteKeys.self, forKey: .remote) {
            remoteAddress = try remote.decodeIfPresent(String.self, forKey: .addr)
        } else {
            remoteAddress = nil
        }

        if let local = try? container.nestedContainer(keyedBy: LocalKeys.self, forKey: .local) {
            localP12Base64 = try local.decodeIfPresent(String.self, forKey: .p12)
            localPassword = try local.decodeIfPresent(String.self, forKey: .password)
            localUsesRSAPSS = try local.decodeIfPresent(Bool.self, forKey: .rsaPSS) ?? false
        } else {
            localP12Base64 = nil
            localPassword = nil
            localUsesRSAPSS = false
        }
    }
}

enum VPNConnectionState: Equatable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting

    var isConnected: Bool {
        switch self {
        case .connected, .reasserting:
            return true
        case .invalid, .disconnected, .connecting, .disconnecting:
            return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting, .reasserting:
            return true
        case .invalid, .disconnected, .connected:
            return false
        }
    }

    var title: String {
        switch self {
        case .invalid: return "VPN Unavailable"
        case .disconnected: return "Not Protected"
        case .connecting: return "Connecting"
        case .connected: return "Protected"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        }
    }

    var description: String {
        switch self {
        case .invalid: return "The VPN configuration is not ready yet."
        case .disconnected: return "Your connection is not secure"
        case .connecting: return "Establishing secure connection..."
        case .connected: return "Your connection is secure"
        case .reasserting: return "Re-establishing the tunnel after a network change..."
        case .disconnecting: return "Closing the secure tunnel..."
        }
    }

    var buttonTitle: String {
        switch self {
        case .invalid: return "Retry"
        case .disconnected: return "Connect"
        case .connecting: return "Cancel"
        case .connected: return "Disconnect"
        case .reasserting: return "Disconnect"
        case .disconnecting: return "Disconnecting..."
        }
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

    var planTier: AccountPlanTier {
        if isPro { return .pro }
        return AccountPlanTier(planName: plan) ?? .free
    }

    var displayName: String {
        planTier.rawValue
    }
}

extension UsageQuota {
    var planTierHint: AccountPlanTier {
        isUnlimited ? .pro : .free
    }
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
