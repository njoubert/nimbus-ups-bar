// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater
import NimbusUpsBarKit
import UpsGuardCore

/// Everything the Inspector shows, rebuilt on every monitor update: the Kit's sections (the
/// UPS, macOS's entry, health, the guard, the volumes) plus the app's own (how the readings
/// are taken, the background agent and this process), the log, and a running list of what
/// changed between looks. `snapshotJSON()` is the whole of it for an agent.
@MainActor
final class InspectorModel {
    let monitor: UPSMonitor
    let updater: Updater?
    private(set) var sections: [Inspector.Section] = []
    /// Newest first, capped.
    private(set) var changes: [Inspector.Change] = []
    /// When each row last changed, by "section id › row key": the flash.
    private(set) var changedAt: [String: Date] = [:]
    private(set) var updatedAt = Date()
    private(set) var updates = 0
    private var last: [String: String]?
    /// Whether the UPS page last showed a full capture: a switch between the routine read and
    /// the full one adds or drops a hundred rows, which are not changes in the UPS.
    private var lastFull: Bool?
    private var launchd = LaunchdJob.Info(text: nil, checkedAt: nil)
    private var launchdChecking = false
    nonisolated static let maxChanges = 1000

    init(monitor: UPSMonitor, updater: Updater?) {
        self.monitor = monitor
        self.updater = updater
    }

    /// Take a new look. Rows that differ from the previous look are logged as changes and
    /// stamped for the flash; the first look sets the baseline and logs nothing.
    func refresh() {
        let now = Date()
        if launchd.checkedAt.map({ now.timeIntervalSince($0) > 10 }) ?? true { checkLaunchd() }
        sections = build()
        var flat = Inspector.flatten(sections)
        let full = monitor.hidRaw?.reports != nil
        if var last {
            if let lastFull, lastFull != full {
                // Compare the UPS page only on the rows both captures have.
                let shared = Set(last.keys).intersection(flat.keys)
                last = last.filter { !$0.key.hasPrefix("ups › ") || shared.contains($0.key) }
                flat = flat.filter { !$0.key.hasPrefix("ups › ") || shared.contains($0.key) }
            }
            let diff = Inspector.changes(from: last, to: flat, at: now)
            for c in diff { changedAt[c.section + " › " + c.key] = now }
            changes.insert(contentsOf: diff.reversed(), at: 0)
            if changes.count > InspectorModel.maxChanges { changes.removeLast(changes.count - InspectorModel.maxChanges) }
        }
        last = Inspector.flatten(sections)
        lastFull = full
        updatedAt = now
        updates += 1
    }

    func clearChanges() { changes = [] }

    /// The log file's last lines, parsed: Events reads these rather than this process's ring,
    /// so it reaches back across relaunches and includes the command-line runs. Re-read only
    /// when the file has grown.
    private var eventsCache: (size: UInt64, lines: [(Date, String)]) = (0, [])
    func recentEvents(limit: Int = 1000) -> [(Date, String)] {
        let url = Log.fileURL
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if size != eventsCache.size {
            var text = ""
            if let h = try? FileHandle(forReadingFrom: url) {
                try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
                text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
                try? h.close()
            }
            eventsCache = (size, Array(LogEvent.parse(text).suffix(limit)))
        }
        // Nothing on disk (the bare binary without persistence): this process's lines.
        return eventsCache.lines.isEmpty ? Log.shared.recent.map { ($0.date, $0.line) } : eventsCache.lines
    }

    // MARK: Sections

    private func build() -> [Inspector.Section] {
        let m = monitor
        let now = monotonicNow()
        let sim = m.simulation.map { "\($0.kind.rawValue), \($0.outage.scenario.rawValue): \($0.guardian.status.phase.title.lowercased()) at \(Duration.text($0.guardian.status.elapsed)) simulated" }
        return [
            Inspector.ups(raw: m.hidRaw, report: m.hidReport, readAge: m.hidReadAt.map { now - $0 }, attached: m.hid.isAttached),
            Inspector.powerSource(iops: PowerSources.rawUPSDictionary(), merged: m.reading, battery: m.internalBattery),
            Inspector.health(m.health),
            Inspector.guardian(m.live.status, policy: m.live.policy, simulation: sim, armed: m.isArmed),
            Inspector.volumes(m.live.status.volumes, mode: Settings.shared.volumeMode == .allExternal ? "all external volumes" : "selected volumes"),
            readings(now: now),
            agent(),
        ]
    }

