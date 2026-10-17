import AppKit

// skyland `[decoration] ui-style = 'glass'`: the background of a skyland panel (overview,
// switcher, HUDs, settings, wallpaper picker, media widget) as one Liquid Glass shape
// instead of the blurred "metal" look. The engine is the best this Mac has (GlassEngine:
// Apple's glass on macOS 26, the refraction shader with Screen Recording, else Core
// Animation's backdrop). The metal engine captures what is behind only while the panel
// is on screen.

/// `ui-style` for the apps skyland starts (wallpaper picker, media widget): skyland
/// writes it to this file when its config loads.
public let uiStyleFile = NSHomeDirectory() + "/.cache/skyland/ui-style"

public func uiStyleIsGlass() -> Bool {
    (try? String(contentsOfFile: uiStyleFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "glass"
}

/// A rounded glass shape under a panel's content, anywhere in its window; the shape is
/// `shapeFrame`, the whole view by default. Moved without a resize (an animation), it
/// needs `refreshShape()` once still.
public final class GlassBackground: NSView {
    public var radius: CGFloat { didSet { refresh() } }
    /// in this view's coordinates; nil: its bounds
    public var shapeFrame: NSRect? { didSet { refresh() } }
    /// over the glass's own light; alpha 0: none
    public var tint: NSColor? { didSet { refresh() } }
    /// how much what is behind is blurred (points; skylandbar's glass_blur): more behind text
    public var blur = 2.0 { didSet { refresh() } }
    private var renderer: GlassRenderer
    private var moved: NSObjectProtocol?

    public init(radius: CGFloat, tint: NSColor? = nil) {
        self.radius = radius
        self.tint = tint
        renderer = GlassEngine.make(GlassEngine.resolve("auto"))
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        add(renderer.view)
    }

    required init?(coder: NSCoder) { nil }

    deinit { moved.map(NotificationCenter.default.removeObserver) }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil } // the content takes the mouse

    override public func layout() {
        super.layout()
        renderer.view.frame = bounds
        refresh()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moved.map(NotificationCenter.default.removeObserver)
        moved = window.map { window in
            // metal: the capture follows the window
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        }
        refresh()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func add(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func refresh() {
        guard let window else { return }
        if renderer.failed { // metal: the capture stopped (permission taken back): Core Animation's
            renderer.view.removeFromSuperview()
            renderer = GlassEngine.make("backdrop")
            add(renderer.view)
        }
        // top-left origin, as the renderers count
        let frame = shapeFrame ?? bounds
        let rect = NSRect(x: frame.minX, y: bounds.height - frame.maxY, width: frame.width, height: frame.height)
        let shapes = rect.width > 0 && rect.height > 0
            ? [GlassShape(rect: rect, radius: Double(radius), tint: tint.map(GlassColor.init) ?? .clear)]
            : []
        var settings = GlassSettings()
        settings.blur = blur
        renderer.update(shapes, settings: settings, window: window)
    }

    public func refreshShape() { refresh() }

    /// Stops the metal capture: the panel is hidden but kept.
    public func pause() {
        guard let window else { return }
        renderer.update([], settings: GlassSettings(), window: window)
    }
}
