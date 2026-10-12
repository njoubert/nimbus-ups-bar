// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UpsGuardCore

/// Is the UPS actually going to do its job? A handful of checks over the current reading,
/// each a line in the menu with a dot: green for fine, a hollow grey for a note that needs no
/// action (recharging, self-test not run), yellow for look-into-it, red for a fault. Nothing
/// here is an alarm the UPS raised on its own except the flags it reports.
public enum Health {
    public enum Level: Int, Comparable {
        case good, info, warning, bad
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        /// Notes do not colour anything; only warnings and faults do.
        public var isConcern: Bool { self >= .warning }
    }

    public struct Item: Equatable {
        public let level: Level
        public let text: String
        public let detail: String?
        /// A few words for the "UPS Health: …" menu row and the headline, where the full text
        /// would widen the menu past the chart. Every warning and fault has one; it is cased
        /// as it should be read after the colon.
        public let short: String?
        public init(_ level: Level, _ text: String, _ detail: String? = nil, short: String? = nil) {
            self.level = level; self.text = text; self.detail = detail; self.short = short
        }
        public var label: String { short ?? text }
    }

    /// Whether the outage notifications can reach the owner.
    public enum NotificationAccess: Equatable, Sendable {
        /// Allowed, or not known yet (no false alarm while macOS answers).
        case allowed
        /// macOS has not asked the owner yet.
        case notDecided
        /// Turned off in this app's Settings › General.
        case offInSettings
        /// Turned off for this app in System Settings › Notifications: the banners never appear.
        case blockedByMacOS
        /// No bundle (the bare binary): there is no notification channel at all.
        case unavailable
    }

    /// How long the UPS has to read 0 % load before that is a warning. One reading of 0 % is
    /// common (the first read of 2026-10-10 said 0 % and 190 min; the next, 10 % and 72 min).
    public static let zeroLoadAfter: TimeInterval = 60

    public static func overall(_ items: [Item]) -> Level { items.map(\.level).max() ?? .good }

    /// The item that sets the overall level, for the menu row and the headline: the first
    /// warning or fault, or nil when everything is fine.
    public static func headline(_ items: [Item]) -> Item? {
        let top = overall(items)
        guard top.isConcern else { return nil }
        return items.first { $0.level == top }
    }

    /// `zeroLoadFor`: how long the load has read 0 % without a break (nil: it does not, or
    /// that is not known). `notifications`: whether the outage banners can reach the owner.
    /// `agentStartFailure`: Run in Background is on but launchd's last attempt to start the app
    /// failed, and why (`LaunchdJob.startFailure`); nil when it did not or the agent is off.
    public static func assess(reading r: UPSReading, hidAge: TimeInterval?, hidAttached: Bool, upsSeen: Bool,
                              internalBattery: PowerSources.InternalBattery?, protectedMounted: Int, staleAfter: TimeInterval = 60,
                              zeroLoadFor: TimeInterval? = nil, notifications: NotificationAccess = .allowed,
                              agentStartFailure: String? = nil) -> [Item] {
        var out = assessUPS(reading: r, hidAge: hidAge, hidAttached: hidAttached, upsSeen: upsSeen, internalBattery: internalBattery,
                            protectedMounted: protectedMounted, staleAfter: staleAfter, zeroLoadFor: zeroLoadFor)
        switch notifications {
        case .blockedByMacOS:
            out.append(Item(.warning, "Notifications are blocked by macOS",
                            "System Settings › Notifications › Nimbus UPS Bar has them off, so the outage banners (power out, closing apps, unmounting, power back) never appear. Allow them there, or open Settings › General here.",
                            short: "notifications blocked"))
        case .offInSettings:
            out.append(Item(.info, "Notifications are off in Settings", "Outage banners are not shown; the log still records everything."))
        case .notDecided:
            out.append(Item(.info, "Notifications not allowed yet", "macOS has not asked yet, or the question is still on screen."))
        case .allowed, .unavailable:
            break
        }
        if let why = agentStartFailure {
            out.append(Item(.warning, "Run in Background is not starting the app",
                            "Run in Background is on, but macOS's last attempt to start Nimbus UPS Bar failed (\(why)), so after a restart or a crash nothing guards the drives until the app is opened by hand. Turn Run in Background off and on again in this menu to register it afresh.",
                            short: "not starting at login"))
        }
        return out
    }

