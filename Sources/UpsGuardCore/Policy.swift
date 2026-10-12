// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// When a stage begins: on battery this long, or the UPS's runtime estimate this short, or
/// its charge this low, whichever comes first. Each condition is optional; a trigger with
/// none is `never`. Every stage of the policy is one of these, so the same three choices are
/// available for asking the apps, forcing the unmount, and putting the Mac down.
public struct Trigger: Equatable, Sendable {
    /// On battery at least this long (postponing from the menu moves it out).
    public var onBatteryFor: TimeInterval?
    /// The runtime estimate at or below this many seconds.
    public var runtimeAtMost: Int?
    /// The charge at or below this percent. This UPS's gauge follows the battery voltage and
    /// sags 20–30 points in the first minute under load; the runtime is the better guide.
    public var chargeAtMost: Int?

    public init(onBatteryFor: TimeInterval? = nil, runtimeAtMost: Int? = nil, chargeAtMost: Int? = nil) {
        self.onBatteryFor = onBatteryFor
        self.runtimeAtMost = runtimeAtMost
        self.chargeAtMost = chargeAtMost
    }

    public static let never = Trigger()
    public var isNever: Bool { onBatteryFor == nil && runtimeAtMost == nil && chargeAtMost == nil }

    /// Why the trigger has fired, one phrase per condition met; empty while it has not.
    /// `usable` is false while readings are still ignored after the transfer: only time counts.
    /// `countTime` is false while line power is back but not yet trusted: the time condition
    /// waits (it fires at once if the power fails again), the charge and runtime still count.
    public func reasons(elapsed: TimeInterval, postponed: TimeInterval, reading: UPSReading, usable: Bool, countTime: Bool = true) -> [String] {
        var r: [String] = []
        if countTime, let t = onBatteryFor, elapsed >= t + postponed { r.append("\(Duration.text(elapsed)) on battery") }
        if usable, let limit = chargeAtMost, let pct = reading.chargePercent, pct <= limit { r.append("charge at \(pct) %") }
        if usable, let limit = runtimeAtMost, let rt = reading.runtimeSeconds, rt <= limit { r.append("runtime down to \(Duration.text(TimeInterval(rt)))") }
        return r
    }

    /// True when nothing in this trigger can fire on what `reading` reports: no time condition,
    /// and no figure for any condition it has (a runtime limit with no runtime, a charge limit
    /// with no charge). A trigger that is `never` is not "unjudgeable"; it is off.
    public func cannotJudge(_ reading: UPSReading) -> Bool {
        guard onBatteryFor == nil, !isNever else { return false }
        return (runtimeAtMost == nil || reading.runtimeSeconds == nil) && (chargeAtMost == nil || reading.chargePercent == nil)
    }

    /// Seconds until the time condition is met; nil without one.
    public func untilTime(elapsed: TimeInterval, postponed: TimeInterval) -> TimeInterval? {
        onBatteryFor.map { max(0, $0 + postponed - elapsed) }
    }

    /// "5 min on battery or 10 min runtime or 50 % charge", or "never".
    public var summary: String {
        var parts: [String] = []
        if let t = onBatteryFor { parts.append("\(Duration.text(t)) on battery") }
        if let r = runtimeAtMost { parts.append("\(Duration.text(TimeInterval(r))) runtime") }
        if let c = chargeAtMost { parts.append("\(c) % charge") }
        return parts.isEmpty ? "never" : parts.joined(separator: " or ")
    }

    var normalized: Trigger {
        Trigger(onBatteryFor: onBatteryFor.map { max(0, $0) },
                runtimeAtMost: runtimeAtMost.map { max(0, $0) },
                chargeAtMost: chargeAtMost.map { min(100, max(0, $0)) })
    }
}

