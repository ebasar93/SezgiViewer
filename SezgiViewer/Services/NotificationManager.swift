import Foundation
import UserNotifications

/// Thin wrapper around local user notifications for the "no highlights" case.
enum NotificationManager {

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Best-effort; the app functions with or without permission.
        }
    }

    static func notifyNoHighlights(fileName: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "No Highlights Found"
            content.body = "No highlights found in \(fileName)"
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content,
                                                trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
