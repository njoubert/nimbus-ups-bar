// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpsBarKit
import UpsGuardCore

/// The owner's choices, in UserDefaults under the bundle id (`defaults read
/// com.njoubert.nimbusupsbar`). The policy numbers default to the handoff's values. Every
/// setter normalizes, calls `onChange` (the monitor) and posts `didChange` (the settings
/// window, the status bar), so a change made anywhere shows everywhere.
@MainActor
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("com.njoubert.nimbusupsbar.settingsChanged")
    private let d = UserDefaults.standard
    var onChange: (() -> Void)?

    private init() { migrateLegacyPolicy() }

    enum Key {
        static let ignoreReadings = "ignoreReadingsSeconds"
        static let lineStable = "lineStableSeconds"
        static let quitApps = "quitApps"
        static let quitTimeout = "quitTimeoutSeconds"
        static let quitTimeoutOn = "quitTimeoutEnabled"
        static let neverQuit = "neverQuit"
        static let powerDownWhenSafe = "powerDownWhenSafe"
        static let powerDownAction = "powerDownAction"
        static let upsGone = "upsGoneSeconds"
        static let upsGoneInOutage = "upsGoneInOutage"
        static let upsGoneInOutagePowersDown = "upsGoneInOutagePowersDown"
        static let upsGoneOnLine = "upsGoneOnLine"
        static let volumeMode = "volumeMode"
        static let selectedVolumes = "selectedVolumeUUIDs"
        static let knownVolumes = "knownVolumes"
        static let notifications = "notificationsEnabled"
        static let showLoadInBar = "showLoadInBar"
        static let lineRead = "lineReadSeconds"
        static let busyRead = "busyReadSeconds"
        static let history = "chartHistorySeconds"
        static let postpone = "postponeSeconds"
        static let policyKeys = [ignoreReadings, lineStable, quitApps, quitTimeout, quitTimeoutOn, neverQuit,
                                 powerDownWhenSafe, powerDownAction, upsGone, upsGoneInOutage, upsGoneInOutagePowersDown, upsGoneOnLine, postpone]
            + Stage.allCases.flatMap { st in Condition.allCases.flatMap { c in [st.key(c), st.key(c) + "On"] } }
        static let readingKeys = [lineRead, busyRead, history, showLoadInBar, ignoreReadings, lineStable]
    }

    /// The three stages of the policy, each a `Trigger` stored as three value + on/off pairs
    /// ("hardRuntime" = 600, "hardRuntimeOn" = true), so turning a condition off and on again
    /// brings its number back.
    enum Stage: String, CaseIterable {
        case soft, hard, powerDown

        func key(_ c: Condition) -> String { rawValue + c.rawValue }

        func trigger(of p: Policy) -> Trigger {
            switch self { case .soft: return p.softAt; case .hard: return p.hardAt; case .powerDown: return p.powerDownAt }
        }
        func set(_ t: Trigger, in p: inout Policy) {
            switch self { case .soft: p.softAt = t; case .hard: p.hardAt = t; case .powerDown: p.powerDownAt = t }
        }
        /// The number a field shows while its condition is off and nothing was ever stored.
        func fallback(_ c: Condition) -> Double {
            if let v = Condition.value(c, of: trigger(of: Policy())) { return v }
            switch (self, c) {
            case (.soft, .time): return 120
            case (.hard, .time): return 300
            case (.powerDown, .time): return 1200
            case (.powerDown, .runtime): return 300
            case (.powerDown, .charge): return 20
            case (_, .runtime): return 600
            case (_, .charge): return 50
            }
        }
    }

    enum Condition: String, CaseIterable {
        case time = "Time", runtime = "Runtime", charge = "Charge"

        static func value(_ c: Condition, of t: Trigger) -> Double? {
            switch c {
            case .time: return t.onBatteryFor
            case .runtime: return t.runtimeAtMost.map(Double.init)
            case .charge: return t.chargeAtMost.map(Double.init)
            }
        }
        static func set(_ c: Condition, _ v: Double?, in t: inout Trigger) {
            switch c {
            case .time: t.onBatteryFor = v
            case .runtime: t.runtimeAtMost = v.map { Int($0.rounded()) }
            case .charge: t.chargeAtMost = v.map { Int($0.rounded()) }
            }
        }
    }

    enum VolumeMode: String {
        case allExternal, selected
    }

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }

    // MARK: Policy

    var policy: Policy {
        get {
            let base = Policy()
            var p = Policy(
                ignoreReadingsSeconds: d.object(forKey: Key.ignoreReadings) as? Double ?? base.ignoreReadingsSeconds,
                lineStableSeconds: d.object(forKey: Key.lineStable) as? Double ?? base.lineStableSeconds,
                quitApps: d.object(forKey: Key.quitApps) as? Bool ?? base.quitApps,
                quitTimeoutSeconds: d.bool(forKey: Key.quitTimeoutOn) ? quitTimeoutValue : nil,
                neverQuit: Set(d.stringArray(forKey: Key.neverQuit) ?? []),
                upsGoneSeconds: d.object(forKey: Key.upsGone) as? Double ?? base.upsGoneSeconds,
                upsGoneInOutage: Policy.UPSGoneInOutage(rawValue: d.string(forKey: Key.upsGoneInOutage) ?? "") ?? base.upsGoneInOutage,
                upsGoneInOutagePowersDown: d.object(forKey: Key.upsGoneInOutagePowersDown) as? Bool ?? base.upsGoneInOutagePowersDown,
                upsGoneOnLine: Policy.UPSGoneOnLine(rawValue: d.string(forKey: Key.upsGoneOnLine) ?? "") ?? base.upsGoneOnLine)
            p.powerDownWhenSafe = d.object(forKey: Key.powerDownWhenSafe) as? Bool ?? base.powerDownWhenSafe
            p.powerDownAction = Policy.MacAction(rawValue: d.string(forKey: Key.powerDownAction) ?? "") ?? base.powerDownAction
            for st in Stage.allCases {
                var t = Trigger()
                for c in Condition.allCases {
                    let on = d.object(forKey: st.key(c) + "On") as? Bool ?? (Condition.value(c, of: st.trigger(of: base)) != nil)
                    Condition.set(c, on ? value(st, c) : nil, in: &t)
                }
                st.set(t, in: &p)
            }
            return p.normalized
        }
        set {
            let p = newValue.normalized
            for st in Stage.allCases {
                for c in Condition.allCases {
                    let v = Condition.value(c, of: st.trigger(of: p))
                    d.set(v != nil, forKey: st.key(c) + "On")
                    if let v { d.set(v, forKey: st.key(c)) }
                }
            }
            d.set(p.powerDownWhenSafe, forKey: Key.powerDownWhenSafe)
            d.set(p.powerDownAction.rawValue, forKey: Key.powerDownAction)
            d.set(p.ignoreReadingsSeconds, forKey: Key.ignoreReadings)
            d.set(p.lineStableSeconds, forKey: Key.lineStable)
            d.set(p.quitApps, forKey: Key.quitApps)
            d.set(p.quitTimeoutSeconds != nil, forKey: Key.quitTimeoutOn)
            if let v = p.quitTimeoutSeconds { d.set(v, forKey: Key.quitTimeout) }
            d.set(Array(p.neverQuit.subtracting(Policy.alwaysKept)).sorted(), forKey: Key.neverQuit)
            d.set(p.upsGoneSeconds, forKey: Key.upsGone)
            d.set(p.upsGoneInOutage.rawValue, forKey: Key.upsGoneInOutage)
            d.set(p.upsGoneInOutagePowersDown, forKey: Key.upsGoneInOutagePowersDown)
            d.set(p.upsGoneOnLine.rawValue, forKey: Key.upsGoneOnLine)
            changed()
        }
    }

    /// The number behind a stage's condition, whether or not the condition is on (for the fields).
    func value(_ st: Stage, _ c: Condition) -> Double { d.object(forKey: st.key(c)) as? Double ?? st.fallback(c) }
    var quitTimeoutValue: TimeInterval { d.object(forKey: Key.quitTimeout) as? Double ?? 60 }

    /// Before 2026-10-11 the policy was a grace period, a hard limit (time, plus optional charge
    /// and runtime) and an after-safe action. Copy those values into the stages once (while no
    /// stage key exists yet), so an existing setup keeps its numbers. The old keys stay, so an
    /// older build run afterwards still finds its own.
    func migrateLegacyPolicy() {
        let old = ["graceSeconds", "hardAfterSeconds", "hardAtPercent", "hardAtPercentEnabled",
                   "hardAtRuntimeSeconds", "hardAtRuntimeEnabled", "afterSafe"]
        guard old.contains(where: { d.object(forKey: $0) != nil }),
              d.object(forKey: Stage.soft.key(.time) + "On") == nil else { return }
        func move(_ from: String, to key: String) {
            if let v = d.object(forKey: from) as? Double { d.set(v, forKey: key) }
        }
        move("graceSeconds", to: Stage.soft.key(.time))
        move("hardAfterSeconds", to: Stage.hard.key(.time))
        move("hardAtPercent", to: Stage.hard.key(.charge))
        move("hardAtRuntimeSeconds", to: Stage.hard.key(.runtime))
        if let on = d.object(forKey: "hardAtPercentEnabled") as? Bool { d.set(on, forKey: Stage.hard.key(.charge) + "On") }
        if let on = d.object(forKey: "hardAtRuntimeEnabled") as? Bool { d.set(on, forKey: Stage.hard.key(.runtime) + "On") }
        d.set(true, forKey: Stage.soft.key(.time) + "On")
        if let raw = d.string(forKey: "afterSafe"), let a = Policy.MacAction(rawValue: raw) {
            d.set(a.rawValue, forKey: Key.powerDownAction)
            d.set(true, forKey: Key.powerDownWhenSafe)
        }
    }

    func resetPolicy() {
        for k in Key.policyKeys { d.removeObject(forKey: k) }
        changed()
    }

    // MARK: Volumes

    var volumeMode: VolumeMode {
        get { VolumeMode(rawValue: d.string(forKey: Key.volumeMode) ?? "") ?? .allExternal }
        set { d.set(newValue.rawValue, forKey: Key.volumeMode); changed() }
    }

    var selectedVolumeUUIDs: Set<String> {
        get { Set(d.stringArray(forKey: Key.selectedVolumes) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Key.selectedVolumes); changed() }
    }

    /// Volumes seen mounted at some point, so the checklist can show a drive that is not
    /// plugged in right now.
    var knownVolumes: [VolumeState] {
        get {
            (d.array(forKey: Key.knownVolumes) as? [[String: String]] ?? []).compactMap { e in
                guard let uuid = e["uuid"], let name = e["name"] else { return nil }
                return VolumeState(uuid: uuid, name: name, isAttached: false, detail: e["detail"] ?? "")
            }
        }
    }

    func remember(_ v: VolumeState) {
        var list = (d.array(forKey: Key.knownVolumes) as? [[String: String]] ?? []).filter { $0["uuid"] != v.uuid }
        list.append(["uuid": v.uuid, "name": v.name, "detail": v.detail])
        d.set(list, forKey: Key.knownVolumes)
    }

    func forget(_ uuid: String) {
        let list = (d.array(forKey: Key.knownVolumes) as? [[String: String]] ?? []).filter { $0["uuid"] != uuid }
        d.set(list, forKey: Key.knownVolumes)
        selectedVolumeUUIDs.remove(uuid)
    }

    /// Does the policy cover this volume?
    func isProtected(_ v: VolumeState) -> Bool {
        switch volumeMode {
        case .allExternal: return true
        case .selected: return selectedVolumeUUIDs.contains(v.uuid)
        }
    }

    // MARK: Readings

    /// How often the UPS is read over USB on line power.
    var lineReadInterval: TimeInterval {
        get { Settings.clamp(d.object(forKey: Key.lineRead) as? Double ?? 10, 2...600) }
        set { d.set(Settings.clamp(newValue, 2...600), forKey: Key.lineRead); changed() }
    }

    /// …and on battery, during a simulation, and while the menu is open. Also the timer the
    /// guard ticks on, so never slower than the line-power interval.
    var busyReadInterval: TimeInterval {
        get { Settings.clamp(d.object(forKey: Key.busyRead) as? Double ?? 2, 1...min(60, lineReadInterval)) }
        set { d.set(Settings.clamp(newValue, 1...60), forKey: Key.busyRead); changed() }
    }

    /// How much history the chart shows and the monitor keeps.
    var historyWindow: TimeInterval {
        get { Settings.clamp(d.object(forKey: Key.history) as? Double ?? 3600, 600...86400) }
        set { d.set(Settings.clamp(newValue, 600...86400), forKey: Key.history); changed() }
    }
    static let historyChoices: [TimeInterval] = [30 * 60, 3600, 2 * 3600, 4 * 3600, 6 * 3600, 12 * 3600, 24 * 3600]

    /// A HID report older than this no longer overrides the macOS figures.
    var hidFreshFor: TimeInterval { max(15, lineReadInterval * 1.5) }
    /// …and older than this is a health warning.
    var hidStaleAfter: TimeInterval { max(60, lineReadInterval * 3) }

    func resetReadings() {
        for k in Key.readingKeys { d.removeObject(forKey: k) }
        changed()
    }

    // MARK: Misc

    var notificationsEnabled: Bool {
        get { d.object(forKey: Key.notifications) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.notifications); changed() }
    }

    var showLoadInBar: Bool {
        get { d.bool(forKey: Key.showLoadInBar) }
        set { d.set(newValue, forKey: Key.showLoadInBar); changed() }
    }

    /// What the outage menu's Postpone adds to the soft stage and the time limit.
    var postponeSeconds: TimeInterval {
        get { Settings.clamp(d.object(forKey: Key.postpone) as? Double ?? 300, 60...3600) }
        set { d.set(Settings.clamp(newValue, 60...3600), forKey: Key.postpone); changed() }
    }

    private static func clamp(_ v: TimeInterval, _ r: ClosedRange<TimeInterval>) -> TimeInterval {
        v.isFinite ? min(r.upperBound, max(r.lowerBound, v)) : r.lowerBound
    }
}
