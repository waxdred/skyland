import AppKit

// skyland's Liquid Glass, ported from skylandbar (github.com/waxdred/skylandBar,
// Sources/skylandbar/LiquidGlass): the glass under a panel, drawn by one of three engines.
//   system    NSGlassEffectView in an NSGlassEffectContainerView (macOS 26)
//   metal     what is behind the window (ScreenCaptureKit) through a shader: refraction at
//             the edges, chromatic aberration, a light blur, saturation, rim light, sheen,
//             and shapes that melt together when closer than glass_spacing (any macOS)
//   backdrop  Core Animation's backdrop layer (blur, saturation) under highlight layers:
//             no refraction, no permission
// `glass_engine=auto` takes the first one this Mac can do.

/// One glass shape, in the window's flipped coordinates (points).
public struct GlassShape: Equatable {
    var rect: NSRect
    var radius: Double
    var tint: GlassColor
    /// regular | clear | lens (inside another shape: a selection, Apple's tab bar style) |
    /// hover (a lighter lens)
    var style: String
    /// a moving lens, lifted (0...1): it magnifies more, its rim and shade grow
    var lift = 0.0
    /// a lens: the drop it leaves behind while it moves, melted into it
    var tail: NSRect?

    public init(rect: NSRect, radius: Double, tint: GlassColor = .clear, style: String = "regular") {
        self.rect = rect
        self.radius = radius
        self.tint = tint
        self.style = style
    }
}

public struct GlassSettings: Equatable {
    var engine = "auto"
    var spacing = 0.0
    var refraction = 14.0
    var blur = 2.0
    var saturation = 1.5
    var lensResponse = 0.35
    var lensBounce = 0.3
    var lensStretch = 1.0
    /// the Reduce Motion setting: lenses do not slide
    var reduceMotion = false

    public init() {}

}

/// The glass of a window: its view fills the window, under the items' view.
public protocol GlassRenderer: AnyObject {
    var view: NSView { get }
    /// it cannot go on (metal: the capture stopped): the window takes another engine
    var failed: Bool { get }
    func update(_ shapes: [GlassShape], settings: GlassSettings, window: NSWindow)
}

public enum GlassEngine {
    static var systemAvailable: Bool { Glass.effectView != nil }

    private static var said = Set<String>()
    private static var asked = false

    /// The engine a setting gives on this Mac, said once on stderr.
    public static func resolve(_ setting: String) -> String {
        var engine: String
        switch setting {
            case "system": engine = systemAvailable ? "system" : resolve("auto")
            case "backdrop": engine = "backdrop"
            case "metal":
                engine = MetalGlass.isAvailable ? "metal" : "backdrop"
                if engine != "metal" && !asked { // ask once; macOS wants the bar restarted after
                    asked = true
                    CGRequestScreenCaptureAccess()
                }
            default: engine = systemAvailable ? "system" : MetalGlass.isAvailable ? "metal" : "backdrop"
        }
        if said.insert("\(setting)>\(engine)").inserted {
            let why = engine == "backdrop" && !systemAvailable
                ? " (metal, with refraction, needs Screen Recording for skyland, then a restart)" : ""
            FileHandle.standardError.write(Data("skyland: glass: \(engine)\(why)\n".utf8))
        }
        return engine
    }

    public static func make(_ engine: String) -> GlassRenderer {
        switch engine {
            case "system": return SystemGlass()
            case "metal": return MetalGlass() ?? BackdropGlass()
            default: return BackdropGlass()
        }
    }
}

// MARK: system

/// Apple's glass: an NSGlassEffectView per shape, in an NSGlassEffectContainerView.
final class SystemGlass: GlassRenderer {
    let view: NSView
    private let holder: NSView
    private var glasses: [NSView] = []
    let failed = false

    init() {
        (view, holder) = Glass.makeContainer()
    }

    func update(_ shapes: [GlassShape], settings: GlassSettings, window: NSWindow) {
        Glass.setSpacing(holder, settings.spacing)
        while glasses.count > shapes.count { glasses.removeLast().removeFromSuperview() }
        while glasses.count < shapes.count {
            let glass = Glass.makeView()
            holder.addSubview(glass)
            glasses.append(glass)
        }
        for (glass, shape) in zip(glasses, shapes) {
            glass.frame = shape.rect
            Glass.update(glass, style: shape.style, tint: shape.tint, cornerRadius: shape.radius)
        }
    }
}

