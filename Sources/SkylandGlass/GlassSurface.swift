import AppKit

// skyland: glass made of several shapes, as skylandbar draws it: panels (regular glass,
// lightly tinted), a selection lens that flows from item to item on springs and leaves a
// drop behind (LensMotion), and a lighter drop under the mouse. Put it under the content,
// anywhere in a window; rects are in its own coordinates, top-left origin.

public final class GlassSurface: NSView {
    public struct Shape: Equatable {
        public var rect: NSRect
        public var radius: Double
        public var tint: NSColor?

        public init(rect: NSRect, radius: Double, tint: NSColor? = nil) {
            self.rect = rect
            self.radius = radius
            self.tint = tint
        }
    }

    public var panels: [Shape] = [] { didSet { if panels != oldValue { refresh() } } }
    /// the selected item: a lens of glass flows to it (it must lie inside a panel)
    public var selection: Shape? { didSet { if selection != oldValue { refresh() } } }
    /// the item under the mouse: a lighter drop, where it is at once
    public var hover: Shape? { didSet { if hover != oldValue { refresh() } } }
    /// how much what is behind is blurred (points)
    public var blur = 2.0 { didSet { refresh() } }
    /// the lens flows like a drop (stretches, leaves a drop behind): small rows; false: it
    /// slides in one piece, for big blocks (cards, thumbnails) where a drop looks out of place
    public var fluid = true {
        didSet {
            lens.stretch = fluid ? 1 : 0
            lens.leavesDrop = fluid
        }
    }

    private var renderer: GlassRenderer
    private let lens = LensMotion()
    private var ticker: SurfaceTicker?
    private var moved: NSObjectProtocol?
    private var settle: DispatchWorkItem?

    public init() {
        renderer = GlassEngine.make(GlassEngine.resolve("auto"))
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        add(renderer.view)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        moved.map(NotificationCenter.default.removeObserver)
        ticker?.stop()
    }

    override public var isFlipped: Bool { true }
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    override public func layout() {
        super.layout()
        renderer.view.frame = bounds
        refresh()
    }

    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // made at 0 x 0, autoresizing never grows it: it fills its superview, placed anywhere after
        if frame.isEmpty, let superview { frame = superview.bounds }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moved.map(NotificationCenter.default.removeObserver)
        moved = window.map { window in
            // follows the window once it stops: a drag moved it on every mouse event, and
            // each move past the captured area started the capture again (a slow drag)
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.settle?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.refresh() }
                self.settle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }
        if window == nil { ticker?.stop(); ticker = nil }
        refresh()
    }

    /// Again where the window is now (it slid, it was placed).
    public func refreshShape() { refresh() }

    private func add(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func refresh() {
        guard let window else { return }
        if renderer.failed { // metal: the capture stopped: Core Animation's
            renderer.view.removeFromSuperview()
            renderer = GlassEngine.make("backdrop")
            add(renderer.view)
        }
        let color = { (tint: NSColor?) in tint.map(GlassColor.init) ?? .clear }
        var shapes = panels.map { GlassShape(rect: $0.rect, radius: $0.radius, tint: color($0.tint), style: "regular") }
        var moving = false
        if let selection {
            let target = Box(x: Double(selection.rect.minX), y: Double(selection.rect.minY),
                             width: Double(selection.rect.width), height: Double(selection.rect.height))
            let step = lens.step([target], now: ProcessInfo.processInfo.systemUptime)
            let r = step.rects[0]
            var shape = GlassShape(rect: NSRect(x: r.x, y: r.y, width: r.width, height: r.height), radius: selection.radius,
                                   tint: color(selection.tint), style: "lens")
            shape.lift = step.lifts[0]
            shape.tail = step.tails[0].map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            shapes.append(shape)
            moving = step.moving
        } else {
            _ = lens.step([], now: ProcessInfo.processInfo.systemUptime) // a new selection grows out of 70 %
        }
        if let hover, hover.rect != selection?.rect {
            shapes.append(GlassShape(rect: hover.rect, radius: hover.radius, tint: color(hover.tint), style: "hover"))
        }
        var settings = GlassSettings()
        settings.blur = blur * GlassTuning.blur / 2
        renderer.update(shapes, settings: settings, window: window)
        if moving, ticker == nil {
            ticker = SurfaceTicker(view: self) { [weak self] in self?.refresh() }
        } else if !moving, let ticker {
            ticker.stop()
            self.ticker = nil
        }
    }
}

/// Calls `tick` at each refresh of the view's display (60 or 120 Hz) while a lens moves.
private final class SurfaceTicker: NSObject {
    private let tick: () -> Void
    private var link: AnyObject?
    private var timer: Timer?

    init(view: NSView, tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if #available(macOS 14, *) {
            let link = view.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    @objc private func step() { tick() }

    func stop() {
        if #available(macOS 14, *) { (link as? CADisplayLink)?.invalidate() }
        timer?.invalidate()
    }
}
