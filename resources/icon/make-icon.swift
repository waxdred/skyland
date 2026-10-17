// Draws the Skyland app icon: a floating island carrying tiled windows over a
// cyberspace grid. `resources/icon/make-icns` turns it into resources/Skyland.icns.
import AppKit

let out = CommandLine.arguments[1]
let px = Int(CommandLine.arguments[2])!
let s = CGFloat(px) / 1024 // the drawing is laid out on a 1024 grid
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: s, y: s)
ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1) // y down

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
let cyan = rgb(0x4DF3FF), magenta = rgb(0xFF3DB8), violet = rgb(0x8A5CFF)

// macOS icon grid: 824 square at 100, continuous corners
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x0A0E22)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
// night sky
ctx.drawLinearGradient(gradient([rgb(0x070A1C), rgb(0x1A1442), rgb(0x3A1656)], [0, 0.6, 1]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// glow behind the island
ctx.drawRadialGradient(gradient([rgb(0x4DF3FF, 0.30), rgb(0x8A5CFF, 0.12), rgb(0x000000, 0)], [0, 0.45, 1]),
                       startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 420, options: [])
// stars
var seed: UInt64 = 7
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
for _ in 0 ..< 46 {
    let p = CGPoint(x: 120 + rnd() * 784, y: 120 + rnd() * 360), r = 1.2 + rnd() * 2.6
    ctx.setFillColor(rgb(0xFFFFFF, 0.25 + rnd() * 0.55))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
}
// cyberspace grid on the horizon
let horizon: CGFloat = 780
ctx.saveGState()
ctx.clip(to: CGRect(x: 100, y: horizon, width: 824, height: 144))
ctx.setLineWidth(2.2)
for i in 0 ..< 8 { // horizontal lines, closer together near the horizon
    let t = pow(CGFloat(i) / 7, 1.8), y = horizon + t * 150
    ctx.setStrokeColor(rgb(0xFF3DB8, 0.18 + 0.5 * t))
    ctx.move(to: CGPoint(x: 100, y: y)); ctx.addLine(to: CGPoint(x: 924, y: y)); ctx.strokePath()
}
for i in -9 ... 9 { // lines converging to the vanishing point
    ctx.setStrokeColor(rgb(0xFF3DB8, 0.45))
    ctx.move(to: CGPoint(x: 512 + CGFloat(i) * 22, y: horizon)); ctx.addLine(to: CGPoint(x: 512 + CGFloat(i) * 150, y: 930)); ctx.strokePath()
}
ctx.restoreGState()
ctx.drawLinearGradient(gradient([rgb(0xFF3DB8, 0), rgb(0xFF3DB8, 0.35), rgb(0xFF3DB8, 0)]),
                       start: CGPoint(x: 512, y: horizon - 30), end: CGPoint(x: 512, y: horizon + 30), options: [])

// its shadow on the grid: it floats
ctx.drawRadialGradient(gradient([rgb(0x05030F, 0.75), rgb(0x05030F, 0)]), startCenter: CGPoint(x: 512, y: 840), startRadius: 0, endCenter: CGPoint(x: 512, y: 840), endRadius: 150, options: [])

ctx.translateBy(x: 0, y: 25) // island and windows: centered in the tile
// the island: a rock tapering down under a flat top
let top: CGFloat = 520, left: CGFloat = 250, right: CGFloat = 774
let rock = CGMutablePath()
rock.move(to: CGPoint(x: left, y: top))
rock.addCurve(to: CGPoint(x: 445, y: 660), control1: CGPoint(x: left + 20, y: 590), control2: CGPoint(x: 380, y: 620))
rock.addLine(to: CGPoint(x: 500, y: 735))
rock.addLine(to: CGPoint(x: 545, y: 680))
rock.addCurve(to: CGPoint(x: right, y: top), control1: CGPoint(x: 650, y: 620), control2: CGPoint(x: right - 20, y: 590))
rock.closeSubpath()
ctx.saveGState()
ctx.addPath(rock); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(0x2B2F5E), rgb(0x141633), rgb(0x0A0B1C)], [0, 0.5, 1]),
                       start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: 735), options: [])
ctx.restoreGState()
// rock facets
ctx.setStrokeColor(rgb(0x8A5CFF, 0.35)); ctx.setLineWidth(3)
for (a, b) in [((330.0, 540.0), (435.0, 650.0)), ((520.0, 540.0), (500.0, 728.0)), ((680.0, 540.0), (565.0, 670.0))] {
    ctx.move(to: CGPoint(x: a.0, y: a.1)); ctx.addLine(to: CGPoint(x: b.0, y: b.1)); ctx.strokePath()
}
// glowing rim on the island's top
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: cyan)
ctx.setStrokeColor(cyan); ctx.setLineWidth(6); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: left, y: top)); ctx.addLine(to: CGPoint(x: right, y: top)); ctx.strokePath()
ctx.restoreGState()

// tiled windows standing on the island (a master and a stack)
func pane(_ r: CGRect) {
    let p = CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0x1C2457, 0.92), rgb(0x10132E, 0.92)]),
                           start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
    ctx.setFillColor(rgb(0x4DF3FF, 0.16)); ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 26)) // title bar
    ctx.restoreGState()
    // the border gradient (cyan to magenta, as skyland's rotating border)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: rgb(0x4DF3FF, 0.8))
    ctx.addPath(p); ctx.setLineWidth(7); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([cyan, violet, magenta]), start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
    ctx.restoreGState()
}
let gap: CGFloat = 16, base = top - 22, h: CGFloat = 300
pane(CGRect(x: 290, y: base - h, width: 250, height: h))
pane(CGRect(x: 540 + gap, y: base - h, width: 178, height: (h - gap) / 2))
pane(CGRect(x: 540 + gap, y: base - (h - gap) / 2, width: 178, height: (h - gap) / 2))
ctx.restoreGState()

// thin highlight on the tile edge
ctx.addPath(squircle); ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(3); ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
