// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import NimbusUpsBarKit
import UserNotifications

/// User notifications for the outage stages. `UNUserNotificationCenter` only works from a
/// bundle, so the bare binary (CLI runs, `swift run`) logs instead.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()
    private var authorized: Bool?
    private var asked = false

    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func requestAuthorizationIfNeeded() {
        guard Notifications.available, !asked else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, error in
            Task { @MainActor in
                self?.authorized = ok
                if let error { Log.shared.append("notifications: \(error.localizedDescription)") }
            }
        }
    }

    func post(title: String, body: String, critical: Bool = false) {
        guard Settings.shared.notificationsEnabled else { return }
        guard Notifications.available else { return }
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = critical ? .defaultCritical : .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { Task { @MainActor in Log.shared.append("notification failed: \(error.localizedDescription)") } }
        }
    }

    /// Show banners even while this app is "frontmost" (it never is, but menu tracking counts).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
