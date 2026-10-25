import AppKit
import Common
import ScreenCaptureKit
import SkylandGlass

// skyland workspace overview, styled after the Hyprland Hyprspace plugin
// (KDE / macOS-like): a translucent glass strip slides down from the top of
// the focused screen with that screen's workspaces, while the windows of the
// screen zoom out below it. Each workspace card shows live window thumbnails
// (ScreenCaptureKit, needs Screen Recording permission; app icons otherwise).
// Drag a window onto another card to move it there (the last "+" card: the first
// empty workspace of the screen), alt + drag a card onto another to swap the two
// workspaces (windows and layout), click a window to focus it, middle click to close
// it, click a card to go to that workspace, click outside to close.
// Shown while the binding mode "overview" is active ([mode.overview.binding]): its keys
// are hotkeys; the panel is key and takes the other ones. A letter (or `overview
// search`, `/`) starts a search: the mode becomes "overview-search", without hotkeys,
// windows not matching the app or title are dimmed, enter focuses the selection, esc
// goes back. `overview next|prev|confirm|close` move, focus or close the selection.

let overviewModeId = "overview"
let overviewSearchModeId = "overview-search"
private let newWorkspaceCard = "+"

@MainActor private var panel: NSPanel? = nil
@MainActor private var strip: OverviewStrip? = nil
/// Windows zoomed out under the strip, with their real rect, to zoom back in.
@MainActor private var zoomedWindows: [(windowId: UInt32, real: Rect, zoomed: Rect)] = []
/// Top of the zoomed out windows (below the strip), to zoom them again after a swap.
@MainActor private var zoomTop: CGFloat = 0
/// Last thumbnail of each window: hidden workspaces keep the last capture if a new one fails.
@MainActor private var thumbnails: [UInt32: NSImage] = [:]
/// Search typed in the overview (app or title), the window picked with the keyboard.
@MainActor private var query = ""
@MainActor private var selectedWindow: UInt32? = nil
@MainActor private var titles: [UInt32: String] = [:]

/// Called by activateMode_nonCancellable.
@MainActor
func overviewModeChanged(_ mode: String?) {
    guard mode == overviewModeId || mode == overviewSearchModeId else { return hideOverview() }
    if !isOverviewOpen { showOverview() }
    if mode == overviewModeId, !query.isEmpty { setQuery("") } // search left (esc)
}

struct OverviewCommand: Command {
    let args: OverviewCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        guard isOverviewOpen else { return .fail(io.err("The overview is not open")) }
        switch args.action.val {
            case .next: stepSelection(1)
            case .prev: stepSelection(-1)
            case .confirm: Task { @MainActor in await confirmOverview() }
            case .close: if let selectedWindow { closeFromOverview(selectedWindow) }
            case .search: startSearch()
        }
        return .succ
    }
}

// MARK: search and keyboard selection

@MainActor
private func matches(_ windowId: UInt32) -> Bool {
    guard !query.isEmpty else { return true }
    let app = MacWindow.allWindowsMap[windowId]?.app.name ?? ""
    return app.localizedCaseInsensitiveContains(query) || (titles[windowId] ?? "").localizedCaseInsensitiveContains(query)
}

/// The windows of the cards, card after card, top to bottom then left to right, matching the search.
@MainActor
private func overviewWindows() -> [UInt32] {
    (strip?.workspaces ?? []).flatMap { workspace in
        workspace.allLeafWindowsRecursive.sorted { lhs, rhs in
            let l = lhs.lastAppliedLayoutPhysicalRect, r = rhs.lastAppliedLayoutPhysicalRect
            return (l?.topLeftY ?? .infinity, l?.topLeftX ?? 0) < (r?.topLeftY ?? .infinity, r?.topLeftX ?? 0)
        }.map(\.windowId)
    }.filter(matches)
}

@MainActor
private func stepSelection(_ delta: Int) {
    let windows = overviewWindows()
    guard !windows.isEmpty else { return }
    let index = selectedWindow.flatMap(windows.firstIndex(of:)).map { ($0 + delta + windows.count) % windows.count } ?? 0
    selectedWindow = windows[index]
    strip?.cardsNeedDisplay()
}

@MainActor
private func startSearch() {
    guard activeMode != overviewSearchModeId else { return }
    Task { @MainActor in await activateMode_nonCancellable(overviewSearchModeId) }
    for workspace in strip?.workspaces ?? [] { // titles are AX calls: asked once per search
        for window in workspace.allLeafWindowsRecursive where titles[window.windowId] == nil {
            let id = window.windowId
            Task { @MainActor in
                titles[id] = (try? await window.getTitle(.nonCancellable)) ?? ""
                if !query.isEmpty { setQuery(query) }
            }
        }
    }
}

