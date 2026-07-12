import Foundation
import UIKit
import UserNotifications

protocol VPNEventNotifying: AnyObject {
    func emit(_ payload: VPNNotificationPayload) async
}

final class SystemVPNEventNotifier: VPNEventNotifying {
    func emit(_ payload: VPNNotificationPayload) async {
        await VPNNotificationEmitter.emit(payload)
    }
}

final class NoOpVPNEventNotifier: VPNEventNotifying {
    func emit(_ payload: VPNNotificationPayload) async {}
}

@MainActor
final class VPNNotificationService: NSObject, UNUserNotificationCenterDelegate {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorizationIfNeeded() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshAuthorizationStatus()
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
