import ActivityKit
import Foundation
import NetworkExtension
import OSLog
import TunnelKitOpenVPNAppExtension

final class PacketTunnelProvider: OpenVPNTunnelProvider {
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

    override init() {
        super.init()
        dataCountInterval = 1_000
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
        publishFinalState()
        super.stopTunnel(with: reason) { [weak self] in
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
        VPNSharedSessionStore.save(traffic: reconnecting)
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
        let previous = VPNSharedSessionStore.loadTraffic() ?? .zero()
        let final = VPNSessionTraffic(
            state: .disconnected,
            downloadedBytes: previous.downloadedBytes,
            uploadedBytes: previous.uploadedBytes,
            downloadBitsPerSecond: 0,
            uploadBitsPerSecond: 0,
            sampledAt: Date()
        )
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
        guard let defaults = UserDefaults(suiteName: VPNSharedConstants.appGroupIdentifier),
              let counts = defaults.array(forKey: "TunnelKitDataCount") as? [Int],
              counts.count == 2 else { return }

        let now = Date()
        let snapshot = TunnelTrafficSnapshot(
            downloadedBytes: Int64(max(0, counts[0])),
            uploadedBytes: Int64(max(0, counts[1]))
        )
        let state: VPNActivityConnectionState = reasserting ? .reconnecting : .connected
        let traffic = trafficAccumulator.consume(snapshot, at: now, state: state)
        VPNSharedSessionStore.save(traffic: traffic)
        await updateActivity(descriptor: descriptor, traffic: traffic)
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
