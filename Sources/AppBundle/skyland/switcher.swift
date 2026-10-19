import AppKit
import Common
import SkylandGlass

// skyland window switcher (hyprswitch, cmd-tab for windows): the windows of every
// workspace, most recently focused first, with live thumbnails (ScreenCaptureKit, the
// overview capture; app icons without Screen Recording).
// `switcher next|prev` held with a modifier works like cmd-tab: it opens on the previous
// window, each press moves on, releasing the modifier focuses the selection.
// `switcher` alone stays open: type to filter by app or title, arrows / tab / ctrl-hjkl,
// enter, esc, click. Picking a window on another workspace switches to it.

/// Focused windows, most recent first (fed by checkOnFocusChangedCallbacks_nonCancellable).
@MainActor private var recentWindows: [UInt32] = []

@MainActor
func noteRecentWindow(_ windowId: UInt32?) {
    guard let windowId else { return }
    recentWindows.removeAll { $0 == windowId }
    recentWindows.insert(windowId, at: 0)
}

@MainActor private var switcher: SwitcherPanel? = nil

struct SwitcherCommand: Command {
    let args: SwitcherCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        if let switcher {
            switch args.direction {
                case .next: switcher.step(1)
                case .prev: switcher.step(-1)
                case nil: switcher.close(confirm: false)
            }
            return .succ
        }
        let items = await switcherItems(focusedOnly: args.scope == .focused)
        guard !items.isEmpty else { return .fail(io.err("No window")) }
        // the binding's modifiers, still down while it opens: releasing them confirms
        let held = args.direction == nil ? [] : NSEvent.modifierFlags.intersection([.option, .command, .control])
        let selected = switch args.direction {
            case nil: 0
            case .next: min(1, items.count - 1)
            case .prev: items.count - 1
        }
        let panel = SwitcherPanel(items: items, selected: selected, held: held)
        switcher = panel
        panel.show()
        return .succ
    }
}

struct SwitcherItem {
    let windowId: UInt32
    let app: String
    let title: String
    let workspace: String
    let icon: NSImage?
}

@MainActor
private func switcherItems(focusedOnly: Bool) async -> [SwitcherItem] {
    noteRecentWindow(focus.windowOrNil?.windowId) // first one, even before any focus change
    let windows = Workspace.all
        .filter { !$0.isScratchpad && (!focusedOnly || $0 == focus.workspace) }
        .flatMap(\.allLeafWindowsRecursive)
    let alive = Set(windows.map(\.windowId))
    recentWindows.removeAll { !alive.contains($0) } // closed windows
    let rank = Dictionary(recentWindows.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
    var items: [SwitcherItem] = []
    for window in windows.sorted(by: { (rank[$0.windowId] ?? .max) < (rank[$1.windowId] ?? .max) }) {
        items.append(SwitcherItem(
            windowId: window.windowId,
            app: window.app.name ?? "",
            title: (try? await window.getTitle(.nonCancellable)) ?? "",
            workspace: window.nodeWorkspace?.name ?? "",
            icon: NSRunningApplication(processIdentifier: window.app.pid)?.icon,
        ))
    }
    return items
}

/// Becomes key without activating skyland, to get the typed keys.
@MainActor
private final class SwitcherPanel: NSPanel {
    private let view: SwitcherView
    private let held: NSEvent.ModifierFlags
    private let previous: UInt32?
    private var monitors: [Any] = []

    init(items: [SwitcherItem], selected: Int, held: NSEvent.ModifierFlags) {
        view = SwitcherView(items: items, selected: selected)
        self.held = held
        previous = focus.windowOrNil?.windowId
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let root: NSView
        if isGlassStyle { // skylandbar's glass: panel, selection lens, hover drop
            hasShadow = false
            root = NSView()
            let surface = GlassSurface()
            surface.fluid = false // big cards: the lens slides in one piece
            root.addSubview(surface)
            view.surface = surface
        } else {
            root = makePanelRoot(radius: 28, for: self)
        }
        root.addSubview(view)
        contentView = root
        view.onPick = { [weak self] confirm in self?.close(confirm: confirm) }
    }

    override var canBecomeKey: Bool { true }

    func show() {
        let screen = nsScreen(of: focus.workspace.workspaceMonitor)
        let size = view.fittingSize(maxWidth: screen.visibleFrame.width * 0.9)
        setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                        width: size.width, height: size.height), display: false)
        view.frame = NSRect(origin: .zero, size: size)
        // the keys (esc, return, arrows, typing) come to a key panel of the active app only:
        // opened with no modifier held (a script, the CLI), they never came and it stayed (#77)
        if held.isEmpty { NSApp.activate(ignoringOtherApps: true) }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(view)
        // a click elsewhere closes it, as a menu would
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(confirm: false) }
        } as Any)
        if !held.isEmpty {
            // flagsChanged goes to the key panel (local) or, focus elsewhere, to the global monitor
            let released: (NSEvent) -> Void = { [weak self] event in
                guard let self, event.modifierFlags.intersection(self.held).isEmpty else { return }
                self.close(confirm: true)
            }
            monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { released($0); return $0 } as Any)
            monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: released) as Any)
            // released before the panel was up
            if NSEvent.modifierFlags.intersection(held).isEmpty { close(confirm: true); return }
        }
        captureWindowThumbnails(Set(view.items.map(\.windowId))) { [weak self] windowId, image in
            guard let self, switcher === self else { return } // closed meanwhile: thumbnails stay freed
            view.thumbnails[windowId] = image
            view.needsDisplay = true
        }
    }

    func step(_ delta: Int) { view.step(delta) }

    func close(confirm: Bool) {
        guard switcher === self else { return }
        switcher = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let target = confirm ? view.selectedWindowId : previous
        orderOut(nil)
        close()
        view.thumbnails = [:] // freed with the panel, like the overview
        // the key panel took the keyboard: cancelled, it goes back to the window that had it
        guard let target else { return }
        Task { @MainActor in await runSkylandCommand("focus --window-id \(target)") }
    }
}

