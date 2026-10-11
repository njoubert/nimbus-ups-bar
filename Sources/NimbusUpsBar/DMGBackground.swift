// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The picture behind the disk image's Finder window: "drag the app onto Applications", an
/// arrow between the two icons, and what to expect on first launch. Geometry is shared with
/// build.sh: a `width`×`height` window, icon centres at `appIcon` and `appsIcon`.
enum DMGBackground {

    static let width: CGFloat = 640
    static let height: CGFloat = 440
    static let iconSize: CGFloat = 128
    static let appIcon = CGPoint(x: 170, y: 210)
    static let appsIcon = CGPoint(x: 470, y: 210)

    private static let ink = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1)
    private static let dim = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1)
    private static let faint = NSColor(srgbRed: 0.58, green: 0.58, blue: 0.62, alpha: 1)
    private static let paper = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.975, alpha: 1)
    private static let arrow = NSColor(srgbRed: 1.0, green: 0.69, blue: 0.18, alpha: 1)

    static func draw(signed: Bool) {
        let w = width, h = height
        paper.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        centered("Nimbus UPS Bar", font: .systemFont(ofSize: 22, weight: .semibold), color: ink, y: h - 52)
        centered("Drag the app onto the Applications folder, then open it from there.", font: .systemFont(ofSize: 13), color: dim, y: h - 76)

        let y = h - appIcon.y
        let x0 = appIcon.x + iconSize / 2 + 22, x1 = appsIcon.x - iconSize / 2 - 22
        let p = NSBezierPath()
        p.lineWidth = 5
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: NSPoint(x: x0, y: y)); p.line(to: NSPoint(x: x1, y: y))
        p.move(to: NSPoint(x: x1 - 18, y: y + 16)); p.line(to: NSPoint(x: x1, y: y)); p.line(to: NSPoint(x: x1 - 18, y: y - 16))
        arrow.setStroke()
        p.stroke()

        let notes: [(String, String)] = [
            ("Background", "On first launch from Applications it registers a launchd agent so it runs at login and comes back "
                + "if it ever crashes. Turn that off in its menu or in System Settings › General › Login Items."),
            ("Notifications", "It asks to show notifications, so you hear when the power goes and what it did about your drives."),
        ]
        var top = h - appIcon.y - iconSize / 2 - 40
        for (head, body) in notes { top = paragraph(head: head, body: body, top: top) - 10 }
        if !signed {
            centered("Unsigned build \u{2014} if macOS refuses to open it, allow it under System Settings › Privacy & Security (\u{201C}Open Anyway\u{201D}).",
                     font: .systemFont(ofSize: 10.5), color: faint, y: 18)
        }
    }

    private static func centered(_ s: String, font: NSFont, color: NSColor, y: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        a.draw(at: NSPoint(x: (width - a.size().width) / 2, y: y))
    }

    private static func paragraph(head: String, body: String, top: CGFloat) -> CGFloat {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byWordWrapping
        ps.lineSpacing = 1.5
        let a = NSMutableAttributedString(string: head + "  ", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: ink, .paragraphStyle: ps])
        a.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dim, .paragraphStyle: ps]))
        let column = NSRect(x: 56, y: 0, width: width - 112, height: top)
        let needed = a.boundingRect(with: NSSize(width: column.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        let r = NSRect(x: column.minX, y: top - needed, width: column.width, height: needed)
        a.draw(with: r, options: [.usesLineFragmentOrigin])
        return r.minY
    }

    static func pngData(scale: Int, signed: Bool) -> Data? {
        let px = (Int(width) * scale, Int(height) * scale)
        guard let ctx = CGContext(data: nil, width: px.0, height: px.1, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        draw(signed: signed)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: width, height: height)
        return rep.representation(using: .png, properties: [:])
    }

    static func write(to dir: String, signed: Bool) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] {
            guard let data = pngData(scale: scale, signed: signed) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
