// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UpsGuardCore

/// Is the UPS actually going to do its job? A handful of checks over the current reading,
/// each a line in the menu with a dot: green for fine, a hollow grey for a note that needs no
/// action (recharging, self-test not run), yellow for look-into-it, red for a fault. Nothing
/// here is an alarm the UPS raised on its own except the flags it reports.
enum Health {
    enum Level: Int, Comparable {
        case good, info, warning, bad
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        /// Notes do not colour anything; only warnings and faults do.
        var isConcern: Bool { self >= .warning }
    }

    struct Item: Equatable {
        let level: Level
        let text: String
        let detail: String?
        init(_ level: Level, _ text: String, _ detail: String? = nil) { self.level = level; self.text = text; self.detail = detail }
    }

    static func overall(_ items: [Item]) -> Level { items.map(\.level).max() ?? .good }

    /// The item that sets the overall level, for the menu row and the headline: the first
    /// warning or fault, or nil when everything is fine.
    static func headline(_ items: [Item]) -> Item? {
        let top = overall(items)
        guard top.isConcern else { return nil }
        return items.first { $0.level == top }
    }

    static func assess(reading r: UPSReading, hidAge: TimeInterval?, hidAttached: Bool, upsSeen: Bool,
                       internalBattery: PowerSources.InternalBattery?, protectedMounted: Int) -> [Item] {
        var out: [Item] = []
        guard r.present else {
            out.append(Item(.bad, upsSeen ? "UPS has disconnected" : "No UPS found",
                            "macOS lists no UPS among its power sources. Check the USB cable between the UPS and the Mac; `pmset -g ps` should show it."))
            if protectedMounted > 0 { out.append(Item(.warning, "\(protectedMounted) protected volume\(protectedMounted == 1 ? "" : "s") mounted with no UPS watching")) }
            return out
        }
        if r.onBattery {
            out.append(Item(.warning, "Running on battery", "Mains power is out. The guard is counting down."))
        }
        if r.flags.contains(.needsReplacement) {
            out.append(Item(.bad, "The UPS says its battery needs replacement", "The replace-battery flag is set. Runtime estimates cannot be trusted until the pack is swapped."))
        }
        if r.flags.contains(.overload) {
            out.append(Item(.bad, "Output overloaded", "Load above the UPS's rating; on battery it would shut off almost at once."))
        }
        if r.flags.contains(.shutdownImminent) {
            out.append(Item(.bad, "The UPS reports shutdown imminent"))
        }
        if let t = r.selfTest {
            switch t {
            case .error: out.append(Item(.bad, "Last battery self-test failed", "Run it again from this menu; a second failure means the battery is done."))
            case .warning: out.append(Item(.warning, "Last battery self-test ended with a warning"))
            case .aborted: out.append(Item(.warning, "Last battery self-test was aborted"))
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
                out.append(Item(.warning, "Battery at \(pct) % on line power", "Below the UPS's own warning limit of \(warn) %. Either it is recharging after an outage or the pack is failing to hold charge."))
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
                out.append(Item(.warning, text, "A healthy lead-acid pack floats well above its nominal voltage on line power (about 27 V for 24 V). Sitting at or below nominal while not charging points at a worn pack."))
            } else {
                out.append(Item(.good, text))
            }
        }
        if let w = r.loadWatts, let pct = r.loadPercent {
            if pct == 0 {
                out.append(Item(.warning, "No load on the battery outlets", "The UPS reports 0 % load. If the display, the drive enclosure and the Mac's charger are plugged into the surge-only outlets, the battery does not back them and an outage kills them at once. Move them to the battery-backed outlets."))
            } else if pct >= 80 {
                out.append(Item(.warning, "Load \(Int(w.rounded())) W (\(pct) %)", "Close to the rating; runtime on battery will be short."))
            } else {
                out.append(Item(.good, "Load \(Int(w.rounded())) W (\(pct) % of \(Int(r.ratedWatts ?? 0)) W)"))
            }
        }
        if let rt = r.runtimeSeconds, !r.onBattery {
            if let lim = r.lowRuntimeLimitSeconds, rt <= lim * 2 {
                out.append(Item(.warning, "Runtime estimate only \(Duration.text(TimeInterval(rt)))", "Within reach of the UPS's own low-battery limit of \(Duration.text(TimeInterval(lim))); lower the load or replace the battery."))
            } else {
                out.append(Item(.good, "Runtime estimate \(Duration.text(TimeInterval(rt))) at this load"))
            }
        }
        if let v = r.inputVoltage, v > 0, let lo = r.lowTransferVoltage, let hi = r.highTransferVoltage, lo > 0, hi > lo {
            if v < lo || v > hi {
                out.append(Item(.warning, String(format: "Line %.0f V outside the %.0f–%.0f V window", v, lo, hi), "The UPS transfers to battery outside this window."))
            } else if v < lo + 4 || v > hi - 4 {
                out.append(Item(.warning, String(format: "Line %.0f V near the edge of the %.0f–%.0f V window", v, lo, hi)))
            } else {
                out.append(Item(.good, String(format: "Line %.0f V, within the %.0f–%.0f V window", v, lo, hi)))
            }
        } else if let v = r.inputVoltage, v > 0 {
            out.append(Item(.good, String(format: "Line %.0f V", v)))
        }
        if r.flags.contains(.boost) { out.append(Item(.warning, "Boosting a low line voltage", "The UPS is correcting the mains without going to battery; frequent boosting wears the relay and hints at a weak supply.")) }
        if r.flags.contains(.buck) { out.append(Item(.warning, "Trimming a high line voltage")) }
        if hidAttached {
            if let age = hidAge {
                if age > 60 { out.append(Item(.warning, "UPS not answering over USB for \(Duration.text(age))", "macOS still lists it, but direct reads are failing. A cable or hub problem.")) }
            } else {
                out.append(Item(.info, "UPS details not read yet"))
            }
        } else {
            out.append(Item(.warning, "UPS is listed by macOS but not reachable over USB HID", "Load, voltages and limits are unavailable; state, charge and runtime still come from macOS."))
        }
        if let b = internalBattery {
            out.append(Item(b.percent < 20 ? .warning : .good, "Mac's own battery at \(b.percent) %" + (b.isCharging ? ", charging" : ""),
                            "What the Mac itself runs on once the UPS is exhausted. The drives do not."))
        }
        return out
    }
}
