// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What the owner approved: how long a blip may last before anything happens, when the
/// volumes come off regardless, whether apps are asked to quit, and what to do once the
/// drives are safe. Every number here is a judgement the owner can change in Settings.
public struct Policy: Equatable, Sendable {
    /// On battery this long, nothing is touched beyond a notification: a flicker must not
    /// disturb anything. After it, apps are asked to quit and volumes unmount as they free up.
    public var graceSeconds: TimeInterval
    /// On battery this long, every protected volume is unmounted whether or not an app still
    /// holds it. The soft stage between `graceSeconds` and this is the apps' chance to close.
    public var hardAfterSeconds: TimeInterval
    /// …or as soon as the UPS reports this charge or less. Nil: the charge never forces anything
    /// (this UPS's gauge follows the battery voltage and sags 20–30 points in the first minute).
    public var hardAtPercent: Int?
    /// …or as soon as the UPS's runtime estimate is this short. Nil: the estimate never forces.
    public var hardAtRuntimeSeconds: Int?
    /// Charge and runtime are ignored this long after the transfer: some UPSes report 0 % or
    /// a nonsense runtime for the first seconds on battery.
    public var ignoreReadingsSeconds: TimeInterval
    /// Line power has to stay back this long before the outage is over. Under a brownout the
    /// UPS transfers every few seconds; without this every flap would reset the clock, the
    /// limits and the ask, and the battery would drain with nothing protected.
    public var lineStableSeconds: TimeInterval
    /// Send the apps holding files a quit event at the soft stage (the same thing as choosing
    /// Quit from their menu; an app with unsaved work shows its own dialog). Off means apps
    /// are never asked and the volumes wait for the hard limit.
    public var quitApps: Bool
    /// An app asked to quit that still holds its volume this long later has the volume
    /// force-unmounted anyway, before any hard limit. Nil: a stubborn app keeps its volume
    /// mounted until a hard limit (the verified behaviour; the default).
    public var quitTimeoutSeconds: TimeInterval?
    /// Apps never sent a quit and never waited for, by bundle id or name. Finder is always in it.
    public var neverQuit: Set<String>
    /// Once every protected volume is unmounted.
    public var afterSafe: AfterSafe

    public enum AfterSafe: String, CaseIterable, Equatable, Sendable {
        case keepRunning, sleep, shutDown

        public var title: String {
            switch self {
            case .keepRunning: return "Keep running"
            case .sleep: return "Put the Mac to sleep"
            case .shutDown: return "Shut the Mac down"
            }
        }
    }

    public init(graceSeconds: TimeInterval = 120, hardAfterSeconds: TimeInterval = 300, hardAtPercent: Int? = 50,
                hardAtRuntimeSeconds: Int? = 600, ignoreReadingsSeconds: TimeInterval = 15, lineStableSeconds: TimeInterval = 30,
                quitApps: Bool = true, quitTimeoutSeconds: TimeInterval? = nil, neverQuit: Set<String> = [], afterSafe: AfterSafe = .keepRunning) {
        self.graceSeconds = graceSeconds
        self.hardAfterSeconds = hardAfterSeconds
        self.hardAtPercent = hardAtPercent
        self.hardAtRuntimeSeconds = hardAtRuntimeSeconds
        self.ignoreReadingsSeconds = ignoreReadingsSeconds
        self.lineStableSeconds = lineStableSeconds
        self.quitApps = quitApps
        self.quitTimeoutSeconds = quitTimeoutSeconds
        self.neverQuit = neverQuit.union(Policy.alwaysKept)
        self.afterSafe = afterSafe
    }

    public static let alwaysKept: Set<String> = ["com.apple.finder", "finder"]

    public func isNeverQuit(_ h: Holder) -> Bool {
        let keys = [h.bundleID, h.appName].compactMap { $0?.lowercased() }
        return keys.contains { neverQuit.contains($0) } || neverQuit.contains { k in keys.contains(k.lowercased()) }
    }

    /// Guard against a policy that can never fire or fires at once.
    public var normalized: Policy {
        var p = self
        p.graceSeconds = max(0, p.graceSeconds)
        p.hardAfterSeconds = max(p.graceSeconds, p.hardAfterSeconds)
        p.hardAtPercent = p.hardAtPercent.map { min(100, max(0, $0)) }
        p.hardAtRuntimeSeconds = p.hardAtRuntimeSeconds.map { max(0, $0) }
        p.ignoreReadingsSeconds = max(0, p.ignoreReadingsSeconds)
        p.lineStableSeconds = max(0, p.lineStableSeconds)
        p.quitTimeoutSeconds = p.quitTimeoutSeconds.map { max(0, $0) }
        return p
    }

    /// The policy in one line, as the log and `--print` write it.
    public var summary: String {
        var limits = ["\(Duration.text(hardAfterSeconds)) on battery"]
        if let pct = hardAtPercent { limits.append("\(pct) % charge") }
        if let rt = hardAtRuntimeSeconds { limits.append("\(Duration.text(TimeInterval(rt))) runtime") }
        let soft = quitApps
            ? "ask apps to quit" + (quitTimeoutSeconds.map { ", force after \(Duration.text($0))" } ?? "")
            : "never quit apps"
        return "grace \(Duration.text(graceSeconds)), \(soft), hard at \(limits.joined(separator: " or ")), "
            + "readings ignored for \(Duration.text(ignoreReadingsSeconds)), then \(afterSafe.title.lowercased())"
    }
}
