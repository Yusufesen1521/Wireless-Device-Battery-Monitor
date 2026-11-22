// Draws the background of the BatteryHub disk-image window, mac/dmg-background.tiff (1x + 2x):
// a title, an arrow from the app to the Applications folder, and where to find the app afterwards. The icon positions must match mac/dmg_settings.py.
//
//   swift mac/make_dmg_background.swift      (from the repository root)

import AppKit

let W: CGFloat = 640, H: CGFloat = 420
let appCenter = NSPoint(x: 160, y: 190)  // Finder coordinates (from the top), as in dmg_settings.py
let appsCenter = NSPoint(x: 480, y: 190)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)  // points, so the 2x version is marked as Retina
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    func y(_ top: CGFloat) -> CGFloat { H - top }  // Finder-style top coordinates -> AppKit

    // Light background with a subtle green tint at the top, matching the app icon.
    NSGradient(colors: [NSColor(srgbRed: 0.93, green: 0.98, blue: 0.95, alpha: 1),
                        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: para]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = str.boundingRect(with: NSSize(width: W - 60, height: 200), options: .usesLineFragmentOrigin).height
        str.draw(with: NSRect(x: 30, y: y(top) - h, width: W - 60, height: h), options: .usesLineFragmentOrigin)
    }

    let ink = NSColor(srgbRed: 0.11, green: 0.13, blue: 0.16, alpha: 1)
    let muted = NSColor(srgbRed: 0.38, green: 0.42, blue: 0.47, alpha: 1)
    let green = NSColor(srgbRed: 0.07, green: 0.62, blue: 0.38, alpha: 1)
    text("Install BatteryHub", size: 24, weight: .semibold, color: ink, top: 34)
    text("Drag BatteryHub onto the Applications folder", size: 14, weight: .regular, color: muted, top: 70)

    // Arrow between the two icons.
    let arrow = NSBezierPath()
    let ay = y(appCenter.y)
    let x0 = appCenter.x + 78, x1 = appsCenter.x - 78
    arrow.move(to: NSPoint(x: x0, y: ay))
    arrow.line(to: NSPoint(x: x1 - 6, y: ay))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    green.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: x1 + 6, y: ay))
    head.line(to: NSPoint(x: x1 - 16, y: ay + 14))
    head.line(to: NSPoint(x: x1 - 16, y: ay - 14))
    head.close()
    green.setFill()
    head.fill()

    // First-launch note in a soft card along the bottom.
    let card = NSRect(x: 40, y: 22, width: W - 80, height: 92)
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
    NSColor(srgbRed: 0.85, green: 0.88, blue: 0.90, alpha: 1).setStroke()
    let border = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
    border.lineWidth = 1
    border.stroke()
    text("After installing", size: 13, weight: .semibold, color: ink, top: H - card.maxY + 12)
    text("BatteryHub lives in the menu bar at the top of the screen (headphones icon), with no window.\n"
         + "Allow Input Monitoring when asked, so it can read devices on 2.4 GHz receivers.",
         size: 12, weight: .regular, color: muted, top: H - card.maxY + 34)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let reps = [draw(scale: 1), draw(scale: 2)]
let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0)!
try data.write(to: URL(fileURLWithPath: "mac/dmg-background.tiff"))
try draw(scale: 2).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/mac/dmg-background-preview.png"))
print("Wrote mac/dmg-background.tiff")
