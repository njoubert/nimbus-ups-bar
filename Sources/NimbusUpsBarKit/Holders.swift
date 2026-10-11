// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import UpsGuardCore

/// Who has files open on a volume, and how to ask them to leave.
///
/// `proc_listpidspath` with `PROC_LISTPIDSPATH_PATH_IS_VOLUME` is what `lsof` uses under the
/// hood for exactly this question: every pid with a file open on the volume, in about 60 ms,
/// with no subprocess. Each pid is mapped to its executable with `proc_pidpath`, and to an
/// app through the `.app/` component of that path plus `NSRunningApplication` for the bundle
/// id and display name.
public enum Holders {

    /// Processes with a file open on `mountPoint`, this process excluded.
    public static func list(mountPoint: String) -> [Holder] {
        let flags = UInt32(PROC_LISTPIDSPATH_PATH_IS_VOLUME | PROC_LISTPIDSPATH_EXCLUDE_EVTONLY)
        var buf = [pid_t](repeating: 0, count: 4096)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, mountPoint, flags, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        let me = getpid()
        var out: [Holder] = []
        for pid in buf.prefix(count) where pid > 0 && pid != me {
            var pathBuf = [CChar](repeating: 0, count: 4096)
            let n = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let exe = n > 0 ? String(cString: pathBuf) : "pid \(pid)"
            out.append(describe(pid: pid, executable: exe))
        }
        return out.sorted { ($0.appName ?? "~", $0.pid) < ($1.appName ?? "~", $1.pid) }
    }

    /// The `.app` bundle a path lives in, if any: `/Applications/Foo.app/Contents/MacOS/foo`
    /// gives `Foo`. Helper processes inside another app's bundle resolve to the outermost
    /// app, which is the one that owns the Quit menu.
    public static func describe(pid: pid_t, executable: String) -> Holder {
        var holder = Holder(pid: pid, executable: executable)
        // Dock, Spotlight, Control Center and friends live in .app bundles under /System but
        // are not apps anyone quits; they are left alone like daemons.
        if executable.hasPrefix("/System/") { return holder }
        if let r = executable.range(of: ".app/") {
            let bundlePath = String(executable[..<r.lowerBound]) + ".app"
            holder.appName = (bundlePath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            holder.bundleID = Bundle(path: bundlePath)?.bundleIdentifier
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            if let n = app.localizedName, !n.isEmpty { holder.appName = holder.appName ?? n }
            holder.bundleID = holder.bundleID ?? app.bundleIdentifier
        }
        return holder
    }

    /// Ask an app to quit the way its Quit menu item does: a quit Apple event, which gives it
    /// the chance to save (or to put up its own "unsaved changes" dialog and refuse). This
    /// needs no Automation permission; the required-suite events are exempt. Never kills.
    @MainActor
    public static func requestQuit(_ holder: Holder) -> Bool {
        // By the owning app's bundle id first: the holding process is often a helper (a
        // Chromium renderer, an Electron utility process) with a LaunchServices registration
        // of its own, and terminating that only makes the parent relaunch it. The app the
        // Quit menu belongs to is the one `describe` resolved from the outer .app.
        if let bid = holder.bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return app.terminate()
        }
        if let app = NSRunningApplication(processIdentifier: holder.pid), app.bundleIdentifier != nil {
            return app.terminate()
        }
        // Not a LaunchServices-registered app at all: ask by bundle id through AppleScript if
        // we have one; daemons are left alone.
        guard let bid = holder.bundleID else { return false }
        let script = NSAppleScript(source: "tell application id \"\(bid)\" to quit")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }
}
