import AppKit
import Common

// skyland workspace overview, styled after the Hyprland Hyprspace plugin
// (KDE / macOS-like): a translucent glass strip slides down from the top of
// the focused screen with that screen's workspaces centered in it, the active
// one with a tinted background and an accent border, the others barely
// visible; the rest of the screen is only lightly dimmed. Shown while the
// binding mode "overview" is active, so it is driven by config bindings
// ([mode.overview.binding]); a click on a card goes there, outside closes.
// Windows are drawn at their place in the layout with their app icon (live
// previews would need Screen Recording permission, and hidden workspaces'
// windows are at alpha 0).

let overviewModeId = "overview"

@MainActor private var panel: NSPanel? = nil
@MainActor private var strip: OverviewStrip? = nil

/// Called by activateMode_nonCancellable.
@MainActor
func overviewModeChanged(_ mode: String?) {
    if mode == overviewModeId { showOverview() } else { hideOverview() }
}

/// Called after every refresh: keep the cards in sync while it is open.
@MainActor
func refreshOverview() {
    guard panel?.isVisible == true else { return }
    strip?.layoutCards()
}

@MainActor
private func showOverview() {
    let monitor = focus.workspace.workspaceMonitor
    let screen = NSScreen.screens.first { abs($0.frame.minX - monitor.rect.topLeftX) < 1 && abs($0.frame.width - monitor.rect.width) < 1 }
        ?? NSScreen.main ?? NSScreen.screens[0]
    let panel = panel ?? makePanel()
    panel.setFrame(screen.frame, display: false)
    let root = panel.contentView!
    root.frame = NSRect(origin: .zero, size: screen.frame.size)
    strip?.removeFromSuperview()
    let newStrip = OverviewStrip(monitorRect: monitor.rect, monitorVisible: monitor.visibleRect)
    strip = newStrip
    root.addSubview(newStrip)
    newStrip.layoutCards()

    // Slide down from above the screen with the windows animation curve
    let final = newStrip.frame
    newStrip.setFrameOrigin(NSPoint(x: final.minX, y: root.bounds.height))
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    let anim = config.animations
    NSAnimationContext.runAnimationGroup { context in
        context.duration = anim.enabled ? min(0.45, Double(anim.windowsMs) / 1000) : 0
        context.timingFunction = CAMediaTimingFunction(controlPoints: Float(anim.windowsBezier.x1), Float(anim.windowsBezier.y1),
                                                       Float(anim.windowsBezier.x2), Float(anim.windowsBezier.y2))
        newStrip.animator().setFrameOrigin(final.origin)
        panel.animator().alphaValue = 1
    }
}

@MainActor
private func hideOverview() {
    panel?.orderOut(nil)
}

@MainActor
private func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .popUpMenu
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.contentView = OverviewBackdrop()
    panel = p
    return p
}

/// Light dim over the whole screen; a click on it closes the overview.
private final class OverviewBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        Task { @MainActor in await activateMode_nonCancellable(mainModeId) }
    }
}

/// The glass strip: blur + theme tint, holding one card per workspace.
private final class OverviewStrip: NSView {
    let monitorRect: Rect, monitorVisible: Rect
    private let blur = NSVisualEffectView()
    private let cardsView = OverviewCards()
    private let radius: CGFloat = 20, padding: CGFloat = 18, spacing: CGFloat = 16, labelHeight: CGFloat = 22

    init(monitorRect: Rect, monitorVisible: Rect) {
        self.monitorRect = monitorRect
        self.monitorVisible = monitorVisible
        super.init(frame: .zero)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        addSubview(blur)
        addSubview(cardsView)
    }

    required init?(coder: NSCoder) { nil }

