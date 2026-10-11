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

    enum Key {
        static let grace = "graceSeconds"
        static let hardAfter = "hardAfterSeconds"
        static let hardAtPercent = "hardAtPercent"
        static let hardAtPercentOn = "hardAtPercentEnabled"
        static let hardAtRuntime = "hardAtRuntimeSeconds"
        static let hardAtRuntimeOn = "hardAtRuntimeEnabled"
        static let ignoreReadings = "ignoreReadingsSeconds"
        static let lineStable = "lineStableSeconds"
        static let quitApps = "quitApps"
        static let quitTimeout = "quitTimeoutSeconds"
        static let quitTimeoutOn = "quitTimeoutEnabled"
        static let neverQuit = "neverQuit"
        static let afterSafe = "afterSafe"
        static let volumeMode = "volumeMode"
        static let selectedVolumes = "selectedVolumeUUIDs"
        static let knownVolumes = "knownVolumes"
        static let notifications = "notificationsEnabled"
        static let showLoadInBar = "showLoadInBar"
        static let lineRead = "lineReadSeconds"
        static let busyRead = "busyReadSeconds"
        static let history = "chartHistorySeconds"
        static let postpone = "postponeSeconds"
        static let policyKeys = [grace, hardAfter, hardAtPercent, hardAtPercentOn, hardAtRuntime, hardAtRuntimeOn,
                                 ignoreReadings, lineStable, quitApps, quitTimeout, quitTimeoutOn, neverQuit, afterSafe]
        static let readingKeys = [lineRead, busyRead, history, showLoadInBar]
    }

    enum VolumeMode: String {
        case allExternal, selected
    }

    private func changed() {
        onChange?()
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }

    // MARK: Policy

    /// The three optional numbers are stored as a value plus an on/off flag, so turning a limit
    /// off and on again brings the number back.
    var policy: Policy {
        get {
            let base = Policy()
            return Policy(
                graceSeconds: d.object(forKey: Key.grace) as? Double ?? base.graceSeconds,
                hardAfterSeconds: d.object(forKey: Key.hardAfter) as? Double ?? base.hardAfterSeconds,
                hardAtPercent: (d.object(forKey: Key.hardAtPercentOn) as? Bool ?? true) ? hardAtPercentValue : nil,
                hardAtRuntimeSeconds: (d.object(forKey: Key.hardAtRuntimeOn) as? Bool ?? true) ? hardAtRuntimeValue : nil,
                ignoreReadingsSeconds: d.object(forKey: Key.ignoreReadings) as? Double ?? base.ignoreReadingsSeconds,
                lineStableSeconds: d.object(forKey: Key.lineStable) as? Double ?? base.lineStableSeconds,
                quitApps: d.object(forKey: Key.quitApps) as? Bool ?? base.quitApps,
                quitTimeoutSeconds: d.bool(forKey: Key.quitTimeoutOn) ? quitTimeoutValue : nil,
                neverQuit: Set(d.stringArray(forKey: Key.neverQuit) ?? []),
                afterSafe: Policy.AfterSafe(rawValue: d.string(forKey: Key.afterSafe) ?? "") ?? base.afterSafe
            ).normalized
        }
        set {
            let p = newValue.normalized
            d.set(p.graceSeconds, forKey: Key.grace)
            d.set(p.hardAfterSeconds, forKey: Key.hardAfter)
            d.set(p.hardAtPercent != nil, forKey: Key.hardAtPercentOn)
            if let v = p.hardAtPercent { d.set(v, forKey: Key.hardAtPercent) }
            d.set(p.hardAtRuntimeSeconds != nil, forKey: Key.hardAtRuntimeOn)
            if let v = p.hardAtRuntimeSeconds { d.set(v, forKey: Key.hardAtRuntime) }
            d.set(p.ignoreReadingsSeconds, forKey: Key.ignoreReadings)
            d.set(p.lineStableSeconds, forKey: Key.lineStable)
            d.set(p.quitApps, forKey: Key.quitApps)
            d.set(p.quitTimeoutSeconds != nil, forKey: Key.quitTimeoutOn)
            if let v = p.quitTimeoutSeconds { d.set(v, forKey: Key.quitTimeout) }
            d.set(Array(p.neverQuit.subtracting(Policy.alwaysKept)).sorted(), forKey: Key.neverQuit)
            d.set(p.afterSafe.rawValue, forKey: Key.afterSafe)
            changed()
        }
    }

    /// The numbers behind the three switches, whether or not the switch is on (for the fields).
    var hardAtPercentValue: Int { d.object(forKey: Key.hardAtPercent) as? Int ?? Policy().hardAtPercent ?? 50 }
    var hardAtRuntimeValue: Int { d.object(forKey: Key.hardAtRuntime) as? Int ?? Policy().hardAtRuntimeSeconds ?? 600 }
    var quitTimeoutValue: TimeInterval { d.object(forKey: Key.quitTimeout) as? Double ?? 60 }

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
