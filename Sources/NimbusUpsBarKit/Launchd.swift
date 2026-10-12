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

    /// Why launchd's last attempt to start the job failed, or nil if it did not: the job is not
    /// running and its last exit code is not 0. That is a spawn launchd gave up on, not a quit
    /// (exit 0, the menu's Quit or the newest copy taking over) and not a crash (a signal, which
    /// KeepAlive restarts). On 2026-10-11 the installed copy's agent sat at "spawn scheduled",
    /// "last exit code = 78: EX_CONFIG" after every login: a development copy with the same
    /// bundle identifier had taken over its Login Items record.
    public static func startFailure(_ text: String?) -> String? {
        let job = Dictionary(parse(text), uniquingKeysWith: { a, _ in a })
        guard let state = job["state"], state != "running",
              let exit = job["last exit code"], let code = Int(exit.prefix { $0 != ":" }), code != 0 else { return nil }
        return "exit code \(exit)"
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
