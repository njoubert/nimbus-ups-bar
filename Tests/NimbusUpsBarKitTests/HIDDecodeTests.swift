// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
import UpsGuardCore

/// `UPSHID.decode` over raw element values: the committed fixture from the CP1500PFCLCDa
/// (`--dump-hid-raw`), and hand-made maps for each quirk. No UPS needed.
final class HIDDecodeTests: XCTestCase {
    typealias V = UPSHID.RawReport.Value
    let input: UInt32 = 0x1A, output: UInt32 = 0x1C, summary: UInt32 = 0x24, battery: UInt32 = 0x12

    func raw(_ values: [V], product: String? = "Test UPS") -> UPSHID.RawReport {
        UPSHID.RawReport(product: product, manufacturer: "CPS", serial: "0001", values: values, readMillis: 11)
    }

    func fixture(_ name: String) throws -> UPSHID.RawReport {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(UPSHID.RawReport.self, from: Data(contentsOf: url))
    }

    func testCP1500Fixture() throws {
        // Captured 2026-10-11 at the desk, on line power, charged, about 50 W of load.
        let rep = UPSHID.decode(try fixture("cp1500pfclcda"), now: 1234)
        let r = rep.reading
        XCTAssertTrue(r.present)
        XCTAssertEqual(r.timestamp, 1234)
        XCTAssertEqual(r.name, "CP1500PFCLCDa")
        XCTAssertEqual(r.manufacturer, "CPS")
        XCTAssertNotNil(r.serialNumber)
        XCTAssertFalse(r.onBattery)
        XCTAssertTrue(r.flags.contains(.acPresent))
        XCTAssertFalse(r.flags.contains(.discharging))
        XCTAssertEqual(r.chargePercent, 100)
        XCTAssertGreaterThan(r.runtimeSeconds ?? 0, 30 * 60)
        XCTAssertEqual(r.ratedWatts, 1000)
        XCTAssertEqual(r.ratedVA, 1500)
        XCTAssertNotNil(r.loadPercent)
        XCTAssertNotNil(r.loadWatts)
        XCTAssertEqual(r.batteryNominalVoltage, 24, "240 in tenths")
        XCTAssertGreaterThan(r.batteryVoltage ?? 0, 24, "a charged pack floats above nominal")
        XCTAssertLessThan(r.batteryVoltage ?? 99, 30)
        XCTAssertGreaterThan(r.inputVoltage ?? 0, 100)
        XCTAssertLessThan(r.inputVoltage ?? 999, 140)
        XCTAssertEqual(r.lowTransferVoltage, 100)
        XCTAssertEqual(r.highTransferVoltage, 139)
        XCTAssertEqual(r.lowRuntimeLimitSeconds, 300)
        XCTAssertNotNil(r.lowChargeLimitPercent)
        XCTAssertNotNil(r.selfTest, "the Test element reads with the update option")
        XCTAssertFalse(r.flags.contains(.needsReplacement))
        XCTAssertFalse(r.flags.contains(.overload))
        XCTAssertEqual(rep.readMillis, try fixture("cp1500pfclcda").readMillis)
        // The labelled fields: every section present, string-table indexes left out.
        XCTAssertTrue(Set(rep.fields.map(\.section)).isSuperset(of: ["Input", "Output", "Battery"]), "\(Set(rep.fields.map(\.section)))")
        XCTAssertFalse(rep.fields.contains { $0.label.contains("string index") })
        XCTAssertTrue(rep.fields.contains { $0.label == "Voltage" && $0.section == "Input" })
        XCTAssertTrue(rep.fields.contains { $0.label == "Self-test" })
        XCTAssertTrue(rep.fields.contains { $0.label == "Beeper" && ["enabled", "disabled", "muted"].contains($0.value) })
    }

