import AppKit
import SkylandGlass

// skyland `[decoration] ui-style = 'metal' | 'glass' | 'glyph'`: the look of skyland's panels.
// metal: a blurred backdrop (NSVisualEffectView) tinted with the theme; glass: Liquid
// Glass (SkylandGlass, from skylandbar) lightly tinted with the theme; glyph: Nothing OS
// like, opaque panels on a faint dot grid, dot matrix numbers (Doto), labels in Space Mono
// caps, one live thing in the theme's highlight (red with the glyph-dark / -light themes).

@MainActor var isGlassStyle: Bool { config.decoration.uiStyle == "glass" }
@MainActor var isGlyphStyle: Bool { config.decoration.uiStyle == "glyph" }

/// For the apps skyland starts (wallpaper picker, media widget), which read it at launch.
@MainActor
func syncUiStyle() {
    // glass-blur: here at once, for the tools at their next launch
    let blur = Double(max(0, config.decoration.glassBlur))
    if GlassTuning.blur != blur {
        GlassTuning.blur = blur
        try? FileManager.default.createDirectory(atPath: (glassBlurFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? String(Int(blur)).write(toFile: glassBlurFile, atomically: true, encoding: .utf8)
    }
    let style = config.decoration.uiStyle
    guard (try? String(contentsOfFile: uiStyleFile, encoding: .utf8)) != style else { return }
    try? FileManager.default.createDirectory(atPath: (uiStyleFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? style.write(toFile: uiStyleFile, atomically: true, encoding: .utf8)
}

/// The root view of a panel in the current style, to hold its content: a theme tinted
/// blur shaped by a rounded mask image, which also shapes the window outline and shadow
/// (metal), or a view over a glass shape (glass; the window keeps no shadow of its own).
@MainActor
func makePanelRoot(radius: CGFloat, for window: NSWindow) -> NSView {
    if isGlyphStyle { return GlyphPanel(radius: radius) }
    if isGlassStyle {
        window.hasShadow = false // the glass draws its own
        let root = NSView()
        root.addSubview(GlassBackground(radius: radius, tint: skylandThemeColors()["bg"]?.withAlphaComponent(0.18)))
        return root
    }
    let blur = NSVisualEffectView()
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.maskImage = roundedMaskImage(radius: radius)
    return blur
}

/// A rounded rectangle stretched to any size (NSVisualEffectView.maskImage).
func roundedMaskImage(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    mask.resizingMode = .stretch
    return mask
}

/// skylandbar's Liquid Glass recipe (its themes/liquid-glass.toml), from the theme's accent:
/// the glass lightly tinted, a flat hover, the selection a tinted lens.
@MainActor
enum LiquidTint {
    static var accent: NSColor { skylandThemeColors()["accent"] ?? .systemBlue }
    static var glass: NSColor { accent.withAlphaComponent(0.08) }
    static var hover: NSColor { accent.withAlphaComponent(0.14) }
    static var lens: NSColor { accent.withAlphaComponent(0.30) }
}

// MARK: glyph

/// glyph: the panel itself, opaque in the theme's panel color, a faint dot grid, a thin
/// line around. Draws the window's shape: the window stays clear around the corners.
final class GlyphPanel: NSView {
    let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated { drawGlyphPanel(in: bounds, radius: radius) }
    }
}

/// The glyph panel look in `rect` (also the overview strip's background).
@MainActor
func drawGlyphPanel(in rect: NSRect, radius: CGFloat) {
    let theme = skylandThemeColors()
    let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
    (theme["bg_panel"] ?? .black).setFill()
    shape.fill()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    (theme["fg"] ?? .white).withAlphaComponent(0.16).setFill()
    let pitch: CGFloat = 12, dot: CGFloat = 1.6
    for y in stride(from: rect.minY + pitch / 2, to: rect.maxY, by: pitch) {
        for x in stride(from: rect.minX + pitch / 2, to: rect.maxX, by: pitch) {
            NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    (theme["border"] ?? .darkGray).setStroke()
    shape.lineWidth = 1
    shape.stroke()
}

/// The panels' fonts: in the glyph style Doto (dot matrix: numbers, titles), Space Grotesk
/// (text) and Space Mono (labels, written in caps); the system fonts otherwise or when the
/// bundled fonts are missing (Skyland.app/Contents/Resources/fonts, see registerPanelFonts).
@MainActor
enum PanelFont {
    static func dots(_ size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        guard isGlyphStyle, let doto = NSFont(name: "Doto-Black", size: size) else { return .systemFont(ofSize: size, weight: weight) }
        // wght 100-900, ROND 100: round dots, as on the Glyph lights
        let axes: [Int: CGFloat] = [2_003_265_652: weight >= .bold ? 800 : weight >= .medium ? 600 : 400, 1_380_929_092: 100]
        return NSFont(descriptor: doto.fontDescriptor.addingAttributes([.init(rawValue: kCTFontVariationAttribute as String): axes]), size: size) ?? doto
    }

    static func text(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name = weight >= .semibold ? "SpaceGrotesk-Bold" : weight >= .medium ? "SpaceGrotesk-Medium" : "SpaceGrotesk-Regular"
        guard isGlyphStyle, let font = NSFont(name: name, size: size) else { return .systemFont(ofSize: size, weight: weight) }
        return font
    }

    static func label(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard isGlyphStyle, let font = NSFont(name: weight >= .semibold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        return font
    }

    /// A label as the style writes it: caps in glyph.
    static func caps(_ text: String) -> String { isGlyphStyle ? text.uppercased() : text }
}

/// Dark or light controls after the theme's background (a glyph panel is opaque in the theme color).
@MainActor
func themeAppearance() -> NSAppearance? {
    guard let bg = skylandThemeColors()["bg"]?.usingColorSpace(.sRGB) else { return NSAppearance(named: .darkAqua) }
    return NSAppearance(named: bg.brightnessComponent < 0.5 ? .darkAqua : .aqua)
}

/// The bundled fonts (resources/fonts, SIL OFL), for this process only: nothing installed.
@MainActor
func registerPanelFonts() {
    guard let dir = Bundle.main.resourceURL?.appending(path: "fonts"),
          let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for file in files where ["ttf", "otf"].contains(file.pathExtension) {
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }
}
