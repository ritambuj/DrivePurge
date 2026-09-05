import AppKit
import Foundation
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let S: CGFloat = 1024
func hex(_ h: String) -> NSColor {
    var s = h; if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff)/255, green: CGFloat((v >> 8) & 0xff)/255, blue: CGFloat(v & 0xff)/255, alpha: 1)
}
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let inset = S * 0.09
let body = NSRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let r = body.width * 0.2237
let plate = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
hex("#ec3013").setFill(); plate.fill()
let inner = body.insetBy(dx: body.width * 0.15, dy: body.width * 0.15)
hex("#f3f2f2").setFill(); NSBezierPath(rect: inner).fill()
NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! (png as NSData).write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