/// What the owner approved: when apps are asked to quit, when the volumes come off regardless,
/// when (if ever) the Mac is put to sleep or shut down, and what a vanished UPS means. Every
/// number here is a judgement the owner can change in Settings.
public struct Policy: Equatable, Sendable {
    /// The soft stage: apps holding files are asked to quit, and a volume unmounts as soon as
    /// none holds it. Before it, nothing is touched beyond a notification: a flicker must not
    /// disturb anything. `never` skips the stage; the volumes wait for the force.
    public var softAt: Trigger
    /// The hard stage: every protected volume is force-unmounted, apps or not. Never `never`:
    /// normalizing gives it the default time limit back.
    public var hardAt: Trigger
    /// The Mac is put to sleep or shut down (`powerDownAction`) when this fires, the volumes
    /// being force-unmounted first. `never`, with `powerDownWhenSafe` off, keeps the Mac running.
    public var powerDownAt: Trigger
    /// …or as soon as every volume is safe, once an unmount stage was due (so a blip with
    /// nothing mounted cannot sleep the Mac).
    public var powerDownWhenSafe: Bool
    public var powerDownAction: MacAction
    /// Charge and runtime are ignored this long after the transfer: some UPSes report 0 % or
    /// a nonsense runtime for the first seconds on battery.
    public var ignoreReadingsSeconds: TimeInterval
    /// Line power has to stay back this long before the outage is over. Under a brownout the
    /// UPS transfers every few seconds; without this every flap would reset the clock, the
    /// limits and the ask, and the battery would drain with nothing protected.
    public var lineStableSeconds: TimeInterval
    /// Send the apps holding files a quit event at the soft stage (the same thing as choosing
    /// Quit from their menu; an app with unsaved work shows its own dialog). Off means apps
    /// are never asked and the volumes wait for the hard stage.
    public var quitApps: Bool
    /// An app asked to quit that still holds its volume this long later has the volume
    /// force-unmounted anyway, before the hard stage. Nil: a stubborn app keeps its volume
    /// mounted until the hard stage (the verified behaviour; the default).
    public var quitTimeoutSeconds: TimeInterval?
    /// Apps never sent a quit and never waited for, by bundle id or name. Finder is always in it.
    public var neverQuit: Set<String>
    /// How long the UPS has to be missing before it counts as gone. Shorter is a USB
    /// re-enumeration, not a lost UPS.
    public var upsGoneSeconds: TimeInterval
    /// The UPS gone mid-outage: almost always the battery run flat (the USB goes with it).
    public var upsGoneInOutage: UPSGoneInOutage
    /// …and put the Mac down too (`powerDownAction`), once the volumes are off.
    public var upsGoneInOutagePowersDown: Bool
    /// The UPS gone while on line power: a pulled cable or a UPS switched off. An outage now
    /// would go unseen.
    public var upsGoneOnLine: UPSGoneOnLine

    public enum MacAction: String, CaseIterable, Equatable, Sendable {
        case sleep, shutDown

        public var title: String {
            switch self {
            case .sleep: return "Put the Mac to sleep"
            case .shutDown: return "Shut the Mac down"
            }
        }
        /// "sleep", "shut down": for "about to …" sentences.
        public var verb: String { self == .sleep ? "sleep" : "shut down" }
    }

    public enum UPSGoneInOutage: String, CaseIterable, Equatable, Sendable {
        case forceUnmount, keepCounting

        public var title: String {
            switch self {
            case .forceUnmount: return "Unmount everything at once"
            case .keepCounting: return "Carry on as if still on battery"
            }
        }
    }

    public enum UPSGoneOnLine: String, CaseIterable, Equatable, Sendable {
        case nothing, notify, unmount

        public var title: String {
            switch self {
            case .nothing: return "Nothing"
            case .notify: return "Notify me"
            case .unmount: return "Notify and unmount everything"
            }
        }
    }

    public static let defaultHardAt = Trigger(onBatteryFor: 300, runtimeAtMost: 600, chargeAtMost: 50)
    /// A forced unmount without a time condition waits for the UPS's runtime or charge. When
    /// the UPS reports neither (both readers failing, or the UPS gone under `keepCounting`),
    /// this much time on battery stands in, so the stage cannot wait forever. The same five
    /// minutes `normalized` gives back to a forced unmount with no condition at all.
    public static let hardStandIn: TimeInterval = 300

