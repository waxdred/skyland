import AppKit
import Common

// skyland: shows a binding mode other than main (Hyprland submap, `mode resize`), else
// easy to get stuck in. `mode-indicator = 'hud'` (default): a HUD at the bottom of the
// screen with the mode name and its bindings, while the mode is active. 'bar': the
// sketchybar item and event (bar.swift). The overview shows itself.
// Drag the HUD to move it: its place is remembered (UserDefaults).

@MainActor private var modeHud: NSPanel? = nil
@MainActor private var barShowsMode = false
@MainActor private var modeHudMoved: NSObjectProtocol? = nil

/// Called by activateMode_nonCancellable.
@MainActor
func modeIndicatorChanged(_ mode: String?) {
    let shown = mode.flatMap { $0 == mainModeId || $0 == overviewModeId || $0 == overviewSearchModeId ? nil : $0 }
    modeHud?.orderOut(nil)
    modeHud = nil
    modeHudMoved.map(NotificationCenter.default.removeObserver)
    modeHudMoved = nil
    if config.modeIndicator == "bar" || barShowsMode { // also hides it after a switch to 'hud' / 'off'
        barShowsMode = config.modeIndicator == "bar" && shown != nil
        updateBarMode(barShowsMode ? shown : nil)
    }
    guard let shown, config.modeIndicator == "hud" else { return }
    let hud = makeModeHud(shown, bindings: config.modes[shown]?.bindings.values.sorted { $0.descriptionWithKeyNotation < $1.descriptionWithKeyNotation } ?? [])
    modeHud = hud
    // dragged by the user (isMovableByWindowBackground): remembered for the next time
    modeHudMoved = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: hud, queue: .main) { _ in
        MainActor.assumeIsolated { UserDefaults.standard.set(NSStringFromPoint(hud.frame.origin), forKey: modeHudOriginKey) }
    }
}

@MainActor
private func makeModeHud(_ mode: String, bindings: [HotkeyBinding]) -> NSPanel {
    let theme = skylandThemeColors()
    let accent = theme["accent"] ?? .systemBlue
    let keyWidth = bindings.map(\.descriptionWithKeyNotation.count).max() ?? 0
    let text = NSMutableAttributedString(string: mode.uppercased() + "\n", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: accent,
    ])
    for binding in bindings.prefix(24) {
        let key = binding.descriptionWithKeyNotation.padding(toLength: keyWidth + 3, withPad: " ", startingAt: 0)
        text.append(NSAttributedString(string: "\n" + key, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.labelColor,
        ]))
        text.append(NSAttributedString(string: binding.commandText, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    }
    let label = NSTextField(labelWithAttributedString: text)
    label.lineBreakMode = .byTruncatingTail
    let fit = label.fittingSize
    let size = NSSize(width: min(520, fit.width + 40), height: fit.height + 32)
    label.frame = NSRect(x: 20, y: 16, width: size.width - 40, height: fit.height)

    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
    var origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 40)
    if let saved = UserDefaults.standard.string(forKey: modeHudOriginKey).map(NSPointFromString),
       NSScreen.screens.contains(where: { $0.frame.contains(saved) }) { // the screen it was on may be gone
        origin = saved
    }
    let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
    panel.appearance = NSAppearance(named: .darkAqua)
    let glass = makePanelRoot(radius: 16, for: panel) // ui-style
    glass.frame = NSRect(origin: .zero, size: size)
    glass.addSubview(label)
    let handle = DragHandle(frame: glass.bounds) // over the label, which would take the clicks
    glass.addSubview(handle)
    panel.contentView = glass
    panel.orderFrontRegardless()
    return panel
}

private let modeHudOriginKey = "modeHudOrigin"

/// Over the label, which would keep the clicks from moving the window.
private final class DragHandle: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
