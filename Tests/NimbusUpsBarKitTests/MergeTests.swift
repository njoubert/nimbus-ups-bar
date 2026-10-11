// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
import UpsGuardCore

/// `ReadingMerge.merge`: IOKit's entry decides presence and state, a fresh HID report fills
/// in the rest.
final class MergeTests: XCTestCase {
    func iops(onBattery: Bool = false) -> UPSReading {
        var r = UPSReading(present: true, name: "CP1500PFCLCDa", onBattery: onBattery, chargePercent: 100, runtimeSeconds: 96 * 60)
        r.flags = onBattery ? [.discharging] : [.acPresent, .charging]
        return r
    }
    func hid() -> UPSReading {
        var r = UPSReading(present: true, name: "CP1500PFCLCDa", onBattery: false, chargePercent: 98, runtimeSeconds: 5880)
        r.flags = [.acPresent, .fullyCharged]
        r.loadWatts = 92
        r.loadPercent = 9
        r.inputVoltage = 122
        r.batteryVoltage = 27.1
        r.selfTest = .passed
        return r
    }

    func testIOKitAbsentWinsOverAFreshHIDReport() {
        let m = ReadingMerge.merge(iops: .absent(), hid: hid(), hidAt: 100, now: 101, freshFor: 15)
        XCTAssertFalse(m.present, "macOS not listing the UPS is the word on presence")
    }

    func testStaleHIDIsIgnored() {
        let m = ReadingMerge.merge(iops: iops(), hid: hid(), hidAt: 100, now: 116, freshFor: 15)
        XCTAssertEqual(m, iops())
        XCTAssertNil(m.loadWatts)
        XCTAssertEqual(m.runtimeSeconds, 96 * 60, "IOKit's minutes stand")
    }

    func testFreshHIDOverridesChargeAndRuntimeAndFillsTheRest() {
        let m = ReadingMerge.merge(iops: iops(), hid: hid(), hidAt: 100, now: 110, freshFor: 15)
        XCTAssertEqual(m.chargePercent, 98)
        XCTAssertEqual(m.runtimeSeconds, 5880, "HID's seconds beat IOKit's minutes")
        XCTAssertEqual(m.loadWatts, 92)
        XCTAssertEqual(m.inputVoltage, 122)
        XCTAssertEqual(m.batteryVoltage, 27.1)
        XCTAssertEqual(m.selfTest, .passed)
        XCTAssertFalse(m.onBattery)
    }

    func testFlagsAreTheUnionWithIOKitsState() {
        let line = ReadingMerge.merge(iops: iops(), hid: hid(), hidAt: 100, now: 101, freshFor: 15)
        XCTAssertEqual(line.flags, [.acPresent, .fullyCharged])
        // IOKit says battery, the HID report (from a moment earlier) still says line: IOKit's
        // state is the one the change event was raised for.
        let battery = ReadingMerge.merge(iops: iops(onBattery: true), hid: hid(), hidAt: 100, now: 101, freshFor: 15)
        XCTAssertTrue(battery.onBattery)
        XCTAssertTrue(battery.flags.contains(.discharging))
        XCTAssertTrue(battery.flags.contains(.fullyCharged), "the HID flags are kept")
    }

    func testNoHIDAtAll() {
        let m = ReadingMerge.merge(iops: iops(), hid: nil, hidAt: nil, now: 0, freshFor: 15)
        XCTAssertEqual(m, iops())
    }
}
