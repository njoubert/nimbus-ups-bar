// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
import UpsGuardCore

/// One fixture reading per health rule. The one bug the app has had so far ("Line 122 V
/// outside the 0–0 V window") was a rule here misfiring on an input nobody had tried.
final class HealthTests: XCTestCase {

    /// A healthy UPS on line power, as the CP1500 reports it at the desk.
    func fine() -> UPSReading {
        var r = UPSReading(present: true, name: "CP1500PFCLCDa", onBattery: false, chargePercent: 100, runtimeSeconds: 98 * 60)
        r.flags = [.acPresent, .fullyCharged]
        r.loadPercent = 5
        r.loadWatts = 50
        r.ratedWatts = 1000
        r.inputVoltage = 123
        r.lowTransferVoltage = 100
        r.highTransferVoltage = 139
        r.batteryVoltage = 27.1
        r.batteryNominalVoltage = 24
        r.lowRuntimeLimitSeconds = 300
        r.warningChargeLimitPercent = 20
        r.selfTest = .passed
        return r
    }

    func assess(_ r: UPSReading, hidAge: TimeInterval? = 1, hidAttached: Bool = true, upsSeen: Bool = true,
                internalBattery: PowerSources.InternalBattery? = nil, protectedMounted: Int = 1, staleAfter: TimeInterval = 60) -> [Health.Item] {
        Health.assess(reading: r, hidAge: hidAge, hidAttached: hidAttached, upsSeen: upsSeen,
                      internalBattery: internalBattery, protectedMounted: protectedMounted, staleAfter: staleAfter)
    }

    func texts(_ items: [Health.Item]) -> [String] { items.map(\.text) }
    func level(_ items: [Health.Item], _ prefix: String) -> Health.Level? { items.first { $0.text.hasPrefix(prefix) }?.level }

    func testHealthyDeskIsAllGreen() {
        let items = assess(fine())
        XCTAssertEqual(Health.overall(items), .good)
        XCTAssertNil(Health.headline(items))
        XCTAssertEqual(texts(items), [
            "Last battery self-test passed",
            "Battery at 100 %, fully charged",
            "Battery 27.1 V on a 24 V pack",
            "Load 50 W (5 % of 1000 W)",
            "Runtime estimate 1 h 38 min at this load",
            "Line 123 V, within the 100–139 V window",
        ])
    }

    func testNoUPS() {
        let never = assess(.absent(), upsSeen: false, protectedMounted: 0)
        XCTAssertEqual(texts(never), ["No UPS found"])
        XCTAssertEqual(Health.overall(never), .bad)
        let gone = assess(.absent(), upsSeen: true, protectedMounted: 2)
        XCTAssertEqual(texts(gone), ["UPS has disconnected", "2 protected volumes mounted with no UPS watching"])
        XCTAssertEqual(Health.headline(gone)?.text, "UPS has disconnected")
    }

    func testOnBatteryIsAWarningAndTheGaugeIsANote() {
        var r = fine(); r.onBattery = true; r.flags = [.discharging]; r.chargePercent = 78
        let items = assess(r)
        XCTAssertEqual(level(items, "Running on battery"), .warning)
        XCTAssertEqual(level(items, "Charge gauge at 78 %"), .info)
        XCTAssertNil(items.first { $0.text.hasPrefix("Runtime estimate") }, "the estimate is a headline figure on battery, not a check")
        XCTAssertEqual(Health.headline(items)?.text, "Running on battery")
    }

    func testFaultFlags() {
        var r = fine(); r.flags.insert(.needsReplacement)
        XCTAssertEqual(level(assess(r), "The UPS says its battery needs replacement"), .bad)
        r = fine(); r.flags.insert(.overload)
        XCTAssertEqual(level(assess(r), "Output overloaded"), .bad)
        r = fine(); r.flags.insert(.shutdownImminent)
        XCTAssertEqual(level(assess(r), "The UPS reports shutdown imminent"), .bad)
        r = fine(); r.flags.insert(.boost)
        XCTAssertEqual(level(assess(r), "Boosting a low line voltage"), .warning)
        r = fine(); r.flags.insert(.buck)
        XCTAssertEqual(level(assess(r), "Trimming a high line voltage"), .warning)
    }

    func testSelfTestCodes() {
        let expected: [(UPSReading.SelfTest, Health.Level)] = [(.passed, .good), (.warning, .warning), (.error, .bad), (.aborted, .warning), (.inProgress, .info), (.notRun, .info)]
        for (code, lvl) in expected {
            var r = fine(); r.selfTest = code
            XCTAssertEqual(level(assess(r), "Battery self-test") ?? level(assess(r), "Last battery self-test"), lvl, "\(code)")
        }
        var r = fine(); r.selfTest = nil
        XCTAssertNil(assess(r).first { $0.text.contains("self-test") })
    }

    func testChargeOnLinePower() {
        var r = fine(); r.chargePercent = 72; r.flags = [.acPresent, .charging]
        XCTAssertEqual(level(assess(r), "Battery at 72 %, recharging"), .info)
        r.chargePercent = 15
        XCTAssertEqual(level(assess(r), "Battery at 15 % on line power"), .warning, "below the UPS's own warning limit")
        r.chargePercent = 95; r.flags = [.acPresent]
        XCTAssertEqual(level(assess(r), "Battery at 95 %"), .good)
        XCTAssertEqual(assess(r).first { $0.text.hasPrefix("Battery at 95") }?.text, "Battery at 95 %", "no 'fully charged' without the flag")
        r.chargePercent = nil
        XCTAssertNil(assess(r).first { $0.text.hasPrefix("Battery at") })
    }