    private static func assessUPS(reading r: UPSReading, hidAge: TimeInterval?, hidAttached: Bool, upsSeen: Bool,
                                  internalBattery: PowerSources.InternalBattery?, protectedMounted: Int, staleAfter: TimeInterval,
                                  zeroLoadFor: TimeInterval?) -> [Item] {
        var out: [Item] = []
        guard r.present else {
            out.append(Item(.bad, upsSeen ? "UPS has disconnected" : "No UPS found",
                            "macOS lists no UPS among its power sources. Check the USB cable between the UPS and the Mac; `pmset -g ps` should show it.",
                            short: upsSeen ? "UPS disconnected" : "no UPS found"))
            if protectedMounted > 0 { out.append(Item(.warning, "\(protectedMounted) protected volume\(protectedMounted == 1 ? "" : "s") mounted with no UPS watching", short: "drives unwatched")) }
            return out
        }
        if r.onBattery {
            out.append(Item(.warning, "Running on battery", "Mains power is out. The guard is counting down.", short: "on battery"))
        }
        if r.flags.contains(.needsReplacement) {
            out.append(Item(.bad, "The UPS says its battery needs replacement", "The replace-battery flag is set. Runtime estimates cannot be trusted until the pack is swapped.", short: "battery needs replacing"))
        }
        if r.flags.contains(.overload) {
            out.append(Item(.bad, "Output overloaded", "Load above the UPS's rating; on battery it would shut off almost at once.", short: "overloaded"))
        }
        if r.flags.contains(.shutdownImminent) {
            out.append(Item(.bad, "The UPS reports shutdown imminent", short: "shutdown imminent"))
        }
        if let t = r.selfTest {
            switch t {
            case .error: out.append(Item(.bad, "Last battery self-test failed", "Run it again from this menu; a second failure means the battery is done.", short: "self-test failed"))
            case .warning: out.append(Item(.warning, "Last battery self-test ended with a warning", short: "self-test warning"))
            case .aborted: out.append(Item(.warning, "Last battery self-test was aborted", short: "self-test aborted"))
            case .inProgress: out.append(Item(.info, "Battery self-test in progress", "The UPS tests its battery for about eleven seconds; the outlets stay on line power."))
            case .passed: out.append(Item(.good, "Last battery self-test passed"))
            case .notRun: out.append(Item(.info, "Battery self-test not run yet", "Run a quick test from this menu to make the UPS prove its battery."))
            }
        }
        if let pct = r.chargePercent {
            if r.onBattery {
                out.append(Item(.info, "Charge gauge at \(pct) %",
                                "On this UPS the gauge follows the battery voltage. It drops 20–30 % in the first minute of any outage as the voltage sags under load, then flattens; the runtime estimate is the better guide. Measured 2026-10-10: 100 % to 78 % in one minute at 92 W, 72 % at two."))
            } else if !r.onBattery, let warn = r.warningChargeLimitPercent, pct < warn {
                out.append(Item(.warning, "Battery at \(pct) % on line power", "Below the UPS's own warning limit of \(warn) %. Either it is recharging after an outage or the pack is failing to hold charge.", short: "battery low (\(pct) %)"))
            } else if !r.onBattery, pct < 90 {
                out.append(Item(.info, "Battery at \(pct) %, recharging",
                                "The gauge follows the battery voltage, so it climbs back as the charger brings the voltage up; a full recharge after an outage takes hours."))
            } else {
                out.append(Item(.good, "Battery at \(pct) %" + (r.flags.contains(.fullyCharged) ? ", fully charged" : "")))
            }
        }
        if let v = r.batteryVoltage, let nominal = r.batteryNominalVoltage, nominal > 0 {
            let text = String(format: "Battery %.1f V on a %.0f V pack", v, nominal)
            if !r.onBattery, !r.flags.contains(.charging), v < nominal * 1.02 {
                out.append(Item(.warning, text, "A healthy lead-acid pack floats well above its nominal voltage on line power (about 27 V for 24 V). Sitting at or below nominal while not charging points at a worn pack.", short: "battery voltage low"))
            } else {
                out.append(Item(.good, text))
            }
        }
        if let w = r.loadWatts, let pct = r.loadPercent {
            if pct == 0, (zeroLoadFor ?? 0) >= zeroLoadAfter {
                out.append(Item(.warning, "No load on the battery outlets", "The UPS reports 0 % load. If the display, the drive enclosure and the Mac's charger are plugged into the surge-only outlets, the battery does not back them and an outage kills them at once. Move them to the battery-backed outlets.", short: "nothing on battery outlets"))
            } else if pct >= 80 {
                out.append(Item(.warning, "Load \(Int(w.rounded())) W (\(pct) %)", "Close to the rating; runtime on battery will be short.", short: "load high (\(pct) %)"))
            } else {
                out.append(Item(.good, "Load \(Int(w.rounded())) W (\(pct) % of \(Int(r.ratedWatts ?? 0)) W)"))
            }
        }
        if let rt = r.runtimeSeconds, !r.onBattery {
            if let lim = r.lowRuntimeLimitSeconds, rt <= lim * 2 {
                out.append(Item(.warning, "Runtime estimate only \(Duration.text(TimeInterval(rt)))", "Within reach of the UPS's own low-battery limit of \(Duration.text(TimeInterval(lim))); lower the load or replace the battery.", short: "runtime short (\(Duration.text(TimeInterval(rt))))"))
            } else {
                out.append(Item(.good, "Runtime estimate \(Duration.text(TimeInterval(rt))) at this load"))
            }
        }
        if let v = r.inputVoltage, v > 0, let lo = r.lowTransferVoltage, let hi = r.highTransferVoltage, lo > 0, hi > lo {
            if v < lo || v > hi {
                out.append(Item(.warning, String(format: "Line %.0f V outside the %.0f–%.0f V window", v, lo, hi), "The UPS transfers to battery outside this window.", short: String(format: "line voltage off (%.0f V)", v)))
            } else if v < lo + 4 || v > hi - 4 {
                out.append(Item(.warning, String(format: "Line %.0f V near the edge of the %.0f–%.0f V window", v, lo, hi), short: String(format: "line voltage marginal (%.0f V)", v)))
            } else {
                out.append(Item(.good, String(format: "Line %.0f V, within the %.0f–%.0f V window", v, lo, hi)))
            }
        } else if let v = r.inputVoltage, v > 0 {
            out.append(Item(.good, String(format: "Line %.0f V", v)))
        }
        if r.flags.contains(.boost) { out.append(Item(.warning, "Boosting a low line voltage", "The UPS is correcting the mains without going to battery; frequent boosting wears the relay and hints at a weak supply.", short: "boosting low mains")) }
        if r.flags.contains(.buck) { out.append(Item(.warning, "Trimming a high line voltage", short: "trimming high mains")) }
        if hidAttached {
            if let age = hidAge {
                if age > staleAfter { out.append(Item(.warning, "UPS not answering over USB for \(Duration.text(age))", "macOS still lists it, but direct reads are failing. A cable or hub problem.", short: "USB reads failing")) }
            } else {
                out.append(Item(.info, "UPS details not read yet"))
            }
        } else {
            out.append(Item(.warning, "UPS is listed by macOS but not reachable over USB HID", "Load, voltages and limits are unavailable; state, charge and runtime still come from macOS.", short: "USB details unavailable"))
        }
        if let b = internalBattery {
            out.append(Item(b.percent < 20 ? .warning : .good, "Mac's own battery at \(b.percent) %" + (b.isCharging ? ", charging" : ""),
                            "What the Mac itself runs on once the UPS is exhausted. The drives do not.", short: "Mac battery low (\(b.percent) %)"))
        }
        return out
    }
}
