// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UpsGuardCore

/// How the guard's `Carryover` is kept between one copy of the app and the next: as JSON in
/// UserDefaults beside `outageStartedAt`, stamped with the wall-clock time it was saved, and
/// dropped when it is older than `maxAge` (the same twelve hours as the outage's start time).
/// Pure, so the round trip and the staleness rule are tested without a desk.
public enum CarryoverStore {
    public static let key = "guardCarryover"
    public static let maxAge: TimeInterval = 12 * 3600

    private struct Saved: Codable {
        var savedAt: Date
        var carryover: Carryover
    }

    /// The bytes to store, or nil when there is nothing to carry (the key is then removed).
    public static func encode(_ c: Carryover, at date: Date) -> Data? {
        guard !c.isEmpty else { return nil }
        return try? JSONEncoder().encode(Saved(savedAt: date, carryover: c))
    }

    /// What the previous copy left, or nil when nothing was saved, it cannot be read, it is
    /// empty, or it was saved more than `maxAge` ago (or in the future: the clock moved).
    public static func decode(_ data: Data?, now: Date) -> Carryover? {
        guard let data, let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        let age = now.timeIntervalSince(saved.savedAt)
        guard age >= 0, age < maxAge, !saved.carryover.isEmpty else { return nil }
        return saved.carryover
    }
}
