// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
@testable import UpsGuardCore

/// The Inspector's sections against the CP1500 fixture: every element shows as a row with its
/// address, the JSON an agent is handed parses back and carries the raw values, and the diff
/// that feeds the flash and the change log reports exactly what moved.
final class InspectorTests: XCTestCase {

    func fixture(_ name: String = "cp1500pfclcda") throws -> UPSHID.RawReport {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(UPSHID.RawReport.self, from: Data(contentsOf: url))
    }

    func parse(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testUPSPageShowsEveryElementOfAnOldCapture() throws {
        // The 2026-10-10 capture: values only. All 58 show, the string slots included.
        let raw = try fixture()
        let s = Inspector.ups(raw: raw, report: UPSHID.decode(raw, now: 0), readAge: 0.4, attached: true)
        XCTAssertEqual(s.rows.count, 58)
        XCTAssertTrue(s.rows.allSatisfy { $0.group?.hasPrefix("Elements › ") == true })
        let charge = try XCTUnwrap(s.rows.first { $0.group == "Elements › Battery" && $0.label == "Charge" })
        XCTAssertEqual(charge.value, "100 %")
        XCTAssertTrue(charge.detail?.contains("0x24 · 0x85/0x66 = 100") == true)
        XCTAssertTrue(s.rows.contains { $0.value.hasPrefix("string slot ") })
        XCTAssertTrue(s.subtitle.hasPrefix("58 elements · the routine read"))
    }

    func testUPSPageShowsTheWholeFullCapture() throws {
        // The 2026-10-11 full capture: 158 elements (4 whose read fails), 10 collections,
        // 76 reports, the descriptor and 47 properties. Every one is a row with its own key.
        let raw = try fixture("cp1500pfclcda-full")
        let s = Inspector.ups(raw: raw, report: UPSHID.decode(raw, now: 0), readAge: 1, attached: true)
        func count(_ prefix: String) -> Int { s.rows.filter { $0.group?.hasPrefix(prefix) == true }.count }
        XCTAssertEqual(count("Elements"), 158)
        XCTAssertEqual(count("Collections"), 10)
        XCTAssertEqual(count("Reports"), 76)
        XCTAssertEqual(count("Report descriptor"), 1)
        XCTAssertEqual(count("Device properties"), 47)
        XCTAssertEqual(s.rows.count, 158 + 10 + 76 + 1 + 47)
        XCTAssertEqual(Set(s.rows.map(\.key)).count, s.rows.count, "the feature and input copies of a usage are separate rows")
        XCTAssertEqual(s.rows.filter { $0.value == "read failed (0xE0005000)" }.count, 4)
        XCTAssertTrue(s.rows.contains { $0.label == "Charge (input-misc)" || $0.label == "Charge (input-button)" || $0.label.hasPrefix("Charge (") })
        XCTAssertTrue(s.subtitle.hasPrefix("158 elements (4 failed) · 10 collections · 76 reports · read just now in"))
    }

    func testUPSJSONIsTheCaptureItself() throws {
        for name in ["cp1500pfclcda", "cp1500pfclcda-full"] {
            let raw = try fixture(name)
            let s = Inspector.ups(raw: raw, report: UPSHID.decode(raw, now: 0), readAge: 2, attached: true)
            let j = try parse(Inspector.json(s.json))
            let capture = try XCTUnwrap(j["capture"])
            let back = try JSONDecoder().decode(UPSHID.RawReport.self, from: JSONSerialization.data(withJSONObject: capture))
            XCTAssertEqual(back, raw, "\(name): what Copy Page hands an agent is exactly what was read")
            let decoded = try XCTUnwrap(j["decoded"] as? [String: Any])
            XCTAssertEqual(decoded["ratedWatts"] as? Double, 1000)
        }
    }

    func testUPSSectionWithoutAReport() {
        let s = Inspector.ups(raw: nil, report: nil, readAge: nil, attached: false)
        XCTAssertTrue(s.rows.isEmpty)
        XCTAssertEqual(s.subtitle, "UPS not reachable over USB HID")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(s.json))
    }

    func testJSONIsSortedAndStable() throws {
        let text = Inspector.json(["b": 1, "a": ["z": NSNull(), "y": "/Volumes/Flitslig"]])
        XCTAssertEqual(text, """
        {
          "a" : {
            "y" : "/Volumes/Flitslig",
            "z" : null
          },
          "b" : 1
        }
        """)
        XCTAssertEqual(Inspector.json(Double.nan), "{}", "not a JSON object: an empty one, never a crash")
    }

