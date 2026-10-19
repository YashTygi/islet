// Draws the Islet app icon (original artwork) and writes Assets/AppIcon.icns.
// Usage: swift tools/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024  // design in 1024 space

    // Body: Apple icon grid, 824 pt squircle centred, continuous corners.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()
    squircle.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.14, blue: 0.30, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.04, blue: 0.09, alpha: 1)])!.draw(in: body, angle: -90)
    // Soft violet glow behind the island.
    NSGradient(colors: [NSColor(srgbRed: 0.55, green: 0.35, blue: 1, alpha: 0.45), .clear])!
        .draw(fromCenter: CGPoint(x: 512 * s, y: 610 * s), radius: 0,
              toCenter: CGPoint(x: 512 * s, y: 610 * s), radius: 420 * s, options: [])

    // Terminal prompt under the island: work running in the background.
    let prompt = NSAttributedString(string: ">_", attributes: [
        .font: NSFont(name: "Menlo-Bold", size: 190 * s) ?? NSFont.monospacedSystemFont(ofSize: 190 * s, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.70, green: 0.62, blue: 1, alpha: 0.42),
    ])
    let ps = prompt.size()
    prompt.draw(at: CGPoint(x: 512 * s - ps.width / 2, y: 255 * s))

    // The island.
    let island = CGRect(x: 232 * s, y: 545 * s, width: 560 * s, height: 150 * s)
    let pill = NSBezierPath(roundedRect: island, xRadius: 75 * s, yRadius: 75 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    NSColor.black.setFill(); pill.fill()
    ctx.restoreGState()
    NSColor.white.withAlphaComponent(0.10).setStroke()
    pill.lineWidth = 3 * s; pill.stroke()

    // Agent status dots: running (violet ring), needs you (orange, glowing), done (green).
    let cy = 620 * s
    let running = NSBezierPath(ovalIn: CGRect(x: 318 * s, y: cy - 30 * s, width: 60 * s, height: 60 * s))
    running.lineWidth = 12 * s
    NSColor(srgbRed: 0.68, green: 0.52, blue: 1, alpha: 1).setStroke(); running.stroke()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40 * s, color: NSColor.orange.withAlphaComponent(0.9).cgColor)
    NSColor(srgbRed: 1, green: 0.62, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: 476 * s, y: cy - 36 * s, width: 72 * s, height: 72 * s)).fill()
    ctx.restoreGState()

    let check = NSBezierPath()
    check.move(to: CGPoint(x: 648 * s, y: cy))
    check.line(to: CGPoint(x: 670 * s, y: cy - 22 * s))
    check.line(to: CGPoint(x: 712 * s, y: cy + 24 * s))
    check.lineWidth = 14 * s; check.lineCapStyle = .round; check.lineJoinStyle = .round
    NSColor(srgbRed: 0.27, green: 0.86, blue: 0.48, alpha: 1).setStroke(); check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: set)
try! fm.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! draw(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
            .write(to: set.appendingPathComponent(name))
    }
}
try! draw(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Assets/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Assets/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: set)
print(p.terminationStatus == 0 ? "wrote Assets/AppIcon.icns" : "iconutil failed")
