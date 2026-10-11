// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import NimbusUpdater
import NimbusUpsBarKit
import UpsGuardCore

/// The command-line face: the same readers and the same guard as the menu, minus the UI.
/// The quickest way to check the data path against the real UPS.
@MainActor
enum CLI {
    enum Command {
        case print
        case watch
        case simulate
        case holders(path: String)
        case volumes
        case checkUpdate
        case preflight(app: String)
        case agentPlist
        case printMenu
        case dumpHIDRaw(path: String)
        case afterSafe(action: String)
    }

    static func run(_ cmd: Command) -> Int32 {
        switch cmd {
        case .agentPlist:
            Swift.print(BackgroundAgent.plist(executable: Updates.executableName))
            return 0

        case .dumpHIDRaw(let path):
            // Every raw element value, as the JSON fixture `UPSHID.decode` is tested against.
            let hid = UPSHID()
            spin(1.0)
            guard let raw = hid.fetch() else { fputs("no UPS over USB HID\n", stderr); return 1 }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(raw) else { return 1 }
            if path == "-" {
                Swift.print(String(decoding: data, as: UTF8.self))
            } else {
                do { try data.write(to: URL(fileURLWithPath: path)) } catch { fputs("\(path): \(error)\n", stderr); return 1 }
                Swift.print("wrote \(path): \(raw.values.count) values from \(raw.product ?? "?") in \(raw.readMillis) ms")
            }
            Swift.print("decodes to: \(summary(UPSHID.decode(raw, now: 0).reading))")
            return 0

        case .afterSafe(let action):
            // The two after-safe actions have no other path to be exercised: the drill never
            // performs them and a real outage is the wrong time to find out. Keyboard only.
            guard isatty(0) != 0, isatty(1) != 0 else { fputs("--after-safe needs a terminal\n", stderr); return 2 }
            let what: Policy.AfterSafe
            switch action.lowercased() {
            case "sleep": what = .sleep
            case "shutdown", "shut-down": what = .shutDown
            default: fputs("--after-safe takes sleep or shutdown\n", stderr); return 2
            }
            let word = what == .sleep ? "sleep" : "shutdown"
            Swift.print(what == .sleep
                ? "This puts the Mac to sleep now (IOPMSleepSystem, what pmset sleepnow does)."
                : "This shuts the Mac down now through the shutdown Apple event to loginwindow: every app gets its unsaved-changes dialog, then the Mac powers off. Save your work first.")
            Swift.print("Type \(word) to go ahead, anything else to stop: ", terminator: "")
            guard let typed = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), typed == word else { Swift.print("stopped"); return 1 }
            Log.shared.persistToFile = true
            Log.shared.append("--after-safe \(word): performing it at the owner's request from the terminal")
            if what == .sleep { PowerActions.sleep() } else { PowerActions.shutDown() }
            spin(2.0)
            return 0

        case .printMenu:
            // The menu built against the real UPS and volumes, as text: a crash here is a crash
            // on the first click, and this is the way to see the structure without a screen.
            let m = UPSMonitor()
            m.poll(reason: nil)
            spin(1.0)
            m.poll(reason: nil)
            // No window server (a CI runner, an SSH session): build the menu without a status
            // item rather than abort in NSStatusBar. NIMBUS_UPS_HEADLESS=1 forces that path.
            let headless = CGSessionCopyCurrentDictionary() == nil || ProcessInfo.processInfo.environment["NIMBUS_UPS_HEADLESS"] != nil
            let bar = StatusBarController(monitor: m, updater: nil, headless: headless)
            Swift.print(bar.menuText())
            return 0

        case .holders(let path):
            let list = Holders.list(mountPoint: path)
            if list.isEmpty { Swift.print("nothing has files open on \(path)") }
            for h in list { Swift.print(describe(h)) }
            return 0

        case .volumes:
            let m = UPSMonitor()
            spin(0.8)   // Disk Arbitration replays "appeared" for every disk on registration
            for v in m.volumes.sorted { Swift.print(describe(v, protected: m.settings.isProtected(v))) }
            if m.volumes.volumes.isEmpty { Swift.print("no external volumes") }
            return 0

        case .print:
            let m = UPSMonitor()
            Log.shared.echoToStderr = false
            m.poll(reason: nil)
            spin(1.0)   // the HID read lands on a background queue; DA replays the disks
            m.poll(reason: nil)
            printReport(m)
            return 0

        case .watch:
            let m = UPSMonitor()
            Log.shared.echoToStderr = true
            Log.shared.persistToFile = true
            var last: UPSReading?
            m.onChange = {
                let r = m.reading
                if r != last {
                    last = r
                    Swift.print("\(stamp()) \(summary(r))  phase=\(m.shown.status.phase.rawValue)")
                }
            }
            m.start()
            Swift.print("watching the UPS and the guard (Ctrl-C to stop); the log is echoed here too")
            RunLoop.main.run()
            return 0

        case .simulate:
            let m = UPSMonitor()
            Log.shared.echoToStderr = true
            Log.shared.persistToFile = true
            m.start()
            spin(1.5)
            m.startRehearsal()
            var lastPhase: OutageGuard.Phase?
            m.onChange = {
                guard let sim = m.simulation else { return }
                let st = sim.guardian.status
                if st.phase != lastPhase {
                    lastPhase = st.phase
                    Swift.print("\(stamp()) [rehearsal] \(st.phase.title) at \(Duration.text(st.elapsed)) simulated: \(summary(st.reading))")
                }
            }
            while m.simulation != nil { spin(0.25) }
            Swift.print("rehearsal finished; see ~/Library/Logs/Nimbus UPS Bar/ups-bar.log")
            return 0

        case .checkUpdate:
            guard let current = Updates.runningVersion ?? Updates.installedVersion else {
                fputs("no version to compare against: \(Updates.appName) is not installed\n", stderr); return 1
            }
            let config = Updates.config(currentVersion: current)
            Swift.print("current: \(current)  (\(Updates.runningVersion != nil ? "this bundle" : "the installed copy"))")
            do {
                guard let release = try block({ try await Release.fetchLatest(config) }) else {
                    Swift.print("latest:  none the updater can read"); return 0
                }
                Swift.print("latest:  \(release.version)  [\(release.tag)]")
                if let asset = release.asset { Swift.print("asset:   \(asset.name)  (\(asset.size) bytes)") }
                else { Swift.print("asset:   none named \(config.assetPrefix)\(release.version.text).zip — invisible to the updater") }
                Swift.print(release.version > current
                    ? (release.asset != nil ? "→ an update is available" : "→ newer, but nothing installable is published")
                    : "→ up to date")
            } catch {
                fputs("error: \(error)\n", stderr); return 1
            }
            return 0

        case .preflight(let path):
            let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
            let info = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? nil
            guard let short = info?["CFBundleShortVersionString"] as? String, let version = SemanticVersion(short) else {
                fputs("\(path) has no readable CFBundleShortVersionString\n", stderr); return 1
            }
            let report = block { await Preflight.run(app: URL(fileURLWithPath: path), config: Updates.config(currentVersion: version), releaseVersion: version) }
            for check in report.checks { Swift.print("\(check.ok ? "ok  " : "FAIL") \(check.name): \(check.detail)") }
            guard report.passed else {
                fputs("\nthis build would break auto-update for people who already have the app\n", stderr); return 1
            }
            Swift.print("\npreflight passed")
            return 0
        }
    }

    // MARK: Report

    private static func printReport(_ m: UPSMonitor) {
        let r = m.reading
        Swift.print("UPS: \(summary(r))")
        if let f = m.freshness { Swift.print("Read \(Duration.text(f.age)) ago over \(f.source); every \(Int(f.interval)) s") }
        if let b = m.internalBattery { Swift.print("Mac battery: \(b.percent) %\(b.isCharging ? ", charging" : "")\(b.onAC ? ", on AC" : ", discharging")") }
        Swift.print("")
        Swift.print("Health:")
        for h in m.health { Swift.print("  \(["●", "·", "◐", "○"][h.level.rawValue]) \(h.text)" + (h.detail.map { "\n      \($0)" } ?? "")) }
        Swift.print("")
        if let rep = m.hidReport {
            Swift.print("USB HID report (\(rep.fields.count) fields, \(rep.readMillis) ms):")
            var section = ""
            for f in rep.fields {
                if f.section != section { section = f.section; Swift.print("  [\(section)]") }
                Swift.print("    \(f.label.padding(toLength: 36, withPad: " ", startingAt: 0)) \(f.value)")
            }
        } else {
            Swift.print("USB HID: \(m.hid.isAttached ? "attached, not read yet" : "no UPS device")")
        }
        Swift.print("")
        Swift.print("macOS power source (pmset -g ps):")
        for (k, v) in PowerSources.rawUPSDescription() { Swift.print("    \(k.padding(toLength: 28, withPad: " ", startingAt: 0)) \(v)") }
        Swift.print("")
        Swift.print("External volumes (\(m.settings.volumeMode == .allExternal ? "protecting all" : "protecting the selected ones")):")
        if m.volumes.volumes.isEmpty { Swift.print("    none") }
        for v in m.volumes.sorted {
            Swift.print("    " + describe(v, protected: m.settings.isProtected(v)))
            if let mp = v.mountPoint {
                for h in Holders.list(mountPoint: mp) { Swift.print("        " + describe(h)) }
            }
        }
        Swift.print("")
        Swift.print("Policy: \(m.policyText)")
        Swift.print("Guard: \(m.live.status.phase.title)")
        Swift.print("Background agent: \(BackgroundAgent.statusDescription)")
        Swift.print("Log: \(Log.fileURL.path)")
    }

    static func summary(_ r: UPSReading) -> String {
        guard r.present else { return "no UPS" }
        var parts: [String] = []
        if let n = r.name { parts.append(n) }
        parts.append(r.onBattery ? "ON BATTERY" : "on line")
        if let p = r.chargePercent { parts.append("\(p) %") }
        if let t = r.runtimeSeconds { parts.append("runtime \(Duration.text(TimeInterval(t)))") }
        if let w = r.loadWatts { parts.append("load \(Int(w.rounded())) W" + (r.loadPercent.map { " (\($0) %)" } ?? "")) }
        if let v = r.inputVoltage { parts.append(String(format: "in %.0f V", v)) }
        if let v = r.outputVoltage { parts.append(String(format: "out %.0f V", v)) }
        if let v = r.batteryVoltage { parts.append(String(format: "battery %.1f V", v)) }
        if let t = r.selfTest { parts.append("self-test \(t.text)") }
        return parts.joined(separator: ", ")
    }

    private static func describe(_ v: VolumeState, protected: Bool) -> String {
        let state = !v.isAttached ? "not attached" : v.isMounted ? "mounted at \(v.mountPoint!)" : "attached, not mounted"
        return "\(v.name)  [\(v.bsdName ?? "-")]  \(state)\(protected ? "" : "  (not protected)")  \(v.detail)  uuid=\(v.uuid)"
    }

    private static func describe(_ h: Holder) -> String {
        h.isApp ? "app   \(h.shortName) (pid \(h.pid), \(h.bundleID ?? "no bundle id"))" : "other \((h.executable as NSString).lastPathComponent) (pid \(h.pid))"
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// Turn the main run loop for a while so IOKit, Disk Arbitration and dispatch callbacks land.
    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Run an async call to completion from synchronous top-level code.
    @discardableResult
    static func block<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<T, Swift.Error>?
        Task.detached {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }

    static func block<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        try! block { () async throws -> T in await body() }
    }
}
