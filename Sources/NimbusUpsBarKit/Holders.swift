// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import UpsGuardCore

/// Who has files open on a volume, and how to ask them to leave.
///
/// `proc_listpidspath` with `PROC_LISTPIDSPATH_PATH_IS_VOLUME` is what `lsof` uses under the
/// hood for exactly this question: every pid with a file open on the volume, in about 60 ms,
/// with no subprocess. Without root it sees only this user's processes: `smbd` serving a
/// share, Spotlight's `mds_stores`, backup agents and other users' processes never appear,
/// so an empty list means "none of yours", not "nothing" (the unmount is forced either way).
///
/// A holder counts as an *app* (asked to quit, and waited for) only when LaunchServices knows
/// an application with a user interface it belongs to: the process is that application, or it
/// is a helper of one that is running (a process the app started, such as a browser renderer,
/// or one of the app's own XPC services or extensions, which launchd starts for it). Background-
/// only processes LaunchServices also lists (`sharingd`, Finder extensions, crash reporters)
/// have no Quit menu and count as daemons. Being inside an `.app` bundle
/// is not enough: Homebrew's `python3` runs from a `Python.app` and the Xcode toolchain
/// behind `/usr/bin/git` runs from `Xcode.app`, and neither is an app anyone can quit (QA
/// 2026-10-11, H2: the first was waited for and asked, the second resolved to Xcode).
public enum Holders {

    /// Processes with a file open on `mountPoint`, this process excluded.
    public static func list(mountPoint: String, world: ProcessWorld = .live) -> [Holder] {
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
            out.append(describe(pid: pid, executable: exe, world: world))
        }
        return out.sorted { ($0.appName ?? "~", $0.pid) < ($1.appName ?? "~", $1.pid) }
    }

    /// What a holding process is: an app (with the name and bundle id of the application the
    /// Quit menu belongs to) or, for everything LaunchServices does not tie to a running
    /// application, a plain process the guard never asks and never waits for.
    public static func describe(pid: pid_t, executable: String, world: ProcessWorld = .live) -> Holder {
        var holder = Holder(pid: pid, executable: executable)
        if isSystemService(executable) { return holder }
        var app: RunningApp?
        // A helper of a running app: the Quit menu is the outer app's.
        if let outer = appBundles(in: executable).first, let parent = world.applicationAt(outer), parent.pid != pid, !parent.isBackgroundOnly,
           isOwnServiceExecutable(executable, of: outer) || descends(pid, from: parent.pid, world: world) {
            app = parent
        }
        // The process is itself an application LaunchServices knows: an app's main process, or
        // a helper registered on its own whose app is not running.
        if app == nil, let own = world.application(pid), !own.isBackgroundOnly { app = own }
        guard let app else { return holder }
        let fileName = app.bundlePath.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
        holder.appName = [app.name, fileName].compactMap { $0 }.first { !$0.isEmpty } ?? "pid \(pid)"
        holder.bundleID = app.bundleID
        return holder
    }

    /// Dock, Spotlight, Control Center, Finder and friends live in .app bundles under /System
    /// (and Apple's /Library/Apple/System) but are not apps anyone quits: left alone like
    /// daemons. The user's apps that Apple ships there are apps like any other: Preview,
    /// TextEdit, QuickTime (`/System/Applications`), Archive Utility (`CoreServices/Applications`),
    /// Safari (`/System/Volumes/Preboot/Cryptexes/App/System/Applications`).
    static func isSystemService(_ executable: String) -> Bool {
        if executable.hasPrefix("/Library/Apple/") { return true }
        guard executable.hasPrefix("/System/") else { return false }
        return !executable.contains("/System/Applications/") && !executable.contains("/CoreServices/Applications/")
    }

    /// The `.app` bundles a path lies in, outermost first.
    static func appBundles(in path: String) -> [String] {
        var out: [String] = []
        var prefix = ""
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + c
            if c.hasSuffix(".app") { out.append(prefix) }
        }
        return out
    }

    /// The main executable of one of the app's own XPC services or extensions: launchd starts
    /// those for the app, so they are not its descendants. `Contents/XPCServices/*.xpc`, the
    /// XPC services of the app's own frameworks (`Contents/Frameworks/…/XPCServices/*.xpc`), and
    /// `Contents/PlugIns/*.appex`. Not anywhere else: Xcode's toolchain keeps XPC services deep
    /// in `Contents/Developer` that serve other apps too (SourceKit for VS Code).
    static func isOwnServiceExecutable(_ executable: String, of outer: String) -> Bool {
        let dir = (executable as NSString).deletingLastPathComponent
        guard dir.hasSuffix("/Contents/MacOS") else { return false }
        let bundle = String(dir.dropLast("/Contents/MacOS".count)) as NSString
        let container = bundle.deletingLastPathComponent
        switch bundle.pathExtension {
        case "xpc":
            return container == outer + "/Contents/XPCServices"
                || (container.hasPrefix(outer + "/Contents/Frameworks/") && container.hasSuffix("/XPCServices"))
        case "appex": return container == outer + "/Contents/PlugIns"
        default: return false
        }
    }

    /// Whether `ancestor` started `pid`, directly or further up.
    static func descends(_ pid: pid_t, from ancestor: pid_t, world: ProcessWorld) -> Bool {
        var cur = pid
        for _ in 0..<32 {
            guard let p = world.parent(cur), p > 1, p != cur else { return false }
            if p == ancestor { return true }
            cur = p
        }
        return false
    }

    public enum QuitRequest: Equatable, Sendable {
        /// The quit Apple event went out (the app may still refuse, or ask about unsaved work).
        case sent
        /// The application is running but the event could not be sent.
        case notSent
        /// LaunchServices knows no running application for this holder: nothing to ask.
        case notAnApp
    }

    /// Ask an app to quit the way its Quit menu item does: a quit Apple event, which gives it
    /// the chance to save (or to put up its own "unsaved changes" dialog and refuse). This
    /// needs no Automation permission; the required-suite events are exempt. Never kills, and
    /// never waits: `NSRunningApplication.terminate` only sends.
    ///
    /// There is deliberately no fallback for a holder LaunchServices does not know. The one
    /// there was (`NSAppleScript` "tell application id … to quit") fetched the target's
    /// scripting terminology over an Apple event, and a process that does not answer Apple
    /// events froze the whole app on the main thread for the two-minute Apple event timeout:
    /// no ticks, no hard limit, no menu (QA 2026-10-11, H1). A test checks it stays gone.
    @MainActor
    public static func requestQuit(_ holder: Holder, world: ProcessWorld = .live) -> QuitRequest {
        // By the owning app's bundle id first: the holding process is often a helper (a
        // Chromium renderer, an Electron utility process) with a LaunchServices registration
        // of its own, and terminating that only makes the parent relaunch it. The app the
        // Quit menu belongs to is the one `describe` resolved.
        if let bid = holder.bundleID, let app = world.applications(bid).first {
            return app.terminate() ? .sent : .notSent
        }
        if let app = world.application(holder.pid) {
            return app.terminate() ? .sent : .notSent
        }
        return .notAnApp
    }
}

