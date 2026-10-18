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

/// Apple's glass: an NSGlassEffectView per shape, in NSGlassEffectContainerViews: one for the
/// panels (closer than spacing they melt), one over it for lenses and hover drops, glass of
/// their own; a lens's drop left behind melts into it there, as a liquid would. skylandbar's
/// look on it all: its own values in Apple's glass filter (GlassLook), a double rim (GlassRim).
final class SystemGlass: GlassRenderer {
    let view: NSView = FlippedHolder()
    private let bodies: (container: NSView, holder: NSView)
    private let drops: (container: NSView, holder: NSView)
    private var bodyViews: [NSView] = []
    private var dropViews: [NSView] = []
    private var rims: [GlassRim] = []
    let failed = false

    init() {
        bodies = Glass.makeContainer()
        drops = Glass.makeContainer()
        for part in [bodies.container, drops.container] {
            part.frame = view.bounds
            part.autoresizingMask = [.width, .height]
            view.addSubview(part)
        }
        view.wantsLayer = true
    }

    func update(_ shapes: [GlassShape], settings: GlassSettings, window: NSWindow) {
        let isDrop = { (style: String) in style == "lens" || style == "hover" }
        var bodyShapes: [GlassShape] = [], dropShapes: [GlassShape] = []
        for shape in shapes {
            guard isDrop(shape.style) else { bodyShapes.append(shape); continue }
            dropShapes.append(shape)
            if let tail = shape.tail, tail.width > 0 { // its drop left behind, the same glass
                var drop = shape
                drop.rect = tail
                drop.radius = min(shape.radius, Double(min(tail.width, tail.height)) / 2)
                drop.tail = nil
                dropShapes.append(drop)
            }
        }
        Glass.setSpacing(bodies.holder, settings.spacing)
        Glass.setSpacing(drops.holder, 14) // a lens and its drop melt while near
        place(bodyShapes, in: bodies.holder, views: &bodyViews)
        // Apple's tint is dense: a drop at half its tint keeps what is behind showing through it
        place(dropShapes.map { var d = $0; d.tint.alpha *= 0.5; return d }, in: drops.holder, views: &dropViews)
        GlassLook.apply(bodies.container, settings: settings,
                        height: bodyShapes.map { Double(min($0.rect.width, $0.rect.height)) }.min() ?? 36)
        if let lens = dropShapes.first {
            GlassLook.apply(drops.container, settings: settings, height: Double(min(lens.rect.width, lens.rect.height)),
                            lift: dropShapes.map(\.lift).max() ?? 0)
        }
        // the double rims, over all the glass
        let rimmed = bodyShapes.map { ($0, 1.0) } + dropShapes.map { ($0, 1.5 + 0.5 * $0.lift) }
        while rims.count > rimmed.count { rims.removeLast().removeFromSuperlayer() }
        while rims.count < rimmed.count {
            let rim = GlassRim()
            rim.zPosition = 10 // over the glass views' own layers
            view.layer?.addSublayer(rim)
            rims.append(rim)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (rim, (shape, strength)) in zip(rims, rimmed) { rim.set(shape.rect, radius: shape.radius, strength: strength) }
        CATransaction.commit()
    }

    private func place(_ shapes: [GlassShape], in holder: NSView, views: inout [NSView]) {
        while views.count > shapes.count { views.removeLast().removeFromSuperview() }
        while views.count < shapes.count {
            let glass = Glass.makeView()
            holder.addSubview(glass)
            views.append(glass)
        }
        for (glass, shape) in zip(views, shapes) {
            glass.frame = shape.rect
            Glass.update(glass, style: shape.style, tint: shape.tint, cornerRadius: shape.radius)
        }
    }
}

// MARK: skylandbar's look on Apple's glass

/// Apple's glass draws what is behind through a private filter (`glassBackground`) on a
/// CABackdropLayer (in each NSGlassEffectView, or in the container rendering them together),
/// set for a frosted look: a lot of blur, a narrow refraction. skyland sets its own values
/// there: a sharp middle, what is behind bent along the edge, colors split a little, a soft
/// shadow and ring shade. Still the window server's glass: live, no capture. Looked up by
/// name; nothing changes if a macOS has it otherwise.
enum GlassLook {
    /// `height`: the smallest shape's, which the bent band keeps within. `lift`: nil for a
    /// panel; a lens's (0 at rest, 1 moving fast): thicker, lighter glass, bending more.
    /// Again on the next turn of the run loop, for the layers made after a layout.
    static func apply(_ view: NSView, settings: GlassSettings, height: Double, lift: Double? = nil) {
        set(view, settings, height, lift)
        DispatchQueue.main.async { set(view, settings, height, lift) }
    }