@MainActor
private func setQuery(_ text: String) {
    query = text
    let windows = overviewWindows()
    if selectedWindow.map(windows.contains) != true { selectedWindow = windows.first }
    // the zoomed out windows that do not match fade back
    for (windowId, _, _) in zoomedWindows {
        let normal = Double(windowOpacity(windowId, focused: windowId == focus.windowOrNil?.windowId)) / 100
        skylandSa("alpha \(windowId) \(matches(windowId) ? normal : 0.25)")
    }
    strip?.cardsNeedDisplay()
}

@MainActor
private func confirmOverview() async {
    if let selectedWindow, query.isEmpty || matches(selectedWindow) {
        await runSkylandCommand("focus --window-id \(selectedWindow)")
    }
    await activateMode_nonCancellable(mainModeId)
}

/// Closed with its animation; the overview stays open and the cards follow.
@MainActor
private func closeFromOverview(_ windowId: UInt32) {
    let windows = overviewWindows()
    if selectedWindow == windowId, let index = windows.firstIndex(of: windowId) {
        selectedWindow = windows.count > 1 ? windows[(index + 1) % windows.count] : nil
    }
    if zoomedWindows.contains(where: { $0.windowId == windowId }) {
        skylandSa("untransform \(windowId)")
        zoomedWindows.removeAll { $0.windowId == windowId }
    }
    Task { @MainActor in await runSkylandCommand("close --window-id \(windowId)") }
}

/// alt + drag of a card: the two workspaces swap their windows, tiling tree (layout,
/// sizes) and floating windows as they are. The focused workspace stays focused and shows
/// the other one's windows, zoomed out again under the strip.
@MainActor
private func swapWorkspaces(_ lhs: String, _ rhs: String) async {
    guard lhs != rhs, let token: RunSessionGuard = .isServerEnabled else { return }
    let a = Workspace.get(byName: lhs), b = Workspace.get(byName: rhs)
    for (windowId, _, _) in zoomedWindows { skylandSa("untransform \(windowId)") }
    zoomedWindows = []
    let shown = focus.workspace
    try? await runLightSession(.hotkeyBinding, token) {
        let aRoot = a.rootTilingContainer, bRoot = b.rootTilingContainer
        let aFloating = a.floatingWindows, bFloating = b.floatingWindows
        aRoot.unbindFromParent()
        bRoot.unbindFromParent()
        aRoot.bind(to: b, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        bRoot.bind(to: a, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        for window in aFloating { window.bindAsFloatingWindow(to: b) }
        for window in bFloating { window.bindAsFloatingWindow(to: a) }
        _ = shown.focusWorkspace()
    }
    zoomOut(shown, below: zoomTop, durationMs: 1)
    strip?.layoutCards()
}

/// The workspace a card name stands for: the "+" card is the first empty workspace of the screen.
@MainActor
private func cardWorkspace(_ name: String, monitorRect: Rect) -> String? {
    guard name == newWorkspaceCard else { return name }
    return (1 ... 99).map(String.init).first { name in
        let workspace = Workspace.get(byName: name)
        return workspace.isEffectivelyEmpty && !workspace.isVisible && workspace.workspaceMonitor.rect.topLeftCorner == monitorRect.topLeftCorner
    }
}

/// The windows are zoomed out under the strip: the focused border has nothing to frame.
@MainActor var isOverviewOpen: Bool { panel?.isVisible == true }

/// Called after every refresh: keep the cards in sync while it is open.
@MainActor
func refreshOverview() {
    guard panel?.isVisible == true else { return }
    strip?.layoutCards()
}

@MainActor
private func showOverview() {
    let monitor = focus.workspace.workspaceMonitor
    let screen = nsScreen(of: monitor)
    let panel = panel ?? makePanel()
    query = ""
    selectedWindow = focus.windowOrNil?.windowId
    panel.setFrame(screen.frame, display: false)
    let root = panel.contentView!
    root.frame = NSRect(origin: .zero, size: screen.frame.size)
    strip?.removeFromSuperview()
    let newStrip = OverviewStrip(monitorRect: monitor.rect, monitorVisible: monitor.visibleRect)
    strip = newStrip
    root.addSubview(newStrip)
    newStrip.layoutCards()
    let ids = Set(newStrip.workspaces.flatMap { $0.allLeafWindowsRecursive.map(\.windowId) })
    captureWindowThumbnails(ids) { windowId, image in
        guard isOverviewOpen else { return } // closed meanwhile: thumbnails stay freed
        thumbnails[windowId] = image
        strip?.cardsNeedDisplay()
    }

    let anim = config.animations
    let duration = anim.enabled ? min(0.45, Double(anim.windowsMs) / 1000) : 0
    // Slide down from above the screen with the windows animation curve
    let final = newStrip.frame
    newStrip.setFrameOrigin(NSPoint(x: final.minX, y: root.bounds.height))
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil) // key: typed letters start a search
    panel.makeFirstResponder(root)
    hideAnimatedBorder()
    NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.timingFunction = CAMediaTimingFunction(controlPoints: Float(anim.windowsBezier.x1), Float(anim.windowsBezier.y1),
                                                       Float(anim.windowsBezier.x2), Float(anim.windowsBezier.y2))
        newStrip.animator().setFrameOrigin(final.origin)
        panel.animator().alphaValue = 1
    } completionHandler: {
        MainActor.assumeIsolated { strip?.glassMoved() } // glass: its capture where the strip landed
    }
    // Zoom the screen's windows out below the strip
    zoomTop = monitor.rect.topLeftY + (root.bounds.height - final.minY) + 12
    zoomOut(focus.workspace, below: zoomTop, durationMs: Int(duration * 1000))
}

