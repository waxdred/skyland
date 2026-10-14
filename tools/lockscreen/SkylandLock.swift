// skyland lock screen saver, hyprlock-like (43PR): blurred wallpaper, glassy
// clock and date in the current theme colors, user name.
// macOS still owns authentication: any key shows the real lock screen.
//
// Reads its data from its own bundle Resources (the screen saver host is
// sandboxed), written by bin/skyland-lock: theme.css (`@define-color k #hex;`),
// wallpaper.jpg (already blurred), name.txt.
import AppKit
import ScreenSaver

@objc(SkylandLockView) // NSPrincipalClass in the bundle Info.plist
final class SkylandLockView: ScreenSaverView {
    private var colors: [String: NSColor] = [:]
    private var wallpaper: NSImage?
    // How opaque the theme-colored veil over the wallpaper is: the further the
    // wallpaper brightness is from the theme background, the stronger (contrast).
    private var veil: CGFloat = 0.25
    private var name = NSFullUserName()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1
        load()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1
        load()
    }

    private func load() {
        // SKYLAND_LOCK_RESOURCES: render outside a .saver (bin/skyland-lock preview)
        let bundle = ProcessInfo.processInfo.environment["SKYLAND_LOCK_RESOURCES"].flatMap { Bundle(path: $0) }
            ?? Bundle(for: SkylandLockView.self)
        if let url = bundle.url(forResource: "theme", withExtension: "css"),
           let css = try? String(contentsOf: url, encoding: .utf8)
        {
            colors = parseColors(css)
        }
        if let url = bundle.url(forResource: "wallpaper", withExtension: "jpg") {
            wallpaper = NSImage(contentsOf: url)
        }
        if let url = bundle.url(forResource: "name", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            name = text
        }
        if let wallpaper {
            let bg = luminance(colors["bg"] ?? .black)
            veil = 0.25 + 0.5 * abs(averageLuminance(wallpaper) - bg)
        }
    }

    private func color(_ key: String, _ alpha: CGFloat = 1, fallback: NSColor) -> NSColor {
        (colors[key] ?? fallback).withAlphaComponent(alpha)
    }

    override func animateOneFrame() {
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        let b = bounds
        // Scale everything from a 1080p reference so the System Settings preview looks the same
        let s = min(b.width / 1920, b.height / 1080)

        // Background: blurred wallpaper (aspect fill) dimmed with the theme background
        color("bg", fallback: .black).setFill()
        b.fill()
        if let wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 {
            let scale = max(b.width / wallpaper.size.width, b.height / wallpaper.size.height)
            let size = NSSize(width: wallpaper.size.width * scale, height: wallpaper.size.height * scale)
            wallpaper.draw(in: NSRect(x: b.midX - size.width / 2, y: b.midY - size.height / 2, width: size.width, height: size.height))
        }
        color("bg", veil, fallback: .black).setFill()
        b.fill(using: .sourceOver)

        let now = Date()
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let date = DateFormatter()
        date.locale = Locale.current
        date.setLocalizedDateFormatFromTemplate("EEEEdMMMM")

        // Glass card behind the clock
        let card = NSRect(x: b.midX - 330 * s, y: b.midY + 40 * s, width: 660 * s, height: 300 * s)
        glass(card, radius: 36 * s)
        text(time.string(from: now), size: 150 * s, weight: .thin, color: color("fg", fallback: .white),
             center: NSPoint(x: card.midX, y: card.midY + 30 * s))
        text(date.string(from: now).capitalized, size: 30 * s, weight: .regular, color: color("fg_dim", fallback: .lightGray),
             center: NSPoint(x: card.midX, y: card.minY + 55 * s))

        // User name
        text(name, size: 34 * s, weight: .medium, color: color("fg", fallback: .white),
             center: NSPoint(x: b.midX, y: b.midY - 50 * s))
    }

    /// Frosted glass: translucent theme card color, light top highlight, thin border.
    private func glass(_ rect: NSRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        color("bg_card", 0.45, fallback: .black).setFill()
        path.fill()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.12), ending: NSColor.white.withAlphaComponent(0.02))?
            .draw(in: path, angle: -90)
        color("fg", 0.18, fallback: .white).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: NSPoint) {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let shadow = NSShadow()
        shadow.shadowColor = self.color("bg", 0.5, fallback: .black)
        shadow.shadowBlurRadius = size / 12
        shadow.shadowOffset = .zero
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .shadow: shadow])
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

/// `@define-color key #rrggbb;` lines of a 43PR-style theme.
func parseColors(_ css: String) -> [String: NSColor] {
    var result: [String: NSColor] = [:]
    let regex = try! NSRegularExpression(pattern: #"@define-color\s+([A-Za-z0-9_]+)\s+#([0-9A-Fa-f]{6})\s*;"#)
    for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
        guard let key = Range(match.range(at: 1), in: css), let hex = Range(match.range(at: 2), in: css),
              let value = UInt32(css[hex], radix: 16) else { continue }
        result[String(css[key])] = NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1,
        )
    }
    return result
}

func luminance(_ color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.sRGB) ?? color
    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
}

/// Average brightness of an image, by drawing it into a single pixel.
func averageLuminance(_ image: NSImage) -> CGFloat {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0.5 }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
    NSGraphicsContext.restoreGraphicsState()
    return rep.colorAt(x: 0, y: 0).map(luminance) ?? 0.5
}