    func testChangesReportWhatMovedAppearedAndWent() {
        let a = Inspector.Section(id: "ups", title: "", symbol: "", rows: [Inspector.Row(group: "Battery", "Charge", "100 %"),
                                                                              Inspector.Row(group: "Battery", "Voltage", "27.1 V"),
                                                                              Inspector.Row("Gone", "x")], json: [:])
        let b = Inspector.Section(id: "ups", title: "", symbol: "", rows: [Inspector.Row(group: "Battery", "Charge", "78 %"),
                                                                              Inspector.Row(group: "Battery", "Voltage", "27.1 V"),
                                                                              Inspector.Row("New", "y")], json: [:])
        let at = Date(timeIntervalSince1970: 0)
        let c = Inspector.changes(from: Inspector.flatten([a]), to: Inspector.flatten([b]), at: at)
        XCTAssertEqual(c, [
            Inspector.Change(at: at, section: "ups", key: "Battery › Charge", old: "100 %", new: "78 %"),
            Inspector.Change(at: at, section: "ups", key: "Gone", old: "x", new: nil),
            Inspector.Change(at: at, section: "ups", key: "New", old: nil, new: "y"),
        ])
        XCTAssertTrue(Inspector.changes(from: Inspector.flatten([a]), to: Inspector.flatten([a]), at: at).isEmpty)
    }

    func testHealthSectionLevelsAndSubtitle() throws {
        let items = [Health.Item(.good, "Battery at 100 %"), Health.Item(.warning, "No load on the battery outlets", "detail", short: "nothing on battery outlets")]
        let s = Inspector.health(items)
        XCTAssertEqual(s.rows.map(\.level), [.good, .warning])
        XCTAssertEqual(s.subtitle, "warning: nothing on battery outlets")
        XCTAssertEqual(Inspector.health([Health.Item(.good, "fine")]).subtitle, "healthy")
        let j = try parse(Inspector.json(s.json))
        XCTAssertEqual(j["overall"] as? String, "warning")
    }

    func testGuardSectionCarriesStateAndPolicy() throws {
        var st = OutageGuard.Status()
        st.phase = .soft
        st.outageStart = 10
        st.elapsed = 130
        st.untilHard = 170
        st.waitingFor = ["Adobe Lightroom Classic"]
        let s = Inspector.guardian(st, policy: Policy(), simulation: nil)
        XCTAssertEqual(s.rows.first { $0.label == "Phase" }?.value, "Closing apps")
        XCTAssertEqual(s.rows.first { $0.label == "Next: force unmount in" }?.value, "2 min 50 s")
        XCTAssertEqual(s.subtitle, "Closing apps · 2 min 10 s on battery")
        let j = try parse(Inspector.json(s.json))
        XCTAssertEqual(j["phase"] as? String, "soft")
        XCTAssertEqual((j["policy"] as? [String: Any])?["summary"] as? String, Policy().summary)
    }

    func testVolumesSection() throws {
        let v = VolumeState(uuid: "B2D1", name: "Flitslig", bsdName: "disk9s1", mountPoint: "/Volumes/Flitslig")
        let lr = Holder(pid: 100, executable: "/Applications/Lightroom.app/Contents/MacOS/Lightroom", appName: "Lightroom", bundleID: "com.adobe.lr")
        let r = OutageGuard.VolumeReport(volume: v, appHolders: [lr], otherHolders: [], inFlight: false, unmountedByGuard: false, lastError: nil, holdersAt: 1)
        let s = Inspector.volumes([r], mode: "all external volumes")
        XCTAssertEqual(s.rows.first { $0.label == "Apps holding files" }?.value, "Lightroom")
        XCTAssertEqual(s.subtitle, "1 protected, 1 mounted · all external volumes")
        let j = try parse(Inspector.json(s.json))
        XCTAssertEqual(((j["volumes"] as? [[String: Any]])?.first?["appHolders"] as? [[String: Any]])?.first?["bundleID"] as? String, "com.adobe.lr")
    }

    func testLaunchdParse() {
        // The shape `launchctl print gui/501/<label>` prints for a loaded agent (trimmed).
        let text = """
        gui/501/com.njoubert.nimbusupsbar.agent = {
        \tactive count = 1
        \tpath = /Applications/Nimbus UPS Bar.app/Contents/Library/LaunchAgents/com.njoubert.nimbusupsbar.agent.plist
        \ttype = LaunchAgent
        \tstate = running

        \tprogram = /Applications/Nimbus UPS Bar.app/Contents/MacOS/NimbusUpsBar
        \tenvironment = {
        \t\tXPC_SERVICE_NAME => com.njoubert.nimbusupsbar.agent
        \t\tstate = nested, not ours
        \t}
        \truns = 2
        \tpid = 4242
        \timmediate reason = semaphore
        \tlast exit code = 0
        }
        """
        let job = LaunchdJob.parse(text)
        XCTAssertEqual(job.map(\.0), ["active count", "path", "state", "program", "runs", "pid", "immediate reason", "last exit code"])
        XCTAssertEqual(job.first { $0.0 == "state" }?.1, "running", "the top-level one, not the nested line")
        XCTAssertEqual(job.first { $0.0 == "pid" }?.1, "4242")
        XCTAssertTrue(LaunchdJob.parse(nil).isEmpty)
    }
}