@MainActor
private func hideOverview() {
    guard panel?.isVisible == true else { return }
    if !query.isEmpty { setQuery("") } // dimmed windows back to their opacity
    titles = [:]
    selectedWindow = nil
    panel?.orderOut(nil)
    // thumbnails, cards and panel are made again at every open: kept, the thumbnails
    // piled up all day (closed windows included) and the hidden full-screen panel kept
    // its buffers (~35 MB)
    thumbnails = [:]
    strip?.removeFromSuperview()
    strip = nil
    panel?.close()
    panel = nil
    // the border comes back around the focused window once it is at its real frame
    pauseAnimatedBorder(ms: zoomIn())
    focus.windowOrNil?.nativeFocus() // the key panel had the keyboard
}

// MARK: zoom out / in (payload transforms, like the window animations)

@MainActor
private func zoomOut(_ workspace: Workspace, below top: CGFloat, durationMs: Int) {
    zoomedWindows = []
    guard config.animations.enabled, payloadCapabilities.contains("close") else { return } // needs `animate ... hold`
    let area = workspace.workspaceMonitor.visibleRectPaddedByOuterGaps
    let available = area.topLeftY + area.height - top
    guard available > 100 else { return }
    let scale = min(0.9, available / area.height)
    let ms = max(1, durationMs), bezier = config.animations.windowsBezier
    for window in workspace.allLeafWindowsRecursive {
        guard let real = window.lastAppliedLayoutPhysicalRect else { continue }
        let zoomed = Rect(
            topLeftX: area.topLeftX + area.width * (1 - scale) / 2 + (real.topLeftX - area.topLeftX) * scale,
            topLeftY: top + (real.topLeftY - area.topLeftY) * scale,
            width: real.width * scale, height: real.height * scale,
        )
        zoomedWindows.append((window.windowId, real, zoomed))
        skylandSa("animate \(window.windowId) \(real.args) \(ms) \(bezier.args) \(zoomed.args) 1")
    }
}

@MainActor @discardableResult
private func zoomIn() -> Int {
    let ms = max(1, config.animations.enabled ? min(450, config.animations.windowsMs) : 1)
    for (windowId, _, zoomed) in zoomedWindows {
        // from the zoomed rect back to the real frame, the transform is reset at the end
        skylandSa("animate \(windowId) \(zoomed.args) \(ms) \(config.animations.windowsBezier.args)")
    }
    zoomedWindows = []
    return ms
}

// MARK: thumbnails (ScreenCaptureKit)

/// One capture per window, 640 px wide at most, handed over as it comes (overview, switcher).
@MainActor
func captureWindowThumbnails(_ ids: Set<UInt32>, _ onImage: @escaping @MainActor (UInt32, NSImage) -> Void) {
    guard #available(macOS 14, *) else { return }
    // a window of a hidden workspace comes back empty: its last picture first (#78)
    for id in ids { if let cached = thumbnailCache[id] { onImage(id, cached) } }
    Task { @MainActor in
        // Asks for Screen Recording permission the first time; without it the cards keep app icons
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        for scWindow in content.windows where ids.contains(scWindow.windowID) {
            let filter = SCContentFilter(desktopIndependentWindow: scWindow) // its content, wherever it is, whatever its alpha
            let configuration = SCStreamConfiguration()
            let scale = min(1, 640 / max(1, scWindow.frame.width))
            configuration.width = Int(scWindow.frame.width * scale)
            configuration.height = Int(scWindow.frame.height * scale)
            configuration.showsCursor = false
            configuration.captureResolution = .nominal // a 640 px thumbnail needs no Retina capture
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration),
                  !isTransparent(image) else { continue } // windows of hidden workspaces come back empty: cached, else app icon
            let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            thumbnailCache[scWindow.windowID] = picture
            onImage(scWindow.windowID, picture)
        }
    }
}

/// The last picture of each window, taken while it was shown: the overview and the switcher
/// show it for the windows of hidden workspaces (captured empty there). Pruned to the
/// windows that still exist.
@MainActor var thumbnailCache: [UInt32: NSImage] = [:]

/// `yes` / `no` in ~/.cache/skyland/screen-recording: whether Skyland may capture windows
/// (live thumbnails). A shell cannot ask for another app; skyland doctor reads this.
@MainActor
func writeScreenRecordingState() {
    let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/screen-recording")
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? (CGPreflightScreenCaptureAccess() ? "yes" : "no").write(to: file, atomically: true, encoding: .utf8)
}