// MARK: backdrop

/// Core Animation's backdrop layer (what vibrancy uses: the window server's blur of what is
/// behind the window) with a saturation boost, under a tint, a sheen, a rim light and a
/// soft shadow, per shape.
final class BackdropGlass: GlassRenderer {
    let view: NSView = LayerHost()
    private var layers: [BackdropShapeLayer] = []
    let failed = false

    func update(_ shapes: [GlassShape], settings: GlassSettings, window: NSWindow) {
        guard let host = view.layer else { return }
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        while layers.count > shapes.count { layers.removeLast().removeFromSuperlayer() }
        while layers.count < shapes.count {
            let layer = BackdropShapeLayer()
            host.addSublayer(layer)
            layers.append(layer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, shape) in zip(layers, shapes) {
            // the host is not flipped: y from the bottom
            let rect = NSRect(x: shape.rect.minX, y: view.bounds.height - shape.rect.maxY, width: shape.rect.width, height: shape.rect.height)
            layer.configure(rect: rect, shape: shape, settings: settings, dark: dark)
        }
        CATransaction.commit()
    }
}

/// A layer-backed view whose sublayers are the glass.
private final class LayerHost: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // the items' view takes the mouse
}

private final class BackdropShapeLayer: CALayer {
    private let clip = CALayer()
    private let backdrop = BackdropShapeLayer.makeBackdrop()
    private let tint = CALayer()
    private let sheen = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()
    private var applied: (blur: Double, saturation: Double)?

    override init() {
        super.init()
        clip.masksToBounds = true
        clip.cornerCurve = .continuous
        clip.addSublayer(backdrop)
        clip.addSublayer(tint)
        clip.addSublayer(sheen)
        addSublayer(clip)
        rimShape.fillColor = nil
        rimShape.strokeColor = NSColor.black.cgColor
        rimShape.lineWidth = 1
        rim.mask = rimShape
        addSublayer(rim)
        shadowColor = NSColor.black.cgColor
        shadowOffset = CGSize(width: 0, height: -2)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    func configure(rect: NSRect, shape: GlassShape, settings: GlassSettings, dark: Bool) {
        frame = rect
        let bounds = CGRect(origin: .zero, size: rect.size)
        let radius = CGFloat(shape.radius)
        clip.frame = bounds
        clip.cornerRadius = radius
        backdrop.frame = bounds
        tint.frame = bounds
        sheen.frame = bounds
        rim.frame = bounds
        rimShape.frame = bounds
        let outline = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(0, radius - 0.5), cornerHeight: max(0, radius - 0.5),
                             transform: nil)
        rimShape.path = outline
        shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let clear = shape.style == "clear"
        let lift = CGFloat(shape.lift) // a moving lens: lifted, its shadow wider
        shadowOpacity = Float(clear ? 0.08 : 0.18 + 0.12 * shape.lift)
        shadowRadius = 8 + 6 * lift
        // the glass's own light: darker and denser in dark mode, milky in light mode, then its tint
        let base = dark ? NSColor(white: 0.08, alpha: clear ? 0.10 : 0.22) : NSColor(white: 1, alpha: clear ? 0.12 : 0.30)
        tint.backgroundColor = (shape.tint.alpha > 0 ? shape.tint.nsColor : base).cgColor
        sheen.colors = [NSColor(white: 1, alpha: dark ? 0.10 : 0.22).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        sheen.startPoint = CGPoint(x: 0.5, y: 1) // the top (the layer is not flipped)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.45)
        // the rim: bright where light from the top left falls, softer opposite
        rim.colors = [NSColor(white: 1, alpha: dark ? 0.55 : 0.85).cgColor, NSColor(white: 1, alpha: 0.06).cgColor,
                      NSColor(white: 1, alpha: dark ? 0.22 : 0.35).cgColor]
        rim.locations = [0, 0.55, 1]
        rim.startPoint = CGPoint(x: 0, y: 1)
        rim.endPoint = CGPoint(x: 1, y: 0)
        let wanted = (blur: max(1, settings.blur * 4), saturation: settings.saturation)
        if applied.map({ $0.blur != wanted.blur || $0.saturation != wanted.saturation }) ?? true {
            applied = wanted
            backdrop.filters = [Self.filter("gaussianBlur", ["inputRadius": wanted.blur]),
                                Self.filter("colorSaturate", ["inputAmount": wanted.saturation])].compactMap { $0 }
        }
    }

    /// CABackdropLayer (private, in QuartzCore): the window server's picture of what is behind
    /// the window; a plain layer if this macOS has none.
    private static func makeBackdrop() -> CALayer {
        guard let type = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return CALayer() }
        let layer = type.init()
        set(layer, "windowServerAware", true)
        set(layer, "scale", 0.25) // drawn at a quarter: it is blurred anyway
        return layer
    }

