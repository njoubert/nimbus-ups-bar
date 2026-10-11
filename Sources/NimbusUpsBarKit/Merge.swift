// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UpsGuardCore

/// How the two views of the UPS become one reading.
public enum ReadingMerge {
    /// IOKit's entry decides whether a UPS exists and what state it is in (that is the entry
    /// macOS raises the change event for); a fresh HID report supplies the finer figures and
    /// takes over charge and runtime (seconds, not minutes). A HID report older than
    /// `freshFor` is ignored and the IOKit figures stand alone.
    public static func merge(iops: UPSReading, hid: UPSReading?, hidAt: TimeInterval?, now: TimeInterval, freshFor: TimeInterval) -> UPSReading {
        guard iops.present else { return iops }
        guard let hid, let at = hidAt, now - at < freshFor else { return iops }
        var r = iops
        if let c = hid.chargePercent { r.chargePercent = c }
        if let s = hid.runtimeSeconds { r.runtimeSeconds = s }
        r = r.merging(hid)
        r.flags = hid.flags.union(iops.onBattery ? [.discharging] : [.acPresent])
        return r
    }
}