/// The windows of the workspace just shown, once settled: their picture for later.
@MainActor
func refreshThumbnailCache(_ workspace: Workspace) {
    guard CGPreflightScreenCaptureAccess() else { return } // never asks: the overview does
    thumbnailCache = thumbnailCache.filter { MacWindow.allWindowsMap[$0.key] != nil }
    let ids = Set(workspace.allLeafWindowsRecursive.map(\.windowId))
    guard !ids.isEmpty else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { // after the slide-in
        guard focus.workspace === workspace else { return }
        captureWindowThumbnails(ids) { _, _ in }
    }
}

/// Every pixel transparent, checked on an 8x8 copy.
private func isTransparent(_ image: CGImage) -> Bool {
    var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        return true
    }
    return drawn && stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] < 8 }
}

@MainActor
func nsScreen(of monitor: MonitorInfo) -> NSScreen {
    let rect = monitor.rect
    let match = NSScreen.screens.first { (screen: NSScreen) -> Bool in
        abs(screen.frame.minX - rect.topLeftX) < 1 && abs(screen.frame.width - rect.width) < 1
    }
    return match ?? NSScreen.main ?? NSScreen.screens[0]
}

// MARK: views

/// Becomes key without activating skyland: the keys the overview mode does not bind come here.
private final class OverviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private func makePanel() -> NSPanel {
    let p = OverviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .popUpMenu
    p.isReleasedWhenClosed = false // closed at every hide, ARC owns it
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.contentView = OverviewBackdrop()
    panel = p
    return p
}

/// Light dim over the whole screen. The zoomed out windows under it can be
/// clicked (focus) or dragged onto a card (move), like in Hyprspace; a click
/// anywhere else closes the overview.
private final class OverviewBackdrop: NSView {
    private var pressed: (windowId: UInt32, start: NSPoint, size: NSSize)? = nil
    private var dragPoint: NSPoint? = nil

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()
        MainActor.assumeIsolated {
            guard let pressed, let dragPoint, let image = thumbnails[pressed.windowId] else { return }
            let rect = NSRect(x: dragPoint.x - pressed.size.width / 2, y: dragPoint.y - pressed.size.height / 2, width: pressed.size.width, height: pressed.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.8)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated { overviewKey(event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            if event.buttonNumber == 2, let hit = zoomedWindow(at: point) { closeFromOverview(hit.windowId) }
        }
    }

    /// Zoomed out window under a point of this view.
    @MainActor
    private func zoomedWindow(at point: NSPoint) -> (windowId: UInt32, zoomed: Rect)? {
        guard let screen = window?.screen, let main = NSScreen.screens.first else { return nil }
        // view coordinates -> global top-left coordinates used by window rects
        let global = CGPoint(x: screen.frame.minX + point.x, y: main.frame.maxY - (screen.frame.minY + point.y))
        return zoomedWindows.last(where: { $0.zoomed.contains(global) }).map { ($0.windowId, $0.zoomed) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            guard let hit = zoomedWindow(at: point) else {
                pressed = nil
                Task { @MainActor in await activateMode_nonCancellable(mainModeId) } // empty area: close
                return
            }
            // dragged at the size of a card thumbnail
            let scale = (strip?.cardScale ?? 0.15)
            pressed = (hit.windowId, point, NSSize(width: hit.zoomed.width * scale, height: hit.zoomed.height * scale))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let point = convert(event.locationInWindow, from: nil)
        if dragPoint == nil && hypot(point.x - pressed.start.x, point.y - pressed.start.y) < 5 { return }
        dragPoint = point
        needsDisplay = true
        MainActor.assumeIsolated { strip?.highlightDrop(at: convert(point, to: strip)) }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pressed = self.pressed, dragged = dragPoint != nil
        self.pressed = nil
        dragPoint = nil
        needsDisplay = true
        guard let pressed else { return }
        MainActor.assumeIsolated {
            strip?.highlightDrop(at: nil)
            let target = strip.flatMap { strip in strip.workspace(at: convert(point, to: strip)).flatMap { cardWorkspace($0, monitorRect: strip.monitorRect) } }
            Task { @MainActor in
                if dragged {
                    guard let target, target != MacWindow.allWindowsMap[pressed.windowId]?.nodeWorkspace?.name else { return }
                    skylandSa("untransform \(pressed.windowId)")
                    zoomedWindows.removeAll { $0.windowId == pressed.windowId }
                    await runSkylandCommand("move-node-to-workspace --window-id \(pressed.windowId) \(target)")
                } else {
                    await runSkylandCommand("focus --window-id \(pressed.windowId)")
                    await activateMode_nonCancellable(mainModeId)
                }
            }
        }
    }
}

/// Keys the overview mode does not bind (all of them while searching).
@MainActor
private func overviewKey(_ event: NSEvent) {
    let searching = activeMode == overviewSearchModeId
    switch event.keyCode {
        case 53: // esc: out of the search (the overview mode binds it otherwise)
            if searching { Task { @MainActor in await activateMode_nonCancellable(overviewModeId) } }
            return
        case 36, 76: Task { @MainActor in await confirmOverview() }; return // return, enter
        case 51: if !query.isEmpty { setQuery(String(query.dropLast())) }; return // delete
        case 125, 48: stepSelection(event.modifierFlags.contains(.shift) ? -1 : 1); return // down, tab
        case 126: stepSelection(-1); return // up
        default: break
    }
    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let chars = event.characters, !chars.isEmpty,
          chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return }
    startSearch()
    setQuery(query + chars)
}

/// The glass strip: blur + theme tint, holding one card per workspace.
private final class OverviewStrip: NSView {
    let monitorRect: Rect, monitorVisible: Rect
    private(set) var workspaces: [Workspace] = []
    private let blur: NSView = isGlassStyle ? GlassSurface() : isGlyphStyle ? NSView() : NSVisualEffectView() // glyph: the cards view draws the opaque panel
    private let cardsView = OverviewCards()
    private let radius: CGFloat = 28, padding: CGFloat = 18, spacing: CGFloat = 16, labelHeight: CGFloat = 22

