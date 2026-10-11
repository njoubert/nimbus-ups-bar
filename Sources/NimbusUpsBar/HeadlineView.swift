// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UpsGuardCore

/// The top of the menu: the phase in words, with its colour, and under it three figures:
/// charge, load, runtime. During an outage the second line carries the countdown.
final class HeadlineView: NSView {

    struct Model: Equatable {
        var title: String          // "Line power", "On battery", "Closing apps"…
        var color: NSColor
        var subtitle: String       // "CP1500PFCLCDa · 190 min at this load" or "Apps close in 1:52 · forced at 4:52"
        var figures: [(String, String)] = []   // (value, caption)

        static func == (a: Model, b: Model) -> Bool {
            a.title == b.title && a.subtitle == b.subtitle && a.figures.map(\.0) == b.figures.map(\.0) && a.figures.map(\.1) == b.figures.map(\.1)
        }
    }

    static let height: CGFloat = 86
    private static let insetX: CGFloat = 14
    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private static let subtitleFont = NSFont.systemFont(ofSize: 11)
    private static let figureFont = NSFont.systemFont(ofSize: 20, weight: .medium)
    private static let captionFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    var model: () -> Model = { Model(title: "", color: .labelColor, subtitle: "") }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let m = model()
        let left = HeadlineView.insetX
        let top = bounds.height - 6
        // Status dot + title.
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: HeadlineView.titleFont, .foregroundColor: NSColor.labelColor]
        let title = NSAttributedString(string: m.title, attributes: titleAttrs)
        let titleY = top - HeadlineView.titleFont.ascender - 2
        m.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: left, y: titleY + 3, width: 10, height: 10)).fill()
        title.draw(at: NSPoint(x: left + 16, y: titleY))
        // The subtitle is " · "-separated facts; drop trailing ones rather than clip mid-word.
        let subAttrs: [NSAttributedString.Key: Any] = [.font: HeadlineView.subtitleFont, .foregroundColor: NSColor.secondaryLabelColor]
        var facts = m.subtitle.components(separatedBy: " · ")
        var sub = NSAttributedString(string: facts.joined(separator: " · "), attributes: subAttrs)
        let subMax = bounds.width - left - 16 - left
        while sub.size().width > subMax, facts.count > 1 {
            facts.removeLast()
            sub = NSAttributedString(string: facts.joined(separator: " · "), attributes: subAttrs)
        }
        sub.draw(at: NSPoint(x: left + 16, y: titleY - sub.size().height - 1))

        // Figures in equal columns.
        guard !m.figures.isEmpty else { return }
        let content = bounds.width - 2 * left
        let colW = content / CGFloat(m.figures.count)
        let figY: CGFloat = 16
        for (i, (value, caption)) in m.figures.enumerated() {
            let cx = left + colW * (CGFloat(i) + 0.5)
            let v = NSAttributedString(string: value, attributes: [.font: HeadlineView.figureFont, .foregroundColor: NSColor.labelColor])
            let c = NSAttributedString(string: caption, attributes: [.font: HeadlineView.captionFont, .foregroundColor: NSColor.secondaryLabelColor])
            v.draw(at: NSPoint(x: cx - v.size().width / 2, y: figY))
            c.draw(at: NSPoint(x: cx - c.size().width / 2, y: figY - c.size().height - 1))
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}
