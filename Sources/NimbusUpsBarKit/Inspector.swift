// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UpsGuardCore

/// What the Inspector window shows, as data: sections of labelled rows (the table) beside a
/// JSON object (the copy for an agent), and the diff between two looks that feeds the flash
/// and the change log. Pure, so the UPS sections can be checked against the HID fixture; the
/// app adds its own sections (readings, the background agent) in the same shape.
public enum Inspector {

    public struct Row: Equatable {
        /// A sub-heading the row sits under ("Battery", a volume's name), or nil.
        public var group: String?
        public var label: String
        public var value: String
        /// A third column: the HID element's address, a health item's explanation.
        public var detail: String?
        /// A dot for health items.
        public var level: Health.Level?

        public init(group: String? = nil, _ label: String, _ value: String, detail: String? = nil, level: Health.Level? = nil) {
            self.group = group; self.label = label; self.value = value; self.detail = detail; self.level = level
        }

        /// Stable within a section: what the diff and the flash key on.
        public var key: String { (group.map { $0 + " › " } ?? "") + label }
    }

    public struct Section {
        public var id: String
        public var title: String
        /// SF Symbol for the sidebar.
        public var symbol: String
        public var rows: [Row]
        /// A JSON object (dictionaries, arrays, strings, numbers, booleans, NSNull).
        public var json: Any
        /// Shown under the title: when it was read, how fresh.
        public var subtitle: String

        public init(id: String, title: String, symbol: String, rows: [Row], json: Any, subtitle: String = "") {
            self.id = id; self.title = title; self.symbol = symbol; self.rows = rows; self.json = json; self.subtitle = subtitle
        }
    }

    public struct Change: Equatable {
        public var at: Date
        public var section: String
        public var key: String
        public var old: String?
        public var new: String?

        public init(at: Date, section: String, key: String, old: String?, new: String?) {
            self.at = at; self.section = section; self.key = key; self.old = old; self.new = new
        }
    }

    // MARK: Diff

    /// Every row as "section id › row key" → value.
    public static func flatten(_ sections: [Section]) -> [String: String] {
        var out: [String: String] = [:]
        for s in sections { for r in s.rows { out[s.id + " › " + r.key] = r.value } }
        return out
    }

    /// What differs between two flattened looks, sorted by key; rows that appeared or went are
    /// changes too (old or new nil).
    public static func changes(from old: [String: String], to new: [String: String], at: Date) -> [Change] {
        Set(old.keys).union(new.keys).sorted().compactMap { k in
            guard old[k] != new[k] else { return nil }
            let parts = k.components(separatedBy: " › ")
            return Change(at: at, section: parts.first ?? "", key: parts.dropFirst().joined(separator: " › "), old: old[k], new: new[k])
        }
    }

    // MARK: JSON

    /// Pretty-printed, keys sorted, slashes unescaped: stable enough to diff by eye and to
    /// paste into an agent.
    public static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Optional values as JSON: nil becomes null.
    public static func value(_ v: Any?) -> Any { v ?? NSNull() }

    public static func hex(_ v: UInt32) -> String { String(format: "0x%02X", v) }

    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// The merged reading the guard sees, every property.
    public static func readingJSON(_ r: UPSReading) -> [String: Any] {
        var flags: [String] = []
        let names: [(UPSReading.Flags, String)] = [(.acPresent, "acPresent"), (.charging, "charging"), (.discharging, "discharging"),
                                                   (.fullyCharged, "fullyCharged"), (.belowCapacityLimit, "belowCapacityLimit"),
                                                   (.runtimeLimitExpired, "runtimeLimitExpired"), (.needsReplacement, "needsReplacement"),
                                                   (.overload, "overload"), (.shutdownImminent, "shutdownImminent"), (.boost, "boost"), (.buck, "buck")]
        for (f, n) in names where r.flags.contains(f) { flags.append(n) }
        return [
            "present": r.present, "name": value(r.name), "manufacturer": value(r.manufacturer), "serialNumber": value(r.serialNumber),
            "onBattery": r.onBattery, "chargePercent": value(r.chargePercent), "runtimeSeconds": value(r.runtimeSeconds),
            "loadPercent": value(r.loadPercent), "loadWatts": value(r.loadWatts), "ratedWatts": value(r.ratedWatts), "ratedVA": value(r.ratedVA),
            "inputVoltage": value(r.inputVoltage), "outputVoltage": value(r.outputVoltage), "batteryVoltage": value(r.batteryVoltage),
            "batteryNominalVoltage": value(r.batteryNominalVoltage), "flags": flags,
            "lowChargeLimitPercent": value(r.lowChargeLimitPercent), "lowRuntimeLimitSeconds": value(r.lowRuntimeLimitSeconds),
            "warningChargeLimitPercent": value(r.warningChargeLimitPercent), "selfTest": value(r.selfTest?.text),
            "lowTransferVoltage": value(r.lowTransferVoltage), "highTransferVoltage": value(r.highTransferVoltage),
        ]
    }