/// A running application as LaunchServices knows it.
public struct RunningApp {
    public var pid: pid_t
    public var bundleID: String?
    public var name: String?
    public var bundlePath: String?
    /// No user interface at all (`activationPolicy == .prohibited`): no Quit menu to ask.
    public var isBackgroundOnly: Bool
    /// Send it the quit Apple event; true when it went out.
    public var terminate: () -> Bool

    public init(pid: pid_t, bundleID: String?, name: String?, bundlePath: String?, isBackgroundOnly: Bool = false,
                terminate: @escaping () -> Bool = { true }) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.bundlePath = bundlePath
        self.isBackgroundOnly = isBackgroundOnly; self.terminate = terminate
    }

    init(_ app: NSRunningApplication) {
        self.init(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: app.localizedName,
                  bundlePath: app.bundleURL?.standardizedFileURL.path, isBackgroundOnly: app.activationPolicy == .prohibited,
                  terminate: { app.terminate() })
    }
}

/// What `Holders` asks the system about processes: LaunchServices and libproc in the app, a
/// made-up desk in the tests (where Xcode, Brave or a Homebrew Python can be "running").
public struct ProcessWorld {
    /// The process itself, when LaunchServices knows it as a running application.
    public var application: (pid_t) -> RunningApp?
    /// The running application whose bundle is at this path.
    public var applicationAt: (String) -> RunningApp?
    /// The running applications with this bundle id.
    public var applications: (String) -> [RunningApp]
    /// A process's parent (nil: none, or not visible to this user).
    public var parent: (pid_t) -> pid_t?

    public init(application: @escaping (pid_t) -> RunningApp?, applicationAt: @escaping (String) -> RunningApp?,
                applications: @escaping (String) -> [RunningApp], parent: @escaping (pid_t) -> pid_t?) {
        self.application = application; self.applicationAt = applicationAt; self.applications = applications; self.parent = parent
    }

    public static var live: ProcessWorld {
        ProcessWorld(
            application: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != nil, !app.isTerminated else { return nil }
                return RunningApp(app)
            },
            applicationAt: { path in
                let want = URL(fileURLWithPath: path).standardizedFileURL.path
                return NSWorkspace.shared.runningApplications
                    .first { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == want }
                    .map(RunningApp.init)
            },
            applications: { bid in NSRunningApplication.runningApplications(withBundleIdentifier: bid).filter { !$0.isTerminated }.map(RunningApp.init) },
            parent: { pid in
                var info = proc_bsdshortinfo()
                let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
                return pid_t(info.pbsi_ppid)
            })
    }
}