    public init(softAt: Trigger = Trigger(onBatteryFor: 120), hardAt: Trigger = Policy.defaultHardAt,
                powerDownAt: Trigger = .never, powerDownWhenSafe: Bool = false, powerDownAction: MacAction = .sleep,
                ignoreReadingsSeconds: TimeInterval = 15, lineStableSeconds: TimeInterval = 30,
                quitApps: Bool = true, quitTimeoutSeconds: TimeInterval? = nil, neverQuit: Set<String> = [],
                upsGoneSeconds: TimeInterval = 10, upsGoneInOutage: UPSGoneInOutage = .forceUnmount,
                upsGoneInOutagePowersDown: Bool = false, upsGoneOnLine: UPSGoneOnLine = .notify) {
        self.softAt = softAt
        self.hardAt = hardAt
        self.powerDownAt = powerDownAt
        self.powerDownWhenSafe = powerDownWhenSafe
        self.powerDownAction = powerDownAction
        self.ignoreReadingsSeconds = ignoreReadingsSeconds
        self.lineStableSeconds = lineStableSeconds
        self.quitApps = quitApps
        self.quitTimeoutSeconds = quitTimeoutSeconds
        self.neverQuit = neverQuit.union(Policy.alwaysKept)
        self.upsGoneSeconds = upsGoneSeconds
        self.upsGoneInOutage = upsGoneInOutage
        self.upsGoneInOutagePowersDown = upsGoneInOutagePowersDown
        self.upsGoneOnLine = upsGoneOnLine
    }

    public static let alwaysKept: Set<String> = ["com.apple.finder", "finder"]

    public func isNeverQuit(_ h: Holder) -> Bool {
        let keys = [h.bundleID, h.appName].compactMap { $0?.lowercased() }
        return keys.contains { neverQuit.contains($0) } || neverQuit.contains { k in keys.contains(k.lowercased()) }
    }

    /// True when anything in the policy can sleep or shut the Mac down.
    public var powersDown: Bool { !powerDownAt.isNever || powerDownWhenSafe || upsGoneInOutagePowersDown }

    /// Guard against a policy that can never fire or fires at once.
    public var normalized: Policy {
        var p = self
        p.softAt = p.softAt.normalized
        p.hardAt = p.hardAt.isNever ? Trigger(onBatteryFor: Policy.defaultHardAt.onBatteryFor) : p.hardAt.normalized
        p.powerDownAt = p.powerDownAt.normalized
        p.ignoreReadingsSeconds = max(0, p.ignoreReadingsSeconds)
        p.lineStableSeconds = max(0, p.lineStableSeconds)
        p.quitTimeoutSeconds = p.quitTimeoutSeconds.map { max(0, $0) }
        p.upsGoneSeconds = max(1, p.upsGoneSeconds)
        return p
    }

    /// The policy in one line, as the log and `--print` write it.
    public var summary: String {
        let soft = softAt.isNever ? "no soft stage"
            : "at \(softAt.summary) " + (quitApps ? "ask apps to quit" + (quitTimeoutSeconds.map { ", force after \(Duration.text($0))" } ?? "") : "unmount what is free")
        var down: [String] = []
        if !powerDownAt.isNever { down.append("at \(powerDownAt.summary)") }
        if powerDownWhenSafe { down.append("once safe") }
        if upsGoneInOutagePowersDown { down.append("if the UPS goes") }
        let power = down.isEmpty ? "keep running" : "\(powerDownAction.verb) \(down.joined(separator: " or "))"
        return "\(soft); force at \(hardAt.summary); \(power); readings ignored for \(Duration.text(ignoreReadingsSeconds)); "
            + "UPS gone \(Duration.text(upsGoneSeconds)): \(upsGoneInOutage == .forceUnmount ? "force" : "carry on") in an outage, \(upsGoneOnLine.rawValue) on line"
    }
}