    // MARK: Sections the Kit can build

    /// Exactly what the UPS returned over USB HID: every element macOS parsed out of the
    /// report descriptor (each with its metadata, its value as read and its bytes, or the error
    /// its read returned), and, on a full read, the collections, every report's bytes, the
    /// descriptor and the device's properties. The table labels the values the decode knows;
    /// the JSON is the capture itself (`--dump-hid-raw`'s format) beside the decoded reading.
    public static func ups(raw: UPSHID.RawReport?, report: UPSHID.Report?, readAge: TimeInterval?, attached: Bool) -> Section {
        var rows: [Row] = []
        var json: [String: Any] = ["attached": attached]
        if let raw {
            var seen: [String: Int] = [:]
            for v in raw.values {
                let key = UPSHID.Key(section: v.section, page: v.page, usage: v.usage)
                let value: String
                if let e = v.error { value = String(format: "read failed (0x%08X)", UInt32(bitPattern: e)) }
                else if UPSHID.stringIndexes.contains(key.page << 8 | key.usage) { value = "string slot \(v.value)" }
                else { value = UPSHID.format(key, v.value) }
                var d = [v.type ?? "?"]
                if let c = v.cookie { d.append("cookie \(c)") }
                if let r = v.reportID { d.append("report \(r)") }
                d.append("\(hex(v.section)) · \(hex(v.page))/\(hex(v.usage)) = \(v.value)")
                if let b = v.bytes { d.append("bytes \(b)") }
                if let lo = v.logicalMin, let hi = v.logicalMax { d.append("logical \(lo)…\(hi)") }
                if let size = v.reportSize, let count = v.reportCount { d.append("\(size)×\(count) bits") }
                if let u = v.unit, u != 0 { d.append(String(format: "unit 0x%X", u) + (v.unitExponent.map { $0 != 0 ? " e\($0)" : "" } ?? "")) }
                var label = v.type == "input-null" && key.page == 0 ? "Padding (no usage)" : UPSHID.label(key)
                let group = "Elements › " + UPSHID.sectionName(v.section)
                // The same usage often comes twice (this UPS sends each value as a feature and
                // as an input): later ones say which, so every row keeps its own key.
                let n = seen[group + label, default: 0]
                seen[group + label] = n + 1
                if n > 0 { label += " (\(v.type ?? "?")\(n > 1 ? " \(n + 1)" : ""))" }
                rows.append(Row(group: group, label, value, detail: d.joined(separator: " · ")))
            }
            for c in raw.collections ?? [] {
                let kinds = [0: "physical", 1: "application", 2: "logical", 3: "report", 4: "named array", 5: "usage switch", 6: "usage modifier"]
                rows.append(Row(group: "Collections", "\(hex(c.page))/\(hex(c.usage))", kinds[Int(c.collectionType)] ?? "type \(c.collectionType)",
                                detail: "cookie \(c.cookie)" + (c.parentCookie.map { " · inside \($0)" } ?? "")))
            }
            for r in raw.reports ?? [] {
                rows.append(Row(group: "Reports (GET_REPORT)", "\(r.type) \(r.id)",
                                r.bytes ?? String(format: "refused (0x%08X)", UInt32(bitPattern: r.error ?? 0)),
                                detail: r.bytes.map { "\($0.count / 2) bytes" }))
            }
            if let d = raw.descriptor { rows.append(Row(group: "Report descriptor", "\(d.count / 2) bytes", d)) }
            for (k, v) in (raw.properties ?? [:]).sorted(by: { $0.key < $1.key }) { rows.append(Row(group: "Device properties", k, v)) }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            if let data = try? enc.encode(raw), let obj = try? JSONSerialization.jsonObject(with: data) { json["capture"] = obj }
        } else if let report {
            for f in report.fields {
                rows.append(Row(group: f.section, f.label, f.value, detail: "\(hex(f.key.section)) · \(hex(f.key.page))/\(hex(f.key.usage)) = \(f.raw)"))
            }
        }
        if let report { json["decoded"] = readingJSON(report.reading) }
        json["readAgeSeconds"] = value(readAge.map { ($0 * 10).rounded() / 10 })
        let sub: String
        if let raw, let age = readAge {
            let failed = raw.values.filter { $0.error != nil }.count
            var parts = ["\(raw.values.count) elements" + (failed > 0 ? " (\(failed) failed)" : "")]
            if raw.reports != nil {
                parts.append("\(raw.collections?.count ?? 0) collections")
                parts.append("\(raw.reports?.count ?? 0) reports")
            } else {
                parts.append("the routine read (input and feature elements, first of each usage); the full capture comes with live updates or Refresh")
            }
            parts.append("read \(age < 1.5 ? "just now" : Duration.text(age) + " ago") in \(raw.readMillis) ms")
            sub = parts.joined(separator: " · ")
        } else { sub = attached ? "Reading the UPS…" : "UPS not reachable over USB HID" }
        return Section(id: "ups", title: "UPS (USB HID)", symbol: "powerplug", rows: rows, json: json, subtitle: sub)
    }

