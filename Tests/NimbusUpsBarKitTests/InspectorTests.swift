// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
@testable import UpsGuardCore

/// The Inspector's sections against the CP1500 fixture: every element shows as a row with its
/// address, the JSON an agent is handed parses back and carries the raw values, and the diff
/// that feeds the flash and the change log reports exactly what moved.
final class InspectorTests: XCTestCase {

    func fixture() throws -> UPSHID.RawReport {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cp1500pfclcda", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(UPSHID.RawReport.self, from: Data(contentsOf: url))
    }

    func parse(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testUPSSectionShowsEveryElementWithItsAddress() throws {
        let raw = try fixture()
        let report = UPSHID.decode(raw, now: 0)
        let s = Inspector.ups(raw: raw, report: report, readAge: 0.4, attached: true)
        XCTAssertEqual(s.rows.count, report.fields.count)
        XCTAssertEqual(Set(s.rows.compactMap(\.group)), Set(report.fields.map(\.section)))
        let charge = try XCTUnwrap(s.rows.first { $0.group == "Battery" && $0.label == "Charge" })
        XCTAssertEqual(charge.value, "100 %")
        XCTAssertEqual(charge.detail, "0x24 · 0x85/0x66 = 100")
        XCTAssertTrue(s.subtitle.hasPrefix("\(report.fields.count) elements · read just now in"))
    }

    func testUPSJSONCarriesDecodedFieldsAndRawValues() throws {
        let raw = try fixture()
        let s = Inspector.ups(raw: raw, report: UPSHID.decode(raw, now: 0), readAge: 2, attached: true)
        let j = try parse(Inspector.json(s.json))
        XCTAssertEqual((j["rawValues"] as? [Any])?.count, 58, "every element as read, string indexes included")
        XCTAssertEqual(j["product"] as? String, "CP1500PFCLCDa")
        let decoded = try XCTUnwrap(j["decoded"] as? [String: Any])
        XCTAssertEqual(decoded["ratedWatts"] as? Double, 1000)
        XCTAssertEqual(decoded["flags"] as? [String], ["acPresent", "fullyCharged"])
        let first = try XCTUnwrap((j["fields"] as? [[String: Any]])?.first)
        XCTAssertNotNil(first["page"] as? String)
        XCTAssertNotNil(first["raw"] as? Int)
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