    func testBatteryVoltsComeInTenths() {
        XCTAssertEqual(UPSHID.batteryVolts(271), 27.1)
        XCTAssertEqual(UPSHID.batteryVolts(240), 24.0)
        XCTAssertEqual(UPSHID.batteryVolts(99), 99, "two-digit figures are whole volts")
        XCTAssertEqual(UPSHID.batteryVolts(24), 24)
        let rep = UPSHID.decode(raw([V(section: summary, page: 0x84, usage: 0x30, value: 271), V(section: summary, page: 0x84, usage: 0x40, value: 240),
                                     V(section: input, page: 0x84, usage: 0x30, value: 122)]), now: 0)
        XCTAssertEqual(rep.reading.batteryVoltage, 27.1)
        XCTAssertEqual(rep.reading.batteryNominalVoltage, 24)
        XCTAssertEqual(rep.reading.inputVoltage, 122, "line volts are whole volts")
        XCTAssertEqual(rep.fields.first { $0.section == "Battery" && $0.label == "Voltage" }?.value, "27.1 V")
        XCTAssertEqual(rep.fields.first { $0.section == "Input" && $0.label == "Voltage" }?.value, "122 V")
    }

    func testACPresentDecidesOnBatteryAndDischargingIsTheFallback() {
        let line = UPSHID.decode(raw([V(section: summary, page: 0x85, usage: 0xD0, value: 1), V(section: summary, page: 0x85, usage: 0x45, value: 1)]), now: 0)
        XCTAssertFalse(line.reading.onBattery, "ACPresent wins even when Discharging is set")
        XCTAssertTrue(line.reading.flags.contains(.acPresent))
        let battery = UPSHID.decode(raw([V(section: summary, page: 0x85, usage: 0xD0, value: 0)]), now: 0)
        XCTAssertTrue(battery.reading.onBattery)
        XCTAssertFalse(battery.reading.flags.contains(.acPresent))
        let noAC = UPSHID.decode(raw([V(section: summary, page: 0x85, usage: 0x45, value: 1)]), now: 0)
        XCTAssertTrue(noAC.reading.onBattery, "without ACPresent, Discharging decides")
        let nothing = UPSHID.decode(raw([V(section: output, page: 0x84, usage: 0x35, value: 5)]), now: 0)
        XCTAssertFalse(nothing.reading.onBattery, "neither: assume line")
    }

    func testSelfTestCodesFollowNUT() {
        for (code, expected): (Int, UPSReading.SelfTest?) in [(1, .passed), (2, .warning), (3, .error), (4, .aborted), (5, .inProgress), (6, .notRun), (0, nil), (7, nil)] {
            let rep = UPSHID.decode(raw([V(section: output, page: 0x84, usage: 0x58, value: code)]), now: 0)
            XCTAssertEqual(rep.reading.selfTest, expected, "code \(code)")
        }
        let underSummary = UPSHID.decode(raw([V(section: summary, page: 0x84, usage: 0x58, value: 1)]), now: 0)
        XCTAssertEqual(underSummary.reading.selfTest, .passed, "some firmware puts Test under the summary")
    }

    func testBatterySectionIsTheFallbackForTheSummary() {
        let fromBattery = UPSHID.decode(raw([V(section: battery, page: 0x85, usage: 0x66, value: 87), V(section: battery, page: 0x85, usage: 0x68, value: 4200)]), now: 0)
        XCTAssertEqual(fromBattery.reading.chargePercent, 87)
        XCTAssertEqual(fromBattery.reading.runtimeSeconds, 4200)
        let both = UPSHID.decode(raw([V(section: summary, page: 0x85, usage: 0x66, value: 90), V(section: battery, page: 0x85, usage: 0x66, value: 87)]), now: 0)
        XCTAssertEqual(both.reading.chargePercent, 90, "the summary wins when both exist")
        let zeroRuntime = UPSHID.decode(raw([V(section: summary, page: 0x85, usage: 0x68, value: 0)]), now: 0)
        XCTAssertNil(zeroRuntime.reading.runtimeSeconds, "0 is 'no estimate', not 'empty'")
    }

