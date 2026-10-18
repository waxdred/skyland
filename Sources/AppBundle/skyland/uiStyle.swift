import AppKit
import SkylandGlass

// skyland `[decoration] ui-style = 'metal' | 'glass'`: the look of skyland's panels.
// metal: a blurred backdrop (NSVisualEffectView) tinted with the theme; glass: Liquid
// Glass (SkylandGlass, from skylandbar) lightly tinted with the theme.

@MainActor var isGlassStyle: Bool { config.decoration.uiStyle == "glass" }

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
