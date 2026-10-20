// Notifier.swift
// Local notifications (transcript ready, capture out of automatic retries).

import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func transcriptReady(title: String) async {
        await post("Meeting transcript ready: \(title)")
    }

    static func recordingExhausted(title: String) async {
        await post(Strings.recordingExhausted(title))
    }

    private static func post(_ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = AppInfo.name
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            AppInfo.logger("Notifier").warning("notificación: \(error.localizedDescription, privacy: .public)")
        }
    }
}
