// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What a log line is about, for the Inspector's Events: an icon, a colour and whether it is
/// routine. The log is prose written for people, so this reads the same words a person would;
/// a line it does not recognise is `other`, never dropped.
public enum LogEvent {
    public enum Kind: String, CaseIterable, Sendable {
        case outage, power, stage, apps, volume, ups, problem, simulation, app, progress, other

        public var title: String {
            switch self {
            case .outage: return "Outage"
            case .power: return "Power back"
            case .stage: return "Stage"
            case .apps: return "Apps"
            case .volume: return "Volume"
            case .ups: return "UPS"
            case .problem: return "Problem"
            case .simulation: return "Simulation"
            case .app: return "App"
            case .progress: return "Progress"
            case .other: return "Other"
            }
        }

        public var symbol: String {
            switch self {
            case .outage: return "bolt.slash.fill"
            case .power: return "bolt.fill"
            case .stage: return "exclamationmark.triangle.fill"
            case .apps: return "app.badge"
            case .volume: return "externaldrive.fill"
            case .ups: return "powerplug"
            case .problem: return "xmark.octagon.fill"
            case .simulation: return "theatermasks"
            case .app: return "gearshape"
            case .progress: return "clock"
            case .other: return "text.alignleft"
            }
        }

        /// Shown only when asked for: the once-a-minute progress line during an outage.
        public var isRoutine: Bool { self == .progress }
    }

    /// The log file's lines as (time, text), oldest first: "2026-10-11 13:17:23 transfer to
    /// battery: …". A line without the stamp (a partial first line from a tail, a stray
    /// continuation) is skipped.
    public static func parse(_ text: String) -> [(Date, String)] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out: [(Date, String)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard raw.count > 20, raw[raw.index(raw.startIndex, offsetBy: 19)] == " ",
                  let d = f.date(from: String(raw.prefix(19))) else { continue }
            out.append((d, String(raw.dropFirst(20))))
        }
        return out
    }

    public static func kind(of line: String) -> Kind {
        let l = line.lowercased()
        func has(_ words: String...) -> Bool { words.contains { l.contains($0) } }
        if l.hasPrefix("[rehearsal]") || l.hasPrefix("[drill]") || l.hasPrefix("rehearsal") || l.hasPrefix("drill") { return .simulation }
        if l.range(of: #"^on battery \d"#, options: .regularExpression) != nil { return .progress }
        if has("failed", "will not", "not answering", "has not returned", "error", "refused") { return .problem }
        if has("transfer to battery", "resuming an outage", "blind outage") { return .outage }
        if has("outage over", "line power is back", "line power failed again") { return .power }
        if has("soft stage", "hard limit", "power-down trigger", "the volumes are safe", "still mounted", "owner asked", "owner postponed",
               ": put the mac to sleep", ": shut the mac down") { return .stage }
        if has("asked to quit", "waiting for", "did not quit", "no app holds") { return .apps }
        if has("unmounted", "remounted", "is mounted again", "every protected volume", "nothing mounted") { return .volume }
        if has("ups attached", "ups detached", "the ups has", "the ups is back", "ups not seen", "not been seen") { return .ups }
        if has("started", " quit", "guard armed", "background agent", "update", "settings") { return .app }
        return .other
    }
}