@MainActor
private final class SwitcherView: NSView {
    let items: [SwitcherItem]
    var thumbnails: [UInt32: NSImage] = [:]
    var onPick: (Bool) -> Void = { _ in }
    private var query = ""
    private var selected: Int
    private var cards: [(rect: NSRect, index: Int)] = []
    private let cardSize = NSSize(width: 220, height: 138), labelHeight: CGFloat = 42
    private let padding: CGFloat = 18, spacing: CGFloat = 14, searchHeight: CGFloat = 30
    private var columns = 1
    /// glass style: the shapes under the cards
    weak var surface: GlassSurface?
    private var hovered: Int?

    init(items: [SwitcherItem], selected: Int) {
        self.items = items
        self.selected = selected
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        columns = max(1, min(items.count, 6, Int((maxWidth - 2 * padding + spacing) / (cardSize.width + spacing))))
        let rows = (items.count + columns - 1) / columns
        return NSSize(width: 2 * padding + CGFloat(columns) * cardSize.width + CGFloat(columns - 1) * spacing,
                      height: 2 * padding + searchHeight + CGFloat(rows) * (cardSize.height + labelHeight) + CGFloat(rows - 1) * spacing)
    }

    /// Indexes in `items` matching the query, recent first.
    private var shown: [Int] {
        guard !query.isEmpty else { return Array(items.indices) }
        return items.indices.filter { items[$0].app.localizedCaseInsensitiveContains(query) || items[$0].title.localizedCaseInsensitiveContains(query) }
    }

    var selectedWindowId: UInt32? {
        let shown = shown
        return shown.isEmpty ? nil : items[shown[min(selected, shown.count - 1)]].windowId
    }

