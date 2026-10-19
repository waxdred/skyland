import AppKit

// skyland: while a tile is dragged (alt + drag) onto another tile's edge, the place it would
// take there: a translucent rect in the theme accent (#82).

@MainActor private var dropPreview: NSPanel? = nil

@MainActor
func showDropPreview(_ rect: Rect) {
    let panel = dropPreview ?? makeDropPreview()
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let frame = NSRect(x: rect.topLeftX, y: primaryHeight - rect.topLeftY - rect.height, width: rect.width, height: rect.height).insetBy(dx: 4, dy: 4)
    if panel.frame != frame { panel.setFrame(frame, display: true) }
    if !panel.isVisible { panel.orderFrontRegardless() }
}

@MainActor
func hideDropPreview() {
    dropPreview?.orderOut(nil)
}

@MainActor private func makeDropPreview() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.level = .floating
    panel.collectionBehavior = [.transient, .ignoresCycle, .canJoinAllSpaces]
    let accent = skylandThemeColors()["accent"] ?? .systemBlue
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
    view.layer?.borderColor = accent.withAlphaComponent(0.85).cgColor
    view.layer?.borderWidth = 2
    view.layer?.cornerRadius = CGFloat(max(8, config.decoration.rounding))
    panel.contentView = view
    dropPreview = panel
    return panel
}
