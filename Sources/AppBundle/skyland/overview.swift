import AppKit
import Common

// skyland workspace overview (Hyprland hyprexpo-like, without live previews):
// shown while the binding mode named "overview" is active, so it is opened,
// closed and driven by ordinary config bindings ([mode.overview.binding]).
// One card per workspace, 4 per row, windows drawn at their place in the
// layout with their app icon, in the current theme colors. Click a card to go
// there. Live window previews would need Screen Recording permission, and the
// windows of hidden workspaces are at alpha 0, so they are not captured.

let overviewModeId = "overview"

@MainActor private var panel: NSPanel? = nil

/// Called by activateMode_nonCancellable.
@MainActor
func overviewModeChanged(_ mode: String?) {
    if mode == overviewModeId { showOverview() } else { hideOverview() }
}

/// Called after every refresh: keep the cards in sync while it is open.
@MainActor
func refreshOverview() {
    panel?.contentView?.subviews.first(where: { $0 is OverviewView })?.needsDisplay = true
}

@MainActor
private func showOverview() {
    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens[0]
    let panel = panel ?? makePanel()
    panel.setFrame(screen.frame, display: false)
    panel.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
    for view in panel.contentView?.subviews ?? [] { view.frame = panel.contentView!.bounds }
    refreshOverview()
    panel.orderFrontRegardless()
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
    let root = NSView()
    let blur = NSVisualEffectView()
    blur.material = .fullScreenUI
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.autoresizingMask = [.width, .height]
    root.addSubview(blur)
    let view = OverviewView()
    view.autoresizingMask = [.width, .height]
    root.addSubview(view)
    p.contentView = root
    panel = p
    return p
}

private final class OverviewView: NSView {
    private var cards: [(rect: NSRect, workspace: String)] = []

    override var isFlipped: Bool { true } // same top-left origin as window rects

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated { drawCards() }
    }

    @MainActor
    private func drawCards() {
        let theme = overviewThemeColors()
        let fg = theme["fg"] ?? .white, accent = theme["accent"] ?? .systemBlue
        (theme["bg"] ?? .black).withAlphaComponent(0.55).setFill()
        bounds.fill()

        let workspaces = Workspace.all.sorted { lhs, rhs in
            if let l = Int(lhs.name), let r = Int(rhs.name) { return l < r }
            return lhs.name < rhs.name
        }
        guard !workspaces.isEmpty else { return }
        let columns = min(4, workspaces.count), rows = (workspaces.count + columns - 1) / columns
        let margin: CGFloat = 70, spacing: CGFloat = 28, labelHeight: CGFloat = 26
        let monitor = mainMonitorInfo.rect
        let aspect = monitor.width / max(1, monitor.height)
        var cardWidth = (bounds.width - 2 * margin - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        var cardHeight = cardWidth / aspect
        let maxHeight = (bounds.height - 2 * margin - CGFloat(rows - 1) * spacing) / CGFloat(rows) - labelHeight
        if cardHeight > maxHeight { cardHeight = maxHeight; cardWidth = cardHeight * aspect }
        let gridWidth = CGFloat(columns) * cardWidth + CGFloat(columns - 1) * spacing
        let gridHeight = CGFloat(rows) * (cardHeight + labelHeight) + CGFloat(rows - 1) * spacing
        let origin = NSPoint(x: (bounds.width - gridWidth) / 2, y: (bounds.height - gridHeight) / 2)

        cards = []
        let focused = focus.workspace
        for (index, workspace) in workspaces.enumerated() {
            let column = index % columns, row = index / columns
            let card = NSRect(x: origin.x + CGFloat(column) * (cardWidth + spacing),
                              y: origin.y + CGFloat(row) * (cardHeight + labelHeight + spacing) + labelHeight,
                              width: cardWidth, height: cardHeight)
            cards.append((card, workspace.name))
            NSAttributedString(string: workspace.name, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: workspace == focused ? accent : fg.withAlphaComponent(0.8),
            ]).draw(at: NSPoint(x: card.minX + 4, y: card.minY - labelHeight + 3))

            let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
            (theme["bg_card"] ?? .darkGray).withAlphaComponent(0.7).setFill()
            path.fill()
            drawWindows(of: workspace, in: card, theme: theme)
            path.lineWidth = workspace == focused ? 3 : 1
            (workspace == focused ? accent : fg.withAlphaComponent(0.15)).setStroke()
            path.stroke()
        }
    }

    /// Windows at their layout position, scaled from the workspace monitor into the card.
    @MainActor
    private func drawWindows(of workspace: Workspace, in card: NSRect, theme: [String: NSColor]) {
        let area = workspace.workspaceMonitor.visibleRect
        let scale = min(card.width / area.width, card.height / area.height)
        for window in workspace.allLeafWindowsRecursive {
            guard let r = window.lastAppliedLayoutPhysicalRect else { continue } // floating: no layout rect
            let rect = NSRect(x: card.minX + (r.topLeftX - area.topLeftX) * scale,
                              y: card.minY + (r.topLeftY - area.topLeftY) * scale,
                              width: r.width * scale, height: r.height * scale).insetBy(dx: 3, dy: 3)
            guard rect.width > 8, rect.height > 8 else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            (theme["bg_hover"] ?? .gray).withAlphaComponent(0.9).setFill()
            path.fill()
            let iconSize = min(56, rect.width * 0.45, rect.height * 0.55)
            if let icon = NSRunningApplication(processIdentifier: window.app.pid)?.icon {
                icon.draw(in: NSRect(x: rect.midX - iconSize / 2, y: rect.midY - iconSize / 2 - 6, width: iconSize, height: iconSize))
            }
            if let name = window.app.name, rect.height > iconSize + 30 {
                let text = NSAttributedString(string: name, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: (theme["fg_dim"] ?? .lightGray),
                ])
                let size = text.size()
                if size.width < rect.width - 8 {
                    text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY + iconSize / 2))
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let name = cards.first(where: { $0.rect.contains(point) })?.workspace else {
            Task { @MainActor in await activateMode_nonCancellable(mainModeId) } // click outside: close
            return
        }
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
