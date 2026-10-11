// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpsBarKit
import UpsGuardCore

/// The last hour of the UPS, as two small panels on one time axis: the load in watts on top,
/// the battery charge in percent below. Two panels rather than two scales on one plot, so
/// neither series borrows the other's axis. Minutes on battery are tinted behind both.
/// Hover for the values at that moment.
final class ChartView: NSView {

    static let chartHeight: CGFloat = 176
    private static let insetX: CGFloat = 14
    private static let insetY: CGFloat = 5
    private static let boxPadding = NSSize(width: 10, height: 8)
    private static let boxRadius: CGFloat = 8
    private static let labelStrip: CGFloat = 14
    private static let panelGap: CGFloat = 12
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let titleFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    var samples: () -> [UPSMonitor.Sample] = { [] }
    var now: () -> TimeInterval = { monotonicNow() }
    var span: TimeInterval = UPSMonitor.historyWindow
    var debugBackground = false
    private var hoverX: CGFloat?
    private var tracking: NSTrackingArea?

    // Series colours: the reference palette's first two categorical slots, stepped per
    // appearance. Text never wears them; the marks do.
    static let loadColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0x39/255, green: 0x87/255, blue: 0xE5/255, alpha: 1)
                                                            : NSColor(srgbRed: 0x2A/255, green: 0x78/255, blue: 0xD6/255, alpha: 1)
    }
    static let chargeColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0xD9/255, green: 0x59/255, blue: 0x26/255, alpha: 1)
                                                            : NSColor(srgbRed: 0xEB/255, green: 0x68/255, blue: 0x34/255, alpha: 1)
    }
    /// Status "warning" from the reference palette, as a wash behind minutes on battery.
    static let outageColor = NSColor(srgbRed: 0xFA/255, green: 0xB2/255, blue: 0x19/255, alpha: 1)
    private static let boxFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.32) : NSColor(white: 0, alpha: 0.05)
    }
    private static let boxStroke = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.10)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }

    // MARK: Layout

    private var boxRect: NSRect { bounds.insetBy(dx: ChartView.insetX, dy: ChartView.insetY) }
    private var innerRect: NSRect { boxRect.insetBy(dx: ChartView.boxPadding.width, dy: ChartView.boxPadding.height) }
    /// Top panel: load. Bottom panel: charge. Each has a label strip above its plot.
    private var panels: (load: NSRect, charge: NSRect) {
        let inner = innerRect
        let plotH = (inner.height - ChartView.panelGap - 2 * ChartView.labelStrip) / 2
        let charge = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: plotH)
        let load = NSRect(x: inner.minX, y: charge.maxY + ChartView.labelStrip + ChartView.panelGap, width: inner.width, height: plotH)
        return (load, charge)
    }
    private func x(for t: TimeInterval, in plot: NSRect, now: TimeInterval) -> CGFloat {
        plot.minX + CGFloat((t - (now - span)) / span) * plot.width
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if debugBackground { NSColor(white: 0.13, alpha: 1).setFill(); bounds.fill() }
        let box = NSBezierPath(roundedRect: boxRect.insetBy(dx: 0.5, dy: 0.5), xRadius: ChartView.boxRadius, yRadius: ChartView.boxRadius)
        ChartView.boxFill.setFill(); box.fill()
        ChartView.boxStroke.setStroke(); box.lineWidth = 1; box.stroke()

        let now = self.now()
        let all = samples().filter { $0.t >= now - span }
        let (loadPlot, chargePlot) = panels
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: ChartView.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: ChartView.titleFont, .foregroundColor: NSColor.secondaryLabelColor]

        // Outage bands, behind both panels, spanning the label strips too.
        drawOutageBands(all, now: now, from: chargePlot.minY, to: loadPlot.maxY + ChartView.labelStrip)

        let peakW = max((all.compactMap(\.loadWatts).max() ?? 0) * 1.15, 50)
        let loadMax = niceCeiling(peakW)
        let hovered = hoverX.flatMap { nearest(all, to: $0, in: loadPlot, now: now) }
        drawPanel(loadPlot, title: "Load", axisTop: "\(Int(loadMax)) W", titleAttrs: titleAttrs, labelAttrs: labelAttrs, labels: hovered == nil)
        drawSeries(all, in: loadPlot, now: now, color: ChartView.loadColor, value: { $0.loadWatts.map { $0 / loadMax } }, area: true)

        drawPanel(chargePlot, title: "Battery charge", axisTop: "100 %", titleAttrs: titleAttrs, labelAttrs: labelAttrs, labels: hovered == nil)
        drawSeries(all, in: chargePlot, now: now, color: ChartView.chargeColor, value: { $0.charge.map { Double($0) / 100 } }, area: false)

        // Time axis, under the bottom panel: the window's start on the left; the end marker
        // on the right is "now".
        let ago = NSAttributedString(string: "\(Int(span / 60)) min ago", attributes: labelAttrs)
        ago.draw(at: NSPoint(x: chargePlot.minX, y: chargePlot.minY - ago.size().height))

        // Hover: a crosshair through both panels and the readout in the top label strip.
        if let s = hovered {
            let sx = x(for: s.t, in: loadPlot, now: now)
            NSColor.tertiaryLabelColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: sx, y: chargePlot.minY)); line.line(to: NSPoint(x: sx, y: loadPlot.maxY))
            line.lineWidth = 1; line.stroke()
            for (plot, v, color) in [(loadPlot, s.loadWatts.map { $0 / loadMax }, ChartView.loadColor),
                                     (chargePlot, s.charge.map { Double($0) / 100 }, ChartView.chargeColor)] {
                guard let v else { continue }
                let p = NSPoint(x: sx, y: plot.minY + CGFloat(min(1, max(0, v))) * plot.height)
                // 8 pt marker with a 2 pt surface ring.
                NSColor.windowBackgroundColor.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)).fill()
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)).fill()
            }
            // One readout per panel, in its own label strip (the title and axis label step
            // aside): time, load and line on top; charge, runtime and battery volts below.
            let age = now - s.t
            var top = [age < 30 ? "now" : "\(Duration.text(age)) ago"]
            if let w = s.loadWatts { top.append("\(Int(w.rounded())) W") }
            if let v = s.inputVoltage, v > 0 { top.append(String(format: "%.0f V in", v)) }
            if s.onBattery { top.append("on battery") }
            var bottom: [String] = []
            if let c = s.charge { bottom.append("\(c) %") }
            if let r = s.runtimeSeconds { bottom.append("\(Duration.text(TimeInterval(r))) left") }
            if let v = s.batteryVoltage { bottom.append(String(format: "%.1f V battery", v)) }
            drawReadout(top, strip: NSRect(x: loadPlot.minX, y: loadPlot.maxY, width: loadPlot.width, height: ChartView.labelStrip), at: sx)
            drawReadout(bottom, strip: NSRect(x: chargePlot.minX, y: chargePlot.maxY, width: chargePlot.width, height: ChartView.labelStrip), at: sx)
        }
    }

    /// " · "-joined facts centred on the crosshair, kept inside the strip: pushed in from the
    /// edges, and trailing facts dropped rather than letting the text run out of the panel.
    private func drawReadout(_ parts: [String], strip: NSRect, at x: CGFloat) {
        var facts = parts
        let attrs: [NSAttributedString.Key: Any] = [.font: ChartView.labelFont, .foregroundColor: NSColor.labelColor]
        var text = NSAttributedString(string: facts.joined(separator: "  ·  "), attributes: attrs)
        while text.size().width > strip.width, facts.count > 1 {
            facts.removeLast()
            text = NSAttributedString(string: facts.joined(separator: "  ·  "), attributes: attrs)
        }
        let w = text.size().width
        text.draw(at: NSPoint(x: min(strip.maxX - w, max(strip.minX, x - w / 2)), y: strip.minY + 2))
    }

    private func drawPanel(_ plot: NSRect, title: String, axisTop: String, titleAttrs: [NSAttributedString.Key: Any],
                           labelAttrs: [NSAttributedString.Key: Any], labels: Bool = true) {
        // Hairline baseline and top gridline, recessive.
        NSColor.separatorColor.setStroke()
        for y in [plot.minY, plot.maxY] {
            let p = NSBezierPath(); p.move(to: NSPoint(x: plot.minX, y: y)); p.line(to: NSPoint(x: plot.maxX, y: y)); p.lineWidth = 1; p.stroke()
        }
        if labels {
            NSAttributedString(string: title, attributes: titleAttrs).draw(at: NSPoint(x: plot.minX, y: plot.maxY + 2))
            let top = NSAttributedString(string: axisTop, attributes: labelAttrs)
            top.draw(at: NSPoint(x: plot.maxX - top.size().width, y: plot.maxY + 2))
        }
        let zero = NSAttributedString(string: "0", attributes: labelAttrs)
        zero.draw(at: NSPoint(x: plot.maxX - zero.size().width, y: plot.minY - zero.size().height))
    }

    private func drawOutageBands(_ s: [UPSMonitor.Sample], now: TimeInterval, from y0: CGFloat, to y1: CGFloat) {
        guard !s.isEmpty else { return }
        let plot = panels.load
        var start: TimeInterval?
        func flush(_ end: TimeInterval) {
            guard let st = start else { return }
            let x0 = x(for: st, in: plot, now: now), x1 = x(for: end, in: plot, now: now)
            ChartView.outageColor.withAlphaComponent(0.14).setFill()
            NSRect(x: max(plot.minX, x0), y: y0, width: max(2, min(plot.maxX, x1) - max(plot.minX, x0)), height: y1 - y0).fill()
            start = nil
        }
        for (i, smp) in s.enumerated() {
            if smp.onBattery, start == nil { start = smp.t }
            if !smp.onBattery { flush(smp.t) }
            if i == s.count - 1, smp.onBattery { flush(now) }
        }
    }

    /// A 2 pt line through the samples, optionally with a 10 % wash under it. Gaps (no value,
    /// or more than three sample intervals apart) break the line.
    private func drawSeries(_ s: [UPSMonitor.Sample], in plot: NSRect, now: TimeInterval, color: NSColor,
                            value: (UPSMonitor.Sample) -> Double?, area: Bool) {
        var runs: [[NSPoint]] = []
        var run: [NSPoint] = []
        var lastT: TimeInterval?
        for smp in s {
            guard let v = value(smp) else { if !run.isEmpty { runs.append(run); run = [] }; lastT = nil; continue }
            if let lt = lastT, smp.t - lt > UPSMonitor.sampleInterval * 3, !run.isEmpty { runs.append(run); run = [] }
            run.append(NSPoint(x: x(for: smp.t, in: plot, now: now), y: plot.minY + CGFloat(min(1, max(0, v))) * plot.height))
            lastT = smp.t
        }
        if !run.isEmpty { runs.append(run) }
        for pts in runs {
            guard let first = pts.first else { continue }
            let path = NSBezierPath()
            path.move(to: first)
            for p in pts.dropFirst() { path.line(to: p) }
            if pts.count == 1 { path.line(to: NSPoint(x: first.x + 1, y: first.y)) }
            if area, let last = pts.last {
                let fill = path.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: last.x, y: plot.minY)); fill.line(to: NSPoint(x: first.x, y: plot.minY)); fill.close()
                color.withAlphaComponent(0.10).setFill(); fill.fill()
            }
            path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
            color.setStroke(); path.stroke()
            // End marker on the newest point.
            if let last = pts.last, pts === runs.last {
                NSColor.windowBackgroundColor.setFill(); NSBezierPath(ovalIn: NSRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)).fill()
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)).fill()
            }
        }
    }

    private func niceCeiling(_ v: Double) -> Double {
        let steps: [Double] = [50, 100, 150, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000]
        return steps.first { $0 >= v } ?? (v / 1000).rounded(.up) * 1000
    }

    private func nearest(_ s: [UPSMonitor.Sample], to px: CGFloat, in plot: NSRect, now: TimeInterval) -> UPSMonitor.Sample? {
        guard !s.isEmpty else { return nil }
        let t = now - span + Double((px - plot.minX) / plot.width) * span
        return s.min { abs($0.t - t) < abs($1.t - t) }
    }

    // MARK: Hover

    func simulateHover(atFraction f: CGFloat) { hoverX = panels.load.minX + f * panels.load.width }
    func clearHover() { if hoverX != nil { hoverX = nil; needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let plot = panels.load
        let nx: CGFloat? = (p.x >= plot.minX && p.x <= plot.maxX) ? p.x : nil
        if nx != hoverX { hoverX = nx; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { clearHover() }
    override func mouseUp(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
}

extension Array where Element == NSPoint {
    static func === (a: [NSPoint], b: [NSPoint]?) -> Bool {
        guard let b else { return false }
        return a.count == b.count && a.first == b.first && a.last == b.last
    }
}
