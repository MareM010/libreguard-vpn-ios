import Foundation
import NetworkExtension
import OSLog

enum VPNAttemptPhase: String, Sendable {
    case preparing, awaitingApproval, starting, connected, stopping, stopped, cancelled
}

struct VPNAttemptEvent {
    let attemptID: UUID
    let protocolName: VPNConfigurationProtocol
    let phase: VPNAttemptPhase
    var failure: VPNConnectionFailure? = nil
    var nativeStartupObserved = false
}

struct VPNConnectionFailure: LocalizedError {
    enum Kind: String {
        case permissionDenied, invalidConfiguration, configurationDisabled, preferencesUnavailable
        case connectionFailed, startupTimeout, stopFailed, protectedSwitch
    }

    let kind: Kind
    var underlyingError: Error? = nil

    var errorDescription: String? {
        switch kind {
        case .permissionDenied:
            "VPN permission wasn’t granted. Tap Retry VPN Setup, then choose Allow when iOS asks."
        case .invalidConfiguration:
            "The VPN configuration or certificate couldn’t be used. Try setting up the VPN again."
        case .configurationDisabled:
            "The VPN configuration is disabled. Try setting up the VPN again."
        case .preferencesUnavailable:
            "iOS couldn’t save or load the VPN setup. Retry, and choose Allow if asked. If your device restricts VPN setup, check Settings → General → VPN & Device Management."
        case .connectionFailed:
            "The VPN couldn’t connect. Try again."
        case .startupTimeout:
            "The VPN didn’t finish connecting. Try again."
        case .stopFailed:
            "iOS hasn’t confirmed that the previous VPN stopped. Retry cleanup before connecting again."
        case .protectedSwitch:
            "Switching protocols requires turning off Kill Switch. Your protection is still on."
        }
    }

    var retryTitle: String? {
        switch kind {
        case .permissionDenied, .invalidConfiguration, .configurationDisabled, .preferencesUnavailable:
            "Retry VPN Setup"
        case .connectionFailed, .startupTimeout: "Retry Connection"
        case .stopFailed: "Retry Cleanup"
        case .protectedSwitch: nil
        }
    }

    static func classify(_ error: Error, phase: VPNAttemptPhase) -> VPNConnectionFailure {
        if let failure = error as? VPNConnectionFailure { return failure }
        let chain = errorChain(error)
        // Read/write failures also cover invalid profiles and device restrictions.
        // Only an explicit permission error in the underlying chain means denial.
        let denied = chain.contains {
            ($0.domain == "NEConfigurationErrorDomain" && $0.code == 10)
                || ($0.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains($0.code))
                || ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteNoPermissionError)
        }
        let code = chain.first { $0.domain == NEVPNErrorDomain }?.code
        let kind: Kind
        if denied { kind = .permissionDenied }
        else if code == NEVPNError.configurationInvalid.rawValue { kind = .invalidConfiguration }
        else if code == NEVPNError.configurationDisabled.rawValue { kind = .configurationDisabled }
        else if phase == .awaitingApproval || code == NEVPNError.configurationReadWriteFailed.rawValue {
            kind = .preferencesUnavailable
        } else { kind = .connectionFailed }
        return VPNConnectionFailure(kind: kind, underlyingError: error)
    }

    static func errorChain(_ error: Error) -> [NSError] {
        var result: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next, result.count < 8 {
            result.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}

struct VPNStopResult: Equatable, Sendable {
    let tunnelStopped: Bool
    let profileReleased: Bool
    var isSafe: Bool { tunnelStopped && profileReleased }
    static let stopped = VPNStopResult(tunnelStopped: true, profileReleased: true)
}

struct VPNConnectionTiming {
    var startup: Duration = .seconds(30)
    var stop: Duration = .seconds(10)
    var providerMessage: Duration = .seconds(2)
    var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// A callback can arrive after timeout or cancellation. Resume exactly once,
/// without waiting for an unresponsive provider to finish a structured child task.
@MainActor
enum VPNCallbackDeadline {
    static func run<Value: Sendable>(
        timeout: Duration,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) throws -> Void
    ) async throws -> Value {
        let pending = PendingVPNCallback<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.timer = Task { @MainActor in
                    do {
                        try await sleep(timeout)
                        try Task.checkCancellation()
                        pending.finish(.failure(VPNConnectionFailure(kind: .startupTimeout)))
                    } catch {}
                }
                do {
                    try start { result in
                        Task { @MainActor in pending.finish(result) }
                    }
                } catch { pending.finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }
}

@MainActor
private final class PendingVPNCallback<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        continuation.resume(with: result)
    }
}