    init(monitorRect: Rect, monitorVisible: Rect) {
        self.monitorRect = monitorRect
        self.monitorVisible = monitorVisible
        super.init(frame: .zero)
        if let surface = blur as? GlassSurface { // skylandbar's glass: a lens on the selected card
            surface.fluid = false // big cards: it slides in one piece
            cardsView.surface = surface
        }
        if let blur = blur as? NSVisualEffectView {
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
        }
        addSubview(blur)
        addSubview(cardsView)
    }

    required init?(coder: NSCoder) { nil }

    func cardsNeedDisplay() { cardsView.needsDisplay = true }
    func glassMoved() { (blur as? GlassSurface)?.refreshShape() }
    /// Size ratio between a window and its thumbnail in a card.
    private(set) var cardScale: CGFloat = 0.15
    func workspace(at point: NSPoint) -> String? { cardsView.workspace(at: convert(point, to: cardsView)) }
    func highlightDrop(at point: NSPoint?) { cardsView.externalDragPoint = point.map { convert($0, to: cardsView) } }

    @MainActor
    func layoutCards() {
        guard let root = superview else { return }
        workspaces = Workspace.all
            .filter { $0.workspaceMonitor.rect.topLeftCorner == monitorRect.topLeftCorner && !$0.isScratchpad }
            .sorted { lhs, rhs in
                if let l = Int(lhs.name), let r = Int(rhs.name) { return l < r }
                return lhs.name < rhs.name
            }
        let cardCount = workspaces.count + 1 // and the "+" card
        let columns = max(1, min(6, cardCount)), rows = max(1, (cardCount + columns - 1) / columns)
        let aspect = monitorRect.width / max(1, monitorRect.height)
        var cardHeight = root.bounds.height * 0.16
        var cardWidth = cardHeight * aspect
        let maxWidth = (root.bounds.width * 0.9 - 2 * padding - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        if cardWidth > maxWidth { cardWidth = maxWidth; cardHeight = cardWidth / aspect }
        let size = NSSize(width: 2 * padding + CGFloat(columns) * cardWidth + CGFloat(columns - 1) * spacing,
                          height: 2 * padding + CGFloat(rows) * (cardHeight + labelHeight) + CGFloat(rows - 1) * spacing)
        // Below the menu bar / sketchybar of this screen (Hyprspace reservedArea)
        let menuBar = monitorVisible.topLeftY - monitorRect.topLeftY
        let top = menuBar + barOverlap(barHeight: barHeight, menuBarHeight: menuBar) + 10
        frame = NSRect(x: (root.bounds.width - size.width) / 2, y: root.bounds.height - top - size.height, width: size.width, height: size.height)
        blur.frame = bounds
        (blur as? NSVisualEffectView)?.maskImage = roundedMaskImage(radius: radius)
        cardsView.frame = bounds
        cardScale = cardWidth / monitorRect.width
        cardsView.configure(workspaces: workspaces, columns: columns, cardSize: NSSize(width: cardWidth, height: cardHeight),
                            padding: padding, spacing: spacing, labelHeight: labelHeight, radius: radius)
    }
}

private final class OverviewCards: NSView {
    private var workspaces: [Workspace] = []
    private var cards: [(rect: NSRect, workspace: String)] = []
    private var windowRects: [(rect: NSRect, windowId: UInt32, workspace: String)] = []
    private var columns = 1, cardSize = NSSize.zero
    private var padding: CGFloat = 0, spacing: CGFloat = 0, labelHeight: CGFloat = 0, radius: CGFloat = 0
    // drag & drop of a window thumbnail (Hyprspace dragAlpha)
    private var pressed: (windowId: UInt32, workspace: String, offset: NSPoint, size: NSSize, start: NSPoint)? = nil
    /// alt + drag of a whole card (a workspace swap)
    private var pressedCard: (workspace: String, rect: NSRect, start: NSPoint)? = nil
    private var dragPoint: NSPoint? = nil
    /// Cursor while a zoomed out window is dragged from the backdrop (drop target highlight).
    var externalDragPoint: NSPoint? = nil { didSet { needsDisplay = true } }
    /// glass style: the shapes under the cards
    weak var surface: GlassSurface?
    private var hoveredCard: String?

