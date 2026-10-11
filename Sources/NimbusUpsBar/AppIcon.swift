// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreGraphics
import Foundation

/// The app icon, drawn in code (no .icns checked in): the family's dark macOS squircle, a
/// battery lying across it with an amber charge and a bolt cut out of the charge, over a
/// warm glow. `build.sh app` renders it to an .iconset → .icns; `build.sh icon` refreshes
/// docs/icon.png.
enum AppIcon {

    private static let ref: CGFloat = 1024
    private static let bodyInset: CGFloat = 100
    private static let bodyRadius: CGFloat = 185.4

    private static let amber = rgb(0xFF, 0xB0, 0x2E)
    private static let amberDeep = rgb(0xF2, 0x7A, 0x1A)
    private static let steel = rgb(0xC8, 0xD2, 0xDE)

    /// Shadow offsets and blurs are in base space (the CTM does not scale them), so every
    /// `setShadow` multiplies by this; see the siblings' CLAUDE.md for the trap.
    nonisolated(unsafe) private static var scale: CGFloat = 1

    static func draw(in ctx: CGContext, size: CGFloat) {
        ctx.saveGState()
        scale = size / ref
        ctx.scaleBy(x: scale, y: scale)

        let body = CGRect(x: bodyInset, y: bodyInset, width: ref - 2 * bodyInset, height: ref - 2 * bodyInset)
        let shape = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale, color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        fillLinear(ctx, from: CGPoint(x: 512, y: body.maxY), to: CGPoint(x: 512, y: body.minY),
                   stops: [(0, rgb(0x2A, 0x36, 0x4A)), (0.5, rgb(0x14, 0x1B, 0x27)), (1, rgb(0x08, 0x0B, 0x11))], rect: body)
        drawGlow(ctx, center: CGPoint(x: 512, y: 500), radius: 480, color: amber, alpha: 0.22)
        drawBattery(ctx)
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.14).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.restoreGState()
    }

    /// A horizontal battery: steel case, amber charge at about three quarters, a bolt punched
    /// out of the charge so the glow shows through it.
    private static func drawBattery(_ ctx: CGContext) {
        let caseRect = CGRect(x: 180, y: 352, width: 600, height: 320)
        let nub = CGRect(x: 780, y: 452, width: 56, height: 120)
        let r: CGFloat = 54
        let shell = CGPath(roundedRect: caseRect, cornerWidth: r, cornerHeight: r, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 40 * scale, color: amber.copy(alpha: 0.35))
        ctx.addPath(shell)
        ctx.setStrokeColor(steel)
        ctx.setLineWidth(34)
        ctx.strokePath()
        ctx.addPath(CGPath(roundedRect: nub, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.setFillColor(steel)
        ctx.fillPath()
        ctx.restoreGState()

        // Charge: three cells' worth, with the bolt cut out of it (even-odd).
        let inner = caseRect.insetBy(dx: 44, dy: 44)
        let fillW = inner.width * 0.76
        let charge = CGRect(x: inner.minX, y: inner.minY, width: fillW, height: inner.height)
        let chargePath = CGMutablePath()
        chargePath.addPath(CGPath(roundedRect: charge, cornerWidth: 24, cornerHeight: 24, transform: nil))
        chargePath.addPath(bolt(center: CGPoint(x: charge.midX, y: charge.midY), height: 200))
        ctx.saveGState()
        ctx.addPath(chargePath)
        ctx.clip(using: .evenOdd)
        fillLinear(ctx, from: CGPoint(x: 0, y: charge.maxY), to: CGPoint(x: 0, y: charge.minY),
                   stops: [(0, amber), (1, amberDeep)], rect: charge)
        ctx.restoreGState()

        // The bolt's own glow, drawn soft behind where it was cut.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30 * scale, color: amber.copy(alpha: 0.9))
        ctx.addPath(bolt(center: CGPoint(x: charge.midX, y: charge.midY), height: 200))
        ctx.setFillColor(rgb(0x1E, 0x27, 0x36))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func bolt(center c: CGPoint, height h: CGFloat) -> CGPath {
        let w = h * 0.58
        let p = CGMutablePath()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * w / 2, y: c.y + y * h / 2) }
        p.move(to: pt(0.15, 1.0)); p.addLine(to: pt(-0.95, -0.1)); p.addLine(to: pt(-0.1, -0.1))
        p.addLine(to: pt(-0.3, -1.0)); p.addLine(to: pt(0.95, 0.15)); p.addLine(to: pt(0.1, 0.15))
        p.closeSubpath()
        return p
    }

    // MARK: Helpers

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func fillLinear(_ ctx: CGContext, from: CGPoint, to: CGPoint, stops: [(CGFloat, CGColor)], rect: CGRect) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 }) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func drawGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, alpha: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color.copy(alpha: alpha)!, color.copy(alpha: 0)!] as CFArray, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: Rasterising

    static func cgImage(px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        draw(in: ctx, size: CGFloat(px))
        return ctx.makeImage()
    }

    static func pngData(px: Int) -> Data? {
        guard let cg = cgImage(px: px) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    static func writeIconset(to dir: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
        for (pt, scale) in variants {
            let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
            guard let data = pngData(px: pt * scale) else { continue }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
