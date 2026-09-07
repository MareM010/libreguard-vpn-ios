import ActivityKit
import Foundation
import NetworkExtension
import OSLog
import TunnelKitCore
import TunnelKitOpenVPNAppExtension

final class PacketTunnelProvider: OpenVPNTunnelProvider {
    private static let privateDNSAddress = "10.254.0.53"
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? OpenVPNConstants.tunnelBundleIdentifier,
        category: "PacketTunnel"
    )
    private let diagnosticsLock = NSLock()
    private var storedDiagnostics = OpenVPNRuntimeDiagnostics(
        state: .idle,
        engine: .tunnelKit,
        canStartConnections: true
    )
    private var activityUpdateTask: Task<Void, Never>?
    private var trafficAccumulator = VPNTrafficAccumulator()
    private var connectivityProbeConnections: [NWTCPConnection] = []
    private var connectivityProbeUDPSessions: [NWUDPSession] = []
    private var connectivityProbeObservations: [NSKeyValueObservation] = []
    private static let connectivityProbeResultsKey = "OpenVPNConnectivityProbeResults"

    override init() {
        super.init()
        dataCountInterval = 1_000
    }

    override func shouldDropPacket(_ packet: Data) -> Bool {
        blocksIPv6 && IPv6PacketFilter.shouldDrop(packet)
    }

    private var diagnostics: OpenVPNRuntimeDiagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return storedDiagnostics
    }

    override var reasserting: Bool {
        didSet {
            mutateDiagnostics { diagnostics in
                diagnostics.state = reasserting ? .reconnecting : .connected
                if !reasserting, diagnostics.connectedAt == nil {
                    diagnostics.connectedAt = Date()
                }
            }
            publishReassertingState()
        }
    }

    override func startTunnel(options: [String: NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        blocksIPv6 = false

        guard let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              OpenVPNIPv6Protection.isEnabled(in: providerConfiguration) else {
            let error = NSError(
                domain: "OpenVPNPacketTunnel",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "IPv6 blocking is not enabled for this OpenVPN tunnel."]
            )
            VPNSharedSessionStore.saveTunnelError(error.localizedDescription)
            completionHandler(error)
            return
        }

        blocksIPv6 = true
        OpenVPNExtensionLifecycleJournal.append("start-requested")
        let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol
        let providerKeys = tunnelProtocol?.providerConfiguration?.keys.sorted().joined(separator: ",") ?? "<missing>"
        OpenVPNExtensionLifecycleJournal.append(
            "provider-configuration serverAddressPresent=\(tunnelProtocol?.serverAddress?.isEmpty == false) keys=\(providerKeys)"
        )
        logger.info("OpenVPN packet tunnel start requested")
        VPNSharedSessionStore.clearTunnelError()
        let metadata = OpenVPNConnectionMetadataStore.load()
        mutateDiagnostics { diagnostics in
            diagnostics = OpenVPNRuntimeDiagnostics(
                state: .starting,
                serverId: metadata?.serverId,
                serverName: metadata?.serverName,
                serverAddress: metadata?.serverAddress,
                engine: .tunnelKit,
                canStartConnections: true
            )
        }

        super.startTunnel(options: options) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            self.persistTunnelKitLog()
            self.mutateDiagnostics { diagnostics in
                if let error {
                    diagnostics.state = .failed
                    let details = Self.describe(error, includingTunnelKitError: true)
                    diagnostics.lastError = details
                    VPNSharedSessionStore.saveTunnelError(details)
                } else {
                    diagnostics.state = .connected
                    diagnostics.connectedAt = Date()
                    diagnostics.lastError = nil
                    VPNSharedSessionStore.clearTunnelError()
                }
            }
            if let error {
                OpenVPNExtensionLifecycleJournal.append("start-failed \(Self.describe(error, includingTunnelKitError: true))")
                self.logger.error("OpenVPN tunnel failed to start: \(Self.describe(error, includingTunnelKitError: true))")
            } else {
                OpenVPNExtensionLifecycleJournal.append("start-completed")
                self.logger.info("OpenVPN tunnel connected")
                self.beginActivityUpdates()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.runConnectivityProbes()
                }
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        OpenVPNExtensionLifecycleJournal.append("stop-requested reason=\(reason.rawValue)")
        logger.info("OpenVPN packet tunnel stop requested with reason \(reason.rawValue, privacy: .public)")
        mutateDiagnostics { $0.state = .stopping }
        activityUpdateTask?.cancel()
        activityUpdateTask = nil
        connectivityProbeConnections.forEach { $0.cancel() }
        connectivityProbeConnections.removeAll()
        connectivityProbeUDPSessions.forEach { $0.cancel() }
        connectivityProbeUDPSessions.removeAll()
        connectivityProbeObservations.forEach { $0.invalidate() }
        connectivityProbeObservations.removeAll()
        publishFinalState()
        super.stopTunnel(with: reason) { [weak self] in
            self?.persistTunnelKitLog()
            OpenVPNExtensionLifecycleJournal.append("stop-completed")
            self?.mutateDiagnostics { diagnostics in
                diagnostics.state = .stopped
                diagnostics.connectedAt = nil
            }
            completionHandler()
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let request = try? OpenVPNProviderMessageCodec.decodeRequest(from: messageData) else {
            super.handleAppMessage(messageData, completionHandler: completionHandler)
            return
        }

        let response = try? OpenVPNProviderMessageCodec.encodeResponse(
            type: request.type,
            diagnostics: diagnostics
        )
        completionHandler?(response)
    }

    private func mutateDiagnostics(_ mutation: (inout OpenVPNRuntimeDiagnostics) -> Void) {
        diagnosticsLock.lock()
        mutation(&storedDiagnostics)
        diagnosticsLock.unlock()
    }

    /// This TunnelKit version keeps its log in memory. Save it before the
    /// extension exits so the containing app can read the failed handshake.
    private func persistTunnelKitLog() {
        let log = PIATunnelKitLogHandler.logStorage.getAllLogs()
        guard !log.isEmpty else {
            logger.error("TunnelKit diagnostic log storage is empty")
            return
        }
        let snapshot = String(log.suffix(64_000))
        // Emit individual lines so unified logging does not truncate a single
        // large message. Raw profile logging is disabled in ConfigurationParser.
        for line in snapshot.split(separator: "\n") {
            logger.debug("TunnelKit: \(String(line), privacy: .public)")
        }
        var destinations = [FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]]
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: OpenVPNConstants.appGroupIdentifier
        ) {
            destinations.append(containerURL)
        } else {
            logger.error("Shared app-group container is unavailable for TunnelKit diagnostics")
        }
        for directory in destinations {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try snapshot.write(
                    to: directory.appendingPathComponent("debug.log"),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                logger.error("Could not save TunnelKit diagnostic log: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A one-time diagnostic only. These probes travel through the established
    /// packet tunnel and distinguish an Internet forwarding failure from a DNS
    /// resolution failure without affecting the VPN session.
    private func runConnectivityProbes() {
        runTCPConnectProbe(label: "public IPv4 TCP", hostname: "1.1.1.1")
        runTCPConnectProbe(label: "LibreGuard API TCP", hostname: "management.libreguard.net")
        runHTTPSProbe()
        runPrivateDNSProbe()
    }

    private func runTCPConnectProbe(label: String, hostname: String) {
        saveConnectivityProbeResult(label: label, result: "started")
        let endpoint = NWHostEndpoint(hostname: hostname, port: "443")
        let connection = createTCPConnectionThroughTunnel(
            to: endpoint,
            enableTLS: false,
            tlsParameters: nil,
            delegate: nil
        )
        connectivityProbeConnections.append(connection)

        var observation: NSKeyValueObservation?
        var completed = false
        let complete: (String) -> Void = { [weak self] result in
            guard !completed else { return }
            completed = true
            observation?.invalidate()
            connection.cancel()
            self?.connectivityProbeConnections.removeAll { $0 === connection }
            if let observation {
                self?.connectivityProbeObservations.removeAll { $0 === observation }
            }
            OpenVPNExtensionLifecycleJournal.append("connectivity-probe \(label)=\(result)")
            self?.saveConnectivityProbeResult(label: label, result: result)
            self?.logger.info("Tunnel connectivity probe (\(label, privacy: .public)): \(result, privacy: .public)")
        }

        observation = connection.observe(\.state, options: [.new]) { connection, _ in
            DispatchQueue.main.async {
                switch connection.state {
                case .connected:
                    complete("connected")
                case .disconnected:
                    complete("disconnected")
                case .cancelled:
                    complete("cancelled")
                default:
                    break
                }
            }
        }
        if let observation {
            connectivityProbeObservations.append(observation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            complete("timed out")
        }
    }

    /// Complete a TLS handshake, send an HTTP request, and require response
    /// bytes. A bare TCP connect is insufficient because it succeeds before
    /// the packet sizes used by TLS and HTTP are exercised.
    private func runHTTPSProbe() {
        let label = "LibreGuard HTTPS payload"
        saveConnectivityProbeResult(label: label, result: "started")
        let connection = createTCPConnectionThroughTunnel(
            to: NWHostEndpoint(hostname: "management.libreguard.net", port: "443"),
            enableTLS: true,
            tlsParameters: nil,
            delegate: nil
        )
        connectivityProbeConnections.append(connection)

        var observation: NSKeyValueObservation?
        var completed = false
        var requestStarted = false
        let complete: (String) -> Void = { [weak self] result in
            guard !completed else { return }
            completed = true
            observation?.invalidate()
            connection.cancel()
            self?.connectivityProbeConnections.removeAll { $0 === connection }
            if let observation {
                self?.connectivityProbeObservations.removeAll { $0 === observation }
            }
            self?.saveConnectivityProbeResult(label: label, result: result)
            self?.logger.info("Tunnel connectivity probe (\(label, privacy: .public)): \(result, privacy: .public)")
        }

        observation = connection.observe(\.state, options: [.new]) { connection, _ in
            DispatchQueue.main.async {
                switch connection.state {
                case .connected where !requestStarted:
                    requestStarted = true
                    let request = Data(
                        "HEAD / HTTP/1.1\r\nHost: management.libreguard.net\r\nConnection: close\r\n\r\n".utf8
                    )
                    connection.write(request) { error in
                        DispatchQueue.main.async {
                            if let error {
                                complete("HTTP write failed: \(Self.shortDescription(error))")
                                return
                            }
                            connection.readMinimumLength(1, maximumLength: 4_096) { data, error in
                                DispatchQueue.main.async {
                                    if let error {
                                        complete("HTTP read failed: \(Self.shortDescription(error))")
                                    } else if let data, !data.isEmpty {
                                        let firstLine = String(decoding: data, as: UTF8.self)
                                            .components(separatedBy: "\r\n")
                                            .first ?? "response"
                                        complete("received \(data.count) bytes (\(firstLine))")
                                    } else {
                                        complete("HTTP connection closed without response")
                                    }
                                }
                            }
                        }
                    }
                case .disconnected:
                    complete("TLS disconnected: \(connection.error.map(Self.shortDescription) ?? "no error")")
                case .cancelled:
                    complete("TLS cancelled: \(connection.error.map(Self.shortDescription) ?? "no error")")
                default:
                    break
                }
            }
        }
        if let observation {
            connectivityProbeObservations.append(observation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            complete(requestStarted ? "HTTP response timed out" : "TLS handshake timed out")
        }
    }

    /// Query the resolver configured by LibreGuard over UDP through the tunnel.
    /// This detects a resolver that is routable but never answers DNS queries.
    private func runPrivateDNSProbe() {
        let label = "private DNS UDP"
        let queryID: UInt16 = 0x4c47
        saveConnectivityProbeResult(label: label, result: "started")
        let session = createUDPSessionThroughTunnel(
            to: NWHostEndpoint(hostname: Self.privateDNSAddress, port: "53"),
            from: nil
        )
        connectivityProbeUDPSessions.append(session)

        var observation: NSKeyValueObservation?
        var completed = false
        var querySent = false
        let complete: (String) -> Void = { [weak self] result in
            guard !completed else { return }
            completed = true
            observation?.invalidate()
            session.cancel()
            self?.connectivityProbeUDPSessions.removeAll { $0 === session }
            if let observation {
                self?.connectivityProbeObservations.removeAll { $0 === observation }
            }
            self?.saveConnectivityProbeResult(label: label, result: result)
            self?.logger.info("Tunnel connectivity probe (\(label, privacy: .public)): \(result, privacy: .public)")
        }

        observation = session.observe(\NWUDPSession.state, options: [.new]) { session, _ in
            DispatchQueue.main.async {
                switch session.state {
                case .ready where !querySent:
                    querySent = true
                    session.setReadHandler({ datagrams, error in
                        DispatchQueue.main.async {
                            if let error {
                                complete("read failed: \(Self.shortDescription(error))")
                            } else if let response = datagrams?.first, response.count >= 12 {
                                let receivedID = UInt16(response[0]) << 8 | UInt16(response[1])
                                let responseCode = response[3] & 0x0f
                                let answers = UInt16(response[6]) << 8 | UInt16(response[7])
                                guard receivedID == queryID else {
                                    complete("response ID mismatch")
                                    return
                                }
                                complete("response rcode=\(responseCode) answers=\(answers)")
                            } else {
                                complete("empty or malformed response")
                            }
                        }
                    }, maxDatagrams: 1)
                    session.writeDatagram(Self.dnsAQuery(hostname: "management.libreguard.net", id: queryID)) { error in
                        if let error {
                            DispatchQueue.main.async {
                                complete("write failed: \(Self.shortDescription(error))")
                            }
                        }
                    }
                case .failed:
                    complete("session failed")
                case .cancelled:
                    complete("session cancelled")
                default:
                    break
                }
            }
        }
        if let observation {
            connectivityProbeObservations.append(observation)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            complete(querySent ? "response timed out" : "session setup timed out")
        }
    }

    private static func dnsAQuery(hostname: String, id: UInt16) -> Data {
        var query = Data([
            UInt8(id >> 8), UInt8(id & 0xff),
            0x01, 0x00,
            0x00, 0x01,
            0x00, 0x00,
            0x00, 0x00,
            0x00, 0x00
        ])
        for label in hostname.split(separator: ".") {
            let bytes = Array(label.utf8)
            query.append(UInt8(bytes.count))
            query.append(contentsOf: bytes)
        }
        query.append(UInt8(0))
        query.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        return query
    }

    private static func shortDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    private func saveConnectivityProbeResult(label: String, result: String) {
        guard let defaults = UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier) else {
            return
        }
        var results = defaults.dictionary(forKey: Self.connectivityProbeResultsKey) as? [String: String] ?? [:]
        results[label] = result
        defaults.set(results, forKey: Self.connectivityProbeResultsKey)
    }

    private func beginActivityUpdates() {
        guard let descriptor = VPNSharedSessionStore.loadDescriptor() else { return }
        trafficAccumulator = VPNTrafficAccumulator(existingTraffic: VPNSharedSessionStore.loadTraffic())
        activityUpdateTask?.cancel()
        activityUpdateTask = Task { [weak self] in
            guard let self else { return }
            await VPNNotificationEmitter.emit(VPNNotificationPayload(
                event: .connected,
                descriptor: descriptor,
                traffic: VPNSharedSessionStore.loadTraffic()
            ))

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self.publishCurrentTraffic(descriptor: descriptor)
            }
        }
    }

    private func publishReassertingState() {
        guard reasserting,
              let descriptor = VPNSharedSessionStore.loadDescriptor() else { return }
        let previous = VPNSharedSessionStore.loadTraffic() ?? .zero()
        let reconnecting = VPNSessionTraffic(
            state: .reconnecting,
            downloadedBytes: previous.downloadedBytes,
            uploadedBytes: previous.uploadedBytes,
            downloadBitsPerSecond: 0,
            uploadBitsPerSecond: 0,
            sampledAt: Date()
        )
        VPNSharedSessionStore.save(traffic: reconnecting, sessionID: descriptor.sessionID)
        Task {
            await updateActivity(descriptor: descriptor, traffic: reconnecting)
            if descriptor.killSwitchEnabled {
                await VPNNotificationEmitter.emit(VPNNotificationPayload(
                    event: .killSwitch,
                    descriptor: descriptor,
                    traffic: reconnecting
                ))
            }
        }
    }

    private func publishFinalState() {
        guard let descriptor = VPNSharedSessionStore.loadDescriptor() else { return }
        let final: VPNSessionTraffic
        if let snapshot = currentTrafficSnapshot() {
            let now = Date()
            if let checkpoint = VPNSharedSessionStore.loadCheckpoint(),
               checkpoint.sessionID == descriptor.sessionID {
                let previous = VPNSharedSessionStore.loadTraffic() ?? .zero(at: checkpoint.sampledAt)
                let gap = snapshot.delta(from: checkpoint.snapshot)
                final = VPNSessionTraffic(
                    state: .disconnected,
                    downloadedBytes: saturatingAdd(previous.downloadedBytes, gap.downloadedBytes),
                    uploadedBytes: saturatingAdd(previous.uploadedBytes, gap.uploadedBytes),
                    downloadBitsPerSecond: 0,
                    uploadBitsPerSecond: 0,
                    sampledAt: now
                )
            } else {
                final = trafficAccumulator.consume(snapshot, at: now, state: .disconnected)
            }
        } else {
            let previous = VPNSharedSessionStore.loadTraffic() ?? .zero()
            final = VPNSessionTraffic(
                state: .disconnected,
                downloadedBytes: previous.downloadedBytes,
                uploadedBytes: previous.uploadedBytes,
                downloadBitsPerSecond: 0,
                uploadBitsPerSecond: 0,
                sampledAt: Date()
            )
        }
        VPNSharedSessionStore.save(traffic: final, sessionID: descriptor.sessionID)
        let intent = VPNSharedSessionStore.loadDisconnectIntent()
        Task {
            await endActivity(descriptor: descriptor, traffic: final)
            guard intent != .suppress else { return }
            let event: VPNNotificationEvent = descriptor.killSwitchEnabled && intent == nil
                ? .killSwitch
                : .disconnected
            await VPNNotificationEmitter.emit(VPNNotificationPayload(
                event: event,
                descriptor: descriptor,
                traffic: final
            ))
        }
    }

    private func publishCurrentTraffic(descriptor: VPNSessionDescriptor) async {
        guard let snapshot = currentTrafficSnapshot() else { return }
        let now = Date()
        let state: VPNActivityConnectionState = reasserting ? .reconnecting : .connected
        let traffic = trafficAccumulator.consume(snapshot, at: now, state: state)
        VPNSharedSessionStore.save(traffic: traffic, sessionID: descriptor.sessionID)
        await updateActivity(descriptor: descriptor, traffic: traffic)
        VPNSharedSessionStore.save(
            checkpoint: VPNTrafficCheckpoint(
                sessionID: descriptor.sessionID,
                snapshot: snapshot,
                sampledAt: traffic.sampledAt
            )
        )
    }

    private func currentTrafficSnapshot() -> TunnelTrafficSnapshot? {
        guard let defaults = UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier),
              let counts = defaults.array(forKey: "TunnelKitDataCount") as? [Int],
              counts.count == 2 else { return nil }
        return TunnelTrafficSnapshot(
            downloadedBytes: Int64(max(0, counts[0])),
            uploadedBytes: Int64(max(0, counts[1]))
        )
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private func updateActivity(
        descriptor: VPNSessionDescriptor,
        traffic: VPNSessionTraffic
    ) async {
        guard let activity = Activity<VPNActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == descriptor.sessionID
        }) else { return }
        await activity.update(ActivityContent(
            state: VPNActivityAttributes.ContentState(traffic: traffic),
            staleDate: traffic.sampledAt.addingTimeInterval(15),
            relevanceScore: traffic.state == .reconnecting ? 110 : 100
        ))
    }

    private func endActivity(
        descriptor: VPNSessionDescriptor,
        traffic: VPNSessionTraffic
    ) async {
        guard let activity = Activity<VPNActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == descriptor.sessionID
        }) else { return }
        await activity.end(
            ActivityContent(
                state: VPNActivityAttributes.ContentState(traffic: traffic),
                staleDate: nil,
                relevanceScore: 0
            ),
            dismissalPolicy: .immediate
        )
    }

    private static func describe(_ error: Error, includingTunnelKitError: Bool = false) -> String {
        let nsError = error as NSError
        var details = ["\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"]
        for key in [NSLocalizedFailureReasonErrorKey, NSLocalizedRecoverySuggestionErrorKey] {
            if let value = nsError.userInfo[key] as? String, !value.isEmpty {
                details.append(value)
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("underlying \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)")
        }
        if includingTunnelKitError,
           let rawError = UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier)?
            .string(forKey: "TunnelKitLastError"),
           !rawError.isEmpty {
            details.append("TunnelKitLastError=\(rawError)")
        }
        return details.joined(separator: " | ")
    }
}