    /// The entry macOS keeps for the UPS (`pmset -g ps`), and the Mac's own battery.
    public static func powerSource(iops: [String: Any]?, merged: UPSReading, battery: PowerSources.InternalBattery?) -> Section {
        var rows: [Row] = []
        for (k, v) in (iops ?? [:]).sorted(by: { $0.key < $1.key }) { rows.append(Row(group: "macOS power source", k, "\(v)")) }
        if let b = battery {
            rows.append(Row(group: "Mac's own battery", "Charge", "\(b.percent) %"))
            rows.append(Row(group: "Mac's own battery", "Charging", b.isCharging ? "yes" : "no"))
            rows.append(Row(group: "Mac's own battery", "On AC", b.onAC ? "yes" : "no"))
            if let m = b.minutesToEmpty { rows.append(Row(group: "Mac's own battery", "Time to empty", Duration.text(TimeInterval(m * 60)))) }
        }
        var json: [String: Any] = ["macOSPowerSource": value(iops), "merged": readingJSON(merged)]
        json["macBattery"] = battery.map { ["percent": $0.percent, "charging": $0.isCharging, "onAC": $0.onAC, "minutesToEmpty": value($0.minutesToEmpty)] as [String: Any] } ?? NSNull()
        return Section(id: "power", title: "Power Source", symbol: "bolt.batteryblock", rows: rows, json: json,
                       subtitle: iops == nil ? "macOS lists no UPS" : "What pmset -g ps reports, and the reading the guard acts on")
    }

    public static func health(_ items: [Health.Item]) -> Section {
        let names: [Health.Level: String] = [.good: "good", .info: "note", .warning: "warning", .bad: "fault"]
        let rows = items.map { Row($0.text, names[$0.level] ?? "", detail: $0.detail, level: $0.level) }
        let json: [String: Any] = [
            "overall": names[Health.overall(items)] ?? "",
            "items": items.map { ["level": names[$0.level] ?? "", "text": $0.text, "short": value($0.short), "detail": value($0.detail)] as [String: Any] },
        ]
        let top = Health.headline(items)
        return Section(id: "health", title: "Health", symbol: "stethoscope", rows: rows, json: json,
                       subtitle: top.map { "\(names[$0.level] ?? ""): \($0.label)" } ?? "healthy")
    }