    private func readings(now: TimeInterval) -> Inspector.Section {
        let m = monitor, s = Settings.shared, st = m.stats
        let reasons = [m.reading.onBattery ? "on battery" : nil, m.simulation != nil ? "simulation" : nil,
                       m.menuOpen ? "menu open" : nil, m.inspectorOpen ? "Inspector open" : nil].compactMap { $0 }
        func ago(_ t: TimeInterval?) -> String { t.map { Duration.text(now - $0) + " ago" } ?? "never" }
        let rows: [Inspector.Row] = [
            Inspector.Row(group: "Cadence", "On line power", "every \(Duration.text(s.lineReadInterval))"),
            Inspector.Row(group: "Cadence", "On battery, menu or Inspector open", "every \(Duration.text(s.busyReadInterval))"),
            Inspector.Row(group: "Cadence", "Now", "every \(Duration.text(m.currentReadInterval))" + (reasons.isEmpty ? "" : " (\(reasons.joined(separator: ", ")))")),
            Inspector.Row(group: "Cadence", "A HID report counts as fresh for", Duration.text(s.hidFreshFor)),
            Inspector.Row(group: "Cadence", "No HID read is a warning after", Duration.text(s.hidStaleAfter)),
            Inspector.Row(group: "USB HID", "Device attached", m.hid.isAttached ? "yes" : "no"),
            Inspector.Row(group: "USB HID", "Last read", ago(m.hidReadAt) + (m.hidReport.map { " in \($0.readMillis) ms" } ?? "")),
            Inspector.Row(group: "USB HID", "Reads", "\(st.hidReads)"),
            Inspector.Row(group: "USB HID", "Reads that returned nothing", "\(st.hidEmpty)"),
            Inspector.Row(group: "USB HID", "Reads abandoned (stuck over \(Int(UPSMonitor.hidAbandonAfter)) s)", "\(st.hidAbandoned)"),
            Inspector.Row(group: "USB HID", "Late results dropped", "\(st.hidDropped)"),
            Inspector.Row(group: "macOS", "Polls", "\(st.polls)"),
            Inspector.Row(group: "macOS", "Power-source change events", "\(st.powerSourceEvents)"),
            Inspector.Row(group: "macOS", "Last change event", ago(st.lastPowerSourceEventAt)),
            Inspector.Row(group: "Chart", "Samples kept", "\(m.samples.count)"),
            Inspector.Row(group: "Chart", "Window", Duration.text(s.historyWindow)),
        ]
        let json: [String: Any] = [
            "lineReadSeconds": s.lineReadInterval, "busyReadSeconds": s.busyReadInterval, "currentReadSeconds": m.currentReadInterval,
            "fastReadReasons": reasons, "hidFreshForSeconds": s.hidFreshFor, "hidStaleAfterSeconds": s.hidStaleAfter,
            "hidAttached": m.hid.isAttached, "hidLastReadAgeSeconds": Inspector.value(m.hidReadAt.map { now - $0 }),
            "hidReads": st.hidReads, "hidEmpty": st.hidEmpty, "hidAbandoned": st.hidAbandoned, "hidDropped": st.hidDropped,
            "polls": st.polls, "powerSourceEvents": st.powerSourceEvents,
            "lastPowerSourceEventAgeSeconds": Inspector.value(st.lastPowerSourceEventAt.map { now - $0 }),
            "chartSamples": m.samples.count, "chartWindowSeconds": s.historyWindow,
        ]
        return Inspector.Section(id: "readings", title: "Readings", symbol: "waveform.path.ecg", rows: rows, json: json,
                                 subtitle: "Reading every \(Duration.text(m.currentReadInterval)) · \(st.hidReads) HID reads since launch")
    }

