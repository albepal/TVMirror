// Draws TVMirror's artwork: the Mac app icon (1024 px), the TV launcher icon and the TV home-screen banner.
// Usage: swift scripts/make-icons.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let bgGradient = NSGradient(colors: [rgb(0x2F6BFF), rgb(0x5B4BFF), rgb(0x9A3DFF)])!

/// The glyph: a TV whose screen shows a little Mac desktop (menu bar, window, cursor).
/// `area` is the square to draw in.
func drawGlyph(in area: NSRect) {
    let u = area.width / 100 // design on a 100-unit grid
    let r = area.offsetBy(dx: 0, dy: 3.75 * u) // centre the TV + stand vertically
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: r.minX + x * u, y: r.minY + y * u, width: w * u, height: h * u)
    }

    // Stand.
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: R(45.5, 21, 9, 8), xRadius: 1 * u, yRadius: 1 * u).fill()
    NSBezierPath(roundedRect: R(33, 17.5, 34, 5), xRadius: 2.5 * u, yRadius: 2.5 * u).fill()

    // Bezel with a soft shadow.
    let bezelRect = R(14, 27, 72, 48)
    let bezel = NSBezierPath(roundedRect: bezelRect, xRadius: 6 * u, yRadius: 6 * u)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0x120A4A, 0.45)
    shadow.shadowBlurRadius = 4 * u
    shadow.shadowOffset = NSSize(width: 0, height: -1.5 * u)
    shadow.set()
    NSColor.white.setFill()
    bezel.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Screen.
    let screenRect = bezelRect.insetBy(dx: 3.6 * u, dy: 3.6 * u)
    let screen = NSBezierPath(roundedRect: screenRect, xRadius: 3 * u, yRadius: 3 * u)
    NSGradient(colors: [rgb(0x0E1640), rgb(0x23307A)])!.draw(in: screen, angle: 90)
    NSGraphicsContext.current?.saveGraphicsState()
    screen.addClip()
    // Menu bar.
    rgb(0xFFFFFF, 0.18).setFill()
    NSRect(x: screenRect.minX, y: screenRect.maxY - 4 * u, width: screenRect.width, height: 4 * u).fill()
    // Window.
    let win = NSRect(x: screenRect.minX + 9 * u, y: screenRect.minY + 8 * u, width: 36 * u, height: 22 * u)
    rgb(0x8FB4FF, 0.95).setFill()
    NSBezierPath(roundedRect: win, xRadius: 2 * u, yRadius: 2 * u).fill()
    rgb(0xDCE7FF).setFill()
    NSBezierPath(roundedRect: NSRect(x: win.minX, y: win.maxY - 4.5 * u, width: win.width, height: 4.5 * u),
                 xRadius: 2 * u, yRadius: 2 * u).fill()
    NSRect(x: win.minX, y: win.maxY - 4.5 * u, width: win.width, height: 2 * u).fill()
    for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        rgb(UInt32(c)).setFill()
        NSBezierPath(ovalIn: NSRect(x: win.minX + (2 + CGFloat(i) * 3) * u, y: win.maxY - 3.3 * u,
                                    width: 2 * u, height: 2 * u)).fill()
    }
    rgb(0xFFFFFF, 0.75).setFill()
    for (i, w) in [24.0, 18.0, 21.0].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: win.minX + 3 * u, y: win.minY + (11.5 - CGFloat(i) * 4) * u,
                                         width: CGFloat(w) * u, height: 1.8 * u), xRadius: 0.9 * u, yRadius: 0.9 * u).fill()
    }
    // Second, smaller window.
    rgb(0xC9A8FF, 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: screenRect.minX + 41 * u, y: screenRect.minY + 18 * u, width: 18 * u, height: 14 * u),
                 xRadius: 2 * u, yRadius: 2 * u).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Cursor.
    let tip = NSPoint(x: screenRect.minX + 47 * u, y: screenRect.minY + 17 * u)
    let cursor = NSBezierPath()
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -13), (3.2, -10), (5.6, -15.4), (8, -14.3), (5.7, -9.1), (10, -9.1)]
    cursor.move(to: NSPoint(x: tip.x, y: tip.y))
    for (x, y) in pts.dropFirst() { cursor.line(to: NSPoint(x: tip.x + x * u * 0.8, y: tip.y + y * u * 0.8)) }
    cursor.close()
    cursor.lineJoinStyle = .round
    cursor.lineWidth = 1.4 * u
    rgb(0x0E1640).setStroke()
    NSColor.white.setFill()
    cursor.fill()
    cursor.stroke()
}

func render(width: Int, height: Int, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

func tile(_ rect: NSRect, shadow: Bool) -> NSBezierPath {
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    if shadow {
        NSGraphicsContext.current?.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.3)
        s.shadowBlurRadius = rect.width * 0.03
        s.shadowOffset = NSSize(width: 0, height: -rect.width * 0.012)
        s.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    bgGradient.draw(in: path, angle: -55)
    // Gentle top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2),
                               xRadius: rect.width * 0.225, yRadius: rect.width * 0.225), angle: -90)
    return path
}

// Mac app icon: macOS grid (824 px tile inside 1024).
save(render(width: 1024, height: 1024) { r in
    let t = r.insetBy(dx: 100, dy: 100)
    _ = tile(t, shadow: true)
    drawGlyph(in: t.insetBy(dx: 40, dy: 40))
}, "icon-1024.png")

// TV launcher icon (square, full bleed).
save(render(width: 512, height: 512) { r in
    _ = tile(r, shadow: false)
    drawGlyph(in: r.insetBy(dx: 21, dy: 21))
}, "tv-icon.png")

// TV home-screen banner, 320×180 dp at xhdpi.
save(render(width: 640, height: 360) { r in
    bgGradient.draw(in: r, angle: -25)
    drawGlyph(in: NSRect(x: 20, y: 30, width: 290, height: 290))
    let title = NSAttributedString(string: "TVMirror", attributes: [
        .font: NSFont.systemFont(ofSize: 66, weight: .bold), .foregroundColor: NSColor.white])
    title.draw(at: NSPoint(x: 300, y: 170))
    let sub = NSAttributedString(string: "Your Mac, on the big screen", attributes: [
        .font: NSFont.systemFont(ofSize: 25, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.85)])
    sub.draw(at: NSPoint(x: 303, y: 128))
}, "banner.png")
print("ok")
