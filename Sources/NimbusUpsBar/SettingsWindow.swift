// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpdater
import UpsGuardCore

/// The Settings window: four panes behind toolbar tabs (Outage, Volumes, Readings, General),
/// every control bound to `Settings` and applied the moment it changes, the way System
/// Settings works. Opened from the menu's Settings… row and ⌘,. One window per app; closing
/// it keeps it for next time.
@MainActor
final class SettingsWindowController: NSWindowController {
    let tabs: SettingsTabs

    init(monitor: UPSMonitor, updater: Updater?) {
        tabs = SettingsTabs(monitor: monitor, updater: updater)
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // A menu bar app is usually not the active app while this window is on screen (the
        // owner clicks elsewhere, or the activation did not stick), and AppKit shows tooltips
        // only for the active app unless the window asks: the Force unmount warning is a tooltip.
        window.allowsToolTipsWhenApplicationIsInactive = true
        super.init(window: window)
        // The window took its size from the tab view's placeholder, not from the first pane.
        if let first = tabs.tabViewItems.first?.viewController { window.setContentSize(first.preferredContentSize) }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    func show(_ pane: SettingsTabs.Pane? = nil) {
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        if window?.isVisible != true { window?.center() }
        // A menu bar app is never the active app; the window would open behind everything.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsTabs: NSTabViewController {
    enum Pane: Int, CaseIterable {
        case outage, volumes, readings, general
        var label: String { ["Outage", "Volumes", "Readings", "General"][rawValue] }
        var symbol: String { ["bolt.fill", "externaldrive", "waveform.path.ecg", "gearshape"][rawValue] }
    }
    init(monitor: UPSMonitor, updater: Updater?) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        let panes: [SettingsPane] = [OutagePane(), VolumesPane(monitor: monitor), ReadingsPane(), GeneralPane(updater: updater)]
        for (p, pane) in zip(Pane.allCases, panes) {
            // The window's title follows the selected pane's title (an untitled pane shows "Untitled").
            pane.title = p.label
            let item = NSTabViewItem(viewController: pane)
            item.label = p.label
            item.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: p.label)
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

// MARK: - Panes

/// A pane is a two-column form (labels right, controls left) that rebuilds its controls from
/// `Settings` on `reload()`, which also runs whenever any setting changes anywhere.
@MainActor
class SettingsPane: NSViewController, NSTextFieldDelegate {
    static let width: CGFloat = 580
    let form = Form()
    var reloading = false
    private var observer: NSObjectProtocol?

    override func loadView() {
        let v = NSView()
        build()
        form.finish()
        v.addSubview(form.grid)
        NSLayoutConstraint.activate([
            form.grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            form.grid.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            form.grid.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
            form.grid.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20),
            v.widthAnchor.constraint(equalToConstant: SettingsPane.width),
        ])
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
        observer = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    /// Add the rows. Called once, before the first `reload()`.
    func build() {}
    /// Set every control from `Settings`. Wrapped so control actions fired by the setting of a
    /// value are ignored.
    func reload() {}

    /// A row came or went (a warning, a status line): the pane's size follows, and the window's
    /// with it, top edge fixed, while this pane is the one on show (the others have no window).
    func fitToContent() {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size != preferredContentSize else { return }
        preferredContentSize = size
        guard let w = view.window, let content = w.contentView else { return }
        let dh = size.height - content.frame.height
        var f = w.frame
        f.origin.y -= dh
        f.size.height += dh
        w.setFrame(f, display: true)
    }

    func withoutActions(_ body: () -> Void) {
        reloading = true
        body()
        reloading = false
    }

    // A field whose text is not a duration (or not a number): keep the focus there and say why.
    func control(_ control: NSControl, didFailToFormatString string: String, errorDescription error: String?) -> Bool {
        form.status.stringValue = error ?? "Not a valid value."
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        form.status.stringValue = ""
    }
}

/// The grid behind every pane.
@MainActor
final class Form {
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    let status = NSTextField(wrappingLabelWithString: "")
    nonisolated static let labelWidth: CGFloat = 190
    nonisolated static let controlWidth: CGFloat = 330

    init() {
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Form.labelWidth
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        status.preferredMaxLayoutWidth = Form.controlWidth
    }

    /// One row: a right-aligned label, the control, and under it an optional explanation.
    @discardableResult
    func row(_ label: String, _ control: NSView, hint: String? = nil) -> NSGridRow {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 2
        l.preferredMaxLayoutWidth = Form.labelWidth
        return grid.addRow(with: [l, hint.map { Form.stack(control, Form.hint($0)) } ?? control])
    }

    /// A small heading across both columns.
    func section(_ title: String) {
        let t = NSTextField(labelWithString: title.uppercased())
        t.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        t.textColor = .secondaryLabelColor
        let r = grid.addRow(with: [t])
        r.mergeCells(in: NSRange(location: 0, length: 2))
        r.topPadding = grid.numberOfRows > 1 ? 10 : 0
        r.cell(at: 0).xPlacement = .leading
    }

    /// Text across both columns.
    func note(_ text: String) {
        let r = grid.addRow(with: [Form.hint(text, width: Form.labelWidth + Form.controlWidth + grid.columnSpacing)])
        r.mergeCells(in: NSRange(location: 0, length: 2))
        r.cell(at: 0).xPlacement = .leading
    }

    /// The error line at the bottom, plus a trailing control (Restore Defaults) if given.
    func finish(trailing: NSView? = nil) {
        let r = grid.addRow(with: [status, trailing ?? NSGridCell.emptyContentView])
        r.topPadding = 8
        r.cell(at: 0).xPlacement = .leading
        if trailing != nil { r.cell(at: 1).xPlacement = .trailing }
    }

    static func hint(_ text: String, width: CGFloat = controlWidth) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = width
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        t.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return t
    }

    static func stack(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    static func line(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = 6
        return s
    }

    static func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
}

/// The controls, made the same way everywhere.
@MainActor
enum Controls {
    static func duration(_ target: SettingsPane, _ action: Selector, width: CGFloat = 96) -> NSTextField {
        let f = NSTextField(string: "")
        f.formatter = DurationFormatter()
        f.target = target
        f.action = action
        f.delegate = target
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        f.toolTip = "A duration: 90 s, 2 min, 1.5 min, 1 h 30 min. A bare number is seconds."
        return f
    }

    static func integer(_ target: SettingsPane, _ action: Selector, range: ClosedRange<Int>, width: CGFloat = 56) -> NSTextField {
        let f = NSTextField(string: "")
        let nf = NumberFormatter()
        nf.minimum = range.lowerBound as NSNumber
        nf.maximum = range.upperBound as NSNumber
        nf.allowsFloats = false
        nf.maximumFractionDigits = 0
        f.formatter = nf
        f.target = target
        f.action = action
        f.delegate = target
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    static func checkbox(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: target, action: action)
    }

    static func radio(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: target, action: action)
    }

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }

    static func popup(_ target: AnyObject, _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.target = target
        p.action = action
        return p
    }

    static func table(_ owner: NSTableViewDataSource & NSTableViewDelegate, columns: [(String, CGFloat)], height: CGFloat) -> (NSScrollView, NSTableView) {
        let table = NSTableView()
        for (id, w) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.width = w
            c.minWidth = w
            table.addTableColumn(c)
        }
        table.headerView = nil
        table.rowHeight = 22
        table.style = .inset
        table.allowsEmptySelection = true
        table.dataSource = owner
        table.delegate = owner
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Form.controlWidth),
            scroll.heightAnchor.constraint(equalToConstant: height),
        ])
        return (scroll, table)
    }

    static func cell(_ table: NSTableView, id: String, editable: Bool, target: AnyObject? = nil, action: Selector? = nil) -> NSTableCellView {
        let ident = NSUserInterfaceItemIdentifier(id)
        if let v = table.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView { return v }
        let v = NSTableCellView()
        v.identifier = ident
        let t = NSTextField(labelWithString: "")
        t.isEditable = editable
        t.isSelectable = editable
        t.isBordered = false
        t.drawsBackground = false
        t.lineBreakMode = .byTruncatingTail
        t.translatesAutoresizingMaskIntoConstraints = false
        if let target, let action { t.target = target; t.action = action }
        v.addSubview(t)
        v.textField = t
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            t.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }

    static func value(_ f: NSTextField) -> Double? { (f.objectValue as? NSNumber)?.doubleValue }
}