    private func agent() -> Inspector.Section {
        let b = Bundle.main
        let env = ProcessInfo.processInfo.environment
        let byLaunchd = getppid() == 1 && env["XPC_SERVICE_NAME"] == BackgroundAgent.label
        let version = (b.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
        let build = (b.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
        let plistURL = b.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(BackgroundAgent.plistName)")
        let plistText = try? String(contentsOf: plistURL, encoding: .utf8)
        let job = LaunchdJob.parse(launchd.text)
        let installed = b.bundlePath.hasPrefix("/Applications/")
        var rows: [Inspector.Row] = [
            Inspector.Row(group: "Run in Background", "Status (SMAppService)", BackgroundAgent.statusDescription),
            Inspector.Row(group: "Run in Background", "Agent plist in this bundle", BackgroundAgent.isAvailable ? "yes" : "no"),
            Inspector.Row(group: "Run in Background", "Label", BackgroundAgent.label),
            Inspector.Row(group: "launchd job", "Loaded", launchd.text == nil ? (launchd.checkedAt == nil ? "checking…" : "no") : "yes"),
        ]
        for (k, v) in job { rows.append(Inspector.Row(group: "launchd job", k, v)) }
        rows += [
            Inspector.Row(group: "This copy", "Version", "\(version) (\(build))"),
            Inspector.Row(group: "This copy", "Bundle", b.bundlePath),
            Inspector.Row(group: "This copy", "Installed in /Applications", installed ? "yes" : "no (a development build)"),
            Inspector.Row(group: "This copy", "Process", "pid \(getpid())"),
            Inspector.Row(group: "This copy", "Started by", byLaunchd ? "launchd (the background agent)" : "hand or Finder (not the agent)"),
            Inspector.Row(group: "This copy", "Running for", Duration.text(Date().timeIntervalSince(monitor.stats.startedAt))),
            Inspector.Row(group: "This copy", "Notifications", Notifications.available ? (Settings.shared.notificationsEnabled ? "on" : "off in Settings") : "unavailable (no bundle)"),
            Inspector.Row(group: "This copy", "Automatic update checks", updater.map { $0.automaticChecks ? "on" : "off" } ?? "—"),
            Inspector.Row(group: "This copy", "Log file", Log.fileURL.path),
        ]
        let json: [String: Any] = [
            "smAppServiceStatus": BackgroundAgent.statusDescription, "plistInBundle": BackgroundAgent.isAvailable,
            "label": BackgroundAgent.label, "plist": Inspector.value(plistText),
            "launchd": ["loaded": launchd.text != nil, "fields": job.reduce(into: [String: String]()) { $0[$1.0] = $1.1 },
                        "checkedAgeSeconds": Inspector.value(launchd.checkedAt.map { Date().timeIntervalSince($0) })] as [String: Any],
            "version": version, "build": build, "bundlePath": b.bundlePath, "installedInApplications": installed,
            "pid": Int(getpid()), "startedByLaunchd": byLaunchd, "runningSeconds": Date().timeIntervalSince(monitor.stats.startedAt),
            "notificationsAvailable": Notifications.available, "notificationsEnabled": Settings.shared.notificationsEnabled,
            "automaticUpdateChecks": Inspector.value(updater?.automaticChecks), "logFile": Log.fileURL.path,
        ]
        let sub = "\(BackgroundAgent.statusDescription) · \(byLaunchd ? "started by launchd" : "not started by launchd") · \(installed ? "/Applications" : "development build")"
        return Inspector.Section(id: "agent", title: "Service & App", symbol: "gearshape.2", rows: rows, json: json, subtitle: sub)
    }

    /// `launchctl print` runs a process; off the main thread, at most every ten seconds.
    private func checkLaunchd() {
        guard !launchdChecking else { return }
        launchdChecking = true
        DispatchQueue.global(qos: .utility).async {
            let text = LaunchdJob.print(label: BackgroundAgent.label)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.launchd = LaunchdJob.Info(text: text, checkedAt: Date())
                    self.launchdChecking = false
                }
            }
        }
    }

    // MARK: Snapshot

    /// Everything, for an agent: every section's JSON, the recent changes and the log tail.
    func snapshotJSON(includeLog: Bool = true) -> String { Inspector.json(snapshot(includeLog: includeLog)) }

    func snapshot(includeLog: Bool = true) -> [String: Any] {
        var all: [String: Any] = ["capturedAt": Inspector.iso(Date()), "app": "Nimbus UPS Bar"]
        for s in sections { all[s.id] = s.json }
        all["changes"] = changesJSON(limit: 200)
        if includeLog { all["log"] = logJSON(limit: 200) }
        return all
    }

    func changesJSON(limit: Int = InspectorModel.maxChanges) -> [[String: Any]] {
        changes.prefix(limit).map { ["at": Inspector.iso($0.at), "section": $0.section, "key": $0.key,
                                     "old": Inspector.value($0.old), "new": Inspector.value($0.new)] }
    }

    func logJSON(limit: Int = 500) -> [[String: Any]] {
        recentEvents().suffix(limit).map { ["at": Inspector.iso($0.0), "line": $0.1, "kind": LogEvent.kind(of: $0.1).rawValue] }
    }
}
