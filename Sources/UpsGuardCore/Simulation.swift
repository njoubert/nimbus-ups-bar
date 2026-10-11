// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A pretend UPS that has just lost mains: the battery drains at `speed` simulated seconds per
/// real second, the charge follows the runtime, and when the runtime reaches zero the UPS
/// vanishes the way a real one does when it shuts off. `restorePower()` ends the outage.
public final class SimulatedOutage {
    public let speed: Double
    public let startedAt: TimeInterval
    public let initialRuntime: Int
    public let name: String
    private let template: UPSReading
    public private(set) var restoredAt: TimeInterval?

    /// `template` supplies the static facts (name, rated power, voltages) so the simulated
    /// readings look like this desk's UPS; `initialRuntime` is how long the pretend battery
    /// lasts, in simulated seconds.
    public init(template: UPSReading?, initialRuntime: Int = 45 * 60, speed: Double, realNow: TimeInterval) {
        self.template = template ?? UPSReading(present: true, name: "Simulated UPS", ratedWatts: 1000)
        self.name = self.template.name ?? "Simulated UPS"
        self.initialRuntime = max(60, initialRuntime)
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

    private var lastCharge = 100
}
