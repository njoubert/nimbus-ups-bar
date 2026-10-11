// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What launchd knows about the agent's job: `launchctl print gui/<uid>/<label>`, reduced to the
/// lines worth showing. Not loaded (never enabled, or disabled) is a nil text.
public enum LaunchdJob {
    public struct Info {
        public var text: String?
        public var checkedAt: Date?
        public init(text: String?, checkedAt: Date?) { self.text = text; self.checkedAt = checkedAt }
    }

    public static func print(label: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", "gui/\(getuid())/\(label)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The top-level "key = value" lines that say whether the job is healthy.
    public static func parse(_ text: String?) -> [(String, String)] {
        guard let text else { return [] }
        let wanted = ["state", "pid", "runs", "last exit code", "last terminating signal", "program", "path", "active count", "immediate reason"]
        var out: [(String, String)] = []
        for line in text.split(separator: "\n") {
            // Top-level properties sit one tab in; nested dictionaries are deeper.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
            guard parts.count == 2, wanted.contains(parts[0]), !out.contains(where: { $0.0 == parts[0] }) else { continue }
            out.append((parts[0], parts[1]))
        }
        return out
    }
}
