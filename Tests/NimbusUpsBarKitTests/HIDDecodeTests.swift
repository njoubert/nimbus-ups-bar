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

    // MARK: The full capture

    func testFullCaptureCarriesEverythingTheDeviceReturned() throws {
        let raw = try fixture("cp1500pfclcda-full")
        XCTAssertEqual(raw.values.count, 158)
        XCTAssertTrue(raw.values.allSatisfy { $0.cookie != nil && $0.type != nil && $0.reportID != nil })
        XCTAssertEqual(Set(raw.values.compactMap(\.cookie)).count, raw.values.count, "one entry per element")
        XCTAssertTrue(raw.values.filter { $0.error == nil }.allSatisfy { $0.bytes != nil }, "a value read comes with its bytes")
        XCTAssertEqual(raw.collections?.count, 10)
        XCTAssertEqual(raw.reports?.count, 76)
        XCTAssertEqual(raw.descriptor?.count, 726 * 2)
        XCTAssertEqual(raw.properties?["VendorID"], "1892", "CyberPower, 0x0764")
        XCTAssertEqual(raw.properties?["Product"], "CP1500PFCLCDa")
        // The feature report the self-test writes to, as the device returned it: id 20, value 1 (passed).
        XCTAssertEqual(raw.reports?.first { $0.type == "feature" && $0.id == 20 }?.bytes, "1401")
    }

    func testFullCaptureDecodesExactlyLikeTheOldElementList() throws {
        // Before the capture kept everything, the element list held only feature and input
        // elements, the first of each (section, page, usage). The decode must not notice.
        let full = try fixture("cp1500pfclcda-full")
        var seen = Set<UPSHID.Key>()
        var old: [UPSHID.RawReport.Value] = []
        for v in full.values where v.error == nil && ["feature", "input-misc", "input-button"].contains(v.type ?? "") {
            let k = UPSHID.Key(section: v.section, page: v.page, usage: v.usage)
            if seen.insert(k).inserted { old.append(UPSHID.RawReport.Value(section: v.section, page: v.page, usage: v.usage, value: v.value)) }
        }
        let reduced = UPSHID.RawReport(product: full.product, manufacturer: full.manufacturer, serial: full.serial, values: old)
        let a = UPSHID.decode(full, now: 0), b = UPSHID.decode(reduced, now: 0)
        XCTAssertEqual(a.reading, b.reading)
        XCTAssertEqual(a.fields, b.fields)
        XCTAssertEqual(a.fields.count, 53)
        let r = UPSHID.decode(full, now: 0).reading
        XCTAssertEqual(r.name, "CP1500PFCLCDa")
        XCTAssertEqual(r.ratedWatts, 1000)
        XCTAssertFalse(r.onBattery)
    }

    func testDecodeSkipsFailedReadsOutputsAndPadding() {
        func v(_ page: UInt32, _ usage: UInt32, _ value: Int, type: String, error: Int32? = nil) -> UPSHID.RawReport.Value {
            var x = UPSHID.RawReport.Value(section: 0x24, page: page, usage: usage, value: value)
            x.type = type; x.error = error
            return x
        }
        let raw = UPSHID.RawReport(product: "X", manufacturer: nil, serial: nil, values: [
            v(0x85, 0x66, 0, type: "feature", error: -536850432),   // failed: not a 0 % charge
            v(0x85, 0x66, 7, type: "output"),                        // an output: not a reading
            v(0x85, 0x66, 9, type: "input-null"),                    // padding: not a reading
            v(0x85, 0x66, 81, type: "feature"),                      // the reading
            v(0x85, 0x66, 12, type: "input-misc"),                   // a repeat: the first stands
        ])
        XCTAssertEqual(UPSHID.decode(raw, now: 0).reading.chargePercent, 81)
    }

    func testDevicePropertiesAreOneLineAndParseBack() throws {
        XCTAssertEqual(UPSHID.propertyText("CP1500PFCLCDa"), "CP1500PFCLCDa")
        XCTAssertEqual(UPSHID.propertyText(NSNumber(value: 1892)), "1892")
        XCTAssertEqual(UPSHID.propertyText(kCFBooleanTrue as Any), "true")
        XCTAssertEqual(UPSHID.propertyText(Data([0x05, 0x84])), "0584")
        let nested: [Any] = [["DeviceUsagePage": 132, "DeviceUsage": 4], ["Blob": Data([0xAB])]]
        XCTAssertEqual(UPSHID.propertyText(nested), #"[{"DeviceUsage":4,"DeviceUsagePage":132},{"Blob":"ab"}]"#)
        // The captured device: no property spans lines, and the nested ones are JSON.
        let raw = try fixture("cp1500pfclcda-full")
        let props = try XCTUnwrap(raw.properties)
        XCTAssertTrue(props.values.allSatisfy { !$0.contains("\n") })
        let pairs = try XCTUnwrap(props["DeviceUsagePairs"])
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(pairs.utf8)) as? [Any])
    }
}
