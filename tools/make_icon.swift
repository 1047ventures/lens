// Draws the Lens app icon (concept B, "Glass") at 1024×1024 and writes it as a PNG.
//   swift tools/make_icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "lens_icon_1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Apple's macOS icon grid: an 824 pt rounded square centred in the 1024 canvas, with a soft shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
color(0x131211).setFill()
tilePath.fill()
ctx.restoreGState()

// A very slight top-to-bottom lift so the tile reads as glass, not a flat square
ctx.saveGState()
tilePath.addClip()
let lift = NSGradient(starting: color(0x1E1C1A), ending: color(0x0F0E0D))!
lift.draw(in: tile, angle: -90)
ctx.restoreGState()
color(0x2A2725).setStroke()
tilePath.lineWidth = 3
tilePath.stroke()

let c = CGPoint(x: 512, y: 512)
func circle(_ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

// Outer barrel
let barrel = circle(284)
color(0x1B1A19).setFill(); barrel.fill()
color(0x3FD1C2).setStroke(); barrel.lineWidth = 27; barrel.stroke()

// Inner ring
let ring = circle(211)
color(0x1E2B2A).setFill(); ring.fill()
color(0x2F9F95).setStroke(); ring.lineWidth = 14; ring.stroke()

// Deep glass and the teal iris
color(0x152120).setFill(); circle(128).fill()
color(0x3FD1C2).setFill(); circle(60).fill()

// Amber light glint on the upper left, plus a small flare lower right.
// (AppKit's y axis points up, so the concept's upper-left arc sits at 105°–160°.)
let glint = NSBezierPath()
glint.appendArc(withCenter: c, radius: 174, startAngle: 110, endAngle: 155, clockwise: false)
color(0xF5A35B).setStroke()
glint.lineWidth = 23
glint.lineCapStyle = .round
glint.stroke()
color(0xF5A35B).setFill()
NSBezierPath(ovalIn: CGRect(x: c.x + 101 - 18, y: c.y - 92 - 18, width: 36, height: 36)).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