/// "2 min" in, 120 out, and back. Rejects anything `Duration.parse` does not understand, which
/// keeps the focus in the field with the reason underneath.
final class DurationFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        guard let n = obj as? NSNumber else { return nil }
        return Duration.text(n.doubleValue)
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard let v = Duration.parse(string) else {
            errorDescription?.pointee = "“\(string)” is not a duration. Write 90 s, 2 min, 1.5 min or 1 h 30 min." as NSString
            return false
        }
        obj?.pointee = NSNumber(value: v)
        return true
    }
}

// MARK: Outage

/// The policy: three stages (ask apps, force unmount, sleep or shut down), each begun by
/// whichever of its ticked conditions comes first; the apps' quit timeout; what a missing UPS
/// means; the readings blackout and the line-stable window; and the never-quit list.
@MainActor
final class OutagePane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let cellWidth: CGFloat = 106
    private var checks: [Settings.Stage: [Settings.Condition: NSButton]] = [:]
    private var fields: [Settings.Stage: [Settings.Condition: NSTextField]] = [:]
    private var quitApps: NSButton!
    private var quitTimeoutOn: NSButton!
    private var quitTimeout: NSTextField!
    private var powerAction: NSPopUpButton!
    private var powerWhenSafe: NSButton!
    private var upsGone: NSTextField!
    private var upsGoneInOutage: NSPopUpButton!
    private var upsGonePowersDown: NSButton!
    private var upsGoneOnLine: NSPopUpButton!
    private var postpone: NSTextField!
    private var hardWarning: NSImageView!
    private var neverQuitTable: NSTableView!
    private var addApp: NSPopUpButton!
    private var removeApp: NSButton!
    private var entries: [String] = []

    /// One cell of the stage grid: a checkbox, the number, its unit.
    private func cell(_ st: Settings.Stage, _ c: Settings.Condition) -> NSView {
        let check = Controls.checkbox("", self, #selector(apply))
        let field: NSTextField
        var views: [NSView] = [check]
        switch c {
        case .time, .runtime:
            field = Controls.duration(self, #selector(apply), width: 72)
            views.append(field)
        case .charge:
            field = Controls.integer(self, #selector(apply), range: 0...100, width: 44)
            views += [field, Form.label("%")]
        }
        checks[st, default: [:]][c] = check
        fields[st, default: [:]][c] = field
        let line = NSStackView(views: views)
        line.orientation = .horizontal
        line.spacing = 4
        line.widthAnchor.constraint(equalToConstant: OutagePane.cellWidth).isActive = true
        return line
    }

    private func header(_ text: String) -> NSView {
        let l = Form.label(text)
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: OutagePane.cellWidth).isActive = true
        return l
    }

    private func stageRow(_ label: String, _ st: Settings.Stage, hint: String? = nil) {
        form.row(label, Form.line(cell(st, .time), cell(st, .runtime), cell(st, .charge)), hint: hint)
    }

    override func build() {
        form.section("Stages: each begins at whichever ticked condition comes first")
        form.row("", Form.line(header("On battery for"), header("Runtime left ≤"), header("Charge ≤")))
        stageRow("Ask apps to quit:", .soft)
        // Shown only while the forced unmount has no time condition (QA 2026-10-11, M3).
        // A warning sign before the label while the forced unmount has no time condition;
        // hover for why (QA 2026-10-11, M3). In the label column, so the grid keeps its width.
        hardWarning = NSImageView()
        hardWarning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular).applying(.init(paletteColors: [.systemOrange])))
        hardWarning.setAccessibilityLabel("No time on battery for the forced unmount")
        form.grid.addRow(with: [Form.line(hardWarning, Form.label("Force unmount:")),
                                Form.line(cell(.hard, .time), cell(.hard, .runtime), cell(.hard, .charge))])
        stageRow("Sleep or shut down:", .powerDown,
                 hint: "Force unmount needs at least one. The charge gauge sags 20–30 points in the first minute; runtime is the better guide.")

        quitApps = Controls.checkbox("Ask the apps holding files to quit", self, #selector(apply))
        form.row("At the first stage:", quitApps,
                 hint: "Once each, like their Quit menu; a volume unmounts once no app holds it.")
        quitTimeoutOn = Controls.checkbox("", self, #selector(apply))
        quitTimeoutOn.toolTip = "Off: an app that will not quit keeps its volume mounted until the forced unmount."
        quitTimeout = Controls.duration(self, #selector(apply), width: 80)
        form.row("Give them at most:", Form.line(quitTimeoutOn, quitTimeout),
                 hint: "From the ask; then their volume is unmounted anyway.")

        powerAction = Controls.popup(self, #selector(apply))
        for a in Policy.MacAction.allCases {
            powerAction.addItem(withTitle: a.title)
            powerAction.lastItem?.representedObject = a.rawValue
        }
        powerWhenSafe = Controls.checkbox("Also as soon as every volume is safe", self, #selector(apply))
        form.row("Sleep or shut down means:", Form.stack(powerAction, powerWhenSafe),
                 hint: "Volumes are forced off first. If one will not come off, a shutdown goes ahead a minute later; a sleep waits for it. Test Shut down once at the keyboard: --after-safe.")
        postpone = Controls.duration(self, #selector(apply))
        form.row("Postpone adds:", postpone,
                 hint: "The outage menu's Postpone moves every time condition out by this much; charge and runtime still apply. 1 min to 1 h.")

        form.section("If the UPS goes missing from USB")
        upsGone = Controls.duration(self, #selector(apply))
        form.row("Missing for:", upsGone,
                 hint: "Shorter is a USB re-enumeration, not a lost UPS.")
        upsGoneInOutage = Controls.popup(self, #selector(apply))
        for o in Policy.UPSGoneInOutage.allCases {
            upsGoneInOutage.addItem(withTitle: o.title)
            upsGoneInOutage.lastItem?.representedObject = o.rawValue
        }
        upsGonePowersDown = Controls.checkbox("And sleep or shut down the Mac", self, #selector(apply))
        form.row("During an outage:", Form.stack(upsGoneInOutage, upsGonePowersDown),
                 hint: "Usually its battery ran flat. Carrying on counts time against the last reading.")
        upsGoneOnLine = Controls.popup(self, #selector(apply))
        for o in Policy.UPSGoneOnLine.allCases {
            upsGoneOnLine.addItem(withTitle: o.title)
            upsGoneOnLine.lastItem?.representedObject = o.rawValue
        }
        form.row("On line power:", upsGoneOnLine,
                 hint: "A pulled cable: an outage would go unseen. Volumes remount when it is back.")

        form.section("Never quit")
        let (scroll, table) = Controls.table(self, columns: [("app", Form.controlWidth - 20)], height: 56)
        neverQuitTable = table
        addApp = NSPopUpButton(frame: .zero, pullsDown: true)
        addApp.target = self
        addApp.action = #selector(addEntry(_:))
        addApp.menu?.delegate = self
        addApp.addItem(withTitle: "Add App")
        addApp.widthAnchor.constraint(equalToConstant: 120).isActive = true
        removeApp = Controls.button("Remove", self, #selector(removeEntry))
        removeApp.isEnabled = false
        form.row("Apps left alone:", Form.stack(scroll, Form.line(addApp, removeApp)),
                 hint: "Besides Finder. Never asked, never waited for. Bundle id or name.")
    }

    override func loadView() {
        super.loadView()
        // The form's bottom row: the error line and Restore Defaults.
        form.grid.removeRow(at: form.grid.numberOfRows - 1)
        form.finish(trailing: Controls.button("Restore Defaults", self, #selector(restore)))
    }

    private static func select<T: RawRepresentable>(_ popup: NSPopUpButton, _ value: T) where T.RawValue == String {
        popup.selectItem(at: popup.indexOfItem(withRepresentedObject: value.rawValue))
    }

    override func reload() {
        let s = Settings.shared
        let p = s.policy
        withoutActions {
            for st in Settings.Stage.allCases {
                let t = st.trigger(of: p)
                for c in Settings.Condition.allCases {
                    let v = Settings.Condition.value(c, of: t)
                    checks[st]?[c]?.state = v != nil ? .on : .off
                    fields[st]?[c]?.objectValue = v ?? s.value(st, c)
                    fields[st]?[c]?.isEnabled = v != nil
                }
            }
            hardWarning.isHidden = p.hardAt.onBatteryFor != nil
            hardWarning.toolTip = "No time on battery: the forced unmount depends on the UPS reporting its runtime or charge. "
                + "If it stops reporting both, \(Duration.text(Policy.hardStandIn)) on battery stands in. The UPS's own low-battery alarm also forces it."
            quitApps.state = p.quitApps ? .on : .off
            quitTimeoutOn.state = p.quitTimeoutSeconds != nil ? .on : .off
            quitTimeout.objectValue = p.quitTimeoutSeconds ?? s.quitTimeoutValue
            quitTimeoutOn.isEnabled = p.quitApps
            quitTimeout.isEnabled = p.quitApps && p.quitTimeoutSeconds != nil
            OutagePane.select(powerAction, p.powerDownAction)
            powerWhenSafe.state = p.powerDownWhenSafe ? .on : .off
            upsGone.objectValue = p.upsGoneSeconds
            OutagePane.select(upsGoneInOutage, p.upsGoneInOutage)
            upsGonePowersDown.state = p.upsGoneInOutagePowersDown ? .on : .off
            postpone.objectValue = s.postponeSeconds
            OutagePane.select(upsGoneOnLine, p.upsGoneOnLine)
            entries = p.neverQuit.subtracting(Policy.alwaysKept).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            neverQuitTable.reloadData()
            removeApp.isEnabled = neverQuitTable.selectedRow >= 0
        }
    }

    @objc private func apply() {
        guard !reloading else { return }
        let s = Settings.shared
        var p = s.policy
        for st in Settings.Stage.allCases {
            var t = Trigger()
            for c in Settings.Condition.allCases where checks[st]?[c]?.state == .on {
                Settings.Condition.set(c, fields[st]?[c].flatMap { Controls.value($0) } ?? s.value(st, c), in: &t)
            }
            st.set(t, in: &p)
        }
        let hardWasNever = p.hardAt.isNever
        p.quitApps = quitApps.state == .on
        p.quitTimeoutSeconds = quitTimeoutOn.state == .on ? (Controls.value(quitTimeout) ?? s.quitTimeoutValue) : nil
        if let raw = powerAction.selectedItem?.representedObject as? String, let a = Policy.MacAction(rawValue: raw) { p.powerDownAction = a }
        p.powerDownWhenSafe = powerWhenSafe.state == .on
        p.upsGoneSeconds = Controls.value(upsGone) ?? p.upsGoneSeconds
        if let raw = upsGoneInOutage.selectedItem?.representedObject as? String, let o = Policy.UPSGoneInOutage(rawValue: raw) { p.upsGoneInOutage = o }
        p.upsGoneInOutagePowersDown = upsGonePowersDown.state == .on
        if let raw = upsGoneOnLine.selectedItem?.representedObject as? String, let o = Policy.UPSGoneOnLine(rawValue: raw) { p.upsGoneOnLine = o }
        p.neverQuit = Set(entries.filter { !$0.isEmpty })
        if let v = Controls.value(postpone), v != s.postponeSeconds { s.postponeSeconds = v }
        s.policy = p
        if hardWasNever {
            form.status.stringValue = "Force unmount needs at least one condition; the time on battery was turned back on."
        }
    }

    @objc private func restore() {
        Settings.shared.resetPolicy()
        form.status.stringValue = ""
    }

    // The never-quit table.

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = Controls.cell(tableView, id: "app", editable: true, target: self, action: #selector(entryEdited(_:)))
        cell.textField?.stringValue = entries[row]
        cell.textField?.placeholderString = "Bundle id or app name"
        cell.textField?.tag = row
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeApp.isEnabled = neverQuitTable.selectedRow >= 0
    }

    @objc private func entryEdited(_ sender: NSTextField) {
        let row = sender.tag
        guard row < entries.count else { return }
        entries[row] = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        apply()
    }

    /// The pull-down lists the apps running now; the last item adds a blank row to type into.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === addApp.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        let have = Set(entries.map { $0.lowercased() }).union(Policy.alwaysKept)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a -> (String, String)? in
                guard let id = a.bundleIdentifier, !have.contains(id.lowercased()), !have.contains((a.localizedName ?? "").lowercased()) else { return nil }
                return (a.localizedName ?? id, id)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        for (name, id) in apps {
            let it = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            it.representedObject = id
            it.toolTip = id
            menu.addItem(it)
        }
        if !apps.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Type a Name or Bundle ID…", action: nil, keyEquivalent: "")
        other.representedObject = ""
        menu.addItem(other)
    }

    @objc private func addEntry(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        entries.append(id)
        neverQuitTable.reloadData()
        let row = entries.count - 1
        neverQuitTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if id.isEmpty {
            neverQuitTable.editColumn(0, row: row, with: nil, select: true)
        } else {
            apply()
        }
    }

    @objc private func removeEntry() {
        let row = neverQuitTable.selectedRow
        guard row >= 0, row < entries.count else { return }
        entries.remove(at: row)
        apply()
        neverQuitTable.reloadData()
    }
}

// MARK: Volumes

/// Which volumes the guard protects: every external one, or a checked subset. Volumes seen
/// before but not attached now stay in the list so they can be checked ahead of time.
@MainActor
final class VolumesPane: SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
    private let monitor: UPSMonitor
    private var all: NSButton!
    private var selected: NSButton!
    private var table: NSTableView!
    private var forget: NSButton!
    private var rows: [VolumeState] = []
    private var observers: [NSObjectProtocol] = []

    init(monitor: UPSMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func build() {
        form.section("Protect")
        all = Controls.radio("All external volumes", self, #selector(modeChanged(_:)))
        selected = Controls.radio("Only the volumes checked below", self, #selector(modeChanged(_:)))
        form.row("Volumes:", Form.stack(all, selected),
                 hint: "Right for a desk where everything external hangs off the UPS. Disk images and the EFI and boot helper partitions never count as external.")
        let (scroll, t) = Controls.table(self, columns: [("check", 24), ("name", 130), ("detail", Form.controlWidth - 24 - 130 - 24)], height: 150)
        table = t
        forget = Controls.button("Forget Volumes That Are Not Attached", self, #selector(forgetDetached))
        form.row("", Form.stack(scroll, forget),
                 hint: "Volumes are tracked by their UUID, so a drive keeps its setting when it comes back as a different disk number.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func reload() {
        let s = Settings.shared
        withoutActions {
            all.state = s.volumeMode == .allExternal ? .on : .off
            selected.state = s.volumeMode == .selected ? .on : .off
            var known = monitor.volumes.volumes
            for v in s.knownVolumes where known[v.uuid] == nil { known[v.uuid] = v }
            rows = known.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            table.reloadData()
            forget.isEnabled = rows.contains { !$0.isAttached }
        }
    }

    @objc private func modeChanged(_ sender: NSButton) {
        guard !reloading else { return }
        Settings.shared.volumeMode = sender === all ? .allExternal : .selected
    }

    @objc private func toggled(_ sender: NSButton) {
        guard !reloading, sender.tag < rows.count else { return }
        var set = Settings.shared.selectedVolumeUUIDs
        let uuid = rows[sender.tag].uuid
        if sender.state == .on { set.insert(uuid) } else { set.remove(uuid) }
        Settings.shared.selectedVolumeUUIDs = set
    }

    @objc private func forgetDetached() {
        for v in rows where !v.isAttached { Settings.shared.forget(v.uuid) }
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v = rows[row]
        let s = Settings.shared
        switch tableColumn?.identifier.rawValue {
        case "check":
            let ident = NSUserInterfaceItemIdentifier("check")
            let box = (tableView.makeView(withIdentifier: ident, owner: nil) as? NSButton) ?? {
                let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
                b.identifier = ident
                return b
            }()
            box.tag = row
            box.state = s.selectedVolumeUUIDs.contains(v.uuid) ? .on : .off
            box.isEnabled = s.volumeMode == .selected
            box.toolTip = v.uuid
            return box
        case "name":
            let cell = Controls.cell(tableView, id: "name", editable: false)
            cell.textField?.stringValue = v.name
            cell.textField?.textColor = v.isAttached ? .labelColor : .secondaryLabelColor
            cell.toolTip = v.uuid
            return cell
        default:
            let cell = Controls.cell(tableView, id: "detail", editable: false)
            var detail = v.detail
            if !v.isAttached { detail = "not attached" + (detail.isEmpty ? "" : " · " + detail) }
            else if !v.isMounted { detail = "not mounted" + (detail.isEmpty ? "" : " · " + detail) }
            cell.textField?.stringValue = detail
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            cell.toolTip = v.uuid
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

// MARK: Readings

/// How often the UPS is read, how much history the chart keeps, and the menu bar's extra.
@MainActor
final class ReadingsPane: SettingsPane {
    private var line: NSTextField!
    private var busy: NSTextField!
    private var history: NSPopUpButton!
    private var showLoad: NSButton!
    private var ignoreReadings: NSTextField!
    private var lineStable: NSTextField!

    override func build() {
        form.section("Reading the UPS")
        line = Controls.duration(self, #selector(apply))
        form.row("On line power, read every:", line,
                 hint: "Charge, load, voltages and the UPS's own limits, over USB; a read takes about 30 ms. 2 s to 10 min.")
        busy = Controls.duration(self, #selector(apply))
        form.row("On battery, read every:", busy,
                 hint: "Also during a simulation and while the menu is open. The outage guard ticks on this clock, so its countdowns move in these steps. 1 s to 1 min, never slower than on line power.")
        form.note("The line/battery state does not wait for a read: macOS posts an event the instant the UPS transfers, and the guard acts on it. "
                  + "A read that stays unanswered for three intervals (at least a minute) is a health warning.")

        form.section("Trusting the readings in an outage")
        ignoreReadings = Controls.duration(self, #selector(apply))
        form.row("Ignore charge and runtime for:", ignoreReadings,
                 hint: "After the transfer; some UPSes report 0 % for a moment. Only the time conditions count meanwhile.")
        lineStable = Controls.duration(self, #selector(apply))
        form.row("Power must stay back for:", lineStable,
                 hint: "Before the outage counts as over. Under a brownout that transfers every few seconds, the clock and the stages keep running.")

        form.section("Chart")
        history = Controls.popup(self, #selector(apply))
        form.row("Show the last:", history,
                 hint: "Samples are kept in memory for this long at the read interval; the chart's time axis follows.")

        form.section("Menu bar")
        showLoad = Controls.checkbox("Show the load in watts next to the icon", self, #selector(apply))
        form.row("", showLoad)
    }

    override func loadView() {
        super.loadView()
        form.grid.removeRow(at: form.grid.numberOfRows - 1)
        form.finish(trailing: Controls.button("Restore Defaults", self, #selector(restore)))
    }

    override func reload() {
        let s = Settings.shared
        withoutActions {
            line.objectValue = s.lineReadInterval
            busy.objectValue = s.busyReadInterval
            history.removeAllItems()
            for h in (Settings.historyChoices + [s.historyWindow]).uniqued().sorted() {
                history.addItem(withTitle: Duration.text(h))
                history.lastItem?.representedObject = h
                if h == s.historyWindow { history.select(history.lastItem) }
            }
            showLoad.state = s.showLoadInBar ? .on : .off
            ignoreReadings.objectValue = s.policy.ignoreReadingsSeconds
            lineStable.objectValue = s.policy.lineStableSeconds
        }
    }

    @objc private func apply() {
        guard !reloading else { return }
        let s = Settings.shared
        if let v = Controls.value(line), v != s.lineReadInterval { s.lineReadInterval = v }
        if let v = Controls.value(busy), v != s.busyReadInterval { s.busyReadInterval = v }
        if let h = history.selectedItem?.representedObject as? TimeInterval, h != s.historyWindow { s.historyWindow = h }
        if (showLoad.state == .on) != s.showLoadInBar { s.showLoadInBar = showLoad.state == .on }
        var p = s.policy
        p.ignoreReadingsSeconds = Controls.value(ignoreReadings) ?? p.ignoreReadingsSeconds
        p.lineStableSeconds = Controls.value(lineStable) ?? p.lineStableSeconds
        if p != s.policy { s.policy = p }
        var notes: [String] = []
        if let v = Controls.value(line), v != s.lineReadInterval { notes.append("line-power interval kept between 2 s and 10 min") }
        if let v = Controls.value(busy), v != s.busyReadInterval { notes.append("battery interval kept between 1 s and the line-power interval") }
        form.status.stringValue = notes.joined(separator: "; ").capitalizingFirst
        reload()
    }

    @objc private func restore() {
        Settings.shared.resetReadings()
        form.status.stringValue = ""
    }
}

// MARK: General

/// Persistence, notifications, updates, and the log.
@MainActor
final class GeneralPane: SettingsPane {
    private let updater: Updater?
    private var agent: NSButton!
    private var agentHint: NSTextField!
    private var notifications: NSButton!
    private var notificationsStatus: NSTextField!
    private var openNotificationSettings: NSButton!
    private var autoUpdate: NSButton?

    init(updater: Updater?) {
        self.updater = updater
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override func viewWillAppear() {
        super.viewWillAppear()
        Notifications.shared.refresh(force: true)
    }

    override func build() {
        form.section("Running")
        agent = Controls.checkbox("Run in the background at login", self, #selector(toggleAgent))
        agentHint = Form.hint("")
        form.grid.addRow(with: [Form.label("Persistence:"), Form.stack(agent, agentHint)])
        form.grid.cell(atColumnIndex: 0, rowIndex: form.grid.numberOfRows - 1).xPlacement = .trailing
        notifications = Controls.checkbox("Show notifications", self, #selector(apply))
        notificationsStatus = Form.hint("")
        openNotificationSettings = Controls.button("Open Notification Settings…", self, #selector(openSystemNotifications))
        form.row("Notifications:", Form.stack(notifications, notificationsStatus, openNotificationSettings),
                 hint: "At the transfer, when apps are asked to quit, at each unmount, and when power returns.")
        if updater != nil {
            let b = Controls.checkbox("Check for updates automatically", self, #selector(apply))
            autoUpdate = b
            form.row("Updates:", b,
                     hint: "Once a day against GitHub releases (api.github.com). Off, the app talks to nothing at all.")
        }


        form.section("Log")
        let open = Controls.button("Open Log File", self, #selector(openLog))
        form.row("", Form.stack(open, Form.hint("Every reading, decision and action, timestamped, in ~/Library/Logs/Nimbus UPS Bar/ups-bar.log. Also in the unified log under com.njoubert.nimbusupsbar.")))
        form.note(StatusBarController.versionString())
    }

    override func reload() {
        let s = Settings.shared
        withoutActions {
            agent.state = BackgroundAgent.isEnabled ? .on : .off
            agent.isEnabled = BackgroundAgent.isAvailable
            if !BackgroundAgent.isAvailable {
                agentHint.stringValue = "This binary has no agent plist (a bare swift build). Use ./build.sh run or install."
            } else if BackgroundAgent.status == .requiresApproval {
                agentHint.stringValue = "Waiting for approval in System Settings › General › Login Items."
            } else if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
                agentHint.stringValue = "This copy runs from \(Bundle.main.bundlePath). Registering points launchd at that path; ./build.sh install is the real thing."
            } else {
                agentHint.stringValue = "A launchd agent starts the app at login and restarts it if it crashes. Quit stays quit."
            }
            notifications.state = s.notificationsEnabled ? .on : .off
            let access = Notifications.shared.access
            switch access {
            case .blockedByMacOS:
                notificationsStatus.stringValue = "Blocked by macOS: no outage banner will appear until they are allowed in System Settings › Notifications."
                notificationsStatus.textColor = .systemOrange
            case .notDecided:
                notificationsStatus.stringValue = "macOS has not asked yet."
                notificationsStatus.textColor = .secondaryLabelColor
            case .unavailable:
                notificationsStatus.stringValue = "This binary has no bundle, so it cannot show notifications."
                notificationsStatus.textColor = .secondaryLabelColor
            case .allowed, .offInSettings:
                notificationsStatus.stringValue = ""
            }
            let hideButton = access != .blockedByMacOS
            if notificationsStatus.isHidden != notificationsStatus.stringValue.isEmpty || openNotificationSettings.isHidden != hideButton {
                notificationsStatus.isHidden = notificationsStatus.stringValue.isEmpty
                openNotificationSettings.isHidden = hideButton
                if isViewLoaded, preferredContentSize != .zero { fitToContent() }
            }
            if let u = updater { autoUpdate?.state = u.automaticChecks ? .on : .off }
        }
    }

    @objc private func apply() {
        guard !reloading else { return }
        let s = Settings.shared
        if (notifications.state == .on) != s.notificationsEnabled {
            s.notificationsEnabled = notifications.state == .on
            if s.notificationsEnabled { Notifications.shared.requestAuthorizationIfNeeded() }
        }
        if let u = updater, let b = autoUpdate, (b.state == .on) != u.automaticChecks { u.automaticChecks = b.state == .on }
        reload()
    }

    @objc private func toggleAgent() {
        guard !reloading else { return }
        UserDefaults.standard.set(true, forKey: BackgroundAgent.registeredDefaultsKey)
        AppDelegate.shared?.setAgent(enabled: agent.state == .on)
        reload()
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }

    @objc private func openSystemNotifications() { Notifications.openSystemSettings() }
}

// MARK: - Main menu

/// A menu bar app shows no menu bar of its own, but the key equivalents still come from
/// `NSApp.mainMenu`: without an Edit menu, ⌘C and ⌘V do nothing in the settings fields and
/// ⌘W does not close the window.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Nimbus UPS Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // The Inspector's search field; disabled where nothing answers (Settings).
        edit.addItem(withTitle: "Find…", action: #selector(InspectorWindowController.focusSearch(_:)), keyEquivalent: "f")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}

private extension String {
    var capitalizingFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}