    @MainActor
    func layoutCards() {
        guard let root = superview else { return }
        let workspaces = Workspace.all
            .filter { $0.workspaceMonitor.rect.topLeftCorner == monitorRect.topLeftCorner }
            .sorted { lhs, rhs in
                if let l = Int(lhs.name), let r = Int(rhs.name) { return l < r }
                return lhs.name < rhs.name
            }
        let columns = max(1, min(6, workspaces.count)), rows = max(1, (workspaces.count + columns - 1) / columns)
        let aspect = monitorRect.width / max(1, monitorRect.height)
        var cardHeight = root.bounds.height * 0.16
        var cardWidth = cardHeight * aspect
        let maxWidth = (root.bounds.width * 0.9 - 2 * padding - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        if cardWidth > maxWidth { cardWidth = maxWidth; cardHeight = cardWidth / aspect }
        let size = NSSize(width: 2 * padding + CGFloat(columns) * cardWidth + CGFloat(columns - 1) * spacing,
                          height: 2 * padding + CGFloat(rows) * (cardHeight + labelHeight) + CGFloat(rows - 1) * spacing)
        // Below the menu bar / sketchybar of this screen (Hyprspace reservedArea)
        let top = (monitorVisible.topLeftY - monitorRect.topLeftY) + barOverlap(barHeight: config.barHeight, menuBarHeight: monitorVisible.topLeftY - monitorRect.topLeftY) + 10
        frame = NSRect(x: (root.bounds.width - size.width) / 2, y: root.bounds.height - top - size.height, width: size.width, height: size.height)
        blur.frame = bounds
        blur.maskImage = roundedMask(radius)
        cardsView.frame = bounds
        cardsView.configure(workspaces: workspaces, columns: columns, cardSize: NSSize(width: cardWidth, height: cardHeight),
                            padding: padding, spacing: spacing, labelHeight: labelHeight, radius: radius)
    }

    private func roundedMask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class OverviewCards: NSView {
    private var workspaces: [Workspace] = []
    private var cards: [(rect: NSRect, workspace: String)] = []
    private var columns = 1, cardSize = NSSize.zero
    private var padding: CGFloat = 0, spacing: CGFloat = 0, labelHeight: CGFloat = 0, radius: CGFloat = 0

    override var isFlipped: Bool { true } // same top-left origin as window rects

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
        let theme = overviewThemeColors()
        let fg = theme["fg"] ?? .white, accent = theme["accent"] ?? .systemBlue
        // Theme tint over the blur, then the strip border (Hyprspace panelBorderColor)
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        (theme["bg"] ?? .black).withAlphaComponent(0.35).setFill()
        outline.fill()
        accent.withAlphaComponent(0.35).setStroke()
        outline.lineWidth = 1
        outline.stroke()

        cards = []
        let focused = focus.workspace
        for (index, workspace) in workspaces.enumerated() {
            let column = index % columns, row = index / columns
            let card = NSRect(x: padding + CGFloat(column) * (cardSize.width + spacing),
                              y: padding + CGFloat(row) * (cardSize.height + labelHeight + spacing) + labelHeight,
                              width: cardSize.width, height: cardSize.height)
            cards.append((card, workspace.name))
            let active = workspace == focused
            NSAttributedString(string: workspace.name, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: active ? .bold : .medium),
                .foregroundColor: active ? accent : fg.withAlphaComponent(0.65),
            ]).draw(at: NSPoint(x: card.minX + 2, y: card.minY - labelHeight + 2))

            let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
            // active: tinted + accent border; inactive: almost transparent (Hyprspace)
            (active ? accent.withAlphaComponent(0.16) : fg.withAlphaComponent(0.05)).setFill()
            path.fill()
            drawWindows(of: workspace, in: card, theme: theme)
            path.lineWidth = active ? 2.5 : 1
            (active ? accent : fg.withAlphaComponent(0.12)).setStroke()
            path.stroke()
        }
    }

    /// Windows at their layout position, scaled from the workspace monitor into the card.
    @MainActor
    private func drawWindows(of workspace: Workspace, in card: NSRect, theme: [String: NSColor]) {
        let area = workspace.workspaceMonitor.visibleRect
        let scale = min(card.width / area.width, card.height / area.height)
        let fg = theme["fg"] ?? .white
        for window in workspace.allLeafWindowsRecursive {
            guard let r = window.lastAppliedLayoutPhysicalRect else { continue } // floating: no layout rect
            let rect = NSRect(x: card.minX + (r.topLeftX - area.topLeftX) * scale,
                              y: card.minY + (r.topLeftY - area.topLeftY) * scale,
                              width: r.width * scale, height: r.height * scale).insetBy(dx: 3, dy: 3)
            guard rect.width > 8, rect.height > 8 else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            (theme["bg_hover"] ?? .gray).withAlphaComponent(0.45).setFill()
            path.fill()
            fg.withAlphaComponent(0.10).setStroke()
            path.lineWidth = 1
            path.stroke()
            let iconSize = min(44, rect.width * 0.5, rect.height * 0.6)
            if let icon = NSRunningApplication(processIdentifier: window.app.pid)?.icon {
                icon.draw(in: NSRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2, width: iconSize, height: iconSize))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let name = cards.first(where: { $0.rect.contains(point) })?.workspace else { return } // strip background: stay open
        Task { @MainActor in
            if let token: RunSessionGuard = .isServerEnabled {
                try? await runLightSession(.hotkeyBinding, token) { _ = Workspace.get(byName: name).focusWorkspace() }
            }
            await activateMode_nonCancellable(mainModeId)
        }
    }
}

/// `@define-color key #rrggbb;` of the current skyland theme (~/.cache/skyland/theme.css).
private func overviewThemeColors() -> [String: NSColor] {
    let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/skyland/theme.css")
    guard let css = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: NSColor] = [:]
    let regex = try! NSRegularExpression(pattern: #"@define-color\s+([A-Za-z0-9_]+)\s+#([0-9A-Fa-f]{6})\s*;"#)
    for m in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
        guard let k = Range(m.range(at: 1), in: css), let h = Range(m.range(at: 2), in: css), let v = UInt32(css[h], radix: 16) else { continue }
        result[String(css[k])] = NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    return result
}
