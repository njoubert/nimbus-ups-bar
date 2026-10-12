// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import NimbusUpsBarKit
import UserNotifications

/// User notifications for the outage stages. `UNUserNotificationCenter` only works from a
/// bundle, so the bare binary (CLI runs, `swift run`) logs instead.
///
/// Whether macOS lets them through is checked at launch and again at most once a minute (the
/// owner can change it in System Settings at any time), logged when it changes, and shown in
/// Health, Settings › General and the Inspector: a guard meant to run unattended whose banners
/// are blocked must say so (QA 2026-10-11, T2; a denial used to be swallowed).
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()
    private var asked = false
    /// What macOS last said (nil: not asked yet).
    private(set) var status: UNAuthorizationStatus?
    private var checkedAt: Date?
    private var checking = false

    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// For Health: can an outage banner reach the owner?
    var access: Health.NotificationAccess {
        guard Notifications.available else { return .unavailable }
        guard Settings.shared.notificationsEnabled else { return .offInSettings }
        switch status {
        case .denied: return .blockedByMacOS
        case .notDetermined: return .notDecided
        default: return .allowed
        }
    }

    /// For the Inspector and Settings.
    var accessText: String {
        switch access {
        case .unavailable: return "unavailable (no bundle)"
        case .offInSettings: return "off in Settings"
        case .blockedByMacOS: return "blocked by macOS (System Settings › Notifications)"
        case .notDecided: return "not decided yet"
        case .allowed: return status == nil ? "on (macOS not asked yet)" : "on, allowed by macOS"
        }
    }

    func requestAuthorizationIfNeeded() {
        guard Notifications.available, !asked else { return }
        asked = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, error in
            Task { @MainActor in
                if let error { Log.shared.append("notifications: \(error.localizedDescription)") }
                else if !ok { Log.shared.append("notifications: not allowed by macOS") }
                Notifications.shared.refresh(force: true)
            }
        }
    }

    /// Ask macOS whether the banners are allowed, at most once a minute unless `force`.
    func refresh(force: Bool = false) {
        guard Notifications.available, !checking else { return }
        if !force, let at = checkedAt, Date().timeIntervalSince(at) < 60 { return }
        checking = true
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let s = settings.authorizationStatus
            Task { @MainActor in
                let me = Notifications.shared
                me.checking = false
                me.checkedAt = Date()
                guard s != me.status else { return }
                me.status = s
                switch s {
                case .denied: Log.shared.append("notifications are blocked by macOS (System Settings › Notifications › Nimbus UPS Bar): outage banners will not appear")
                case .notDetermined: Log.shared.append("notifications: macOS has not asked yet")
                default: Log.shared.append("notifications: allowed by macOS")
                }
                NotificationCenter.default.post(name: Settings.didChange, object: nil)
            }
        }
    }

    /// System Settings › Notifications, at this app's page where macOS supports that.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(url)
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