    func testLoadFromPercentWhenNoWattageIsReported() {
        let pctOnly = UPSHID.decode(raw([V(section: output, page: 0x84, usage: 0x35, value: 9), V(section: output, page: 0x84, usage: 0x44, value: 1000)]), now: 0)
        XCTAssertEqual(pctOnly.reading.loadPercent, 9)
        XCTAssertEqual(pctOnly.reading.loadWatts, 90)
        let withWatts = UPSHID.decode(raw([V(section: output, page: 0x84, usage: 0x35, value: 9), V(section: output, page: 0x84, usage: 0x44, value: 1000),
                                           V(section: output, page: 0x84, usage: 0x34, value: 92)]), now: 0)
        XCTAssertEqual(withWatts.reading.loadWatts, 92, "the active-power element is the better figure")
        let zeroWatts = UPSHID.decode(raw([V(section: output, page: 0x84, usage: 0x35, value: 9), V(section: output, page: 0x84, usage: 0x44, value: 1000),
                                           V(section: output, page: 0x84, usage: 0x34, value: 0)]), now: 0)
        XCTAssertEqual(zeroWatts.reading.loadWatts, 90, "0 W with 9 % load is a missing element, not a figure")
        let noRating = UPSHID.decode(raw([V(section: output, page: 0x84, usage: 0x35, value: 9)]), now: 0)
        XCTAssertNil(noRating.reading.loadWatts)
    }

    func testFlagsAndLimits() {
        let rep = UPSHID.decode(raw([
            V(section: summary, page: 0x85, usage: 0x44, value: 1), V(section: summary, page: 0x85, usage: 0x46, value: 0),
            V(section: summary, page: 0x85, usage: 0x4B, value: 1), V(section: output, page: 0x84, usage: 0x65, value: 1),
            V(section: output, page: 0x84, usage: 0x69, value: 1), V(section: output, page: 0x84, usage: 0x6E, value: 1),
            V(section: summary, page: 0x85, usage: 0x29, value: 10), V(section: summary, page: 0x85, usage: 0x2A, value: 300),
            V(section: summary, page: 0x85, usage: 0x8C, value: 20), V(section: output, page: 0x84, usage: 0x53, value: 100),
            V(section: output, page: 0x84, usage: 0x54, value: 139),
        ]), now: 0)
        let r = rep.reading
        XCTAssertEqual(r.flags, [.charging, .needsReplacement, .overload, .shutdownImminent, .boost])
        XCTAssertEqual(r.lowChargeLimitPercent, 10)
        XCTAssertEqual(r.lowRuntimeLimitSeconds, 300)
        XCTAssertEqual(r.warningChargeLimitPercent, 20)
        XCTAssertEqual(r.lowTransferVoltage, 100)
        XCTAssertEqual(r.highTransferVoltage, 139)
        XCTAssertEqual(rep.fields.first { $0.label == "Overload" }?.value, "yes")
        XCTAssertEqual(rep.fields.first { $0.label == "Low-battery limit (runtime)" }?.value, "5 min")
    }

    func testStringIndexesAreNotFields() {
        let rep = UPSHID.decode(raw([V(section: 0, page: 0x84, usage: 0xFE, value: 2), V(section: summary, page: 0x85, usage: 0x89, value: 4),
                                     V(section: output, page: 0x84, usage: 0x35, value: 5)]), now: 0)
        XCTAssertEqual(rep.fields.count, 1)
        XCTAssertEqual(rep.fields.first?.label, "Load")
        XCTAssertEqual(rep.fields.first?.value, "5 %")
    }

    func testRawReportRoundTripsThroughJSON() throws {
        let original = raw([V(section: input, page: 0x84, usage: 0x30, value: 122)])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(UPSHID.RawReport.self, from: data), original)
    }
}
