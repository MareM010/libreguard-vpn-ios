import Foundation

struct OpenVPNProfileEnvelope: Codable, Equatable {
    static let currentSchemaVersion = OpenVPNConstants.profileSchemaVersion

    let schemaVersion: Int
    let serverId: Int
    let serverName: String
    let serverAddress: String
    let certificateName: String?
    let issueDate: Date?
    let expirationDate: Date?
    let configContent: String
    let privateKeyPassphrase: String
    let storedAt: Date

    init(
        serverId: Int,
        serverName: String,
        serverAddress: String,
        certificateName: String?,
        issueDate: Date?,
        expirationDate: Date?,
        configContent: String,
        privateKeyPassphrase: String,
        storedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.serverId = serverId
        self.serverName = serverName
        self.serverAddress = serverAddress
        self.certificateName = certificateName
        self.issueDate = issueDate
        self.expirationDate = expirationDate
        self.configContent = configContent
        self.privateKeyPassphrase = privateKeyPassphrase
        self.storedAt = storedAt
    }

    var isExpired: Bool {
        guard let expirationDate else { return false }
        return expirationDate <= Date()
    }
}

struct OpenVPNProfileConfiguration: Equatable {
    struct Directive: Equatable {
        let name: String
        let arguments: [String]
    }

    struct RemoteEndpoint: Equatable {
        let host: String
        let port: Int?
    }

    let rawConfiguration: String
    let directives: [Directive]
    let inlineBlocks: [String: String]

    var remoteEndpoints: [RemoteEndpoint] {
        directives
            .filter { $0.name == "remote" && !$0.arguments.isEmpty }
            .compactMap { directive in
                let host = directive.arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !host.isEmpty else { return nil }
                let port = directive.arguments.dropFirst().first.flatMap { Int($0) }
                return RemoteEndpoint(host: host, port: port)
            }
    }

    var deviceType: String? {
        directiveValue(named: "dev")
    }

    var transportProtocol: String? {
        directiveValue(named: "proto")
    }

    var usesTLSCrypt: Bool {
        hasInlineBlock(named: "tls-crypt") || directives.contains(where: { $0.name == "tls-crypt" })
    }

    var hasClientCertificateBlocks: Bool {
        hasInlineBlock(named: "ca") && hasInlineBlock(named: "cert") && hasInlineBlock(named: "key")
    }

    func validateMobileCompatibility() throws {
        guard directives.contains(where: { $0.name == "client" }) else {
            throw OpenVPNProfileError.missingRequiredDirective("client")
        }

        guard let dev = deviceType?.lowercased(), dev == "tun" else {
            throw OpenVPNProfileError.unsupportedDeviceType(deviceType ?? "missing")
        }

        if directives.contains(where: { $0.name == "secret" }) {
            throw OpenVPNProfileError.unsupportedDirective("secret")
        }
        if directives.contains(where: { $0.name == "fragment" }) {
            throw OpenVPNProfileError.unsupportedDirective("fragment")
        }
        if directives.contains(where: { $0.name == "tap" }) {
            throw OpenVPNProfileError.unsupportedDeviceType("tap")
        }

        guard !remoteEndpoints.isEmpty else {
            throw OpenVPNProfileError.missingRequiredDirective("remote")
        }

        guard transportProtocol != nil else {
            throw OpenVPNProfileError.missingRequiredDirective("proto")
        }

        guard hasClientCertificateBlocks else {
            throw OpenVPNProfileError.missingRequiredBlock("ca/cert/key")
        }

        guard usesTLSCrypt else {
            throw OpenVPNProfileError.missingRequiredBlock("tls-crypt")
        }
    }

    static func parse(_ rawConfiguration: String) throws -> OpenVPNProfileConfiguration {
        guard !rawConfiguration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenVPNProfileError.invalidConfiguration("The OpenVPN profile is empty.")
        }

        var directives: [Directive] = []
        var inlineBlocks: [String: String] = [:]
        let lines = rawConfiguration.components(separatedBy: .newlines)
        var currentBlockName: String?
        var currentBlockContents: [String] = []

        func flushBlock() {
            guard let blockName = currentBlockName else { return }
            inlineBlocks[blockName] = currentBlockContents.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if let blockName = currentBlockName {
                if line.caseInsensitiveCompare("</\(blockName)>") == .orderedSame {
                    flushBlock()
                    currentBlockName = nil
                    currentBlockContents = []
                } else {
                    currentBlockContents.append(rawLine)
                }
                continue
            }

            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }

            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                let blockName = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !blockName.isEmpty else {
                    throw OpenVPNProfileError.invalidConfiguration("Malformed inline block tag: \(line)")
                }
                currentBlockName = blockName
                currentBlockContents = []
                continue
            }

            let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let name = tokens.first?.lowercased() else { continue }
            let arguments = Array(tokens.dropFirst())
            directives.append(Directive(name: name, arguments: arguments))
        }

        if let blockName = currentBlockName {
            throw OpenVPNProfileError.invalidConfiguration("Missing closing tag for <\(blockName)> block.")
        }

        return OpenVPNProfileConfiguration(
            rawConfiguration: rawConfiguration,
            directives: directives,
            inlineBlocks: inlineBlocks
        )
    }

    private func hasInlineBlock(named name: String) -> Bool {
        inlineBlocks[name.lowercased()] != nil
    }

    private func directiveValue(named name: String) -> String? {
        directives.first(where: { $0.name == name })?.arguments.first
    }
}

enum OpenVPNProfileError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case missingRequiredDirective(String)
    case missingRequiredBlock(String)
    case unsupportedDirective(String)
    case unsupportedDeviceType(String)
    case expiredCertificate

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            return message
        case let .missingRequiredDirective(name):
            return "The OpenVPN profile is missing required directive: \(name)"
        case let .missingRequiredBlock(name):
            return "The OpenVPN profile is missing required block: \(name)"
        case let .unsupportedDirective(name):
            return "The OpenVPN profile uses an unsupported directive: \(name)"
        case let .unsupportedDeviceType(deviceType):
            return "The OpenVPN profile uses an unsupported device type: \(deviceType)"
        case .expiredCertificate:
            return "The OpenVPN certificate has expired."
        }
    }
}
