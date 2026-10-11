// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater
import NimbusUpsBarKit
import UpsGuardCore

/// The Inspector: everything the app knows, live. A sidebar of sections (the UPS over USB,
/// macOS's entry, health, the guard, the volumes, the readings, the background agent, what
/// changed, the log); each shows as a table whose changed rows flash, or as the JSON an agent
/// can be handed, with Copy Page for either (`--inspect-json` prints the whole snapshot). While it
/// is on screen the UPS is read as often as on battery.
@MainActor
final class InspectorWindowController: NSWindowController, NSWindowDelegate {
    let model: InspectorModel
    let split = NSSplitViewController()
    let sidebar: InspectorSidebar
    let detail: InspectorDetail
    private var observers: [NSObjectProtocol] = []
    private var pending = false
    /// Live updates on: every read redraws the pages and flashes what changed. Off: the pages
    /// hold still (for a close look, or when the flashing distracts) until Refresh or until
    /// it is turned back on; the UPS goes back to its normal pace meanwhile. Remembered.
    static let liveKey = "inspectorLive"
    private(set) var live = UserDefaults.standard.object(forKey: InspectorWindowController.liveKey) as? Bool ?? true
    /// Refresh while paused: take the next update, then hold still again.
    private var oneShot = false

    init(monitor: UPSMonitor, updater: Updater?) {
        model = InspectorModel(monitor: monitor, updater: updater)
        detail = InspectorDetail(model: model)
        sidebar = InspectorSidebar(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Inspector"
        window.minSize = NSSize(width: 720, height: 420)
        window.setFrameAutosaveName("Inspector")
        super.init(window: window)
        window.delegate = self
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 200
        side.maximumThickness = 260
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 960, height: 620))
        sidebar.onSelect = { [weak self] id in self?.detail.show(id) }
        sidebar.onLive = { [weak self] on in self?.setLive(on) }
        sidebar.onRefresh = { [weak self] in self?.refreshOnce() }
        sidebar.setLive(live)
        detail.paused = !live
        model.refresh()
        sidebar.reload()
        sidebar.select("unified")
        for name in [UPSMonitor.didUpdate, Log.didAppend] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        })
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Opening the window always takes one full, fresh look, live updates on or off.
        refreshOnce()
        visibilityChanged()
        // Whether anyone can see the window (another Space, a full-screen app, the window
        // covered) changes without a reliable notification: while it is open, look once a
        // second rather than rely on one.
        visibilityTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        }
        RunLoop.main.add(t, forMode: .common)
        visibilityTimer = t
    }
    private var visibilityTimer: Timer?

    /// Edit › Find (⌘F), through the responder chain.
    @objc func focusSearch(_ sender: Any?) { detail.focusSearch() }

    func windowDidChangeOcclusionState(_ notification: Notification) { visibilityChanged() }
    func windowDidMiniaturize(_ notification: Notification) { visibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { visibilityChanged() }

    /// Several notifications arrive per read (the poll, the HID result, a log line): one
    /// rebuild for the lot.
    func setLive(_ on: Bool) {
        live = on
        UserDefaults.standard.set(on, forKey: InspectorWindowController.liveKey)
        sidebar.setLive(on)
        detail.paused = !on
        visibilityChanged()
        detail.reload()
    }

    /// One fresh look while paused: read the UPS now and redraw once the result is in.
    private func refreshOnce() {
        oneShot = true
        model.monitor.readNow()
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard window?.isVisible == true, !pending, live || oneShot else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                // A one-shot refresh waits for the HID read it asked for, then stops.
                if !self.live, self.oneShot, self.model.monitor.hid.isAttached,
                   self.model.monitor.hidReadAt.map({ monotonicNow() - $0 > 1 }) ?? true { return }
                self.oneShot = false
                self.model.refresh()
                self.sidebar.reload()
                self.detail.reload()
            }
        }
    }

    private func visibilityChanged() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        // The full HID capture whenever the window can be seen; the fast pace only while live.
        let fast = visible && live
        let becameVisible = visible && !model.monitor.inspectorVisible
        if model.monitor.inspectorVisible != visible { model.monitor.inspectorVisible = visible }
        if model.monitor.inspectorOpen != fast { model.monitor.inspectorOpen = fast }
        // Shown again (from another Space, unminimised) while paused: one complete look.
        if becameVisible, !live { refreshOnce() }
        if visible, fast != wasFast { scheduleRefresh() }
        wasFast = fast
    }
    private var wasFast = false

    func windowWillClose(_ notification: Notification) {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
        model.monitor.inspectorOpen = false
        model.monitor.inspectorVisible = false
        model.reset()
        sidebar.reload()
    }
}

