// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit.ps
import UpsGuardCore

/// What macOS itself knows about the power sources: the UPS entry `ioupsd` publishes (the
/// same one `pmset -g ps` prints) and the laptop's internal battery. The UPS entry carries
/// state, charge and runtime; everything finer (load, voltages, flags) comes from `UPSHID`.
///
/// Changes arrive through `IOPSNotificationCreateRunLoopSource` on the main run loop, so a
/// transfer to battery is seen within a second rather than at the next poll.
@MainActor
public final class PowerSources {

    public struct InternalBattery: Equatable {
        public var percent: Int
        public var isCharging: Bool
        public var onAC: Bool
        public var minutesToEmpty: Int?
        public init(percent: Int, isCharging: Bool, onAC: Bool, minutesToEmpty: Int? = nil) {
            self.percent = percent; self.isCharging = isCharging; self.onAC = onAC; self.minutesToEmpty = minutesToEmpty
        }
    }

    public struct Snapshot: Equatable {
        public var ups: UPSReading
        public var internalBattery: InternalBattery?
        /// "AC Power" or "Battery Power": what the Mac itself is drawing from.
        public var providing: String
    }

    public var onChange: (() -> Void)?
    public init() {}
    private var source: CFRunLoopSource?

    public func start() {
        guard source == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerSources>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.onChange?() }
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        source = s
    }

    public func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        source = nil
    }

    /// One read of every power source. `now` is the monotonic stamp for the reading.
    public nonisolated static func read(now: TimeInterval) -> Snapshot {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        let providing = IOPSGetProvidingPowerSourceType(blob).map { $0.takeUnretainedValue() as String } ?? "AC Power"
        var ups = UPSReading.absent(at: now)
        var battery: InternalBattery?
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let type = d[kIOPSTypeKey] as? String
            let state = d[kIOPSPowerSourceStateKey] as? String
            let cap = d[kIOPSCurrentCapacityKey] as? Int
            let max = d[kIOPSMaxCapacityKey] as? Int
            let pct: Int? = (cap != nil && max != nil && max! > 0) ? Int((Double(cap!) * 100 / Double(max!)).rounded()) : cap
            let tte = d[kIOPSTimeToEmptyKey] as? Int
            if type == kIOPSUPSType {
                ups = UPSReading(present: (d[kIOPSIsPresentKey] as? Bool) ?? true,
                                 name: d[kIOPSNameKey] as? String,
                                 onBattery: state == kIOPSBatteryPowerValue,
                                 chargePercent: pct,
                                 // IOKit gives minutes; 0 and negative mean "no estimate".
                                 runtimeSeconds: (tte ?? 0) > 0 ? tte! * 60 : nil,
                                 timestamp: now)
                // Not `Voltage`: ioupsd fills that key with whichever voltage element it read
                // last (122000 mV one minute, 27100 the next, the battery's). The HID read is
                // the only trustworthy source for input, output and battery volts.
                if (d[kIOPSIsChargingKey] as? Bool) == true { ups.flags.insert(.charging) }
                if state == kIOPSACPowerValue { ups.flags.insert(.acPresent) }
                if state == kIOPSBatteryPowerValue { ups.flags.insert(.discharging) }
                if let serial = d["Accessory Identifier"] as? String { ups.serialNumber = serial }
            } else if type == kIOPSInternalBatteryType {
                battery = InternalBattery(percent: pct ?? 0,
                                          isCharging: (d[kIOPSIsChargingKey] as? Bool) ?? false,
                                          onAC: state == kIOPSACPowerValue,
                                          minutesToEmpty: (tte ?? 0) > 0 ? tte : nil)
            }
        }
        return Snapshot(ups: ups, internalBattery: battery, providing: providing)
    }

    /// The raw UPS dictionary, for the details submenu and `--print`.
    /// The UPS's power-source dictionary with JSON-safe values (strings, numbers, booleans;
    /// anything else as its description), for the Inspector's copy. Nil when none is listed.
    public nonisolated static func rawUPSDictionary() -> [String: Any]? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSUPSType else { continue }
            return d.mapValues { v in (v is String || v is NSNumber) ? v : "\(v)" }
        }
        return nil
    }

    public nonisolated static func rawUPSDescription() -> [(String, String)] {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSUPSType else { continue }
            return d.sorted { $0.key < $1.key }.map { ($0.key, "\($0.value)") }
        }
        return []
    }
}

/// Monotonic seconds that keep counting through sleep. Wall-clock time can step backwards
/// (NTP) and would stall a deadline.
public func monotonicNow() -> TimeInterval {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
}