    func testBatteryVoltageAgainstNominal() {
        var r = fine(); r.batteryVoltage = 24.2; r.flags = [.acPresent]
        XCTAssertEqual(level(assess(r), "Battery 24.2 V"), .warning, "at nominal and not charging: a worn pack")
        r.flags = [.acPresent, .charging]
        XCTAssertEqual(level(assess(r), "Battery 24.2 V"), .good, "charging explains a low voltage")
        r.flags = [.acPresent]; r.batteryVoltage = 26.4
        XCTAssertEqual(level(assess(r), "Battery 26.4 V"), .good)
        r.batteryNominalVoltage = nil
        XCTAssertNil(assess(r).first { $0.text.hasPrefix("Battery 26.4") }, "no nominal, no judgement")
    }

    func testLoad() {
        var r = fine(); r.loadPercent = 0; r.loadWatts = 0
        XCTAssertEqual(level(assess(r), "No load on the battery outlets"), .warning)
        r.loadPercent = 85; r.loadWatts = 850
        XCTAssertEqual(level(assess(r), "Load 850 W (85 %)"), .warning)
        r.loadPercent = 10; r.loadWatts = 104.6
        XCTAssertEqual(assess(r).first { $0.text.hasPrefix("Load") }?.text, "Load 105 W (10 % of 1000 W)")
        r.loadWatts = nil
        XCTAssertNil(assess(r).first { $0.text.hasPrefix("Load") })
    }

    func testRuntimeNearTheUPSLimit() {
        var r = fine(); r.runtimeSeconds = 540
        XCTAssertEqual(level(assess(r), "Runtime estimate only 9 min"), .warning, "within twice the 5 min limit")
        r.runtimeSeconds = 601
        XCTAssertEqual(level(assess(r), "Runtime estimate 10 min 01 s at this load"), .good)
        r.lowRuntimeLimitSeconds = nil; r.runtimeSeconds = 60
        XCTAssertEqual(level(assess(r), "Runtime estimate 1 min at this load"), .good, "no limit reported, no comparison")
    }

    func testLineVoltageWindow() {
        var r = fine(); r.inputVoltage = 95
        XCTAssertEqual(level(assess(r), "Line 95 V outside the 100–139 V window"), .warning)
        r.inputVoltage = 102
        XCTAssertEqual(level(assess(r), "Line 102 V near the edge of the 100–139 V window"), .warning)
        r.inputVoltage = 137
        XCTAssertEqual(level(assess(r), "Line 137 V near the edge"), .warning)
        r.inputVoltage = 120
        XCTAssertEqual(level(assess(r), "Line 120 V, within"), .good)
    }

    func testLineVoltageWithoutATransferWindowIsJustReported() {
        // The regression: a cached HID read gave 0 for both transfer voltages and the line
        // was flagged as "outside the 0–0 V window".
        var r = fine(); r.lowTransferVoltage = 0; r.highTransferVoltage = 0; r.inputVoltage = 122
        XCTAssertEqual(assess(r).first { $0.text.hasPrefix("Line") }?.text, "Line 122 V")
        XCTAssertEqual(level(assess(r), "Line 122 V"), .good)
        r.lowTransferVoltage = nil; r.highTransferVoltage = nil
        XCTAssertEqual(level(assess(r), "Line 122 V"), .good)
        r.lowTransferVoltage = 139; r.highTransferVoltage = 100   // inverted: not a window either
        XCTAssertEqual(assess(r).first { $0.text.hasPrefix("Line") }?.text, "Line 122 V")
        r.inputVoltage = 0
        XCTAssertNil(assess(r).first { $0.text.hasPrefix("Line") }, "0 V is 'not read', not 'no mains'")
    }

    func testHIDFreshness() {
        XCTAssertEqual(level(assess(fine(), hidAge: 61), "UPS not answering over USB for 1 min 01 s"), .warning)
        XCTAssertNil(assess(fine(), hidAge: 61, staleAfter: 90).first { $0.text.hasPrefix("UPS not answering") }, "the threshold follows the read interval")
        XCTAssertEqual(level(assess(fine(), hidAge: nil), "UPS details not read yet"), .info)
        XCTAssertEqual(level(assess(fine(), hidAttached: false), "UPS is listed by macOS but not reachable over USB HID"), .warning)
    }

    func testMacsOwnBattery() {
        let low = PowerSources.InternalBattery(percent: 15, isCharging: false, onAC: false)
        XCTAssertEqual(level(assess(fine(), internalBattery: low), "Mac's own battery at 15 %"), .warning)
        let charging = PowerSources.InternalBattery(percent: 80, isCharging: true, onAC: true)
        XCTAssertEqual(level(assess(fine(), internalBattery: charging), "Mac's own battery at 80 %, charging"), .good)
    }

    func testOverallAndHeadline() {
        let items = [Health.Item(.good, "a"), Health.Item(.info, "b"), Health.Item(.warning, "c"), Health.Item(.warning, "d")]
        XCTAssertEqual(Health.overall(items), .warning)
        XCTAssertEqual(Health.headline(items)?.text, "c", "the first at the top level")
        XCTAssertNil(Health.headline([Health.Item(.good, "a"), Health.Item(.info, "b")]), "notes colour nothing")
        XCTAssertEqual(Health.overall([]), .good)
    }
}
