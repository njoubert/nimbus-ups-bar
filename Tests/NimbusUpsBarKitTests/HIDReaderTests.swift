// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import NimbusUpsBarKit

/// A UPS read that never returns (QA 2026-10-11, M4). Before, every read sat on one serial
/// queue, so one wedged USB transaction stopped every later read until a relaunch.
final class HIDReaderTests: XCTestCase {

    func testATimelyReadIsDeliveredAndTheNextWaitsForIt() {
        var g = HIDReadGate()
        XCTAssertEqual(g.begin(now: 0), .start(seq: 1, abandoned: nil, reopen: false))
        XCTAssertEqual(g.begin(now: 5), .busy, "one read at a time")
        XCTAssertTrue(g.finish(seq: 1))
        XCTAssertEqual(g.begin(now: 6), .start(seq: 2, abandoned: nil, reopen: false))
    }

    func testAnOverdueReadIsWrittenOffAndItsLateResultDropped() {
        var g = HIDReadGate()
        _ = g.begin(now: 0)
        XCTAssertEqual(g.begin(now: 9.9), .busy)
        XCTAssertEqual(g.begin(now: 10), .start(seq: 2, abandoned: 1, reopen: true), "the next read does not queue behind it, and has a device object of its own")
        XCTAssertFalse(g.finish(seq: 1), "late: dropped")
        XCTAssertEqual(g.dropped, 1)
        XCTAssertTrue(g.finish(seq: 2))
        XCTAssertEqual(g.consecutiveAbandoned, 0, "a read that came back in time starts the count over")
    }

    func testEveryWriteOffReopensAndThreeStuckStopStarting() {
        var g = HIDReadGate()
        _ = g.begin(now: 0)
        XCTAssertEqual(g.begin(now: 10), .start(seq: 2, abandoned: 1, reopen: true))
        XCTAssertEqual(g.begin(now: 20), .start(seq: 3, abandoned: 2, reopen: true))
        XCTAssertEqual(g.reopens, 2)
        XCTAssertEqual(g.consecutiveAbandoned, 2)
        XCTAssertEqual(g.begin(now: 30), .stuck(count: 3), "each stuck read holds a thread: no fourth")
        XCTAssertEqual(g.begin(now: 40), .stuck(count: 3))
        XCTAssertFalse(g.finish(seq: 1), "one of them comes back at last")
        XCTAssertEqual(g.begin(now: 41), .start(seq: 4, abandoned: nil, reopen: false))
        XCTAssertEqual(g.abandoned, 3)
    }

    /// The reader on real threads: the first two reads hang, each write-off opens the device
    /// afresh, and the third read is delivered while the two stuck ones are still out.
    @MainActor
    func testTheThirdReadSucceedsBesideTwoStuckOnes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cp1500pfclcda", withExtension: "json", subdirectory: "Fixtures"))
        let raw = try JSONDecoder().decode(UPSHID.RawReport.self, from: Data(contentsOf: url))
        let hang = DispatchSemaphore(value: 0)
        let calls = Counter(), reopens = Counter()
        let reader = HIDReader(fetch: { _ in
            if calls.next() <= 2 { hang.wait() }
            return raw
        }, reopen: { reopens.next(); return true })
        var lines: [String] = []
        reader.log = { lines.append($0) }
        var delivered: [Int] = []
        reader.read(full: false, now: 0) { _ in delivered.append(1) }
        reader.read(full: false, now: 10) { _ in delivered.append(2) }
        let third = expectation(description: "the third read comes back")
        let d = reader.read(full: false, now: 20) { r in delivered.append(3); XCTAssertEqual(r, raw); third.fulfill() }
        XCTAssertEqual(d, .start(seq: 3, abandoned: 2, reopen: true))
        wait(for: [third], timeout: 5)
        XCTAssertEqual(reopens.value, 2)
        XCTAssertEqual(delivered, [3])
        XCTAssertTrue(lines.contains { $0.contains("opens the UPS afresh") }, "\(lines)")
        // The stuck reads come back at last: dropped, not delivered.
        hang.signal(); hang.signal()
        let deadline = Date().addingTimeInterval(5)
        while reader.gate.dropped < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(reader.gate.dropped, 2)
        XCTAssertEqual(delivered, [3])
    }
}

/// A thread-safe counter for the fakes.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func next() -> Int { lock.withLock { n += 1; return n } }
    var value: Int { lock.withLock { n } }
}
