// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import NimbusUpsBarKit
import UpsGuardCore

/// The last hour of the UPS, as two small panels on one time axis: the load in watts on top,
/// the battery charge in percent below. Two panels rather than two scales on one plot, so
/// neither series borrows the other's axis. Each panel's header carries its newest value;
/// minutes on battery are tinted behind both and labelled with their length; the charge
/// panel draws the policy's charge limit, when one is set. Hover for the values at a moment.
final class ChartView: NSView {

    static let chartHeight: CGFloat = 190
    private static let insetX: CGFloat = 14
    private static let insetY: CGFloat = 5
    private static let boxPadding = NSSize(width: 10, height: 6)
    private static let boxRadius: CGFloat = 8
    private static let headerStrip: CGFloat = 15
    private static let axisStrip: CGFloat = 13
    private static let panelGap: CGFloat = 10
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let titleFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    var samples: () -> [UPSMonitor.Sample] = { [] }
    var now: () -> TimeInterval = { monotonicNow() }
    var span: TimeInterval = 3600
    /// A gap between samples longer than this breaks the line (the app was not running).
    var sampleGap: TimeInterval = 30
    /// The policy's "unmount at N % charge", drawn as a dashed line; nil when that limit is off.
    var chargeLimit: Int?
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
    /// Gridlines: quieter than the separator, so the marks lead.
    private static let gridColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.07)
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
    /// From the bottom: the time axis, the charge plot, its header, a gap, the load plot, its header.
    private var panels: (load: NSRect, charge: NSRect) {
        let inner = innerRect
        let plotH = (inner.height - ChartView.axisStrip - ChartView.panelGap - 2 * ChartView.headerStrip) / 2
        let charge = NSRect(x: inner.minX, y: inner.minY + ChartView.axisStrip, width: inner.width, height: plotH)
        let load = NSRect(x: inner.minX, y: charge.maxY + ChartView.headerStrip + ChartView.panelGap, width: inner.width, height: plotH)
        return (load, charge)
    }
    private func x(for t: TimeInterval, in plot: NSRect, now: TimeInterval) -> CGFloat {
        plot.minX + CGFloat((t - (now - span)) / span) * plot.width
    }
    private func header(_ plot: NSRect) -> NSRect {
        NSRect(x: plot.minX, y: plot.maxY, width: plot.width, height: ChartView.headerStrip)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if debugBackground { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        let box = NSBezierPath(roundedRect: boxRect.insetBy(dx: 0.5, dy: 0.5), xRadius: ChartView.boxRadius, yRadius: ChartView.boxRadius)
        ChartView.boxFill.setFill(); box.fill()
        ChartView.boxStroke.setStroke(); box.lineWidth = 1; box.stroke()

        let now = self.now()
        let all = samples().filter { $0.t >= now - span }
        let (loadPlot, chargePlot) = panels
        let muted: [NSAttributedString.Key: Any] = [.font: ChartView.labelFont, .foregroundColor: NSColor.tertiaryLabelColor]

        // Outage bands, behind both panels, spanning the headers too.
        let bands = outageBands(all, now: now)
        drawOutageBands(bands, now: now, from: chargePlot.minY, to: loadPlot.maxY + ChartView.headerStrip)

        let loadMax = niceCeiling(max((all.compactMap(\.loadWatts).max() ?? 0) * 1.15, 50))
        drawGrid(loadPlot, now: now, levels: [(0.5, nil, false)])
        let limit = chargeLimit.map { min(100, max(0, $0)) }
        drawGrid(chargePlot, now: now, levels: limit.map { [(Double($0) / 100, "unmount at \($0) %", true)] } ?? [(0.5, nil, false)])
        drawTimeAxis(chargePlot, now: now, attrs: muted)
        drawBandLabels(bands, now: now, in: loadPlot, attrs: muted)

        drawSeries(all, in: loadPlot, now: now, color: ChartView.loadColor, value: { $0.loadWatts.map { $0 / loadMax } }, area: true)
        drawSeries(all, in: chargePlot, now: now, color: ChartView.chargeColor, value: { $0.charge.map { Double($0) / 100 } }, area: false)

        guard !all.isEmpty else {
            let text = NSAttributedString(string: "Waiting for the first reading", attributes: [.font: ChartView.titleFont, .foregroundColor: NSColor.secondaryLabelColor])
            let sz = text.size()
            text.draw(at: NSPoint(x: loadPlot.midX - sz.width / 2, y: loadPlot.midY + 3))
            drawHeader(header(loadPlot), title: "Load", value: nil, scale: "\(Int(loadMax)) W")
            drawHeader(header(chargePlot), title: "Battery", value: nil, scale: "100 %")
            return
        }

        guard let s = hoverX.flatMap({ nearest(all, to: $0, in: loadPlot, now: now) }) else {
            // At rest: each header names its panel, says the newest value, and gives the scale.
            let last = all.last
            drawHeader(header(loadPlot), title: "Load", value: last?.loadWatts.map { "\(Int($0.rounded())) W" }, scale: "\(Int(loadMax)) W")
            var battery: [String] = []
            if let c = all.last(where: { $0.charge != nil })?.charge { battery.append("\(c) %") }
            if let r = all.last(where: { $0.runtimeSeconds != nil })?.runtimeSeconds { battery.append("\(Duration.text(roundedToMinute(TimeInterval(r)))) left") }
            drawHeader(header(chargePlot), title: "Battery", value: battery.isEmpty ? nil : battery.joined(separator: " · "), scale: "100 %")
            return
        }

        // Hover: a crosshair through both panels and a readout in each header.
        let sx = x(for: s.t, in: loadPlot, now: now)
        NSColor.secondaryLabelColor.setStroke()
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
        // Time, load and line volts on top; charge, runtime and battery volts below.
        let age = now - s.t
        var top = [age < 30 ? "now" : "\(Duration.text(roundedToMinute(age))) ago"]
        if let w = s.loadWatts { top.append("\(Int(w.rounded())) W") }
        if s.onBattery { top.append("on battery") } else if let v = s.inputVoltage, v > 0 { top.append(String(format: "%.0f V in", v)) }
        var bottom: [String] = []
        if let c = s.charge { bottom.append("\(c) %") }
        if let r = s.runtimeSeconds { bottom.append("\(Duration.text(roundedToMinute(TimeInterval(r)))) left") }
        if let v = s.batteryVoltage { bottom.append(String(format: "%.1f V", v)) }
        drawReadout(top, strip: header(loadPlot), at: sx)
        drawReadout(bottom, strip: header(chargePlot), at: sx)
    }

    /// "Load  92 W" on the left, the scale's top on the right.
    private func drawHeader(_ strip: NSRect, title: String, value: String?, scale: String) {
        let text = NSMutableAttributedString(string: title, attributes: [.font: ChartView.titleFont, .foregroundColor: NSColor.secondaryLabelColor])
        if let value {
            text.append(NSAttributedString(string: "  " + value, attributes: [.font: ChartView.valueFont, .foregroundColor: NSColor.labelColor]))
        }
        text.draw(at: NSPoint(x: strip.minX, y: strip.minY + 2))
        let top = NSAttributedString(string: scale, attributes: [.font: ChartView.labelFont, .foregroundColor: NSColor.tertiaryLabelColor])
        top.draw(at: NSPoint(x: strip.maxX - top.size().width, y: strip.minY + 2))
    }

    /// " · "-joined facts centred on the crosshair, kept inside the strip: pushed in from the
    /// edges, and trailing facts dropped rather than letting the text run out of the panel.
    private func drawReadout(_ parts: [String], strip: NSRect, at x: CGFloat) {
        var facts = parts
        let attrs: [NSAttributedString.Key: Any] = [.font: ChartView.valueFont, .foregroundColor: NSColor.labelColor]
        var text = NSAttributedString(string: facts.joined(separator: "  ·  "), attributes: attrs)
        while text.size().width > strip.width, facts.count > 1 {
            facts.removeLast()
            text = NSAttributedString(string: facts.joined(separator: "  ·  "), attributes: attrs)
        }
        let w = text.size().width
        text.draw(at: NSPoint(x: min(strip.maxX - w, max(strip.minX, x - w / 2)), y: strip.minY + 2))
    }

    /// Baseline and top line, the vertical time ticks, and the given levels (a fraction of the
    /// plot's height, a label drawn at the left just above it, dashed or not). Only the charge
    /// limit is labelled: a mid-scale label sits on the line as often as not, and the header
    /// already gives the top of the scale.
    private func drawGrid(_ plot: NSRect, now: TimeInterval, levels: [(Double, String?, Bool)]) {
        ChartView.gridColor.setStroke()
        for y in [plot.minY + 0.5, plot.maxY - 0.5] { hline(plot, y) }
        for t in ticks(now: now) where t > now - span + 1 && t < now - 1 {
            let x = x(for: t, in: plot, now: now).rounded() + 0.5
            let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: plot.minY)); p.line(to: NSPoint(x: x, y: plot.maxY)); p.lineWidth = 1; p.stroke()
        }
        NSColor.separatorColor.setStroke()
        hline(plot, plot.minY + 0.5)
        for (f, label, dashed) in levels {
            let y = (plot.minY + CGFloat(f) * plot.height).rounded() + 0.5
            (dashed ? NSColor.secondaryLabelColor : ChartView.gridColor).setStroke()
            hline(plot, y, dash: dashed)
            guard let label else { continue }
            let attrs: [NSAttributedString.Key: Any] = [.font: ChartView.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
            NSAttributedString(string: label, attributes: attrs).draw(at: NSPoint(x: plot.minX + 2, y: y + 1))
        }
    }

    private func hline(_ plot: NSRect, _ y: CGFloat, dash: Bool = false) {
        let p = NSBezierPath(); p.move(to: NSPoint(x: plot.minX, y: y)); p.line(to: NSPoint(x: plot.maxX, y: y)); p.lineWidth = 1
        if dash { p.setLineDash([3, 3], count: 2, phase: 0) }
        p.stroke()
    }

    /// Tick times, newest first: now, then back by a round step that gives at most four
    /// intervals across the span.
    private func ticks(now: TimeInterval) -> [TimeInterval] {
        let steps: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200]
        let step = steps.first { span / $0 <= 4.01 } ?? span / 4
        return stride(from: 0, through: span + 1, by: step).map { now - $0 }
    }

    /// "now" at the right edge, "15 min" … at each tick, and the oldest tick says "ago".
    private func drawTimeAxis(_ plot: NSRect, now: TimeInterval, attrs: [NSAttributedString.Key: Any]) {
        let ts = ticks(now: now)
        for (i, t) in ts.enumerated() {
            let age = now - t
            let label = i == 0 ? "now" : i == ts.count - 1 ? "\(Duration.text(age)) ago" : Duration.text(age)
            let text = NSAttributedString(string: label, attributes: attrs)
            let w = text.size().width
            let x = x(for: t, in: plot, now: now)
            text.draw(at: NSPoint(x: min(plot.maxX - w, max(plot.minX, x - w / 2)), y: plot.minY - text.size().height - 1))
        }
    }

    /// Runs of samples on battery, as (start, end) in monotonic time; an open run ends now.
    private func outageBands(_ s: [UPSMonitor.Sample], now: TimeInterval) -> [(TimeInterval, TimeInterval)] {
        var bands: [(TimeInterval, TimeInterval)] = []
        var start: TimeInterval?
        for smp in s {
            if smp.onBattery, start == nil { start = smp.t }
            if !smp.onBattery, let st = start { bands.append((st, smp.t)); start = nil }
        }
        if let st = start { bands.append((st, now)) }
        return bands
    }

    private func drawOutageBands(_ bands: [(TimeInterval, TimeInterval)], now: TimeInterval, from y0: CGFloat, to y1: CGFloat) {
        let plot = panels.load
        ChartView.outageColor.withAlphaComponent(0.14).setFill()
        for (st, end) in bands {
            let x0 = max(plot.minX, x(for: st, in: plot, now: now)), x1 = min(plot.maxX, x(for: end, in: plot, now: now))
            NSRect(x: x0, y: y0, width: max(2, x1 - x0), height: y1 - y0).fill()
        }
    }

    /// The length of each outage, at the top of its band in the load panel, when it fits.
    private func drawBandLabels(_ bands: [(TimeInterval, TimeInterval)], now: TimeInterval, in plot: NSRect, attrs: [NSAttributedString.Key: Any]) {
        for (st, end) in bands {
            let x0 = max(plot.minX, x(for: st, in: plot, now: now)), x1 = min(plot.maxX, x(for: end, in: plot, now: now))
            for label in ["\(Duration.text(roundedToMinute(end - st))) on battery", Duration.text(roundedToMinute(end - st))] {
                let text = NSAttributedString(string: label, attributes: attrs)
                let sz = text.size()
                guard sz.width + 6 <= x1 - x0 else { continue }
                text.draw(at: NSPoint(x: (x0 + x1) / 2 - sz.width / 2, y: plot.maxY - sz.height - 1))
                break
            }
        }
    }

    /// A 2 pt line through the samples, optionally with a 10 % wash under it. Gaps (no value,
    /// or more than `sampleGap` apart) break the line.
    private func drawSeries(_ s: [UPSMonitor.Sample], in plot: NSRect, now: TimeInterval, color: NSColor,
                            value: (UPSMonitor.Sample) -> Double?, area: Bool) {
        var runs: [[NSPoint]] = []
        var run: [NSPoint] = []
        var lastT: TimeInterval?
        for smp in s {
            guard let v = value(smp) else { if !run.isEmpty { runs.append(run); run = [] }; lastT = nil; continue }
            if let lt = lastT, smp.t - lt > sampleGap, !run.isEmpty { runs.append(run); run = [] }
            run.append(NSPoint(x: x(for: smp.t, in: plot, now: now), y: plot.minY + CGFloat(min(1, max(0, v))) * plot.height))
            lastT = smp.t
        }
        if !run.isEmpty { runs.append(run) }
        for (i, pts) in runs.enumerated() {
            guard let first = pts.first, let last = pts.last else { continue }
            let path = NSBezierPath()
            path.move(to: first)
            for p in pts.dropFirst() { path.line(to: p) }
            if pts.count == 1 { path.line(to: NSPoint(x: first.x + 1, y: first.y)) }
            if area {
                let fill = path.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: last.x, y: plot.minY)); fill.line(to: NSPoint(x: first.x, y: plot.minY)); fill.close()
                color.withAlphaComponent(0.10).setFill(); fill.fill()
            }
            path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
            color.setStroke(); path.stroke()
            // End marker on the newest point.
            if i == runs.count - 1 {
                NSColor.windowBackgroundColor.setFill(); NSBezierPath(ovalIn: NSRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)).fill()
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)).fill()
            }
        }
    }

    private func niceCeiling(_ v: Double) -> Double {
        let steps: [Double] = [50, 100, 150, 200, 300, 400, 500, 750, 1000, 1500, 2000, 3000]
        return steps.first { $0 >= v } ?? (v / 1000).rounded(.up) * 1000
    }

    /// Whole minutes from a minute up, so the readouts do not tick through seconds.
    private func roundedToMinute(_ t: TimeInterval) -> TimeInterval {
        t < 60 ? t.rounded() : max(60, (t / 60).rounded() * 60)
    }

    private func nearest(_ s: [UPSMonitor.Sample], to px: CGFloat, in plot: NSRect, now: TimeInterval) -> UPSMonitor.Sample? {
        guard !s.isEmpty else { return nil }
        let t = now - span + Double((px - plot.minX) / plot.width) * span
        return s.min { abs($0.t - t) < abs($1.t - t) }
    }

    // MARK: Hover

    func simulateHover(atFraction f: CGFloat?) { hoverX = f.map { panels.load.minX + $0 * panels.load.width } }
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
