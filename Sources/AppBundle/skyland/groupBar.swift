import AppKit
import Common

// skyland: Hyprland groupbar. With [decoration] group-bar-height, an accordion
// container is a group: its tabs show in the whole slot (layoutAccordion), the
// other tabs are transparent (isHiddenGroupTab), and this bar sits in the strip
// left on top: one tab per child, the shown one in the theme accent, a click
// focuses it; the group's name first when it has one (groupRename.swift), a double
// click asks for it. Rebuilt after each layout of the visible workspaces.

private struct GroupTab: Equatable {
    let title: String
    let windowId: UInt32?
    let active: Bool
}

@MainActor private var bars: [ObjectIdentifier: NSPanel] = [:]
@MainActor private var barTask: Task<Void, Never>? = nil

@MainActor
func scheduleGroupBarsRefresh() {
    barTask?.cancel()
    barTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(30)) // coalesce the layouts of one refresh
        if Task.isCancelled { return }
        await refreshGroupBars()
    }
}

@MainActor
private func refreshGroupBars() async {
    let height = CGFloat(config.decoration.groupBarHeight)
    var groups: [(TilingContainer, Rect)] = []
    if height > 0 && TrayMenuModel.shared.isEnabled {
        for workspace in Workspace.all where workspace.isVisible {
            collect(workspace.rootTilingContainer, into: &groups)
        }
    }
    refreshGroupNames()
    var alive = Set<ObjectIdentifier>()
    for (group, rect) in groups {
        var tabs: [GroupTab] = []
        for child in group.children {
            let window = (child as? Window) ?? child.allLeafWindowsRecursive.first
            var title = (try? await window?.getTitle(.nonCancellable)) ?? ""
            let appName = window?.app.name ?? "window"
            if title.count <= 2 { title = title.isEmpty ? appName : "\(appName) · \(title)" } // "👻": say which app
            let extra = child.allLeafWindowsRecursive.count - 1
            tabs.append(GroupTab(title: extra > 0 ? "\(title) +\(extra)" : title, windowId: window?.windowId,
                                 active: child === group.mostRecentChild))
        }
        let id = ObjectIdentifier(group)
        alive.insert(id)
        let panel = bars[id] ?? makeBarPanel()
        bars[id] = panel
        let view = panel.contentView as! GroupBarView
        view.onRename = { [weak group] in
            guard let group else { return }
            askGroupName(group, refocus: focus.windowOrNil?.windowId)
        }
        // AeroSpace rects: top-left origin on the main screen; AppKit: bottom-left
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(x: rect.topLeftX, y: mainHeight - rect.topLeftY - height, width: rect.width, height: height - 2)
        let name = groupNames[id]
        if panel.frame == frame && view.tabs == tabs && view.name == name && panel.isVisible { continue } // nothing to move or redraw
        panel.setFrame(frame, display: false)
        if view.tabs != tabs { view.tabs = tabs }
        if view.name != name { view.name = name }
        panel.orderFrontRegardless()
    }
    for (id, panel) in bars where !alive.contains(id) {
        panel.orderOut(nil)
        bars[id] = nil
    }
}

/// Accordion containers of a tree with a laid out rect (nested groups too).
@MainActor
private func collect(_ container: TilingContainer, into groups: inout [(TilingContainer, Rect)]) {
    if container.layout == .accordion, let rect = container.lastAppliedLayoutPhysicalRect {
        groups.append((container, rect))
    }
    for child in container.children {
        if let sub = child as? TilingContainer { collect(sub, into: &groups) }
    }
}

@MainActor
private func makeBarPanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1) // over tiles, under floating windows
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.contentView = GroupBarView()
    return panel
}

private final class GroupBarView: NSView {
    var tabs: [GroupTab] = [] { didSet { needsDisplay = true } }
    /// the group's name, first in the bar
    var name: String? { didSet { needsDisplay = true } }
    var onRename: () -> Void = {}
    let gap: CGFloat = 4

    private let nameFont = NSFont.systemFont(ofSize: 12, weight: .bold)

    /// The name's chip: as wide as its text, at most a third of the bar.
    private var nameRect: NSRect? {
        guard let name else { return nil }
        let text = (name as NSString).size(withAttributes: [.font: nameFont]).width
        return NSRect(x: 0, y: 0, width: min(bounds.width / 3, text + 24), height: bounds.height)
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tabRect(_ index: Int) -> NSRect {
        let start = nameRect.map { $0.maxX + gap } ?? 0
        let width = (bounds.width - start - gap * CGFloat(max(0, tabs.count - 1))) / CGFloat(max(1, tabs.count))
        return NSRect(x: start + CGFloat(index) * (width + gap), y: 0, width: width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = MainActor.assumeIsolated { skylandThemeColors() }
        let accent = colors["accent"] ?? .controlAccentColor
        let card = colors["bg_card"] ?? NSColor(white: 0.18, alpha: 1)
        let fg = colors["fg"] ?? .white, dim = colors["fg_dim"] ?? .lightGray
        let background = colors["bg"] ?? .black
        let radius = CGFloat(MainActor.assumeIsolated { config.decoration.rounding })
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center
        if let name, let rect = nameRect { // an outlined chip in the accent, the name bold
            let chip = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: min(radius, rect.height / 2), yRadius: min(radius, rect.height / 2))
            background.withAlphaComponent(0.85).setFill()
            chip.fill()
            accent.setStroke()
            chip.lineWidth = 1.5
            chip.stroke()
            let text = NSAttributedString(string: name, attributes: [.font: nameFont, .foregroundColor: accent, .paragraphStyle: style])
            let textHeight = nameFont.ascender - nameFont.descender
            text.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - textHeight / 2, width: rect.width - 16, height: textHeight))
        }
        for (index, tab) in tabs.enumerated() {
            let rect = tabRect(index)
            (tab.active ? accent : card.withAlphaComponent(0.85)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(radius, rect.height / 2), yRadius: min(radius, rect.height / 2)).fill()
            let font = NSFont.systemFont(ofSize: 12, weight: tab.active ? .semibold : .regular)
            let text = NSAttributedString(string: tab.title, attributes: [
                .font: font, .foregroundColor: tab.active ? background : dim.blended(withFraction: 0.2, of: fg) ?? dim, .paragraphStyle: style,
            ])
            let textHeight = font.ascender - font.descender
            text.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - textHeight / 2, width: rect.width - 16, height: textHeight))
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return onRename() } // a double click: name the group
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabs.indices.first(where: { tabRect($0).contains(point) }), let windowId = tabs[index].windowId else { return }
        Task { @MainActor in await runSkylandCommand("focus --window-id \(windowId)") }
    }
}
