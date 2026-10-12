// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// When a UPS read over USB may start, when one that has not come back is written off, and
/// when the device is closed and opened again. Pure, so the recovery from a wedged read is
/// tested without a UPS that misbehaves on demand.
///
/// A read that wedges inside `IOHIDDeviceGetValueWithOptions` may never return. Before
/// 2026-10-11 every read ran on one serial queue, so the next read waited behind the stuck
/// one for the life of the process: load, voltages, the UPS's alarms and the shutdown-imminent
/// flag were gone until a relaunch (QA 2026-10-11, M4). Now a read overdue by `abandonAfter`
/// is written off and the next one starts beside it, through a freshly opened device object
/// (`UPSHID.reopen`), so two reads never share one and the stuck one is never closed under its
/// thread; with `maxStuck` threads still stuck nothing more is started (each holds a thread)
/// until one of them comes back.
public struct HIDReadGate: Equatable, Sendable {
    public static let abandonAfter: TimeInterval = 10
    public static let maxStuck = 3

    public enum Decision: Equatable, Sendable {
        /// A read is in flight and not overdue: wait for it.
        case busy
        /// Start read `seq`. `abandoned`: the overdue read written off to make room for it.
        /// `reopen`: open the device afresh before reading (always after a write-off).
        case start(seq: Int, abandoned: Int?, reopen: Bool)
        /// This many written-off reads have not come back: start nothing.
        case stuck(count: Int)
    }

    /// The read in flight and when it started.
    public private(set) var currentSeq: Int?
    public private(set) var currentAt: TimeInterval?
    /// Reads written off that have not returned: each still holds a thread.
    public private(set) var stuck: Set<Int> = []
    public private(set) var sequence = 0
    /// Written off since the last read that came back in time.
    public private(set) var consecutiveAbandoned = 0
    /// Since launch, for the Inspector.
    public private(set) var abandoned = 0
    public private(set) var dropped = 0
    public private(set) var reopens = 0

    public init() {}

    public mutating func begin(now: TimeInterval) -> Decision {
        var writtenOff: Int?
        if let seq = currentSeq, let at = currentAt {
            if now - at < Self.abandonAfter { return .busy }
            stuck.insert(seq)
            writtenOff = seq
            currentSeq = nil
            currentAt = nil
            consecutiveAbandoned += 1
            abandoned += 1
        }
        if stuck.count >= Self.maxStuck { return .stuck(count: stuck.count) }
        let reopen = writtenOff != nil
        if reopen { reopens += 1 }
        sequence += 1
        currentSeq = sequence
        currentAt = now
        return .start(seq: sequence, abandoned: writtenOff, reopen: reopen)
    }

    /// Read `seq` came back. True when its result is wanted (it is the read in flight); a
    /// written-off read's result is dropped, and its thread counts as free again.
    public mutating func finish(seq: Int) -> Bool {
        if seq == currentSeq {
            currentSeq = nil
            currentAt = nil
            consecutiveAbandoned = 0
            return true
        }
        if stuck.remove(seq) != nil { dropped += 1 }
        return false
    }
}

/// Runs the UPS reads off the main thread under a `HIDReadGate`: each read on a thread of
/// its own (a concurrent queue, so a stuck read holds up nothing behind it), its result back
/// on the main thread if it is still wanted. `fetch` and `reopen` are `UPSHID`'s in the app,
/// fakes in the tests.
@MainActor
public final class HIDReader {
    public private(set) var gate = HIDReadGate()
    /// Where the reader says what it did about a stuck read (the app's log).
    public var log: (String) -> Void = { _ in }
    private let fetch: @Sendable (Bool) -> UPSHID.RawReport?
    private let reopen: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "com.njoubert.nimbusupsbar.hid", qos: .utility, attributes: .concurrent)
    private var saidStuck = false

    public init(fetch: @escaping @Sendable (Bool) -> UPSHID.RawReport?, reopen: @escaping @Sendable () -> Bool) {
        self.fetch = fetch
        self.reopen = reopen
    }

    /// Start a read if the gate allows one; `done` runs on the main thread with its result
    /// (nil: nothing read) unless the read was written off first.
    @discardableResult
    public func read(full: Bool, now: TimeInterval, done: @escaping @MainActor (UPSHID.RawReport?) -> Void) -> HIDReadGate.Decision {
        let decision = gate.begin(now: now)
        switch decision {
        case .busy:
            break
        case .stuck(let count):
            if !saidStuck {
                saidStuck = true
                log("\(count) HID reads have not returned: starting no more until one does (the guard runs on macOS's own figures meanwhile)")
            }
        case .start(let seq, let writtenOff, let reopenFirst):
            saidStuck = false
            if writtenOff != nil {
                log("a HID read has not returned after \(Int(HIDReadGate.abandonAfter)) s (\(gate.consecutiveAbandoned) in a row): written off; the next read opens the UPS afresh beside it")
            }
            let fetch = self.fetch, reopen = self.reopen
            queue.async {
                if reopenFirst, !reopen() {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.log("reopening the UPS device failed") } }
                }
                let raw = fetch(full)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if self.gate.finish(seq: seq) { done(raw) }
                    }
                }
            }
        }
        return decision
    }
}