    override var isFlipped: Bool { true } // same top-left origin as window rects

    func workspace(at point: NSPoint) -> String? { cards.first(where: { $0.rect.contains(point) })?.workspace }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor
    func configure(workspaces: [Workspace], columns: Int, cardSize: NSSize, padding: CGFloat, spacing: CGFloat, labelHeight: CGFloat, radius: CGFloat) {
        (self.workspaces, self.columns, self.cardSize) = (workspaces, columns, cardSize)
        (self.padding, self.spacing, self.labelHeight, self.radius) = (padding, spacing, labelHeight, radius)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated { drawStrip() }
    }

    @MainActor
    private func drawStrip() {
        let theme = skylandThemeColors()
        let fg = theme["fg"] ?? .white, accent = theme["accent"] ?? .systemBlue
        // Theme tint over the blur, then the strip border (Hyprspace panelBorderColor)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if isGlyphStyle {
            drawGlyphPanel(in: bounds, radius: radius)
        } else if !isGlassStyle { // the glass has its own tint
            (theme["bg"] ?? .black).withAlphaComponent(0.35).setFill()
            outline.fill()
        }
        if surface == nil && !isGlyphStyle { // glass: its own rim; glyph: the panel's line
            accent.withAlphaComponent(0.35).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }

        cards = []
        windowRects = []
        let focused = focus.workspace
        for (index, workspace) in workspaces.enumerated() {
            let column = index % columns, row = index / columns
            let card = NSRect(x: padding + CGFloat(column) * (cardSize.width + spacing),
                              y: padding + CGFloat(row) * (cardSize.height + labelHeight + spacing) + labelHeight,
                              width: cardSize.width, height: cardSize.height)
            cards.append((card, workspace.name))
            let active = workspace == focused
            let highlighted = active || (dragPoint ?? externalDragPoint).map(card.contains) == true // drop target while dragging
            NSAttributedString(string: workspace.name, attributes: [
                .font: isGlyphStyle ? PanelFont.dots(21) : NSFont.systemFont(ofSize: 13, weight: active ? .bold : .medium),
                .foregroundColor: active ? (isGlyphStyle ? fg : accent) : fg.withAlphaComponent(isGlyphStyle ? 0.45 : 0.65),
            ]).draw(at: NSPoint(x: card.minX + (isGlyphStyle && active ? 16 : 2), y: card.minY - labelHeight + (isGlyphStyle ? -4 : 2)))
            if isGlyphStyle, active { // the one live thing: the shown workspace's red dot
                (theme["highlight"] ?? .systemRed).setFill()
                NSBezierPath(ovalIn: NSRect(x: card.minX + 2, y: card.minY - labelHeight / 2 - 4, width: 8, height: 8)).fill()
            }

            let path = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
            // active: tinted + accent border; inactive: almost transparent (Hyprspace). Glass:
            // the lens and the hover drop instead, a faint fill for the empty ones
            (surface != nil ? fg.withAlphaComponent(0.03) : isGlyphStyle ? theme["bg_card"] ?? fg.withAlphaComponent(0.08)
                : highlighted ? accent.withAlphaComponent(0.16) : fg.withAlphaComponent(0.05)).setFill()
            path.fill()
            drawWindows(of: workspace, in: card, theme: theme)
            if surface == nil || (dragPoint ?? externalDragPoint).map(card.contains) == true {
                path.lineWidth = highlighted ? 2.5 : 1
                (highlighted ? accent : isGlyphStyle ? theme["border"] ?? fg.withAlphaComponent(0.12) : fg.withAlphaComponent(0.12)).setStroke()
                path.stroke()
            }
        }
        // "+": dropped there, a window goes to the first empty workspace of the screen
        let index = workspaces.count, column = index % columns, row = index / columns
        let plus = NSRect(x: padding + CGFloat(column) * (cardSize.width + spacing),
                          y: padding + CGFloat(row) * (cardSize.height + labelHeight + spacing) + labelHeight,
                          width: cardSize.width, height: cardSize.height)
        cards.append((plus, newWorkspaceCard))
        let dropping = (dragPoint ?? externalDragPoint).map(plus.contains) == true
        let plusPath = NSBezierPath(roundedRect: plus.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        plusPath.setLineDash([6, 5], count: 2, phase: 0)
        plusPath.lineWidth = dropping ? 2.5 : 1.2
        (dropping ? accent : fg.withAlphaComponent(0.3)).setStroke()
        plusPath.stroke()
        let plusText = NSAttributedString(string: "+", attributes: [.font: isGlyphStyle ? PanelFont.dots(34, weight: .regular) : NSFont.systemFont(ofSize: 34, weight: .light), .foregroundColor: fg.withAlphaComponent(0.5)])
        plusText.draw(at: NSPoint(x: plus.midX - plusText.size().width / 2, y: plus.midY - plusText.size().height / 2))
        if let surface { // the glass follows the cards: a lens on the selection's card (else the shown one)
            surface.panels = [GlassSurface.Shape(rect: bounds, radius: Double(radius), tint: LiquidTint.glass)]
            let selectedCard = selectedWindow.flatMap { MacWindow.allWindowsMap[$0]?.nodeWorkspace?.name } ?? focused.name
            let rect = { (name: String?) in name.flatMap { n in self.cards.first { $0.workspace == n }?.rect } }
            surface.selection = rect(selectedCard).map { GlassSurface.Shape(rect: $0.insetBy(dx: -4, dy: -4), radius: 20, tint: LiquidTint.lens) }
            surface.hover = rect(hoveredCard).map { GlassSurface.Shape(rect: $0.insetBy(dx: -4, dy: -4), radius: 20, tint: LiquidTint.hover) }
        }
        // the search, in the strip's top margin
        if !query.isEmpty || activeMode == overviewSearchModeId {
            NSAttributedString(string: PanelFont.caps("search: ") + query, attributes: [
                .font: PanelFont.label(11, weight: .semibold), .foregroundColor: accent,
            ]).draw(at: NSPoint(x: padding + 2, y: 2))
        }
        // dragged card (alt): an outline under the cursor
        if let pressedCard, let dragPoint {
            let rect = pressedCard.rect.offsetBy(dx: dragPoint.x - pressedCard.start.x, dy: dragPoint.y - pressedCard.start.y)
            let ghost = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            accent.withAlphaComponent(0.18).setFill()
            ghost.fill()
            ghost.lineWidth = 2
            accent.setStroke()
            ghost.stroke()
            NSAttributedString(string: pressedCard.workspace, attributes: [.font: PanelFont.dots(22), .foregroundColor: accent])
                .draw(at: NSPoint(x: rect.minX + 10, y: rect.minY + 8))
        }
        // dragged window under the cursor
        if let pressed, let dragPoint {
            let rect = NSRect(x: dragPoint.x - pressed.offset.x, y: dragPoint.y - pressed.offset.y, width: pressed.size.width, height: pressed.size.height)
            drawWindow(pressed.windowId, in: rect, theme: theme, alpha: 0.8)
        }
    }

