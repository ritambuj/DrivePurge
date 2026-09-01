// Renders DrivePurge's app icon: a dark squircle carrying a miniature treemap
// in the app's own category palette. Run:  swift Scripts/make-icon.swift <out.png>
import AppKit
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024

func hex(_ h: String, _ a: CGFloat = 1) -> NSColor {
    var s = h; if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: a)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: artwork sits inside ~82% of the canvas.
let inset: CGFloat = S * 0.09
let body = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = body.width * 0.2237   // Apple's continuous-corner ratio
let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

// Base plate
NSGradient(colors: [hex("#1c1c22"), hex("#0b0b0d")])?.draw(in: squircle, angle: -90)
squircle.addClip()

// Miniature treemap, laid out with the same proportional logic as the app.
struct Tile { let r: NSRect; let c: NSColor }
let pad: CGFloat = body.width * 0.055
let field = body.insetBy(dx: pad, dy: pad)
let g: CGFloat = body.width * 0.022
let w = field.width, h = field.height

let leftW = w * 0.56
let tiles: [Tile] = [
    // big blue "system" block
    Tile(r: NSRect(x: field.minX, y: field.minY + h * 0.42, width: leftW - g, height: h * 0.58), c: hex("#0a84ff")),
    // green dev block
    Tile(r: NSRect(x: field.minX, y: field.minY, width: leftW * 0.60 - g, height: h * 0.42 - g), c: hex("#30d158")),
    // cyan cache block
    Tile(r: NSRect(x: field.minX + leftW * 0.60, y: field.minY, width: leftW * 0.40 - g, height: h * 0.42 - g), c: hex("#64d2ff")),
    // magenta media block
    Tile(r: NSRect(x: field.minX + leftW, y: field.minY + h * 0.60, width: w - leftW, height: h * 0.40), c: hex("#ff375f")),
    // orange apps block
    Tile(r: NSRect(x: field.minX + leftW, y: field.minY + h * 0.28, width: w - leftW, height: h * 0.32 - g), c: hex("#ff9f0a")),
    // purple docs block
    Tile(r: NSRect(x: field.minX + leftW, y: field.minY, width: (w - leftW) * 0.55 - g, height: h * 0.28 - g), c: hex("#bf5af2")),
    // yellow downloads block
    Tile(r: NSRect(x: field.minX + leftW + (w - leftW) * 0.55, y: field.minY, width: (w - leftW) * 0.45, height: h * 0.28 - g), c: hex("#ffd60a"))
]

for t in tiles {
    let path = NSBezierPath(roundedRect: t.r, xRadius: body.width * 0.028, yRadius: body.width * 0.028)
    NSGradient(colors: [t.c.blended(withFraction: 0.06, of: .white) ?? t.c,
                        t.c.blended(withFraction: 0.20, of: .black) ?? t.c])?.draw(in: path, angle: -90)
    t.c.blended(withFraction: 0.40, of: .white)?.withAlphaComponent(0.30).setStroke()
    path.lineWidth = S * 0.005
    path.stroke()
}

// Top gloss
NSGraphicsContext.current?.saveGraphicsState()
let gloss = NSBezierPath(ovalIn: NSRect(x: body.minX - body.width * 0.25,
                                        y: body.midY + body.height * 0.18,
                                        width: body.width * 1.5, height: body.height * 0.8))
gloss.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.05), NSColor.white.withAlphaComponent(0.0)])?
    .draw(in: body, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

// Rim light
NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rim = NSBezierPath(roundedRect: body.insetBy(dx: S * 0.004, dy: S * 0.004),
                       xRadius: radius, yRadius: radius)
rim.lineWidth = S * 0.008
NSColor.white.withAlphaComponent(0.14).setStroke()
rim.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
