// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UpsGuardCore

/// The owner's choices, in UserDefaults under the bundle id (`defaults read
/// com.njoubert.nimbusupsbar`). The policy numbers default to the handoff's values.
@MainActor
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    var onChange: (() -> Void)?

    enum Key {
        static let grace = "graceSeconds"
        static let hardAfter = "hardAfterSeconds"
        static let hardAtPercent = "hardAtPercent"
        static let hardAtRuntime = "hardAtRuntimeSeconds"
        static let quitApps = "quitApps"
        static let neverQuit = "neverQuit"
        static let afterSafe = "afterSafe"
        static let volumeMode = "volumeMode"
        static let selectedVolumes = "selectedVolumeUUIDs"
        static let knownVolumes = "knownVolumes"
        static let notifications = "notificationsEnabled"
        static let showLoadInBar = "showLoadInBar"
    }

    enum VolumeMode: String {
        case allExternal, selected
    }

    // MARK: Policy

    var policy: Policy {
        get {
            let base = Policy()
            return Policy(
                graceSeconds: d.object(forKey: Key.grace) as? Double ?? base.graceSeconds,
                hardAfterSeconds: d.object(forKey: Key.hardAfter) as? Double ?? base.hardAfterSeconds,
                hardAtPercent: d.object(forKey: Key.hardAtPercent) as? Int ?? base.hardAtPercent,
                hardAtRuntimeSeconds: d.object(forKey: Key.hardAtRuntime) as? Int ?? base.hardAtRuntimeSeconds,
                quitApps: d.object(forKey: Key.quitApps) as? Bool ?? base.quitApps,
                neverQuit: Set(d.stringArray(forKey: Key.neverQuit) ?? []),
                afterSafe: Policy.AfterSafe(rawValue: d.string(forKey: Key.afterSafe) ?? "") ?? base.afterSafe
            ).normalized
        }
        set {
            let p = newValue.normalized
            d.set(p.graceSeconds, forKey: Key.grace)
            d.set(p.hardAfterSeconds, forKey: Key.hardAfter)
            d.set(p.hardAtPercent, forKey: Key.hardAtPercent)
            d.set(p.hardAtRuntimeSeconds, forKey: Key.hardAtRuntime)
            d.set(p.quitApps, forKey: Key.quitApps)
            d.set(Array(p.neverQuit.subtracting(Policy.alwaysKept)).sorted(), forKey: Key.neverQuit)
            d.set(p.afterSafe.rawValue, forKey: Key.afterSafe)
            onChange?()
        }
    }

    // MARK: Volumes

    var volumeMode: VolumeMode {
        get { VolumeMode(rawValue: d.string(forKey: Key.volumeMode) ?? "") ?? .allExternal }
        set { d.set(newValue.rawValue, forKey: Key.volumeMode); onChange?() }
    }

    var selectedVolumeUUIDs: Set<String> {
        get { Set(d.stringArray(forKey: Key.selectedVolumes) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Key.selectedVolumes); onChange?() }
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

    // MARK: Misc

    var notificationsEnabled: Bool {
        get { d.object(forKey: Key.notifications) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.notifications); onChange?() }
    }

    var showLoadInBar: Bool {
        get { d.bool(forKey: Key.showLoadInBar) }
        set { d.set(newValue, forKey: Key.showLoadInBar); onChange?() }
    }

    /// The choices the menu offers, in seconds. The current value is always offered even
    /// when it is not one of these (set from `defaults`).
    static let graceChoices: [TimeInterval] = [30, 60, 120, 300, 600]
    static let hardAfterChoices: [TimeInterval] = [180, 300, 600, 900, 1800, 3600]
    static let hardAtPercentChoices: [Int] = [25, 40, 50, 60, 75]
    static let hardAtRuntimeChoices: [Int] = [300, 600, 900, 1200, 1800]
}
