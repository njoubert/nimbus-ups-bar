// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A pretend UPS that has just lost mains: the battery drains at `speed` simulated seconds per
/// real second, the charge follows the runtime, and when the runtime reaches zero the UPS
/// vanishes the way a real one does when it shuts off. `restorePower()` ends the outage.
/// A `Scenario` picks which part of the policy the pretend outage exercises.
public final class SimulatedOutage {
    public enum Scenario: String, CaseIterable, Sendable {
        /// The battery drains from the desk's runtime (at most 40 min): the time conditions fire.
        case drain
        /// A 13-minute battery: the runtime and charge conditions fire before the time ones.
        case shortBattery
        /// The UPS drops off USB `lostAfter` into the outage and stays gone: the in-outage
        /// UPS-gone policy.
        case upsLostInOutage
        /// No outage: the UPS drops off USB on line power and comes back `lostOnLineFor` later
        /// (sooner once the volumes are safe): the on-line UPS-gone policy.
        case upsLostOnLine

        public var title: String {
            switch self {
            case .drain: return "Battery Drains"
            case .shortBattery: return "Short Battery (Runtime and Charge Fire First)"
            case .upsLostInOutage: return "UPS Lost Mid-Outage"
            case .upsLostOnLine: return "UPS Lost on Line Power"
            }
        }
    }

    /// Simulated seconds into the outage at which `upsLostInOutage` loses the UPS.
    public static let lostAfter: TimeInterval = 90
    /// Simulated seconds `upsLostOnLine` keeps the UPS away when nothing makes it safe sooner.
    public static let lostOnLineFor: TimeInterval = 180
    /// Simulated seconds "safe" is held so it can be seen before the power comes back.
    public static let safeHold: TimeInterval = 20

    public let scenario: Scenario
    public let speed: Double
    public let startedAt: TimeInterval
    public let initialRuntime: Int
    public let name: String
    private let template: UPSReading
    public private(set) var restoredAt: TimeInterval?

    /// `template` supplies the static facts (name, rated power, voltages) so the simulated
    /// readings look like this desk's UPS; `initialRuntime` is how long the pretend battery
    /// lasts, in simulated seconds.
    public init(template: UPSReading?, initialRuntime: Int = 45 * 60, speed: Double, realNow: TimeInterval, scenario: Scenario = .drain) {
        self.template = template ?? UPSReading(present: true, name: "Simulated UPS", ratedWatts: 1000)
        self.name = self.template.name ?? "Simulated UPS"
        self.scenario = scenario
        self.initialRuntime = scenario == .shortBattery ? 13 * 60 : max(60, initialRuntime)
        self.speed = max(1, speed)
        self.startedAt = realNow
    }

    public var powerRestored: Bool { restoredAt != nil }

    public func restorePower(realNow: TimeInterval) {
        if restoredAt == nil { restoredAt = realNow }
    }

    /// Simulated seconds since the outage began.
    public func elapsed(realNow: TimeInterval) -> TimeInterval { (realNow - startedAt) * speed }

    public func reading(realNow: TimeInterval, monotonicStamp: TimeInterval) -> UPSReading {
        var r = template
        r.present = true
        r.name = name
        r.timestamp = monotonicStamp
        r.serialNumber = "SIMULATED"
        if powerRestored {
            r.onBattery = false
            r.flags = [.acPresent, .charging]
            r.chargePercent = min(100, lastCharge + Int((realNow - (restoredAt ?? realNow)) * speed / 30))
            r.runtimeSeconds = initialRuntime * (r.chargePercent ?? 100) / 100
            return r
        }
        switch scenario {
        case .upsLostOnLine: return .absent(at: monotonicStamp)
        case .upsLostInOutage where elapsed(realNow: realNow) >= Self.lostAfter: return .absent(at: monotonicStamp)
        default: break
        }
        let remaining = Double(initialRuntime) - elapsed(realNow: realNow)
        if remaining <= 0 {
            // Battery exhausted: the UPS switches off and its USB connection goes with it.
            return .absent(at: monotonicStamp)
        }
        r.onBattery = true
        r.flags = [.discharging]
        r.runtimeSeconds = Int(remaining)
        let charge = Int((remaining / Double(initialRuntime) * 100).rounded())
        r.chargePercent = max(0, min(100, charge))
        lastCharge = r.chargePercent ?? 0
        if let lim = r.lowChargeLimitPercent, charge <= lim { r.flags.insert(.belowCapacityLimit) }
        // Line power is gone: input reads 0, output rides the inverter at nominal.
        r.inputVoltage = 0
        if let v = r.outputVoltage, v > 0 { r.outputVoltage = v } else { r.outputVoltage = 120 }
        return r
    }

    /// Whether the pretend power (or the pretend UPS) comes back now, given the guard's phase:
    /// once "safe" has been on show for `safeHold`, when the battery runs flat, or, for
    /// `upsLostOnLine`, after `lostOnLineFor`. Returns the log line when it does.
    public func advance(phase: OutageGuard.Phase, realNow: TimeInterval) -> String? {
        guard !powerRestored else { return nil }
        if phase == .safe {
            if safeSince == nil { safeSince = realNow }
            if (realNow - (safeSince ?? realNow)) * speed >= Self.safeHold {
                restorePower(realNow: realNow)
                return scenario == .upsLostOnLine || scenario == .upsLostInOutage ? "the pretend UPS is back, on line power" : "pretend power restored"
            }
        }
        if scenario != .upsLostOnLine, elapsed(realNow: realNow) >= Double(initialRuntime) {
            restorePower(realNow: realNow)
            return "the pretend UPS ran flat; pretend power restored"
        }
        if scenario == .upsLostOnLine, phase == .line, elapsed(realNow: realNow) >= Self.lostOnLineFor {
            restorePower(realNow: realNow)
            return "the pretend UPS is back"
        }
        return nil
    }

    private var lastCharge = 100
    private var safeSince: TimeInterval?
}