    /// The live guard: where the outage stands, what comes next, and the policy it runs.
    public static func guardian(_ st: OutageGuard.Status, policy: Policy, simulation: String?, armed: Bool = true) -> Section {
        func t(_ v: TimeInterval?) -> String { v.map { Duration.text($0) } ?? "—" }
        var rows: [Row] = [
            Row(group: "State", "Guarding", armed ? "yes" : "no: this process only looks (a command-line run, or the first seconds after launch)"),
            Row(group: "State", "Phase", st.phase.title),
            Row(group: "State", "UPS present", st.upsPresent ? "yes" : "no"),
            Row(group: "State", "On battery for", st.outageStart == nil ? "—" : Duration.text(st.elapsed)),
            Row(group: "State", "Next: ask apps in", t(st.untilSoft)),
            Row(group: "State", "Next: force unmount in", t(st.untilHard)),
            Row(group: "State", "Next: sleep or shut down in", t(st.untilPowerDown)),
            Row(group: "State", "Quit timeout in", t(st.untilQuitTimeout)),
            Row(group: "State", "Power back, stands down in", t(st.untilStandDown)),
            Row(group: "State", "UPS missing for", t(st.upsAbsentFor)),
            Row(group: "State", "Blind outage (UPS lost on line power)", st.blind ? "yes" : "no"),
            Row(group: "State", "Power-down pending", st.powerDownPending ? "yes" : "no"),
            Row(group: "State", "Waiting for", st.waitingFor.isEmpty ? "—" : st.waitingFor.joined(separator: ", ")),
            Row(group: "State", "Hard reasons", st.hardReasons.isEmpty ? "—" : st.hardReasons.joined(separator: "; ")),
            Row(group: "State", "Postponed by", st.postponedBy > 0 ? Duration.text(st.postponedBy) : "—"),
            Row(group: "State", "Quit apps this outage", st.quitAppsThisOutage ? "yes" : "no"),
            Row(group: "State", "Last outage", t(st.lastOutageSeconds)),
        ]
        if let simulation { rows.append(Row(group: "State", "Simulation", simulation)) }
        rows += [
            Row(group: "Policy", "Ask apps to quit at", policy.softAt.summary),
            Row(group: "Policy", "Force unmount at", policy.hardAt.summary),
            Row(group: "Policy", "Sleep or shut down at", policy.powerDownAt.summary + (policy.powerDownWhenSafe ? ", or once safe" : "")),
            Row(group: "Policy", "Power-down action", policy.powerDownAction.title),
            Row(group: "Policy", "Ask apps to quit", policy.quitApps ? "yes" : "no"),
            Row(group: "Policy", "Quit timeout", policy.quitTimeoutSeconds.map { Duration.text($0) } ?? "off"),
            Row(group: "Policy", "UPS missing for", Duration.text(policy.upsGoneSeconds)),
            Row(group: "Policy", "UPS missing in an outage", policy.upsGoneInOutage.title + (policy.upsGoneInOutagePowersDown ? ", then power down" : "")),
            Row(group: "Policy", "UPS missing on line power", policy.upsGoneOnLine.title),
            Row(group: "Policy", "Ignore readings for", Duration.text(policy.ignoreReadingsSeconds)),
            Row(group: "Policy", "Power must stay back for", Duration.text(policy.lineStableSeconds)),
            Row(group: "Policy", "Never quit", policy.neverQuit.sorted().joined(separator: ", ")),
        ]
        func trig(_ x: Trigger) -> [String: Any] {
            ["onBatteryForSeconds": value(x.onBatteryFor), "runtimeAtMostSeconds": value(x.runtimeAtMost), "chargeAtMostPercent": value(x.chargeAtMost)]
        }
        let json: [String: Any] = [
            "armed": armed, "phase": st.phase.rawValue, "upsPresent": st.upsPresent, "elapsedSeconds": st.elapsed,
            "untilSoftSeconds": value(st.untilSoft), "untilHardSeconds": value(st.untilHard), "untilPowerDownSeconds": value(st.untilPowerDown),
            "untilQuitTimeoutSeconds": value(st.untilQuitTimeout), "untilStandDownSeconds": value(st.untilStandDown),
            "upsAbsentForSeconds": value(st.upsAbsentFor), "blind": st.blind, "powerDownPending": st.powerDownPending,
            "waitingFor": st.waitingFor, "hardReasons": st.hardReasons, "postponedBySeconds": st.postponedBy,
            "quitAppsThisOutage": st.quitAppsThisOutage, "lastOutageSeconds": value(st.lastOutageSeconds), "simulation": value(simulation),
            "policy": [
                "summary": policy.summary, "softAt": trig(policy.softAt), "hardAt": trig(policy.hardAt), "powerDownAt": trig(policy.powerDownAt),
                "powerDownWhenSafe": policy.powerDownWhenSafe, "powerDownAction": policy.powerDownAction.rawValue,
                "quitApps": policy.quitApps, "quitTimeoutSeconds": value(policy.quitTimeoutSeconds), "neverQuit": policy.neverQuit.sorted(),
                "upsGoneSeconds": policy.upsGoneSeconds, "upsGoneInOutage": policy.upsGoneInOutage.rawValue,
                "upsGoneInOutagePowersDown": policy.upsGoneInOutagePowersDown, "upsGoneOnLine": policy.upsGoneOnLine.rawValue,
                "ignoreReadingsSeconds": policy.ignoreReadingsSeconds, "lineStableSeconds": policy.lineStableSeconds,
            ] as [String: Any],
        ]
        return Section(id: "guard", title: "Outage Guard", symbol: "shield.lefthalf.filled", rows: rows, json: json,
                       subtitle: armed ? st.phase.title + (st.outageStart == nil ? "" : " · \(Duration.text(st.elapsed)) on battery") : "Not guarding: this process only looks")
    }