// MARK: - Sidebar

@MainActor
final class InspectorSidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: InspectorModel
    var onSelect: ((String) -> Void)?
    var onLive: ((Bool) -> Void)?
    var onRefresh: (() -> Void)?
    private let table = NSTableView()
    private var liveBox: NSButton!
    private var refreshButton: NSButton!
    private(set) var entries: [(id: String, title: String, symbol: String, badge: String?)] = []

    init(model: InspectorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        table.style = .sourceList
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("s")))
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        scroll.documentView = table
        // At the foot of the sidebar: one setting for the whole window, in the same place
        // whichever page is showing.
        liveBox = NSButton(checkboxWithTitle: "Live updates", target: self, action: #selector(liveToggled))
        liveBox.toolTip = "On: the pages follow every read and flash what changed. Off: they hold still until Refresh."
        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.controlSize = .small
        refreshButton.bezelStyle = .rounded
        let foot = NSStackView(views: [liveBox, refreshButton])
        foot.spacing = 8
        let v = NSView()
        for x in [scroll, foot] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -8),
            foot.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            foot.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -8),
            foot.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
            foot.heightAnchor.constraint(equalToConstant: 22),
        ])
        view = v
    }

    func setLive(_ on: Bool) {
        _ = view
        liveBox.state = on ? .on : .off
        refreshButton.isHidden = on
    }

    @objc private func liveToggled() { onLive?(liveBox.state == .on) }
    @objc private func refreshClicked() { onRefresh?() }

    func reload() {
        var e = [(id: "unified", title: "Unified", symbol: "square.stack.3d.up", badge: nil as String?)]
        e += model.sections.map { (id: $0.id, title: $0.title, symbol: $0.symbol, badge: nil as String?) }
        e.append((id: "changes", title: "Changes", symbol: "arrow.triangle.2.circlepath", badge: model.changes.isEmpty ? nil : "\(min(model.changes.count, 999))"))
        e.append((id: "events", title: "Events", symbol: "list.bullet.rectangle", badge: nil))
        let selected = table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow].id : nil
        let structural = e.map(\.id) != entries.map(\.id)
        entries = e
        if structural { table.reloadData() } else { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<entries.count), columnIndexes: [0]) }
        if let selected { select(selected, notify: false) }
    }

    func select(_ id: String, notify: Bool = true) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes([i], byExtendingSelection: false)
        if notify { onSelect?(id) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = entries[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil) ?? NSImage())
        let text = NSTextField(labelWithString: e.title)
        let badge = NSTextField(labelWithString: e.badge ?? "")
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        badge.textColor = .secondaryLabelColor
        for v in [image, text, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard r >= 0, r < entries.count else { return }
        onSelect?(entries[r].id)
    }
}

// MARK: - Detail

