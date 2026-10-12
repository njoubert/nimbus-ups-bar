// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpsBarKit
import ServiceManagement

/// Persistence: a per-user launchd agent, registered through `SMAppService` from the plist in
/// the app bundle's `Contents/Library/LaunchAgents/`. It starts the app at login and, with
/// `KeepAlive.SuccessfulExit = false`, relaunches it if it ever crashes, while a deliberate
/// Quit (exit code 0) stays quit. It shows up in System Settings › General › Login Items
/// under "Allow in the Background".
///
/// A plain Login Item (what the sibling apps use) restarts nothing; for a guard that has to be
/// running when the owner is away, the crash restart is the point.
///
/// The registration is tied to the bundle that makes the call, so `build.sh install` runs the
/// installed copy with `--enable-agent`, and `uninstall` runs it with `--disable-agent` before
/// deleting it (otherwise a dangling entry is left behind).
///
/// The label follows the bundle identifier, so the development bundle (`Updates.devBundleID`)
/// has an agent of its own and never touches the installed copy's.
enum BackgroundAgent {
    static func label(bundleID: String) -> String { "\(bundleID).agent" }
    /// The bare binary has no bundle identifier; it has no agent either (`isAvailable`).
    static var label: String { label(bundleID: Bundle.main.bundleIdentifier ?? Updates.bundleID) }
    static var plistName: String { "\(label).plist" }
    /// Set once the app has registered itself (first launch from /Applications, or
    /// `--enable-agent`) or the user has toggled it; after that, never auto-register again.
    static let registeredDefaultsKey = "agentRegistered"

    static var service: SMAppService { SMAppService.agent(plistName: plistName) }
    static var status: SMAppService.Status { service.status }
    static var isEnabled: Bool { status == .enabled }

    /// Is the plist present in this bundle at all? A bare `swift build` binary has none.
    static var isAvailable: Bool {
        guard let url = Bundle.main.builtInPlugInsURL?.deletingLastPathComponent() else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Library/LaunchAgents/\(plistName)").path)
    }

    static func setEnabled(_ on: Bool) throws {
        if on { try service.register() } else { try service.unregister() }
    }

    /// `SMAppService` reports an agent that was never registered as `.notFound` (the launchd
    /// database has no such job), not `.notRegistered`; whether the plist exists in the bundle
    /// is `isAvailable`'s question.
    static var statusDescription: String {
        guard isAvailable else { return "no agent plist in this bundle (a bare swift build; use build.sh run or install)" }
        switch status {
        case .enabled: return "enabled"
        case .notRegistered, .notFound: return "not registered"
        case .requiresApproval: return "requires approval in System Settings › Login Items"
        @unknown default: return "unknown"
        }
    }

    /// The agent plist, as `build.sh` writes it into the bundle. Kept here so the label, the
    /// executable name and the KeepAlive rule live next to the code that registers them.
    static func plist(executable: String, label: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>BundleProgram</key><string>Contents/MacOS/\(executable)</string>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>ThrottleInterval</key><integer>10</integer>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <key>ProcessType</key><string>Interactive</string>
        </dict></plist>
        """
    }
}
