// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater
import NimbusUpsBarKit
import UpsGuardCore

/// The status item and its dropdown. On line power the bar shows a bolt (and the load, if
/// asked); during an outage it turns orange with the charge and the countdown, red while
/// forcing, green once the drives are safe. The menu is rebuilt on every open and the rows
/// that move (headline, chart, countdowns, volumes) are refreshed in place while it is open.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    /// nil when headless: `--print-menu` on a machine with no window server (CI) builds the
    /// menu without a status item, since `NSStatusBar` aborts without a WindowServer session.
    private let item: NSStatusItem?
    private let menu = NSMenu()
    private let monitor: UPSMonitor
    private let updater: Updater?
    private var menuOpen = false
    private var liveTimer: Timer?

    static let chartWidth: CGFloat = 340
    private let headline = HeadlineView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: HeadlineView.height))
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: ChartView.chartHeight))
    private var actionItems: [String: NSMenuItem] = [:]
    private var volumeItems: [String: NSMenuItem] = [:]
    private var simulationStatusItem: NSMenuItem?
    private var versionItem: NSMenuItem?
    private var lastBar: (symbol: String, title: String, color: String)?
    private var settingsObserver: NSObjectProtocol?

    init(monitor: UPSMonitor, updater: Updater? = nil, headless: Bool = false) {
        self.monitor = monitor
        self.updater = updater
        item = headless ? nil : NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item?.menu = menu
        headline.model = { [weak self] in self?.headlineModel() ?? HeadlineView.Model(title: "", color: .clear, subtitle: "") }
        chart.samples = { [weak self] in self?.monitor.samples ?? [] }
        monitor.onChange = { [weak self] in self?.monitorChanged() }
        Log.shared.onAppend = { [weak self] in self?.logChanged() }
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        settingsChanged()
    }

    /// A setting changed somewhere (the Settings window, mostly): the bar's extra, the chart's
    /// span and the cadence in the tooltip follow at once.
    private func settingsChanged() {
        let s = Settings.shared
        chart.span = s.historyWindow
        chart.sampleGap = s.lineReadInterval * 3
        chart.chargeLimit = s.policy.hardAt.chargeAtMost
        chart.needsDisplay = true
        headline.toolTip = "Charge, load and voltages come from a USB read of the UPS: every \(Int(s.lineReadInterval)) s on line power, every \(Int(s.busyReadInterval)) s on battery and while this menu is open (Settings › Readings). "
            + "The line/battery state also arrives from macOS the moment it changes. The top-right figure is the age of what you see."
        lastBar = nil
        updateBar()
        if menuOpen { refreshLiveRows() }
    }

    private func monitorChanged() {
        updateBar()
        guard menuOpen else { return }
        refreshLiveRows()
    }

    private func logChanged() {}

    /// The whole menu as indented text, submenus included: what `--print-menu` shows. Builds
    /// the menu exactly as an open would, without opening it.
    func menuText() -> String {
        rebuild()
        var out: [String] = []
        func walk(_ m: NSMenu, _ depth: Int) {
            for it in m.items {
                let pad = String(repeating: "    ", count: depth)
                if it.isSeparatorItem { out.append(pad + "────"); continue }
                var title = it.attributedTitle?.string ?? it.title
                if it.view is HeadlineView { let h = headlineModel(); title = "[headline] \(h.title) — \(h.subtitle) — " + h.figures.map { "\($0.0) \($0.1)" }.joined(separator: ", ") }
                else if it.view is ChartView { title = "[chart: \(monitor.samples.count) samples]" }
                let state = it.state == .on ? " ✓" : ""
                let off = it.isEnabled || it.action == nil && it.submenu == nil ? "" : " (disabled)"
                out.append(pad + title.replacingOccurrences(of: "\n", with: " ⏎ ") + state + off)
                if let sub = it.submenu { walk(sub, depth + 1) }
            }
        }
        walk(menu, 0)
        return out.joined(separator: "\n")
    }

    /// Render the status button (layout check without a screen grab).
    func dumpBar(to path: String) -> Bool {
        guard let b = item?.button, let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return false }
        b.cacheDisplay(in: b.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: Bar

    private func updateBar() {
        let st = monitor.shown.status
        let r = monitor.simulation != nil ? st.reading : monitor.reading
        let health = Health.overall(monitor.health)
        var symbol = "bolt.fill"
        var color: NSColor?
        var title = ""
        let pct = r.chargePercent.map { "\($0) %" } ?? ""
        switch st.phase {
        case .line:
            // Line power: the bolt carries the health colour, so a glance says whether the
            // UPS is ready. Green fine, yellow look-into-it, red fault or no UPS at all.
            if !r.present { symbol = "bolt.slash"; color = .systemRed }
            else if health == .bad { symbol = "bolt.trianglebadge.exclamationmark"; color = .systemRed }
            else if health == .warning { color = .systemYellow }
            else { color = .systemGreen }
            if r.present, Settings.shared.showLoadInBar, let w = r.loadWatts { title = "\(Int(w.rounded())) W" }
        case .holding:
            symbol = StatusBarController.batterySymbol(r.chargePercent)
            color = .systemOrange
            title = [pct, st.untilSoft.map { Duration.countdown($0) } ?? ""].filter { !$0.isEmpty }.join()
        case .soft:
            symbol = StatusBarController.batterySymbol(r.chargePercent)
            color = .systemOrange
            title = [pct, "closing apps"].filter { !$0.isEmpty }.join()
        case .hard:
            symbol = "exclamationmark.triangle.fill"
            color = .systemRed
            title = [pct, "unmounting"].filter { !$0.isEmpty }.join()
        case .safe:
            symbol = "checkmark.shield.fill"
            color = .systemGreen
            title = [pct, "drives safe"].filter { !$0.isEmpty }.join()
        case .restoring:
            symbol = "arrow.triangle.2.circlepath"
            color = .systemBlue
            title = "remounting"
        }
        if let sim = monitor.simulation { title = (sim.kind == .rehearsal ? "REHEARSAL" : "DRILL") + (title.isEmpty ? "" : " · " + title) }
        let key = (symbol, title, color?.description ?? "")
        if let l = lastBar, l == key { return }
        lastBar = key
        guard let button = item?.button else { return }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "UPS")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        if let color, let img = image {
            image = img.withSymbolConfiguration(.init(paletteColors: [color]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: st.phase == .line ? NSColor.labelColor : (color ?? NSColor.labelColor)])
        button.toolTip = "Nimbus UPS Bar — " + headlineModel().title + (headlineModel().subtitle.isEmpty ? "" : ": " + headlineModel().subtitle)
    }

    private static func batterySymbol(_ pct: Int?) -> String {
        guard let p = pct else { return "battery.50percent" }
        if p > 87 { return "battery.100percent" }
        if p > 62 { return "battery.75percent" }
        if p > 37 { return "battery.50percent" }
        if p > 12 { return "battery.25percent" }
        return "battery.0percent"
    }

    // MARK: Headline

    private func headlineModel() -> HeadlineView.Model {
        let st = monitor.shown.status
        let r = monitor.simulation != nil ? st.reading : monitor.reading
        let p = Settings.shared.policy
        var title = st.phase.title
        var color: NSColor = .systemGreen
        var subtitle = ""
        switch st.phase {
        case .line:
            if !r.present { title = "No UPS"; color = .systemRed; subtitle = monitor.upsSeen ? "The UPS has disconnected from USB" : "No UPS power source is listed by macOS" }
            else {
                let health = monitor.health
                let overall = Health.overall(health)
                color = overall == .bad ? .systemRed : overall == .warning ? .systemYellow : .systemGreen
                var parts: [String] = []
                // A warning or fault leads the line; the rest is context.
                if let concern = Health.headline(health) { parts.append(concern.label.prefix(1).uppercased() + concern.label.dropFirst()) }
                else if let n = r.name { parts.append(n) }
                parts.append("\(monitor.protectedMountedCount) protected volume\(monitor.protectedMountedCount == 1 ? "" : "s") mounted")
                if let last = st.lastOutageSeconds { parts.append("last outage \(Duration.text(last))") }
                subtitle = parts.joined(separator: " · ")
            }
        case .holding:
            color = .systemOrange
            let first = st.quitAppsThisOutage ? "Apps asked to quit" : "Free volumes unmount"
            if let soft = st.untilSoft { subtitle = "\(first) in \(Duration.countdown(soft))" }
            else if !p.softAt.isNever { subtitle = "\(first) at \(p.softAt.summary)" }
            else { subtitle = "Holding until a forced unmount" }
            if let hard = st.untilForce { subtitle += " · forced by \(Duration.countdown(hard))" }
        case .soft:
            color = .systemOrange
            subtitle = st.waitingFor.isEmpty ? "Unmounting volumes no app is using" : "Waiting for \(st.waitingFor.joined(separator: ", "))"
            if let hard = st.untilForce { subtitle += " · forced in \(Duration.countdown(hard))" }
        case .hard:
            color = .systemRed
            subtitle = st.powerDownPending ? "Unmounting before the Mac goes to \(p.powerDownAction.verb)"
                : st.hardReasons.first.map { "Hard limit: \($0)" } ?? "Force-unmounting every protected volume"
        case .safe:
            color = .systemGreen
            let n = st.volumes.filter(\.unmountedByGuard).count
            subtitle = n == 0 ? "Nothing was mounted; waiting for power" : "\(n) volume\(n == 1 ? "" : "s") unmounted; waiting for power"
            if st.powerDownPending { subtitle += " · about to \(p.powerDownAction.verb)" }
            else if p.powerDownWhenSafe { subtitle += " · then: \(p.powerDownAction.title.lowercased())" }
        case .restoring:
            color = .systemBlue
            subtitle = "Power is back; remounting"
        }
        if st.phase.isOutage, st.phase != .safe, let down = st.untilPowerDown { subtitle += " · \(p.powerDownAction.verb) in \(Duration.countdown(down))" }
        if st.blind { title = "UPS not seen" }
        // The two debounces: mains back but not yet trusted, and the UPS not answering.
        if st.phase.isOutage, let sd = st.untilStandDown {
            color = .systemBlue
            subtitle = "Power is back · outage over in \(Duration.countdown(sd)) unless it fails again"
        } else if st.phase.isOutage, let gone = st.upsAbsentFor, gone >= 2 {
            subtitle = "UPS not answering for \(Duration.text(gone)) · " + subtitle
        }
        if let sim = monitor.simulation { title = (sim.kind == .rehearsal ? "Rehearsal · " : "Drill · ") + title }
        var figures: [(String, String)] = []
        if r.present {
            figures.append((r.chargePercent.map { "\($0) %" } ?? "—", "Charge"))
            figures.append((r.loadWatts.map { "\(Int($0.rounded())) W" } ?? "—", "Load"))
            figures.append((r.runtimeSeconds.map { Duration.text(TimeInterval($0)) } ?? "—", r.onBattery ? "Left" : "Runtime"))
        }
        var fresh = ""
        if let f = monitor.freshness {
            fresh = (f.age < 1.5 ? "read just now" : "read \(Duration.text(f.age)) ago") + " · every \(Int(f.interval)) s"
            if f.source != "USB HID" { fresh += " · macOS only" }
        }
        return HeadlineView.Model(title: title, color: color, subtitle: subtitle, figures: figures, freshness: fresh)
    }

    // MARK: Menu lifecycle

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        updater?.checkIfStale()
        monitor.menuOpen = true
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLiveRows() }
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        monitor.menuOpen = false
        liveTimer?.invalidate()
        liveTimer = nil
        chart.clearHover()
    }

    private func refreshLiveRows() {
        headline.needsDisplay = true
        chart.needsDisplay = true
        updateActionRows()
        updateVolumeRows()
        if let s = simulationStatusItem, let sim = monitor.simulation {
            s.title = "\(sim.kind == .rehearsal ? "Rehearsal" : "Drill") running: \(sim.guardian.status.phase.title.lowercased()), \(Duration.text(sim.guardian.status.elapsed)) simulated"
        }
    }

    private func rebuild() {
        menu.removeAllItems()
        actionItems = [:]
        volumeItems = [:]
        simulationStatusItem = nil
        versionItem = nil
        // Reset the stretchy views to their natural width or the menu only ever gets wider.
        headline.setFrameSize(NSSize(width: StatusBarController.chartWidth, height: HeadlineView.height))
        chart.setFrameSize(NSSize(width: StatusBarController.chartWidth, height: ChartView.chartHeight))

        menu.addItem(viewItem(headline))
        menu.addItem(viewItem(chart))
        menu.addItem(.separator())

        addActionRows()
        addVolumeRows()
        menu.addItem(.separator())

        let health = monitor.health
        let overall = Health.overall(health)
        let healthItem = NSMenuItem(title: "UPS Health: " + (Health.headline(health)?.label ?? "healthy"), action: nil, keyEquivalent: "")
        healthItem.image = StatusBarController.dot(overall)
        healthItem.submenu = healthMenu(health)
        menu.addItem(healthItem)
        let details = NSMenuItem(title: "UPS Details", action: nil, keyEquivalent: "")
        details.submenu = detailsMenu()
        menu.addItem(details)
        menu.addItem(.separator())

        let sim = NSMenuItem(title: "Simulate an Outage", action: nil, keyEquivalent: "")
        sim.submenu = simulationMenu()
        menu.addItem(sim)
        let events = NSMenuItem(title: "Recent Events", action: nil, keyEquivalent: "")
        events.submenu = eventsMenu()
        menu.addItem(events)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.toolTip = "Policy: " + monitor.policyText
        menu.addItem(settings)
        menu.addItem(.separator())

        let agent = NSMenuItem(title: "Run in Background at Login", action: #selector(toggleAgent(_:)), keyEquivalent: "")
        agent.target = self
        agent.state = BackgroundAgent.isEnabled ? .on : .off
        if BackgroundAgent.status == .requiresApproval { agent.title = "Run in Background at Login (approve in System Settings)" }
        if !BackgroundAgent.isAvailable {
            agent.isEnabled = false
            agent.toolTip = "This binary has no agent plist (a bare swift build). Use ./build.sh run or install."
        } else if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            agent.toolTip = "This copy runs from \(Bundle.main.bundlePath). Registering points launchd at this path; use ./build.sh install for the real thing."
        } else {
            agent.toolTip = "A launchd agent starts the app at login and restarts it if it crashes. Quit stays quit."
        }
        menu.addItem(agent)
        addUpdateItems()
        menu.addItem(.separator())

        let versionText = StatusBarController.versionString()
        let version = NSMenuItem(title: versionText, action: #selector(copyValue(_:)), keyEquivalent: "")
        version.target = self
        version.representedObject = versionText
        version.toolTip = "Click to copy"
        menu.addItem(version)
        versionItem = version
        updateVersionRow()
        menu.addItem(NSMenuItem(title: "Quit Nimbus UPS Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Outage actions

    private func addActionRows() {
        let st = monitor.shown.status
        guard st.phase.isOutage || st.volumes.contains(where: \.unmountedByGuard) else { return }
        let now = action("Unmount Now", #selector(unmountNow))
        now.toolTip = "Go straight to the hard limit: every protected volume is force-unmounted."
        menu.addItem(now); actionItems["unmount"] = now
        let post = action("Postpone \(Duration.text(Settings.shared.postponeSeconds))", #selector(postpone))
        post.toolTip = "Push the soft stage and the time limit out by \(Duration.text(Settings.shared.postponeSeconds)) (Settings › General). The charge and runtime limits still apply."
        menu.addItem(post); actionItems["postpone"] = post
        let skip = action("Don't Quit Apps This Outage", #selector(skipQuitting))
        skip.toolTip = "Leave the apps alone; volumes unmount only at the hard limit or when their apps let go."
        menu.addItem(skip); actionItems["skip"] = skip
        let remount = action("Remount Now", #selector(remountNow))
        menu.addItem(remount); actionItems["remount"] = remount
        menu.addItem(.separator())
        updateActionRows()
    }

    private func updateActionRows() {
        guard !actionItems.isEmpty else { return }
        let st = monitor.shown.status
        let mounted = st.volumes.contains { $0.volume.isMounted }
        actionItems["unmount"]?.isEnabled = st.phase.isOutage && st.phase != .safe && mounted
        actionItems["postpone"]?.isEnabled = st.phase == .holding || st.phase == .soft
        if st.postponedBy > 0 { actionItems["postpone"]?.title = "Postpone \(Duration.text(Settings.shared.postponeSeconds)) More (postponed \(Duration.text(st.postponedBy)))" }
        actionItems["skip"]?.isEnabled = (st.phase == .holding || st.phase == .soft) && st.quitAppsThisOutage
        actionItems["skip"]?.title = st.quitAppsThisOutage ? "Don't Quit Apps This Outage" : "Apps Will Not Be Quit This Outage"
        actionItems["remount"]?.isEnabled = !st.phase.isOutage && st.volumes.contains { $0.unmountedByGuard && $0.volume.isAttached && !$0.volume.isMounted }
    }

    // MARK: Volume rows

    private func addVolumeRows() {
        let header = disabled("Protected Volumes")
        header.attributedTitle = NSAttributedString(string: "PROTECTED VOLUMES", attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize).withWeight(.semibold), .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(header)
        let all = monitor.volumes.sorted
        if all.isEmpty {
            menu.addItem(disabled("No external volumes"))
            return
        }
        for v in all {
            let it = NSMenuItem(title: v.name, action: nil, keyEquivalent: "")
            it.submenu = volumeMenu(v)
            menu.addItem(it)
            volumeItems[v.uuid] = it
        }
        updateVolumeRows()
    }

    private func updateVolumeRows() {
        let st = monitor.shown.status
        for (uuid, it) in volumeItems {
            guard let v = monitor.volumes.volumes[uuid] else { continue }
            let report = st.volumes.first { $0.volume.uuid == uuid }
            let protected = Settings.shared.isProtected(v)
            var state: String
            var level: Health.Level
            if !v.isAttached { state = "not attached"; level = .bad }
            else if v.isMounted {
                state = "mounted"
                level = .good
                if let r = report, !r.appHolders.isEmpty {
                    state += " · " + r.appHolders.map(\.shortName).uniqued().joined(separator: ", ")
                    level = st.phase.isOutage ? .warning : .good
                }
                if let r = report, r.inFlight { state = "unmounting…"; level = .warning }
            } else {
                state = report?.unmountedByGuard == true ? "unmounted by the guard" : "attached, not mounted"
                level = .warning
            }
            if let e = report?.lastError { state += " · ⚠︎ \(e)" }
            if !protected { state += " · not protected" }
            let t = NSMutableAttributedString(string: v.name, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: protected ? NSColor.labelColor : NSColor.secondaryLabelColor])
            t.append(NSAttributedString(string: "  " + state, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
            it.attributedTitle = t
            it.image = StatusBarController.dot(protected ? level : .good, hollow: !protected || !v.isMounted)
            it.toolTip = v.detail + (v.bsdName.map { "\n\($0)" } ?? "") + "\n" + v.uuid
        }
    }

    private func volumeMenu(_ v: VolumeState) -> NSMenu {
        let m = NSMenu()
        if v.isMounted {
            let u = NSMenuItem(title: "Unmount \(v.name) Now", action: #selector(unmountVolume(_:)), keyEquivalent: "")
            u.target = self; u.representedObject = v.uuid
            u.toolTip = "Force-unmount, as the guard would. Nothing remounts it for you."
            m.addItem(u)
        } else if v.isAttached {
            let mt = NSMenuItem(title: "Mount \(v.name)", action: #selector(mountVolume(_:)), keyEquivalent: "")
            mt.target = self; mt.representedObject = v.uuid
            m.addItem(mt)
        }
        m.addItem(.separator())
        m.addItem(row(label: "Volume UUID", value: v.uuid, copy: v.uuid))
        if let b = v.bsdName { m.addItem(row(label: "Device", value: "/dev/\(b)", copy: b)) }
        if let p = v.mountPoint { m.addItem(row(label: "Mounted at", value: p, copy: p)) }
        if !v.detail.isEmpty { m.addItem(row(label: "Drive", value: v.detail, copy: v.detail)) }
        if let mp = v.mountPoint {
            m.addItem(.separator())
            let holders = Holders.list(mountPoint: mp)
            if holders.isEmpty {
                m.addItem(disabled("Nothing has files open on it"))
            } else {
                let h = disabled("Processes with files open")
                m.addItem(h)
                for holder in holders {
                    let never = Settings.shared.policy.isNeverQuit(holder)
                    let text = holder.isApp ? "\(holder.shortName)  (pid \(holder.pid))\(never ? " · never quit" : "")" : "\((holder.executable as NSString).lastPathComponent)  (pid \(holder.pid)) · daemon, not asked"
                    let it = NSMenuItem(title: text, action: #selector(copyValue(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = holder.executable
                    it.indentationLevel = 1
                    it.toolTip = holder.executable
                    m.addItem(it)
                }
            }
        }
        return m
    }

    // MARK: Health and details

    private func healthMenu(_ items: [Health.Item]) -> NSMenu {
        let m = NSMenu()
        for h in items {
            let it = NSMenuItem(title: h.text, action: h.detail == nil ? nil : #selector(showDetail(_:)), keyEquivalent: "")
            it.target = self
            it.image = StatusBarController.dot(h.level)
            it.toolTip = h.detail
            it.representedObject = h
            m.addItem(it)
        }
        m.addItem(.separator())
        let test = NSMenuItem(title: "Run Battery Self-Test…", action: #selector(runSelfTest), keyEquivalent: "")
        test.target = self
        test.isEnabled = monitor.hid.isAttached && monitor.simulation == nil && !(monitor.reading.present && monitor.reading.onBattery)
        test.toolTip = "The UPS's own quick test: about ten seconds on battery, then a pass/fail result. The one thing this app ever writes to the UPS."
        m.addItem(test)
        return m
    }

    private func detailsMenu() -> NSMenu {
        let m = NSMenu()
        if let rep = monitor.hidReport {
            var section = ""
            for f in rep.fields {
                if f.section != section {
                    section = f.section
                    if m.items.count > 0 { m.addItem(.separator()) }
                    let h = disabled(section.uppercased())
                    h.attributedTitle = NSAttributedString(string: section.uppercased(), attributes: [
                        .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize).withWeight(.semibold), .foregroundColor: NSColor.secondaryLabelColor])
                    m.addItem(h)
                }
                m.addItem(row(label: f.label, value: f.value, copy: f.value))
            }
            m.addItem(.separator())
            let age = monitor.hidReadAtAge.map { "read \(Duration.text($0)) ago in \(rep.readMillis) ms" } ?? ""
            m.addItem(disabled("USB HID report · \(age)"))
        } else {
            m.addItem(disabled(monitor.hid.isAttached ? "Reading the UPS…" : "UPS not reachable over USB HID"))
        }
        let raw = PowerSources.rawUPSDescription()
        if !raw.isEmpty {
            m.addItem(.separator())
            let h = disabled("MACOS POWER SOURCE")
            h.attributedTitle = NSAttributedString(string: "MACOS POWER SOURCE (pmset -g ps)", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize).withWeight(.semibold), .foregroundColor: NSColor.secondaryLabelColor])
            m.addItem(h)
            for (k, v) in raw { m.addItem(row(label: k, value: v, copy: v)) }
        }
        if let b = monitor.internalBattery {
            m.addItem(.separator())
            m.addItem(row(label: "Mac's battery", value: "\(b.percent) %\(b.isCharging ? ", charging" : "")\(b.onAC ? ", on AC" : ", discharging")", copy: "\(b.percent)"))
        }
        return m
    }

    // MARK: Simulation, policy, volumes to protect, events

    private func simulationMenu() -> NSMenu {
        let m = NSMenu()
        if let sim = monitor.simulation {
            let s = disabled("")
            simulationStatusItem = s
            m.addItem(s)
            m.addItem(action("End Simulation", #selector(endSimulation)))
            refreshLiveRows()
            if sim.kind == .drill { m.addItem(disabled("A drill really unmounts; ending it early leaves volumes as they are")) }
        } else {
            m.addItem(disabled("Rehearse (nothing is touched, 10× speed):"))
            for scenario in SimulatedOutage.Scenario.allCases {
                let r = action(scenario.title, #selector(startRehearsal(_:)))
                r.representedObject = scenario.rawValue
                r.indentationLevel = 1
                r.toolTip = "Plays a pretend outage at 10× speed against the real volumes and the real apps holding them, under the current policy, and logs what it would do: which apps it would ask to quit, when it would unmount, whether it would sleep or shut down. Nothing is quit, unmounted, slept or shut down."
                m.addItem(r)
            }
            m.addItem(.separator())
            let d = action("Drill: Simulate an Outage With Real Unmounts…", #selector(startDrill))
            d.toolTip = "A pretend outage at 5× speed with real actions: apps holding files are asked to quit, the protected volumes are force-unmounted, and remounted when the pretend power returns. Never sleeps or shuts down the Mac."
            d.isEnabled = !(monitor.reading.present && monitor.reading.onBattery)
            m.addItem(d)
            m.addItem(.separator())
            m.addItem(disabled("The real test is pulling the UPS's plug with the log open."))
        }
        return m
    }

    private func eventsMenu() -> NSMenu {
        let m = NSMenu()
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let recent = Log.shared.recent.suffix(18)
        if recent.isEmpty { m.addItem(disabled("Nothing yet")) }
        for e in recent {
            var line = e.line
            if line.count > 96 { line = String(line.prefix(93)) + "…" }
            let it = NSMenuItem(title: "", action: #selector(copyValue(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.line
            it.toolTip = e.line
            let t = NSMutableAttributedString(string: f.string(from: e.date) + "  ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor])
            t.append(NSAttributedString(string: line, attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)]))
            it.attributedTitle = t
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(action("Open Log File", #selector(openLog)))
        return m
    }

    // MARK: Updates (the same rows as the sibling apps)

    private func addUpdateItems() {
        guard let updater else { return }
        switch updater.state {
        case .ready(let release) where updater.canInstall:
            let install = action("Install Update \(release.version) and Relaunch", #selector(installUpdate))
            let firstLines = release.notes.split(separator: "\n").prefix(3).joined(separator: "\n")
            install.toolTip = firstLines.isEmpty ? "Downloaded and checked against this app's Developer ID. Installs in a few seconds." : firstLines
            menu.addItem(install)
        case .available(let release):
            let it = action("Update \(release.version) Available…", #selector(openUpdatePage))
            it.toolTip = updater.canInstall
                ? "That release has no installable download; this opens its page."
                : "Updates install only into /Applications, and this copy runs from \(Bundle.main.bundlePath). Opens the release page."
            menu.addItem(it)
        case .downloading(let release):
            menu.addItem(disabled("Downloading \(release.version)…"))
        case .installing:
            menu.addItem(disabled("Installing…"))
        default:
            break
        }
        let check = action("Check for Updates…", #selector(checkForUpdates))
        switch updater.state {
        case .checking, .downloading, .installing: check.isEnabled = false
        default: break
        }
        menu.addItem(check)
        if updater.canInstall {
            let auto = NSMenuItem(title: "Check for Updates Automatically", action: #selector(toggleAutomaticUpdates(_:)), keyEquivalent: "")
            auto.target = self
            auto.state = updater.automaticChecks ? .on : .off
            auto.toolTip = "Once a day, asks github.com for the newest release and downloads it."
            menu.addItem(auto)
        }
    }

    func updaterChanged() {
        guard menuOpen else { return }
        updateVersionRow()
    }

    private func updateVersionRow() {
        guard let item = versionItem else { return }
        var text = StatusBarController.versionString()
        if let updater, case .ready(let release) = updater.state { text += "  ·  \(release.version) ready" }
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
    }

    // MARK: Actions

    @objc private func unmountNow() { monitor.unmountNow() }
    @objc private func postpone() { monitor.postpone(seconds: Settings.shared.postponeSeconds) }
    @objc private func skipQuitting() { monitor.skipQuittingApps() }
    @objc private func remountNow() { monitor.remountNow() }

    @objc private func unmountVolume(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String, let v = monitor.volumes.volumes[uuid] else { return }
        let alert = NSAlert()
        alert.messageText = "Unmount \(v.name) now?"
        let holders = v.mountPoint.map(Holders.list) ?? []
        let apps = holders.filter(\.isApp).map(\.shortName).uniqued()
        alert.informativeText = (apps.isEmpty ? "Nothing has files open on it." : "\(apps.joined(separator: ", ")) still ha\(apps.count == 1 ? "s" : "ve") files open on it; the unmount is forced, and they will lose them.")
            + " The volume stays unmounted until you mount it again."
        alert.addButton(withTitle: "Unmount")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { monitor.unmount(v) }
    }

    @objc private func mountVolume(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String, let v = monitor.volumes.volumes[uuid] else { return }
        monitor.mount(v)
    }

    @objc private func showDetail(_ sender: NSMenuItem) {
        guard let h = sender.representedObject as? Health.Item, let d = h.detail else { return }
        let alert = NSAlert()
        alert.messageText = h.text
        alert.informativeText = d
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func runSelfTest() {
        let alert = NSAlert()
        alert.messageText = "Run the UPS's quick battery self-test?"
        alert.informativeText = "The UPS switches its outlets to battery for about ten seconds and reports whether the battery held up. Everything plugged in keeps running, as in a real outage. Do it on line power with nothing critical mid-flight."
        alert.addButton(withTitle: "Run Test")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !monitor.runSelfTest() {
            let fail = NSAlert()
            fail.messageText = "Could not start the self-test"
            fail.informativeText = "The UPS refused the command, or no UPS is reachable over USB. See the log."
            fail.runModal()
        }
    }

    @objc private func startRehearsal(_ sender: NSMenuItem) {
        monitor.startRehearsal(SimulatedOutage.Scenario(rawValue: sender.representedObject as? String ?? "") ?? .drain)
    }

    @objc private func startDrill() {
        let names = monitor.volumes.mounted.filter { Settings.shared.isProtected($0) }.map(\.name)
        let alert = NSAlert()
        alert.messageText = "Run an outage drill with real unmounts?"
        alert.informativeText = (names.isEmpty ? "No protected volume is mounted, so nothing will be unmounted; the drill just shows the stages."
            : "Apps with files open on \(names.joined(separator: ", ")) will be asked to quit (as from their Quit menu), then the volume\(names.count == 1 ? " is" : "s are") force-unmounted and remounted when the pretend power returns.")
            + " Time runs 5× faster than the policy says. Save your work first."
        alert.addButton(withTitle: "Start Drill")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { monitor.startDrill() }
    }

    @objc private func endSimulation() { monitor.endSimulation() }

    @objc private func openSettings() { AppDelegate.shared?.showSettings() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        let turnOn = !BackgroundAgent.isEnabled
        UserDefaults.standard.set(true, forKey: BackgroundAgent.registeredDefaultsKey)
        AppDelegate.shared?.setAgent(enabled: turnOn)
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func installUpdate() { updater?.installAndRelaunch() }
    @objc private func openUpdatePage() { updater?.openReleasePage() }
    @objc private func toggleAutomaticUpdates(_ sender: NSMenuItem) {
        guard let updater else { return }
        updater.automaticChecks.toggle()
        sender.state = updater.automaticChecks ? .on : .off
    }
    @objc private func checkForUpdates() {
        guard let updater else { return }
        Task { @MainActor in updater.presentCheckResult(await updater.checkNow()) }
    }

    // MARK: Helpers

    private static let monoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// "Label  value" row; click copies `copy`.
    private func row(label: String, value: String, copy: String?) -> NSMenuItem {
        let it = NSMenuItem(title: "\(label) \(value)", action: copy == nil ? nil : #selector(copyValue(_:)), keyEquivalent: "")
        it.target = self
        it.indentationLevel = 1
        it.representedObject = copy
        let s = NSMutableAttributedString(string: label + "  ", attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor])
        s.append(NSAttributedString(string: value, attributes: [.font: StatusBarController.monoFont, .foregroundColor: NSColor.labelColor]))
        it.attributedTitle = s
        it.toolTip = copy == nil ? nil : "Click to copy"
        return it
    }

    private func viewItem(_ v: NSView) -> NSMenuItem { let it = NSMenuItem(); it.view = v; return it }

    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    static func dot(_ level: Health.Level, hollow: Bool = false) -> NSImage {
        let color: NSColor
        var hollow = hollow
        switch level {
        case .good: color = .systemGreen
        case .info: color = .tertiaryLabelColor; hollow = true
        case .warning: color = .systemYellow
        case .bad: color = .systemRed
        }
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let p = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if hollow { color.setStroke(); p.lineWidth = 1.5; p.stroke() } else { color.setFill(); p.fill() }
            return true
        }
        return img
    }

    static func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? "Nimbus UPS Bar"
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "\(name) — dev build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(name) v\(short) (\($0))" } ?? "\(name) v\(short)"
    }
}

extension UPSMonitor {
    var hidReadAtAge: TimeInterval? { hidReadAt.map { monotonicNow() - $0 } }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array where Element == String {
    func join() -> String { joined(separator: " · ") }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
