// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpsBarKit
import os

/// Every decision, reading and action, in one readable file:
/// `~/Library/Logs/Nimbus UPS Bar/ups-bar.log`. The same lines go to the unified log
/// (`log stream --predicate 'subsystem == "com.njoubert.nimbusupsbar"'`) and to a short ring
/// the Inspector shows under Events.
@MainActor
final class Log {
    static let shared = Log()

    struct Entry: Equatable {
        let date: Date
        let line: String
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Nimbus UPS Bar", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("ups-bar.log")
    /// Rotate once the file passes this; one older copy is kept as `ups-bar.log.1`.
    static let rotateAt = 8 * 1024 * 1024
    static let ringSize = 1000

    private(set) var recent: [Entry] = []
    var onAppend: (() -> Void)?
    /// `--watch` and `--simulate` print to the terminal too.
    var echoToStderr = false
    /// Only the app and the long-running CLI modes write the file; a `--print` must not leave
    /// "started" lines in the app's log.
    var persistToFile = false
    private let os = Logger(subsystem: "com.njoubert.nimbusupsbar", category: "guard")
    private lazy var handle: FileHandle? = openFile()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let didAppend = Notification.Name("com.njoubert.nimbusupsbar.logAppended")

    func append(_ line: String) {
        defer { NotificationCenter.default.post(name: Log.didAppend, object: nil) }
        let now = Date()
        recent.append(Entry(date: now, line: line))
        if recent.count > Log.ringSize { recent.removeFirst(recent.count - Log.ringSize) }
        os.log("\(line, privacy: .public)")
        let text = "\(stamp.string(from: now)) \(line)\n"
        if echoToStderr { FileHandle.standardError.write(text.data(using: .utf8)!) }
        if persistToFile, let h = handle, let data = text.data(using: .utf8) {
            h.write(data)
            if let size = try? h.offset(), size > Log.rotateAt { rotate() }
        }
        onAppend?()
    }

    private func openFile() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Log.fileURL.path) { fm.createFile(atPath: Log.fileURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: Log.fileURL) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }

    private func rotate() {
        try? handle?.close()
        let old = Log.directory.appendingPathComponent("ups-bar.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: Log.fileURL, to: old)
        handle = openFile()
    }
}