    /// A private CAFilter ("gaussianBlur", "colorSaturate") with its inputs; nil without one.
    private static func filter(_ type: String, _ inputs: [String: Any]) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") else { return nil }
        let make = NSSelectorFromString("filterWithType:")
        let object = filterClass as AnyObject
        guard object.responds(to: make), let filter = object.perform(make, with: type)?.takeUnretainedValue() as? NSObject else { return nil }
        for (key, value) in inputs { filter.setValue(value, forKey: key) }
        filter.setValue(type, forKey: "name")
        return filter
    }

    /// A private property, only where the layer has it (a missing key would raise).
    private static func set(_ object: NSObject, _ key: String, _ value: Any) {
        let setter = NSSelectorFromString("set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
        if object.responds(to: setter) { object.setValue(value, forKey: key) }
    }
}

// MARK: system glass views

/// Liquid Glass: NSGlassEffectView on macOS 26, a blurred NSVisualEffectView before.
/// skyland: Apple's classes are looked up at run time (properties through KVC), so this
/// builds with any SDK, the macOS 15 one of CI included.
enum Glass {
    static let effectView = NSClassFromString("NSGlassEffectView") as? NSView.Type
    static let containerView = NSClassFromString("NSGlassEffectContainerView") as? NSView.Type

    static func makeView() -> NSView {
        if let effectView { return effectView.init(frame: .zero) }
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    /// The parent of a window's item glass views: on macOS 26 an NSGlassEffectContainerView,
    /// which renders them together (fewer passes) and merges the ones closer than its
    /// spacing, as Apple asks for groups of glass; a plain view before. (container, holder):
    /// the glass views go in the holder, the container in the window.
    static func makeContainer() -> (container: NSView, holder: NSView) {
        let holder = FlippedHolder()
        holder.autoresizingMask = [.width, .height]
        if let containerView {
            let container = containerView.init(frame: .zero)
            holder.frame = container.bounds
            container.setValue(holder, forKey: "contentView")
            return (container, holder)
        }
        return (holder, holder)
    }

    /// The merging distance of the container a holder is in.
    static func setSpacing(_ holder: NSView, _ spacing: Double) {
        guard let containerView, let container = holder.superview, container.isKind(of: containerView),
              (container.value(forKey: "spacing") as? Double) != spacing else { return }
        container.setValue(spacing, forKey: "spacing")
    }

    /// `style`: regular | clear; `tint`: the background's color.
    static func update(_ view: NSView, style: String, tint: GlassColor, cornerRadius: Double) {
        if let effectView, view.isKind(of: effectView) {
            view.setValue(cornerRadius, forKey: "cornerRadius")
            view.setValue(tint.alpha > 0 ? tint.nsColor : nil, forKey: "tintColor")
            view.setValue(style == "clear" ? 1 : 0, forKey: "style") // NSGlassEffectView.Style: regular 0, clear 1
            return
        }
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous // Apple's shapes: no circular corners
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = tint.nsColor.cgColor
    }
}

/// Glass views are placed in flipped coordinates.
private final class FlippedHolder: NSView {
    override var isFlipped: Bool { true }
}

/// A color for the glass (sRGB, 0...1); alpha 0: the glass's own light.
public struct GlassColor: Equatable {
    public var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
    public static let clear = GlassColor()

    public init() {}

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        (red, green, blue, alpha) = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}
