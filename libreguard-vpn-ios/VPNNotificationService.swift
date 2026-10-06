import Foundation
import UIKit
import UserNotifications

protocol VPNEventNotifying: AnyObject {
    func emit(_ payload: VPNNotificationPayload) async
}
final class SystemVPNEventNotifier: VPNEventNotifying {
    func emit(_ payload: VPNNotificationPayload) async { await VPNNotificationEmitter.emit(payload) }
}
final class NoOpVPNEventNotifier: VPNEventNotifying {
    func emit(_ payload: VPNNotificationPayload) async {}
}

enum VPNNotificationAuthorizationOutcome: Equatable {
    case allowed, denied, notRequested, failed
}

@MainActor
protocol VPNNotificationAuthorizing: AnyObject {
    var authorizationStatus: UNAuthorizationStatus { get }
    func refreshAuthorizationStatus() async
    func requestAuthorizationIfNeeded() async -> VPNNotificationAuthorizationOutcome
    func openSystemSettings()
}

@MainActor
final class VPNNotificationService: NSObject, UNUserNotificationCenterDelegate, VPNNotificationAuthorizing {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private let readStatus: () async -> UNAuthorizationStatus
    private let request: () async throws -> Bool
    private let openSettings: () -> Void

    init(
        readStatus: @escaping () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        request: @escaping () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        },
        openSettings: @escaping () -> Void = {
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            UIApplication.shared.open(url)
        },
        installsDelegate: Bool = true
    ) {
        self.readStatus = readStatus
        self.request = request
        self.openSettings = openSettings
        super.init()
        if installsDelegate { UNUserNotificationCenter.current().delegate = self }
    }

    func refreshAuthorizationStatus() async { authorizationStatus = await readStatus() }

    func requestAuthorizationIfNeeded() async -> VPNNotificationAuthorizationOutcome {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return currentOutcome }
        do {
            _ = try await request()
            await refreshAuthorizationStatus()
            return currentOutcome
        } catch {
            await refreshAuthorizationStatus()
            return .failed
        }
    }

    private var currentOutcome: VPNNotificationAuthorizationOutcome {
        switch authorizationStatus {
        case .denied: .denied
        case .notDetermined: .notRequested
        default: .allowed
        }
    }
    func openSystemSettings() { openSettings() }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
}