    /// Windows at their layout position, scaled from the workspace monitor into the card.
    @MainActor
    private func drawWindows(of workspace: Workspace, in card: NSRect, theme: [String: NSColor]) {
        let area = workspace.workspaceMonitor.visibleRect
        let scale = min(card.width / area.width, card.height / area.height)
        for window in workspace.allLeafWindowsRecursive {
            let rect: NSRect
            if let r = window.lastAppliedLayoutPhysicalRect {
                rect = NSRect(x: card.minX + (r.topLeftX - area.topLeftX) * scale,
                              y: card.minY + (r.topLeftY - area.topLeftY) * scale,
                              width: r.width * scale, height: r.height * scale).insetBy(dx: 3, dy: 3)
            } else if let size = window.lastFloatingSize { // floating: no layout rect, centered at its size
                let w = min(size.width * scale, card.width - 6), h = min(size.height * scale, card.height - 6)
                rect = NSRect(x: card.midX - w / 2, y: card.midY - h / 2, width: w, height: h)
            } else {
                continue
            }
            guard rect.width > 8, rect.height > 8 else { continue }
            windowRects.append((rect, window.windowId, workspace.name))
            if pressed?.windowId == window.windowId && dragPoint != nil { continue } // drawn under the cursor
            drawWindow(window.windowId, in: rect, theme: theme, alpha: matches(window.windowId) ? 1 : 0.25)
            if window.windowId == selectedWindow { // keyboard selection
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 9, yRadius: 9)
                ring.lineWidth = 2.5
                (theme["accent"] ?? .systemBlue).setStroke()
                ring.stroke()
            }
        }
        // pinned windows of the screen's other workspaces: shown on every card, see through
        let pinned = Workspace.all.filter { $0 != workspace && $0.workspaceMonitor.rect.topLeftCorner == workspace.workspaceMonitor.rect.topLeftCorner }
            .flatMap(\.allLeafWindowsRecursive).filter(isPinned)
        for window in pinned {
            guard let size = window.lastFloatingSize else { continue }
            let w = min(size.width * scale, card.width - 6), h = min(size.height * scale, card.height - 6)
            drawWindow(window.windowId, in: NSRect(x: card.maxX - w - 4, y: card.minY + 4, width: w, height: h), theme: theme, alpha: 0.45)
        }
    }

