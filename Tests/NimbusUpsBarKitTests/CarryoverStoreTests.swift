// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit
import UpsGuardCore

/// What a relaunched copy finds of the previous one's unfinished work (QA 2026-10-11, M1):
/// without it a crash restart mid-outage never remounted the drives it had unmounted.
final class CarryoverStoreTests: XCTestCase {
    let saved = Date(timeIntervalSince1970: 1_791_000_000)
    let carried = Carryover(unmounted: ["B2D16C3E-2857-443F-A983-9442CF1686AE": "Flitslig"], askedAt: ["com.adobe.LightroomClassic": 121])

    func testRoundTrip() {
        let data = CarryoverStore.encode(carried, at: saved)
        XCTAssertNotNil(data)
        XCTAssertEqual(CarryoverStore.decode(data, now: saved.addingTimeInterval(30)), carried)
    }

    func testNothingToCarryIsNotStored() {
        XCTAssertNil(CarryoverStore.encode(Carryover(), at: saved), "an empty carryover removes the key")
    }

    func testStaleOrUnreadableIsDropped() {
        let data = CarryoverStore.encode(carried, at: saved)
        XCTAssertNotNil(CarryoverStore.decode(data, now: saved.addingTimeInterval(11 * 3600)))
        XCTAssertNil(CarryoverStore.decode(data, now: saved.addingTimeInterval(12 * 3600)), "twelve hours on, it is history")
        XCTAssertNil(CarryoverStore.decode(data, now: saved.addingTimeInterval(-60)), "saved in the future: the clock moved")
        XCTAssertNil(CarryoverStore.decode(nil, now: saved))
        XCTAssertNil(CarryoverStore.decode(Data("not json".utf8), now: saved))
    }
}