    /// The protected volumes, each with its state and who holds it.
    public static func volumes(_ reports: [OutageGuard.VolumeReport], mode: String) -> Section {
        var rows: [Row] = []
        for r in reports {
            let v = r.volume
            let g = v.name
            rows.append(Row(group: g, "State", v.isMounted ? "mounted" : v.isAttached ? "attached, not mounted" : "not attached"))
            rows.append(Row(group: g, "UUID", v.uuid))
            rows.append(Row(group: g, "Device", v.bsdName ?? "—"))
            rows.append(Row(group: g, "Mount point", v.mountPoint ?? "—"))
            if !v.detail.isEmpty { rows.append(Row(group: g, "Drive", v.detail)) }
            rows.append(Row(group: g, "Apps holding files", r.appHolders.isEmpty ? "—" : r.appHolders.map(\.shortName).joined(separator: ", ")))
            rows.append(Row(group: g, "Others holding files", r.otherHolders.isEmpty ? "—" : r.otherHolders.map(\.shortName).joined(separator: ", ")))
            rows.append(Row(group: g, "Unmount or mount in flight", r.inFlight ? "yes" : "no"))
            rows.append(Row(group: g, "Unmounted by the guard", r.unmountedByGuard ? "yes" : "no"))
            if let e = r.lastError { rows.append(Row(group: g, "Last error", e)) }
        }
        func holder(_ h: Holder) -> [String: Any] {
            ["pid": h.pid, "executable": h.executable, "appName": value(h.appName), "bundleID": value(h.bundleID), "isApp": h.isApp]
        }
        let json: [String: Any] = [
            "mode": mode,
            "volumes": reports.map { r -> [String: Any] in
                ["name": r.volume.name, "uuid": r.volume.uuid, "bsdName": value(r.volume.bsdName), "mountPoint": value(r.volume.mountPoint),
                 "attached": r.volume.isAttached, "mounted": r.volume.isMounted, "detail": r.volume.detail,
                 "appHolders": r.appHolders.map(holder), "otherHolders": r.otherHolders.map(holder),
                 "inFlight": r.inFlight, "unmountedByGuard": r.unmountedByGuard, "lastError": value(r.lastError)]
            },
        ]
        let mounted = reports.filter(\.volume.isMounted).count
        return Section(id: "volumes", title: "Volumes", symbol: "externaldrive", rows: rows, json: json,
                       subtitle: "\(reports.count) protected, \(mounted) mounted · \(mode)")
    }
}
