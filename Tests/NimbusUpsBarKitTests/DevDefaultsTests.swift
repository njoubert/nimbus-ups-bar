// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit

/// The development bundle's first run copies the owner's settings across from the release's
/// domain, and never the installed copy's outage.
final class DevDefaultsTests: XCTestCase {
    let leaving: Set = ["outageStartedAt", CarryoverStore.key, "agentRegistered"]

    /// The shape of the release's domain on this desk, 2026-10-11 (a few of its keys).
    let releaseDomain: [String: Any] = [
        "softTime": 1800.0, "softTimeOn": true, "hardCharge": 50.0, "powerDownAction": "sleep",
        "neverQuit": ["com.apple.Terminal"], "knownVolumes": [["uuid": "A1", "name": "Flitslig", "detail": "USB"]],
        "agentRegistered": true, "outageStartedAt": 1_791_774_000.0, "guardCarryover": Data([1, 2, 3]),
    ]

    func testFirstRunCopiesThePreferencesAndNotTheOutage() throws {
        let seed = try XCTUnwrap(DevDefaults.seed(release: releaseDomain, dev: [:], leaving: leaving))
        XCTAssertEqual(Set(seed.keys), ["softTime", "softTimeOn", "hardCharge", "powerDownAction", "neverQuit", "knownVolumes", DevDefaults.seededKey])
        XCTAssertEqual(seed["softTime"] as? Double, 1800)
        XCTAssertNil(seed["guardCarryover"], "a dev copy must not remount what the installed copy unmounted")
        XCTAssertNil(seed["outageStartedAt"])
        XCTAssertNil(seed["agentRegistered"])
    }

    func testOnlyOnce() {
        XCTAssertNil(DevDefaults.seed(release: releaseDomain, dev: [DevDefaults.seededKey: true], leaving: leaving))
    }

    func testTheDevCopysOwnValuesWin() throws {
        let seed = try XCTUnwrap(DevDefaults.seed(release: releaseDomain, dev: ["softTime": 600.0], leaving: leaving))
        XCTAssertNil(seed["softTime"])
        XCTAssertEqual(seed["hardCharge"] as? Double, 50)
    }

    func testNoReleaseDomainStillMarksItDone() {
        XCTAssertEqual(DevDefaults.seed(release: nil, dev: [:], leaving: leaving)?.keys.sorted(), [DevDefaults.seededKey])
    }
}
