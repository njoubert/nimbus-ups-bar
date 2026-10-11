// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit

/// The Events display reads the log's own sentences. These are lines the guard and the app
/// really write (several from the 2026-10-11 plug-pull), each with the kind it must show as.
final class LogEventTests: XCTestCase {
    func testRealLinesClassify() {
        let cases: [(String, LogEvent.Kind)] = [
            ("transfer to battery: CP1500PFCLCDa, on battery, 100 %, runtime 1 h 6 min, load 105 W, battery 25.6 V; mounted: Flitslig", .outage),
            ("on battery 1 min 02 s: CP1500PFCLCDa, on battery, 78 %, runtime 52 min 19 s, load 105 W, battery 24.5 V; mounted: Flitslig", .progress),
            ("soft stage (10 min on battery): asking apps to quit, then unmounting", .stage),
            ("asked to quit: Adobe Lightroom Classic (holding Flitslig)", .apps),
            ("no app holds Flitslig: unmounting", .apps),
            ("hard limit (charge at 50 %): unmounting Flitslig regardless of apps", .stage),
            ("unmounted Flitslig (disk9s1)", .volume),
            ("every protected volume is unmounted", .volume),
            ("the volumes are safe (power down once safe): put the mac to sleep", .stage),
            ("line power is back; standing down in 30 s unless it fails again", .power),
            ("outage over after 12 min 4 s: line power is back", .power),
            ("remounted Flitslig (disk9s1)", .volume),
            ("unmount of Flitslig failed: dissented by smbd; retrying every 10 s", .problem),
            ("a HID read started 12 s ago has not returned; starting another", .problem),
            ("UPS attached over USB HID", .ups),
            ("the UPS has not been seen for 22 s on line power", .ups),
            ("[rehearsal] REHEARSAL: would force-unmount Flitslig (disk9s1)", .simulation),
            ("rehearsal started at 10× speed: battery drains, battery good for 40 min", .simulation),
            ("Nimbus UPS Bar started: /Applications/Nimbus UPS Bar.app; policy …", .app),
            ("guard armed: 1 external volume mounted", .app),
            ("Nimbus UPS Bar quit", .app),
            ("something nobody wrote a rule for", .other),
        ]
        for (line, kind) in cases { XCTAssertEqual(LogEvent.kind(of: line), kind, line) }
        XCTAssertTrue(LogEvent.Kind.progress.isRoutine)
        XCTAssertFalse(LogEvent.Kind.outage.isRoutine)
    }

    func testParseTheLogFile() {
        let text = """
        23 s on line power
        2026-10-11 13:23:35 line power is back; standing down in 30 s unless it fails again
        2026-10-11 13:24:06 outage over after 6 min 44 s: line power is back

        not a log line at all
        2026-10-11 13:24:44 transfer to battery: CP1500PFCLCDa, on battery, 67 %
        """
        let lines = LogEvent.parse(text)
        XCTAssertEqual(lines.map(\.1), ["line power is back; standing down in 30 s unless it fails again",
                                         "outage over after 6 min 44 s: line power is back",
                                         "transfer to battery: CP1500PFCLCDa, on battery, 67 %"])
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: lines[2].0)
        XCTAssertEqual([c.hour, c.minute, c.second], [13, 24, 44])
    }
}
