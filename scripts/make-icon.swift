// Draws the ColimaDeck app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        let s = size / 1024
        let ctx = NSGraphicsContext.current!.cgContext

        // Background: Apple's icon grid puts an 824pt rounded square in a 1024pt canvas.
        let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.addPath(bodyPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1).cgColor, // teal
            NSColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1).cgColor, // blue
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        ctx.restoreGState()

        // Three stacked layers, back to front.
        let layerWidth: CGFloat = 520 * s, layerHeight: CGFloat = 150 * s, gap: CGFloat = 34 * s
        let x = (size - layerWidth) / 2
        let stackHeight = layerHeight * 3 + gap * 2
        let bottom = (size - stackHeight) / 2 - 6 * s
        for (index, alpha) in [0.55, 0.78, 1.0].enumerated() {
            let rect = CGRect(x: x, y: bottom + CGFloat(index) * (layerHeight + gap), width: layerWidth, height: layerHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: 42 * s, cornerHeight: 42 * s, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 18 * s, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // Two slots on each layer, like the front of a server.
            for slot in 0..<2 {
                let slotRect = CGRect(x: rect.minX + 70 * s + CGFloat(slot) * 120 * s, y: rect.midY - 14 * s, width: 90 * s, height: 28 * s)
                ctx.addPath(CGPath(roundedRect: slotRect, cornerWidth: 14 * s, cornerHeight: 14 * s, transform: nil))
                ctx.setFillColor(NSColor(red: 0.12, green: 0.45, blue: 0.80, alpha: 0.35).cgColor)
                ctx.fillPath()
            }

            // Status light: green on the top layer, dim on the others.
            let light = CGRect(x: rect.maxX - 110 * s, y: rect.midY - 26 * s, width: 52 * s, height: 52 * s)
            ctx.addEllipse(in: light)
            ctx.setFillColor(index == 2
                ? NSColor(red: 0.20, green: 0.83, blue: 0.40, alpha: 1).cgColor
                : NSColor(red: 0.12, green: 0.45, blue: 0.80, alpha: 0.30).cgColor)
            ctx.fillPath()
        }
        return true
    }
}

func png(_ image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try! png(drawIcon(size: 0), pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! png(drawIcon(size: 0), pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try! png(drawIcon(size: 0), pixels: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
