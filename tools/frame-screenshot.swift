// Frame a screenshot for the README: gradient background in the current theme
// colors, rounded corners, drop shadow, optional caption.
//   frame-screenshot <in.png> <out.png> [caption]
// Colors: accent/highlight/bg of ~/.cache/skyland/theme.css, or of the CSS
// theme given in SKYLAND_FRAME_THEME (to match the theme of the screenshot).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let shot = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: frame-screenshot <in.png> <out.png> [caption]\n".data(using: .utf8)!)
    exit(1)
}
let caption = args.count > 3 ? args[3] : nil

func themeColors() -> [String: NSColor] {
    let url = ProcessInfo.processInfo.environment["SKYLAND_FRAME_THEME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/theme.css")
    guard let css = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: NSColor] = [:]
    let regex = try! NSRegularExpression(pattern: #"@define-color\s+([A-Za-z0-9_]+)\s+#([0-9A-Fa-f]{6})\s*;"#)
    for m in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
        guard let k = Range(m.range(at: 1), in: css), let h = Range(m.range(at: 2), in: css), let v = UInt32(css[h], radix: 16) else { continue }
        result[String(css[k])] = NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    return result
}
let colors = themeColors()

// Work in pixels of the screenshot (retina captures are 2x)
let rep = shot.representations.first
let pixelSize = NSSize(width: rep?.pixelsWide ?? Int(shot.size.width), height: rep?.pixelsHigh ?? Int(shot.size.height))
let unit = pixelSize.width / 1728 // 1 on a 1728 px wide shot
let pad = 110 * unit, radius = 22 * unit, captionHeight: CGFloat = caption == nil ? 0 : 90 * unit
let canvas = NSSize(width: pixelSize.width + 2 * pad, height: pixelSize.height + 2 * pad + captionHeight)

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
out.size = canvas
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSGraphicsContext.current?.imageInterpolation = .high

// Background: diagonal gradient between the theme accent and highlight, darkened with bg
let accent = colors["accent"] ?? .systemPurple, highlight = colors["highlight"] ?? .systemBlue, bg = colors["bg"] ?? .black
NSGradient(colors: [accent.blended(withFraction: 0.35, of: bg)!, highlight.blended(withFraction: 0.55, of: bg)!, bg])!
    .draw(in: NSRect(origin: .zero, size: canvas), angle: -35)

// Screenshot with rounded corners and a soft shadow
let frame = NSRect(x: pad, y: pad + captionHeight, width: pixelSize.width, height: pixelSize.height)
let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
shadow.shadowBlurRadius = 60 * unit
shadow.shadowOffset = NSSize(width: 0, height: -18 * unit)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
path.addClip()
shot.draw(in: frame)
NSGraphicsContext.restoreGraphicsState()
NSColor.white.withAlphaComponent(0.12).setStroke()
path.lineWidth = 1.5 * unit
path.stroke()

if let caption {
    let font = NSFont.systemFont(ofSize: 34 * unit, weight: .semibold)
    let text = NSAttributedString(string: caption, attributes: [.font: font, .foregroundColor: (colors["fg"] ?? .white)])
    let size = text.size()
    text.draw(at: NSPoint(x: (canvas.width - size.width) / 2, y: pad * 0.55 + (captionHeight - size.height) / 2))
}
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
