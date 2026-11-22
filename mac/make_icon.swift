// Turns res/app.svg (the BatteryHub app icon by nik-txt) into the macOS app icon, mac/AppIcon.icns:
// the white glyph on a rounded-square tile with a green gradient, in every size macOS uses.
//
//   swift mac/make_icon.swift            (from the repository root; needs only the Xcode command line tools)
//
// Like res/make_icon.py, only the simple SVG subset the icon uses is understood: <path d="..."> with
// M L H V C S Z commands (absolute and relative), filled even-odd.

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = try String(contentsOf: root.appendingPathComponent("res/app.svg"), encoding: .utf8)

// ---- minimal SVG path parser ----------------------------------------------------------------

func parsePath(_ d: String) -> NSBezierPath {
    let path = NSBezierPath()
    let regex = try! NSRegularExpression(pattern: "[MmLlHhVvCcSsZz]|-?(?:\\d+\\.?\\d*|\\.\\d+)(?:e-?\\d+)?")
    let tokens = regex.matches(in: d, range: NSRange(d.startIndex..., in: d)).map { String(d[Range($0.range, in: d)!]) }
    var i = 0, cmd = "M"
    var cur = NSPoint.zero, start = NSPoint.zero
    var lastCtrl: NSPoint? = nil
    func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
    while i < tokens.count {
        if tokens[i].first!.isLetter { cmd = tokens[i]; i += 1 }
        let rel = cmd == cmd.lowercased()
        let base = rel ? cur : .zero
        switch cmd.uppercased() {
        case "M":
            cur = NSPoint(x: base.x + num(), y: base.y + num()); start = cur
            path.move(to: cur); lastCtrl = nil
            cmd = rel ? "l" : "L"  // further pairs are line-tos
        case "L":
            cur = NSPoint(x: base.x + num(), y: base.y + num()); path.line(to: cur); lastCtrl = nil
        case "H":
            cur = NSPoint(x: (rel ? cur.x : 0) + num(), y: cur.y); path.line(to: cur); lastCtrl = nil
        case "V":
            cur = NSPoint(x: cur.x, y: (rel ? cur.y : 0) + num()); path.line(to: cur); lastCtrl = nil
        case "C":
            let c1 = NSPoint(x: base.x + num(), y: base.y + num())
            let c2 = NSPoint(x: base.x + num(), y: base.y + num())
            let p = NSPoint(x: base.x + num(), y: base.y + num())
            path.curve(to: p, controlPoint1: c1, controlPoint2: c2); cur = p; lastCtrl = c2
        case "S":
            let c1 = lastCtrl.map { NSPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let c2 = NSPoint(x: base.x + num(), y: base.y + num())
            let p = NSPoint(x: base.x + num(), y: base.y + num())
            path.curve(to: p, controlPoint1: c1, controlPoint2: c2); cur = p; lastCtrl = c2
        case "Z":
            path.close(); cur = start; lastCtrl = nil
        default:
            i += 1
        }
    }
    return path
}

let dRegex = try NSRegularExpression(pattern: "\\sd=\"([^\"]+)\"")
let glyph = NSBezierPath()
for m in dRegex.matches(in: svg, range: NSRange(svg.startIndex..., in: svg)) {
    glyph.append(parsePath(String(svg[Range(m.range(at: 1), in: svg)!])))
}
glyph.windingRule = .evenOdd
let glyphBox = NSRect(x: 0, y: 0, width: 512, height: 512)  // the SVG viewBox

// ---- rendering ----------------------------------------------------------------------------------

// Apple's macOS icon grid: on a 1024 canvas the tile is 824 x 824, inset 100, corner radius ~185.
func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let s = CGFloat(size) / 1024
    let tileRect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185 * s, yRadius: 185 * s)

    // Soft drop shadow under the tile, as on other macOS icons.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 18 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Battery-green gradient tile.
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.84, blue: 0.42, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.55, blue: 0.36, alpha: 1)])!.draw(in: tile, angle: -90)

    // The white glyph, centred and scaled to ~62% of the tile (SVG y points down, AppKit's up).
    let g = glyph.copy() as! NSBezierPath
    let target = 824 * s * 0.62
    let scale = target / glyphBox.width
    let t = AffineTransform(translationByX: 512 * s - target / 2, byY: 512 * s + target / 2 - 8 * s)
    var flip = AffineTransform(scaleByX: scale, byY: -scale)
    flip.append(t)
    g.transform(using: flip)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    glow.shadowBlurRadius = 6 * s
    glow.shadowOffset = NSSize(width: 0, height: -3 * s)
    glow.set()
    NSColor.white.setFill()
    g.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let png = render(base * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
try render(1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("mac/AppIcon-1024.png"))

// Menu-bar glyph (shown while no device is found): the same glyph, black on transparent, used as a
// template image so macOS tints it for light and dark menu bars. 18 pt tall, at 1x and 2x.
func menuGlyph(scale: Int) -> NSBitmapImageRep {
    let side = 18 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 18, height: 18)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = glyph.copy() as! NSBezierPath
    let b = g.bounds
    // rep.size is 18 pt, so drawing coordinates are points (the 2x bitmap maps them to 36 px).
    let fit = 18 * 0.94 / max(b.width, b.height)
    // x' = (x - midX) * fit + side/2,  y' = -(y - midY) * fit + side/2  (SVG y points down)
    let half: CGFloat = 9
    g.transform(using: AffineTransform(m11: fit, m12: 0, m21: 0, m22: -fit,
                                       tX: half - b.midX * fit, tY: half + b.midY * fit))
    NSColor.black.setFill()
    g.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
try menuGlyph(scale: 1).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("mac/MenuIcon.png"))
try menuGlyph(scale: 2).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("mac/MenuIcon@2x.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("mac/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote mac/AppIcon.icns and mac/AppIcon-1024.png" : "iconutil failed")