/// One section: a header (title, how fresh, Table/JSON, Copy Page) over the table or the
/// JSON text.
@MainActor
final class InspectorDetail: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let model: InspectorModel
    private(set) var current = "ups"
    /// Live updates are off: the subtitle says so.
    var paused = false
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["Table", "JSON"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let text = NSTextView()
    private let textScroll = NSScrollView()
    private var copied: NSButton!
    /// A section's own actions: Show Progress, Open Log File and Show in Finder under Events
    /// (which has no copy button), Clear under Changes.
    private var extra: NSButton!
    private var extra2: NSButton!
    private var openLog: NSButton!
    private var showProgress = false
    /// Search: plain text, the open page only. The table keeps the rows that match (and their
    /// headings); the JSON keeps everything and highlights the matches, Return stepping through
    /// them. The query stays when the page changes; Copy Page copies the whole page regardless.
    private let search = NSSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private var query: String { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var jsonMatches: [NSRange] = []
    private var matchIndex = 0

    /// What the table shows: a group heading or a row (with the flash key).
    private enum Line { case group(String); case row(Inspector.Row, flashKey: String?); case event(LogEvent.Kind, Date, String) }
    private var lines: [Line] = []

    var showingJSON: Bool { mode.selectedSegment == 1 }

    init(model: InspectorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        copied = NSButton(title: "Copy Page", target: self, action: #selector(copySection))

        for (id, title, width) in [("label", "Field", 230.0), ("value", "Value", 290.0), ("detail", "Detail", 210.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.resizingMask = .userResizingMask
            table.addTableColumn(c)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true

        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true
        textScroll.isHidden = true

        let titles = NSStackView(views: [titleLabel, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        extra = NSButton(title: "", target: self, action: #selector(extraAction))
        extra.isHidden = true
        openLog = NSButton(title: "Open Log File", target: self, action: #selector(openLogFile))
        openLog.toolTip = Log.fileURL.path
        openLog.isHidden = true
        extra2 = NSButton(title: "Show in Finder", target: self, action: #selector(revealLog))
        extra2.toolTip = Log.fileURL.path
        extra2.isHidden = true
        search.placeholderString = "Search this page"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self
        search.toolTip = "Plain text, ignoring case, on this page only. Table: only the matching rows. JSON: the matches highlighted; Return goes to the next."
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let searchRow = NSStackView(views: [search, matchLabel])
        searchRow.spacing = 8
        search.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let buttons = NSStackView(views: [extra, mode, openLog, extra2, copied])
        buttons.spacing = 8
        // The buttons are pinned to the right edge, so they stay put in every section whatever
        // the title and subtitle say; "Copied" does not resize Copy Page either. A section's
        // own buttons (Show Progress, Clear) grow leftwards; Events trades Copy Page for the log buttons from the segmented control.
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        copied.widthAnchor.constraint(equalToConstant: 96).isActive = true
        for x in [titles, buttons, searchRow, tableScroll, textScroll] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            titles.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 12),
            titles.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            buttons.centerYAnchor.constraint(equalTo: titles.centerYAnchor),
            searchRow.topAnchor.constraint(equalTo: titles.bottomAnchor, constant: 10),
            searchRow.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            searchRow.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -16),
            tableScroll.topAnchor.constraint(equalTo: searchRow.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            textScroll.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])
        view = v
    }

    func show(_ id: String) {
        current = id
        table.scrollRowToVisible(0)
        text.scrollToBeginningOfDocument(nil)
        reload(force: true)
    }

    func selectMode(json: Bool) {
        mode.selectedSegment = json ? 1 : 0
        modeChanged()
    }

    @objc private func modeChanged() {
        reload(force: true)
    }

    /// The copy button reads Copy All on the Unified page, which is everything.
    private var copyTitle: String { current == "unified" ? "Copy All" : "Copy Page" }

    private func layoutFor(_ id: String) {
        if copied.title != "Copied" { copied.title = copyTitle }
        copied.toolTip = current == "unified"
            ? "Copy every page, the recent changes and the log tail as one JSON document (what --inspect-json prints): the form to paste into an agent."
            : "Copy this page as JSON (in Table view too): the form to paste into an agent."
        tableScroll.isHidden = showingJSON
        textScroll.isHidden = !showingJSON
        extra.isHidden = !["events", "changes"].contains(id)
        extra2.isHidden = id != "events"
        openLog.isHidden = id != "events"
        copied.isHidden = id == "events"
        switch id {
        case "events": extra.title = showProgress ? "Hide Progress Lines" : "Show Progress Lines"; extra.toolTip = "The once-a-minute \"on battery …\" readings during an outage"
        default: extra.title = "Clear"; extra.toolTip = "Forget the changes seen so far"
        }
        let titles: [String]
        switch id {
        case "events": titles = ["Time", "Event", "Kind"]
        case "changes": titles = ["Time and field", "New value", "Old value"]
        default: titles = ["Field", "Value", "Detail"]
        }
        for (c, t) in zip(table.tableColumns, titles) { c.title = t }
    }

    // MARK: Content

    private var section: Inspector.Section? { model.sections.first { $0.id == current } }

    private func currentJSON() -> Any {
        switch current {
        case "unified": return model.snapshot()
        case "changes": return model.changesJSON()
        case "events": return model.logJSON()
        default: return section?.json ?? [:]
        }
    }

    func reload(force: Bool = false) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        layoutFor(current)
        switch current {
        case "changes":
            titleLabel.stringValue = "Changes"
            subtitle.stringValue = "\(model.changes.count) changed values since the Inspector opened · newest first"
            lines = model.changes.map { c in
                .row(Inspector.Row("\(f.string(from: c.at))  \(c.section) › \(c.key)", c.new ?? "(gone)", detail: c.old.map { "was \($0)" } ?? "(new)"), flashKey: nil)
            }
        case "events":
            titleLabel.stringValue = "Events"
            let all = model.recentEvents().reversed().map { (LogEvent.kind(of: $0.1), $0) }
            let shown = all.filter { showProgress || !$0.0.isRoutine }
            subtitle.stringValue = "What the app decided and did, newest first, from the log file · \(shown.count) of its last \(all.count) lines"
            lines = shown.map { .event($0.0, $0.1.0, $0.1.1) }
        case "unified":
            titleLabel.stringValue = "Unified"
            subtitle.stringValue = "Every page in one place; the JSON adds the recent changes and the log · updated \(f.string(from: model.updatedAt))"
            var out: [Line] = []
            var heading = ""
            for s in model.sections {
                for r in s.rows {
                    let h = s.title + (r.group.map { " › " + $0 } ?? "")
                    if h != heading { out.append(.group(h)); heading = h }
                    out.append(.row(r, flashKey: s.id + " › " + r.key))
                }
            }
            lines = out
        default:
            guard let s = section else { return }
            titleLabel.stringValue = s.title
            subtitle.stringValue = s.subtitle + " · updated \(f.string(from: model.updatedAt))"
            var out: [Line] = []
            var group: String?
            for r in s.rows {
                if r.group != group, let g = r.group { out.append(.group(g)) }
                group = r.group
                out.append(.row(r, flashKey: s.id + " › " + r.key))
            }
            lines = out
        }
        if paused { subtitle.stringValue = "Paused · " + subtitle.stringValue }
        subtitle.toolTip = subtitle.stringValue
        if showingJSON {
            let json = Inspector.json(currentJSON())
            if force || text.string != json {
                let visible = textScroll.contentView.bounds.origin
                text.string = json
                if !force { textScroll.contentView.scroll(to: visible) }
            }
            highlight()
        } else {
            let all = lines.filter { if case .group = $0 { return false }; return true }.count
            lines = Inspector.filter(lines, query: query, heading: { if case .group(let g) = $0 { return g }; return nil }, fields: { line in
                switch line {
                case .row(let r, _): return [r.label, r.value, r.detail]
                case .event(let kind, _, let text): return [text, kind.title]
                case .group: return []
                }
            })
            let shown = lines.filter { if case .group = $0 { return false }; return true }.count
            matchLabel.stringValue = query.isEmpty ? "" : shown == 0 ? "No matches" : "\(shown) of \(all) rows"
            let visible = tableScroll.contentView.bounds.origin
            table.reloadData()
            if !force { tableScroll.contentView.scroll(to: visible) }
        }
    }

    // MARK: Search

    @objc private func searchChanged() {
        matchIndex = 0
        reload(force: true)
        if !showingJSON { table.scrollRowToVisible(0) }
        if showingJSON, let first = jsonMatches.first { reveal(first) }
    }

    /// ⌘F.
    func focusSearch() { view.window?.makeFirstResponder(search) }

    /// For --dump-inspector.
    func setSearch(_ q: String) { search.stringValue = q; searchChanged() }

    /// Return in the search field: the next match in the JSON.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search, selector == #selector(NSResponder.insertNewline(_:)), showingJSON, !jsonMatches.isEmpty else { return false }
        matchIndex = (matchIndex + 1) % jsonMatches.count
        highlight()
        reveal(jsonMatches[matchIndex])
        return true
    }

    /// Every match in the JSON marked, the current one stronger.
    private func highlight() {
        guard let storage = text.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: whole)
        jsonMatches = Inspector.ranges(of: query, in: text.string)
        if matchIndex >= jsonMatches.count { matchIndex = 0 }
        for (i, r) in jsonMatches.enumerated() where i != matchIndex {
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.3), range: r)
        }
        if matchIndex < jsonMatches.count {
            storage.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: jsonMatches[matchIndex])
            storage.addAttribute(.foregroundColor, value: NSColor.black, range: jsonMatches[matchIndex])
        }
        storage.endEditing()
        matchLabel.stringValue = query.isEmpty ? "" : jsonMatches.isEmpty ? "No matches" : "\(matchIndex + 1) of \(jsonMatches.count) matches"
    }

    private func reveal(_ r: NSRange) {
        text.scrollRangeToVisible(r)
        text.showFindIndicator(for: r)
    }

    @objc private func extraAction() {
        switch current {
        case "events": showProgress.toggle(); reload(force: true)
        default: model.clearChanges(); reload(force: true)
        }
    }

    @objc private func openLogFile() { NSWorkspace.shared.open(Log.fileURL) }

    @objc private func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }

    @objc private func copySection() {
        put(Inspector.json(currentJSON()), on: copied, title: copyTitle)
    }


    private func put(_ s: String, on button: NSButton, title: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        button.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { button.title = title } }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = lines[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .event(let kind, let date, let line):
            let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "MMM d HH:mm:ss"
            let id = tableColumn?.identifier.rawValue ?? "label"
            let cell = NSTableCellView()
            let t = InspectorDetail.oneLineLabel(id == "label" ? f.string(from: date) : id == "value" ? line : kind.title)
            t.toolTip = InspectorDetail.tip(line)
            t.translatesAutoresizingMaskIntoConstraints = false
            if id == "label" { t.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular); t.textColor = .secondaryLabelColor }
            if id == "detail" { t.textColor = .secondaryLabelColor; t.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
            if kind == .problem || kind == .outage || kind == .stage { t.font = .systemFont(ofSize: NSFont.systemFontSize, weight: id == "value" ? .semibold : .regular) }
            cell.addSubview(t)
            var leading = t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
            if id == "label" {
                let icon = NSImageView(image: NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title) ?? NSImage())
                icon.contentTintColor = InspectorDetail.color(kind)
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                             icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                             icon.widthAnchor.constraint(equalToConstant: 16)])
                leading = t.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8)
            }
            NSLayoutConstraint.activate([leading, t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                                         t.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        case .group(let g):
            let t = NSTextField(labelWithString: g.uppercased())
            t.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            t.textColor = .secondaryLabelColor
            return t
        case .row(let r, _):
            let id = tableColumn?.identifier.rawValue ?? "label"
            let value: String
            switch id {
            case "label": value = r.label
            case "value": value = r.value
            default: value = r.detail ?? ""
            }
            let cell = NSTableCellView()
            let t = InspectorDetail.oneLineLabel(value)
            if id == "value" { t.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium) }
            if id == "detail" { t.textColor = .secondaryLabelColor; t.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
            t.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(t)
            cell.textField = t
            var leading = t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
            if id == "label", let level = r.level {
                let dot = NSImageView(image: StatusBarController.dot(level))
                dot.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(dot)
                NSLayoutConstraint.activate([dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                             dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                leading = t.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6)
            }
            NSLayoutConstraint.activate([leading, t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
                                         t.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = FlashRowView()
        if case .row(_, let key?) = lines[row], let at = model.changedAt[key], Date().timeIntervalSince(at) < 0.6 { v.flashOnce = true }
        return v
    }
}

extension InspectorDetail {
    /// A table cell's text: one line whatever the value holds (a property's JSON, a long path),
    /// cut with "…"; the whole value is in the tooltip and in the JSON view.
    static func oneLineLabel(_ value: String) -> NSTextField {
        let t = NSTextField(labelWithString: value.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        t.usesSingleLineMode = true
        t.maximumNumberOfLines = 1
        t.cell?.wraps = false
        t.lineBreakMode = .byTruncatingTail
        t.isSelectable = true
        t.toolTip = tip(value)
        return t
    }

    /// Tooltips past a few thousand characters stop being readable: say where the rest is.
    static func tip(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return value.count > 3000 ? String(value.prefix(3000)) + "… (the whole value is in the JSON view)" : value
    }

    /// Status colours for the kinds that are about the outage; the rest stay neutral.
    static func color(_ k: LogEvent.Kind) -> NSColor {
        switch k {
        case .outage: return .systemOrange
        case .stage: return .systemRed
        case .problem: return .systemRed
        case .power: return .systemGreen
        case .volume: return .systemBlue
        case .apps: return .systemPurple
        case .ups: return .systemTeal
        default: return .secondaryLabelColor
        }
    }
}

/// A row that changed in the last update: a warm wash that fades over a second and a half.
final class FlashRowView: NSTableRowView {
    var flashOnce = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard flashOnce, window != nil else { return }
        flashOnce = false
        wantsLayer = true
        let a = CABasicAnimation(keyPath: "backgroundColor")
        a.fromValue = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        a.toValue = NSColor.clear.cgColor
        a.duration = 1.5
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(a, forKey: "flash")
    }
}
