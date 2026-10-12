// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A development build runs under its own bundle identifier (`build.sh run`: …nimbusupsbar.dev),
/// so it has its own defaults domain. Its first launch copies the owner's preferences across from
/// the release's domain, once; what belongs to one copy's run rather than to the owner (the
/// outage it may be carrying, whether it registered its agent) stays behind, so a dev copy never
/// resumes the installed copy's outage or remounts the volumes it unmounted.
public enum DevDefaults {
    /// Set in the dev domain once the copy is made (or found unnecessary).
    public static let seededKey = "seededFromRelease"

    /// What to write into the dev domain, or nil when it was seeded before. Keys the dev domain
    /// already has keep their values.
    public static func seed(release: [String: Any]?, dev: [String: Any], leaving: Set<String>) -> [String: Any]? {
        guard dev[seededKey] == nil else { return nil }
        var out = (release ?? [:]).filter { !leaving.contains($0.key) && dev[$0.key] == nil && $0.key != seededKey }
        out[seededKey] = true
        return out
    }
}