    func step(_ delta: Int) {
        let count = shown.count
        guard count > 0 else { return }
        selected = ((min(selected, count - 1) + delta) % count + count) % count
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let ctrl = event.modifierFlags.contains(.control)
        switch (event.keyCode, ctrl ? event.charactersIgnoringModifiers ?? "" : "") {
            case (53, _): onPick(false) // esc
            case (36, _), (76, _): onPick(true) // return, enter
            case (123, _), (126, _), (_, "h"), (_, "k"): step(-1)
            case (124, _), (125, _), (_, "l"), (_, "j"): step(1)
            case (48, _): step(event.modifierFlags.contains(.shift) ? -1 : 1) // tab
            case (51, _): // delete
                if !query.isEmpty { query.removeLast(); selected = 0; needsDisplay = true }
            default:
                guard !ctrl, !event.modifierFlags.contains(.command), let chars = event.characters,
                      chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), !chars.isEmpty else { return }
                query += chars
                selected = 0
                needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = cards.first(where: { $0.rect.contains(point) })?.index
        if hit != hovered { hovered = hit; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = cards.first(where: { $0.rect.contains(point) }), let position = shown.firstIndex(of: hit.index) else { return }
        selected = position
        onPick(true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = skylandThemeColors()
        let fg = theme["fg"] ?? .white, accent = theme["accent"] ?? .systemBlue
        let glass = surface != nil
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 28, yRadius: 28)
        if !glass { // metal: a theme tint and a border; glass: its tint and its rim
            (theme["bg"] ?? .black).withAlphaComponent(0.35).setFill()
            outline.fill()
            accent.withAlphaComponent(0.35).setStroke()
            outline.stroke()
        }

        let search = query.isEmpty ? "Type to filter" : query
        NSAttributedString(string: search, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: query.isEmpty ? .regular : .semibold),
            .foregroundColor: query.isEmpty ? fg.withAlphaComponent(0.4) : fg,
        ]).draw(at: NSPoint(x: padding + 2, y: padding))

        cards = []
        let shown = shown
        let current = shown.isEmpty ? -1 : min(selected, shown.count - 1)
        for (position, index) in shown.enumerated() {
            let item = items[index]
            let column = position % columns, row = position / columns
            let card = NSRect(x: padding + CGFloat(column) * (cardSize.width + spacing),
                              y: padding + searchHeight + CGFloat(row) * (cardSize.height + labelHeight + spacing),
                              width: cardSize.width, height: cardSize.height + labelHeight)
            cards.append((card, index))
            let active = position == current
            let path = NSBezierPath(roundedRect: card, xRadius: 20, yRadius: 20) // concentric: panel 28, padding 8
            if !glass { // glass: the lens and the hover drop are the card's highlight
                (active ? accent.withAlphaComponent(0.18) : fg.withAlphaComponent(0.05)).setFill()
                path.fill()
            }
            drawThumbnail(item, in: NSRect(x: card.minX, y: card.minY, width: card.width, height: cardSize.height).insetBy(dx: 8, dy: 8), theme: theme)

            let labelTop = card.minY + cardSize.height
            item.icon?.draw(in: NSRect(x: card.minX + 10, y: labelTop, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let truncate = NSMutableParagraphStyle()
            truncate.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: item.app, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: active && !glass ? accent : fg, .paragraphStyle: truncate,
            ]).draw(in: NSRect(x: card.minX + 32, y: labelTop, width: card.width - 64, height: 16))
            NSAttributedString(string: item.workspace, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: fg.withAlphaComponent(0.55),
            ]).draw(at: NSPoint(x: card.maxX - 26, y: labelTop + 1))
            NSAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: fg.withAlphaComponent(0.6), .paragraphStyle: truncate,
            ]).draw(in: NSRect(x: card.minX + 10, y: labelTop + 18, width: card.width - 20, height: 15))

            if !glass {
                path.lineWidth = active ? 2.5 : 1
                (active ? accent : fg.withAlphaComponent(0.12)).setStroke()
                path.stroke()
            }
        }
        if let surface { // the glass follows the cards: a lens flows to the selection
            surface.panels = [GlassSurface.Shape(rect: bounds, radius: 28, tint: LiquidTint.glass)]
            let card = { (index: Int) in self.cards.first { $0.index == index }?.rect }
            surface.selection = shown.indices.contains(current) ? card(shown[current]).map { GlassSurface.Shape(rect: $0, radius: 20, tint: LiquidTint.lens) } : nil
            surface.hover = hovered.flatMap(card).map { GlassSurface.Shape(rect: $0, radius: 20, tint: LiquidTint.hover) }
        }
    }

    private func drawThumbnail(_ item: SwitcherItem, in area: NSRect, theme: [String: NSColor]) {
        if let image = thumbnails[item.windowId], image.size.width > 0, image.size.height > 0 {
            let scale = min(area.width / image.size.width, area.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let rect = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).addClip() // concentric to the card (20, inset 8)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            (theme["bg_hover"] ?? .gray).withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: area, xRadius: 12, yRadius: 12).fill()
            let edge = min(56, area.height * 0.6)
            item.icon?.draw(in: NSRect(x: area.midX - edge / 2, y: area.midY - edge / 2, width: edge, height: edge),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}
