// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpsBarKit
import NimbusUpdater

/// This app's side of `NimbusUpdater`: the facts that identify it, in one place. Identical in
/// shape to the sibling apps'.
enum Updates {
    static let repo = "njoubert/nimbus-ups-bar"
    static let bundleID = "com.njoubert.nimbusupsbar"
    /// The Developer ID team the release is signed with; a download signed by anyone else is
    /// refused. Shared with the other Nimbus apps (one Apple ID, one team).
    static let teamID = "93A96TD57U"
    static let appName = "Nimbus UPS Bar"
    static let executableName = "NimbusUpsBar"

    static func config(currentVersion: SemanticVersion) -> UpdaterConfig {
        UpdaterConfig(repo: repo, bundleID: bundleID, teamID: teamID, appName: appName,
                      executableName: executableName, currentVersion: currentVersion,
                      announcesReadyUpdates: true)
    }

    static var runningVersion: SemanticVersion? { SemanticVersion.ofBundle() }

    static var installedVersion: SemanticVersion? {
        let plist = URL(fileURLWithPath: "/Applications/\(appName).app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return SemanticVersion(short)
    }
}