    @MainActor
    private func drawWindow(_ windowId: UInt32, in rect: NSRect, theme: [String: NSColor], alpha: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image = thumbnails[windowId] {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
        } else {
            (theme["bg_hover"] ?? .gray).withAlphaComponent(0.45 * alpha).setFill()
            rect.fill()
            let iconSize = min(44, rect.width * 0.5, rect.height * 0.6)
            if let window = MacWindow.allWindowsMap[windowId], let icon = NSRunningApplication(processIdentifier: window.app.pid)?.icon {
                icon.draw(in: NSRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize),
                          from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil) // the cards are flipped
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        (theme["fg"] ?? .white).withAlphaComponent(0.12 * alpha).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: mouse: click a window = focus it, click a card = go there, drag a window = move it

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressedCard = nil
        if event.modifierFlags.contains(.option), let card = cards.first(where: { $0.rect.contains(point) && $0.workspace != newWorkspaceCard }) {
            pressed = nil
            pressedCard = (card.workspace, card.rect, point)
            return
        }
        if let hit = windowRects.last(where: { $0.rect.contains(point) }) {
            pressed = (hit.windowId, hit.workspace, NSPoint(x: point.x - hit.rect.minX, y: point.y - hit.rect.minY), hit.rect.size, point)
        } else {
            pressed = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let card = cards.first(where: { $0.rect.contains(point) })?.workspace
        if card != hoveredCard { hoveredCard = card; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredCard != nil { hoveredCard = nil; needsDisplay = true }
    }

    override func otherMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.buttonNumber == 2, let hit = windowRects.last(where: { $0.rect.contains(point) }) else { return }
        MainActor.assumeIsolated { closeFromOverview(hit.windowId) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let start = pressed?.start ?? pressedCard?.start else { return }
        if dragPoint == nil && hypot(point.x - start.x, point.y - start.y) < 5 { return }
        dragPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let card = cards.first(where: { $0.rect.contains(point) })?.workspace
        let pressed = self.pressed, dragged = dragPoint != nil, pressedCard = self.pressedCard
        self.pressed = nil
        self.pressedCard = nil
        dragPoint = nil
        needsDisplay = true
        Task { @MainActor in
            let target = card.flatMap { name in strip.flatMap { cardWorkspace(name, monitorRect: $0.monitorRect) } }
            if let pressedCard {
                if dragged, let target { await swapWorkspaces(pressedCard.workspace, target) }
                return
            }
            if let pressed, dragged {
                // dropped on another workspace: move the window there, stay in the overview
                guard let target, target != pressed.workspace else { return }
                skylandSa("untransform \(pressed.windowId)") // it may be zoomed out under the strip
                zoomedWindows.removeAll { $0.windowId == pressed.windowId }
                await runSkylandCommand("move-node-to-workspace --window-id \(pressed.windowId) \(target)")
                return
            }
            if let pressed {
                await runSkylandCommand("focus --window-id \(pressed.windowId)")
            } else if let target {
                await runSkylandCommand("workspace \(target)")
            } else {
                return // strip background: stay open
            }
            await activateMode_nonCancellable(mainModeId)
        }
    }
}

@MainActor
func runSkylandCommand(_ raw: String) async {
    guard let token: RunSessionGuard = .isServerEnabled,
          case .cmd(let command) = parseCommand(raw, allowExecAndForget: false, allowEval: false) else { return }
    try? await runLightSession(.hotkeyBinding, token) {
        _ = await command.run(.defaultEnv, .emptyStdin)
    }
}

extension Rect {
    fileprivate var args: String { "\(topLeftX) \(topLeftY) \(width) \(height)" }
}

private let themeCssPath = NSHomeDirectory() + "/.cache/skyland/theme.css"
@MainActor private var themeCache: [String: NSColor]? = nil
@MainActor private var themeWatch: DispatchSourceFileSystemObject? = nil

/// `@define-color key #rrggbb;` of the current skyland theme (~/.cache/skyland/theme.css),
/// read once per change of the file (a watcher drops the cache).
@MainActor
func skylandThemeColors() -> [String: NSColor] {
    if let themeCache { return themeCache }
    let colors = readThemeColors()
    let fd = open(themeCssPath, O_EVTONLY)
    guard fd >= 0 else { return colors } // no theme file yet: read again next time
    themeCache = colors
    let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
    watch.setEventHandler {
        MainActor.assumeIsolated { // dropped with the cache, armed again by the next read (the file may be a new one)
            themeCache = nil
            themeWatch?.cancel()
            themeWatch = nil
        }
    }
    watch.setCancelHandler { close(fd) }
    watch.resume()
    themeWatch = watch
    return colors
}

private let themeColorRegex = try! NSRegularExpression(pattern: #"@define-color\s+([A-Za-z0-9_]+)\s+#([0-9A-Fa-f]{6})\s*;"#)

private func readThemeColors() -> [String: NSColor] {
    guard let css = try? String(contentsOfFile: themeCssPath, encoding: .utf8) else { return [:] }
    var result: [String: NSColor] = [:]
    let regex = themeColorRegex
    for m in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
        guard let k = Range(m.range(at: 1), in: css), let h = Range(m.range(at: 2), in: css), let v = UInt32(css[h], radix: 16) else { continue }
        result[String(css[k])] = NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    return result
}

