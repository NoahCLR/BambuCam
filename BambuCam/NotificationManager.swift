import Foundation
import UserNotifications
import BambuKit

/// Thin wrapper over UNUserNotificationCenter honoring per-event toggles.
@MainActor
final class NotificationManager {
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(event: PrintEvent, settings: NotificationSettings) {
        let content = UNMutableNotificationContent()
        switch event {
        case .finished:
            guard settings.finished else { return }
            content.title = "Print finished"
            content.body = "Your print is done."
        case .failed:
            guard settings.failed else { return }
            content.title = "Print failed"
            content.body = "The printer reported a failure."
        case .milestone(let pct):
            guard settings.milestones else { return }
            content.title = "Print progress"
            content.body = "\(pct)% complete."
        }
        content.sound = .default
        deliver(content)
    }

    func postConnectionLost() {
        let content = UNMutableNotificationContent()
        content.title = "Printer unreachable"
        content.body = "BambuCam lost the connection and keeps retrying."
        content.sound = .default
        deliver(content)
    }

    private func deliver(_ content: UNMutableNotificationContent) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