    private static func set(_ view: NSView, _ settings: GlassSettings, _ height: Double, _ lift: Double?) {
        guard let root = view.layer else { return }
        var values: [String: Double]
        if let lift { // a drop: a third of its height bent, its middle magnified, a light of its own
            let band = max(2, height * (0.34 + 0.1 * lift))
            values = [
                "inputInnerRefractionAmount": -(1.8 + 2.4 * lift) * band, "inputInnerRefractionHeight": band,
                "inputAberrationAmount": (0.3 + 0.3 * lift) * band, "inputAberrationHeight": band,
                "inputBlurRadius": settings.blur * 0.3,
                "inputFaceColorMatrixWhite": 1.32 + 0.1 * lift, "inputFaceColorMatrixBlack": 0.1,
                "inputKeyFillHighlightAmount": 0.8 + 0.3 * lift,
                "inputRingShadowOpacity": 0.4, "inputRingShadowOffset": 2, "inputRingShadowStrokeWidth": 1.2,
                "inputRingShadowBlurRadius": 1.5,
                "inputShadowOpacity": 0.35 + 0.15 * lift, "inputShadowAmount": 4 + 3 * lift, "inputShadowHeight": 4 + 3 * lift,
                "inputShadowBlurRadius": 5 + 3 * lift,
            ]
        } else {
            let band = min(2.3 * settings.refraction, max(2, height / 4))
            values = [
                "inputInnerRefractionAmount": -2.5 * band, "inputInnerRefractionHeight": band,
                "inputAberrationAmount": 0.2 * band, "inputAberrationHeight": band,
                "inputBlurRadius": settings.blur / 2,
                "inputKeyFillHighlightAmount": 0.6,
                "inputRingShadowOpacity": 0.3, "inputRingShadowOffset": 2, "inputRingShadowStrokeWidth": 1.2,
                "inputRingShadowBlurRadius": 1.5,
                "inputShadowOpacity": 0.3, "inputShadowAmount": 4, "inputShadowHeight": 4, "inputShadowBlurRadius": 5,
            ]
        }
        // the blur shows more as it grows (at 2 points, barely: what is behind stays sharp)
        let blurOpacity = min(1, max(0.1, settings.blur / 8))
        values.merge([
            "inputBlurOpacity0": blurOpacity, "inputBlurOpacity1": blurOpacity, "inputBlurOpacity2": blurOpacity, "inputBlurOpacity3": blurOpacity,
            "inputBlurFillNormalOpacity": 0, "inputBlurFillDarkenOpacity": 0, "inputBlurFillLightenOpacity": 0, "inputBleedAmount": 0,
            "inputFaceColorMatrixSaturation": 1 + (settings.saturation - 1) * 0.6,
            // Apple's luminance cap (0.5) kept: without it a bright wallpaper burned the text out
        ]) { mine, _ in mine }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for backdrop in backdrops(root) {
            if (backdrop.value(forKey: "scale") as? Double) != 1 { backdrop.setValue(1, forKey: "scale") } // Apple's: half resolution
            for (key, value) in values where (backdrop.value(forKeyPath: "filters.glassBackground.\(key)") as? Double) != value {
                backdrop.setValue(value, forKeyPath: "filters.glassBackground.\(key)")
            }
        }
        CATransaction.commit()
    }

    private static func backdrops(_ layer: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        if NSStringFromClass(type(of: layer)) == "CABackdropLayer",
           (layer.filters as? [NSObject])?.contains(where: { ($0.value(forKey: "name") as? String) == "glassBackground" }) == true
        {
            found.append(layer)
        }
        for sublayer in layer.sublayers ?? [] { found += backdrops(sublayer) }
        return found
    }
}

/// The double rim over a glass shape: an outer line lit from the top left, fading toward the
/// bottom, and an inner one, 1.5 pt in, lit from the bottom right (the light coming back
/// through the glass's thickness): a bevel, the glass standing off what is behind.
final class GlassRim: CALayer {
    private let outer = CAGradientLayer(), outerMask = CAShapeLayer()
    private let inner = CAGradientLayer(), innerMask = CAShapeLayer()

    override init() {
        super.init()
        for (gradient, mask) in [(outer, outerMask), (inner, innerMask)] {
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = 1
            gradient.mask = mask
            addSublayer(gradient)
        }
        outer.startPoint = CGPoint(x: 0, y: 0) // flipped: the top left
        outer.endPoint = CGPoint(x: 1, y: 1)
        inner.startPoint = CGPoint(x: 1, y: 1)
        inner.endPoint = CGPoint(x: 0, y: 0)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    /// `strength`: 1 for a panel, more for a lens.
    func set(_ rect: NSRect, radius: Double, strength: Double) {
        frame = rect
        let bounds = CGRect(origin: .zero, size: rect.size)
        let path = { (inset: CGFloat) -> CGPath in
            let r = bounds.insetBy(dx: inset, dy: inset), corner = max(0, min(CGFloat(radius) - inset, r.height / 2, r.width / 2))
            return CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
        }
        for layer in [outer, outerMask, inner, innerMask] as [CALayer] { layer.frame = bounds }
        outerMask.path = path(0.5)
        innerMask.path = path(2)
        let white = { (alpha: Double) in NSColor(white: 1, alpha: min(1, alpha * strength)).cgColor }
        outer.colors = [white(0.55), white(0.12), white(0.22)]
        outer.locations = [0, 0.55, 1]
        inner.colors = [white(0.3), white(0.04), white(0)]
        inner.locations = [0, 0.5, 1]
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // the content takes the mouse
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
