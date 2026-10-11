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
        visibilityChanged()
    }

    /// Several notifications arrive per read (the poll, the HID result, a log line): one
    /// rebuild for the lot.
    private func scheduleRefresh() {
        guard window?.isVisible == true, !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.model.refresh()
                self.sidebar.reload()
                self.detail.reload()
            }
        }
    }

    private func visibilityChanged() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        if model.monitor.inspectorOpen != visible { model.monitor.inspectorOpen = visible }
        if visible { scheduleRefresh() }
    }

    func windowWillClose(_ notification: Notification) {
        model.monitor.inspectorOpen = false
    }
}

// MARK: - Sidebar

@MainActor
final class InspectorSidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: InspectorModel
    var onSelect: ((String) -> Void)?
    private let table = NSTableView()
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
        view = scroll
    }

    func reload() {
        var e = [(id: "unified", title: "Unified", symbol: "square.stack.3d.up", badge: nil as String?)]
        e += model.sections.map { (id: $0.id, title: $0.title, symbol: $0.symbol, badge: nil as String?) }
        e.append((id: "changes", title: "Changes", symbol: "arrow.triangle.2.circlepath", badge: model.changes.isEmpty ? nil : "\(min(model.changes.count, 999))"))
        e.append((id: "events", title: "Events", symbol: "list.bullet.rectangle", badge: nil))
        e.append((id: "log", title: "Log File", symbol: "doc.plaintext", badge: nil))
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
final class InspectorDetail: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let model: InspectorModel
    private(set) var current = "ups"
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let mode = NSSegmentedControl(labels: ["Table", "JSON"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let tableScroll = NSScrollView()
    private let text = NSTextView()
    private let textScroll = NSScrollView()
    private var copied: NSButton!
    /// A section's own actions: Show Progress under Events, Clear under Changes, Open Log File
    /// and Show in Finder under Log File.
    private var extra: NSButton!
    private var extra2: NSButton!
    private var showProgress = false
    /// The Log File view: the file's tail, followed as it grows.
    private let logText = NSTextView()
    private let logScroll = NSScrollView()
    private var logOffset: UInt64 = 0
    private var logPathShown = ""
    static let logTail: UInt64 = 2_000_000

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
        logText.isEditable = false
        logText.isSelectable = true
        logText.usesFindBar = true
        logText.isIncrementalSearchingEnabled = true
        logText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logText.textContainerInset = NSSize(width: 10, height: 10)
        logText.isVerticallyResizable = true
        logText.autoresizingMask = [.width]
        logScroll.documentView = logText
        logScroll.hasVerticalScroller = true
        logScroll.isHidden = true

        let titles = NSStackView(views: [titleLabel, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        extra = NSButton(title: "", target: self, action: #selector(extraAction))
        extra.isHidden = true
        extra2 = NSButton(title: "Show in Finder", target: self, action: #selector(revealLog))
        extra2.isHidden = true
        let buttons = NSStackView(views: [extra, extra2, mode, copied])
        buttons.spacing = 8
        // The buttons are pinned to the right edge, so they stay put in every section whatever
        // the title and subtitle say; "Copied" does not resize Copy Page either. A section's
        // own buttons (Show Progress, Open Log File…) grow leftwards from the segmented control.
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        copied.widthAnchor.constraint(equalToConstant: 96).isActive = true
        for x in [titles, buttons, tableScroll, textScroll, logScroll] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        NSLayoutConstraint.activate([
            titles.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 12),
            titles.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            titles.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -16),
            buttons.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            buttons.centerYAnchor.constraint(equalTo: titles.centerYAnchor),
            tableScroll.topAnchor.constraint(equalTo: titles.bottomAnchor, constant: 12),
            tableScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            textScroll.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            logScroll.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            logScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            logScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
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
            : "Copy this page as JSON (in Table view too; the Log File as its text): the form to paste into an agent."
        let isLog = id == "log"
        mode.isHidden = isLog
        tableScroll.isHidden = isLog || showingJSON
        textScroll.isHidden = isLog || !showingJSON
        logScroll.isHidden = !isLog
        extra.isHidden = !["events", "changes", "log"].contains(id)
        extra2.isHidden = !isLog
        switch id {
        case "events": extra.title = showProgress ? "Hide Progress Lines" : "Show Progress Lines"; extra.toolTip = "The once-a-minute \"on battery …\" readings during an outage"
        case "changes": extra.title = "Clear"; extra.toolTip = "Forget the changes seen so far"
        default: extra.title = "Open Log File"; extra.toolTip = Log.fileURL.path
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
        case "events", "log": return model.logJSON()
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
        case "log":
            titleLabel.stringValue = "Log File"
            followLog(force: force)
            return
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
        subtitle.toolTip = subtitle.stringValue
        if showingJSON {
            let json = Inspector.json(currentJSON())
            if force || text.string != json {
                let visible = textScroll.contentView.bounds.origin
                text.string = json
                if !force { textScroll.contentView.scroll(to: visible) }
            }
        } else {
            let visible = tableScroll.contentView.bounds.origin
            table.reloadData()
            if !force { tableScroll.contentView.scroll(to: visible) }
        }
    }

    @objc private func extraAction() {
        switch current {
        case "log": NSWorkspace.shared.open(Log.fileURL)
        case "events": showProgress.toggle(); reload(force: true)
        default: model.clearChanges(); reload(force: true)
        }
    }

    @objc private func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }

    @objc private func copySection() {
        put(current == "log" ? logText.string : Inspector.json(currentJSON()), on: copied, title: copyTitle)
    }

    /// The log file's last `logTail` bytes, then whatever is appended, keeping the view at the
    /// bottom when it was there. A file that shrank (rotated, deleted) is read again from its tail.
    private func followLog(force: Bool) {
        let url = Log.fileURL
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        let atBottom = logScroll.contentView.bounds.maxY >= (logText.frame.height - 20)
        if force || size < logOffset || logPathShown != url.path {
            logOffset = size > InspectorDetail.logTail ? size - InspectorDetail.logTail : 0
            logText.string = ""
            logPathShown = url.path
        }
        if size > logOffset, let h = try? FileHandle(forReadingFrom: url) {
            try? h.seek(toOffset: logOffset)
            let data = h.readDataToEndOfFile()
            try? h.close()
            logOffset += UInt64(data.count)
            var chunk = String(decoding: data, as: UTF8.self)
            if logText.string.isEmpty, logOffset > UInt64(data.count), let nl = chunk.firstIndex(of: "\n") {
                chunk = String(chunk[chunk.index(after: nl)...])   // start on a whole line
            }
            logText.textStorage?.append(NSAttributedString(string: chunk, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]))
            if force || atBottom { logText.scrollToEndOfDocument(nil) }
        }
        let mb = Double(size) / 1_000_000
        subtitle.stringValue = "\(url.path) · \(String(format: mb < 0.1 ? "%.0f KB" : "%.1f MB", mb < 0.1 ? Double(size) / 1000 : mb))"
            + (size > InspectorDetail.logTail ? " · showing the last 2 MB" : "") + " · ⌘F to search"
        subtitle.toolTip = subtitle.stringValue
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
            let t = NSTextField(labelWithString: id == "label" ? f.string(from: date) : id == "value" ? line : kind.title)
            t.lineBreakMode = .byTruncatingTail
            t.isSelectable = true
            t.toolTip = line
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
            let t = NSTextField(labelWithString: value)
            t.lineBreakMode = .byTruncatingTail
            t.isSelectable = true
            t.toolTip = value.isEmpty ? nil : value
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
