// Notifier.swift
// Local notifications (transcript ready).

import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func transcriptReady(title: String) async {
        let content = UNMutableNotificationContent()
        content.title = AppInfo.name
        content.body = "Meeting transcript ready: \(title)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppInfo.logger("Notifier").warning("notificación: \(error.localizedDescription, privacy: .public)")
        }
    }
}