@MainActor
enum VPNConnectionJournal {
    private static let logger = Logger(subsystem: "net.libreguard.connection", category: "Lifecycle")
    static func record(_ event: VPNAttemptEvent) {
        let errors = event.failure?.underlyingError.map {
            VPNConnectionFailure.errorChain($0).map { "\($0.domain)(\($0.code))" }.joined(separator: " <- ")
        } ?? ""
        let line = "\(ISO8601DateFormatter().string(from: Date())) attempt=\(event.attemptID) protocol=\(event.protocolName.rawValue) phase=\(event.phase.rawValue) failure=\(event.failure?.kind.rawValue ?? "none") \(errors)"
        logger.info("\(line, privacy: .public)")
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VPNSharedConstants.appGroupIdentifier) else { return }
        let library = container.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let url = library.appendingPathComponent("vpn-connection-lifecycle.log")
        let previous = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: container.appendingPathComponent("vpn-connection-lifecycle.log"), encoding: .utf8))
            ?? ""
        var lines = previous.split(separator: "\n").map(String.init)
        lines.append(line)
        // Keep complete UTF-8 lines and a bounded amount of diagnostic data.
        while lines.joined(separator: "\n").utf8.count > 64_000 { lines.removeFirst() }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Never resave a certificate profile without its identity. Cleanup is local,
/// works offline, and cannot remove a running or Kill Switch protected profile.
@MainActor
enum IKEv2StoppedProfileRecovery {
    static func recover(
        killSwitchEnabled: Bool,
        load: () async throws -> Void,
        profile: () -> NEVPNProtocolIKEv2?,
        isStopped: () -> Bool,
        disable: (NEVPNProtocolIKEv2) -> Void,
        save: () async throws -> Void,
        remove: () async throws -> Void,
        verifyReleased: () -> Bool
    ) async -> VPNStoppedProfileRecoveryResult {
        func failed(_ diagnostic: String) -> VPNStoppedProfileRecoveryResult {
            VPNStoppedProfileRecoveryResult(isApplicable: true, routingReleased: false,
                onDemandDisabled: false, profileDisabled: false, diagnostic: diagnostic)
        }
        guard !killSwitchEnabled, isStopped() else { return failed("The IKEv2 profile is still protected or running.") }
        do {
            try await load()
            try Task.checkCancellation()
            guard isStopped() else { return failed("IKEv2 resumed during profile cleanup.") }
            guard let current = profile() else { return .notApplicable }
            var needsRemoval = current.identityData?.isEmpty != false
            if !needsRemoval {
                disable(current)
                do { try await save() }
                catch {
                    let error = error as NSError
                    guard error.domain == NEVPNErrorDomain,
                          error.code == NEVPNError.configurationInvalid.rawValue else { throw error }
                    needsRemoval = true
                }
            }
            try Task.checkCancellation()
            if needsRemoval {
                guard isStopped() else { return failed("IKEv2 resumed before invalid profile removal.") }
                try await remove()
            }
            try await load()
            try Task.checkCancellation()
            guard isStopped(), !needsRemoval || profile() == nil, verifyReleased() else {
                return failed("iOS did not confirm that the stopped IKEv2 profile released routing.")
            }
            return VPNStoppedProfileRecoveryResult(isApplicable: true, routingReleased: true,
                onDemandDisabled: true, profileDisabled: true, diagnostic: nil)
        } catch {
            let codes = VPNConnectionFailure.errorChain(error).map { "\($0.domain)(\($0.code))" }.joined(separator: " <- ")
            return failed("IKEv2 profile cleanup failed: \(codes)")
        }
    }
}

extension VPNConfigurationProtocol {
    var transportProtocol: VPNConfigurationProtocol { self == .openVPN ? .openVPN : .ikev2 }
    static func fromSessionName(_ name: String) -> VPNConfigurationProtocol? {
        switch name {
        case "IKEV2", "IKEv2/IPSec", "IKEv2": .ikev2
        case "OPENVPN", "OpenVPN": .openVPN
        default: nil
        }
    }
}

/// Keep only the identity from a successful save, in memory, and reuse it only
/// for the same authenticated endpoint. Never persist the decrypted password.
struct IKEv2ApprovedIdentity {
    private let data: Data
    private let password: String?
    private let server: String
    private let local: String
    private let remote: String
    private let certificateType: NEVPNIKEv2CertificateType

    init?(profile: NEVPNProtocolIKEv2) {
        guard let data = profile.identityData, !data.isEmpty,
              let server = profile.serverAddress, !server.isEmpty,
              let local = profile.localIdentifier, !local.isEmpty,
              let remote = profile.remoteIdentifier, !remote.isEmpty,
              profile.authenticationMethod == .certificate else { return nil }
        self.data = data
        password = profile.identityDataPassword
        self.server = server
        self.local = local
        self.remote = remote
        certificateType = profile.certificateType
    }

    func hydrate(_ profile: NEVPNProtocolIKEv2) {
        guard profile.identityData?.isEmpty != false,
              profile.serverAddress == server, profile.localIdentifier == local,
              profile.remoteIdentifier == remote, profile.certificateType == certificateType,
              profile.authenticationMethod == .certificate else { return }
        profile.identityData = data
        profile.identityDataPassword = password
    }
}
